import Foundation
import Metal
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers
import QuartzCore
import DuoBlurCore

/// 渲染统计数据。
///
/// 单独拿出来（而不是直接写 `FoldRenderer` 的字段）：`addCompletedHandler` 的闭包是
/// `@Sendable` 的，捕获非 Sendable 的 self 会触发 Swift 6 的检查。用一个受锁保护的小盒子
/// 既满足并发要求，也避免为了消警告而把整个渲染器标成 `@unchecked Sendable`。
private final class RenderStats: @unchecked Sendable {
    private let lock = NSLock()
    private var frames: UInt64 = 0
    private var error: String?

    func noteSuccess() {
        lock.lock(); defer { lock.unlock() }
        frames &+= 1
        error = nil
    }

    func noteFailure(_ message: String) {
        lock.lock(); defer { lock.unlock() }
        error = message
    }

    var snapshot: (frames: UInt64, error: String?) {
        lock.lock(); defer { lock.unlock() }
        return (frames, error)
    }
}

/// 单显示器的渲染器：金字塔 + 两个 pass。
///
/// 金字塔用**一张带 mip 链的纹理**，而不是每级一张独立纹理：
/// - 逐级渲染进 mip level（`MTLRenderPassDescriptor.colorAttachments[0].level`）
/// - 用 blit encoder 的 `generateMipmaps` 生成其余层级
/// - 合成时 `sample(sampler, uv, level(lod))` 由**硬件三线性**在相邻两级之间插值
///
/// 这样模糊半径是连续无跳档的（视觉原则 3），而且每像素只需一次纹理采样。
/// 若改成多张独立纹理 + 手动两级混合，就得动态索引资源数组或多路分支，
/// 效果相同但更慢更复杂。
public final class FoldRenderer {

    public let context: MetalContext
    private let display: DisplayInfo

    private var pyramid: MTLTexture?
    private var pyramidPixelSize: CGSize = .zero
    public private(set) var pyramidLevels: Int = 10
    private let stats = RenderStats()

    /// 诊断计数
    public var renderedFrames: UInt64 { stats.snapshot.frames }
    public var lastRenderError: String? { stats.snapshot.error }

    public init(context: MetalContext, display: DisplayInfo) {
        self.context = context
        self.display = display
    }

    /// 渲染一帧到 drawable。
    ///
    /// - Returns: 是否成功编码。false 表示这一帧应被放弃（保持图层透明），而不是崩溃。
    @discardableResult
    public func render(frame: CapturedFrame, to drawable: CAMetalDrawable, uniforms: FoldUniforms) -> Bool {
        guard let commandBuffer = context.makeCommandBuffer(label: "DuoBlur frame") else {
            stats.noteFailure("无法创建命令缓冲")
            return false
        }

        // 金字塔按**输出尺寸**（显示器物理像素）建，而不是按输入纹理尺寸。
        //
        // 这一点很关键：预过滤 pass 会把捕获帧按"显示器 uv → 捕获 uv"的映射写进
        // 金字塔 level 0，所以金字塔里的内容是**显示器坐标**下的画面，
        // 合成 pass 才能在显示器 uv 下直接采样它。测试图案模式更是完全与捕获无关。
        //
        // （曾经这里是按输入纹理尺寸建的，于是测试图案模式用 1×1 占位纹理时
        //   试图创建 10 级 mip，被 Metal 校验直接 abort。）
        guard let pyramid = ensurePyramid(
            width: drawable.texture.width,
            height: drawable.texture.height,
            levels: uniforms.levels
        ) else {
            stats.noteFailure("无法创建模糊金字塔")
            return false
        }

        var localUniforms = uniforms
        let uniformLength = MemoryLayout<FoldUniforms>.stride

        // ---- Pass 1：3×3 二项式预过滤 → 金字塔 level 0 ----
        let prepass = MTLRenderPassDescriptor()
        prepass.colorAttachments[0].texture = pyramid
        prepass.colorAttachments[0].level = 0
        prepass.colorAttachments[0].loadAction = .dontCare
        prepass.colorAttachments[0].storeAction = .store

        if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: prepass) {
            encoder.label = "foldPrepass"
            encoder.setRenderPipelineState(context.prepassPipeline)
            encoder.setFragmentTexture(frame.texture, index: 0)
            encoder.setFragmentBytes(&localUniforms, length: uniformLength, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
        } else {
            stats.noteFailure("无法创建预过滤编码器")
            return false
        }

        // ---- Pass 1.5：生成 mip 链（硬件 blit，代价约 1.33× 基础尺寸）----
        if let blit = commandBuffer.makeBlitCommandEncoder() {
            blit.label = "foldPyramid"
            blit.generateMipmaps(for: pyramid)
            blit.endEncoding()
        }

        // ---- Pass 2：Duo 折页合成 → drawable ----
        let composite = MTLRenderPassDescriptor()
        composite.colorAttachments[0].texture = drawable.texture
        composite.colorAttachments[0].loadAction = .dontCare
        composite.colorAttachments[0].storeAction = .store

        if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: composite) {
            encoder.label = "foldComposite"
            encoder.setRenderPipelineState(context.compositePipeline)
            encoder.setFragmentTexture(frame.texture, index: 0)     // 锐利路径
            encoder.setFragmentTexture(pyramid, index: 1)           // 模糊路径
            encoder.setFragmentBytes(&localUniforms, length: uniformLength, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
        } else {
            stats.noteFailure("无法创建合成编码器")
            return false
        }

        let stats = self.stats
        commandBuffer.addCompletedHandler { buffer in
            if buffer.status == .error {
                stats.noteFailure(buffer.error?.localizedDescription ?? "命令缓冲执行失败")
            } else {
                stats.noteSuccess()
            }
        }
        commandBuffer.present(drawable)
        commandBuffer.commit()
        return true
    }

    /// 按需创建/重建金字塔纹理。尺寸不变则复用（避免每帧分配 —— 渲染路径上不允许分配）。
    private func ensurePyramid(width: Int, height: Int, levels: Int32) -> MTLTexture? {
        guard width > 0, height > 0 else { return nil }
        let size = CGSize(width: width, height: height)

        // 夹住 mip 层数上限：一个 N×N 纹理最多只能有 floor(log2(N))+1 级。
        // 不夹的话 MTLTextureDescriptor 校验会直接 abort（不是抛错，是 abort）。
        let maxLevelsForSize = Int(floor(log2(Double(max(width, height))))) + 1
        let levelCount = max(1, min(Int(levels), maxLevelsForSize))

        if let pyramid, pyramidPixelSize == size, pyramid.mipmapLevelCount == levelCount {
            return pyramid
        }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: width,
            height: height,
            mipmapped: levelCount > 1
        )
        descriptor.mipmapLevelCount = levelCount
        descriptor.usage = [.shaderRead, .renderTarget]
        descriptor.storageMode = .private

        guard let texture = context.device.makeTexture(descriptor: descriptor) else {
            return nil
        }
        texture.label = "foldPyramid \(width)×\(height) level=\(levelCount)"
        pyramid = texture
        pyramidPixelSize = size
        pyramidLevels = levelCount
        return texture
    }

    /// 离屏渲染一帧并读回为 `CGImage`。
    ///
    /// 用途有两个，都很实在：
    /// 1. **定量验证**：把着色器输出写成 PNG，就能用脚本量模糊半径、色带、折痕位置，
    ///    而不是靠肉眼看截图。这是黄金图像测试的基础设施。
    /// 2. **绕开窗口**：诊断"渲染了但看不见"时，离屏结果能立刻分清是着色器的问题
    ///    还是窗口合成的问题。
    public func renderOffscreen(uniforms: FoldUniforms, size: CGSize) -> CGImage? {
        let width = Int(size.width)
        let height = Int(size.height)
        guard width > 0, height > 0 else { return nil }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false
        )
        // .shared 才能 getBytes 读回；离屏路径不在热循环里，这点开销无所谓
        descriptor.usage = [.shaderRead, .renderTarget]
        descriptor.storageMode = .shared
        guard let target = context.device.makeTexture(descriptor: descriptor) else { return nil }
        target.label = "DuoBlur offscreen target"

        var localUniforms = uniforms
        localUniforms.viewportWidth = Float(width)
        localUniforms.viewportHeight = Float(height)
        let uniformLength = MemoryLayout<FoldUniforms>.stride

        guard let commandBuffer = context.makeCommandBuffer(label: "DuoBlur offscreen"),
              let pyramid = ensurePyramid(width: width, height: height, levels: localUniforms.levels) else {
            return nil
        }

        // 一个 1×1 的占位输入纹理：实测图案模式不读它，正常/直通模式需要真实捕获，
        // 那种情况下调用方应改用窗口路径。
        let placeholderDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: 1, height: 1, mipmapped: false
        )
        placeholderDescriptor.usage = [.shaderRead]
        placeholderDescriptor.storageMode = .shared
        guard let placeholder = context.device.makeTexture(descriptor: placeholderDescriptor) else {
            return nil
        }

        let prepass = MTLRenderPassDescriptor()
        prepass.colorAttachments[0].texture = pyramid
        prepass.colorAttachments[0].level = 0
        prepass.colorAttachments[0].loadAction = .dontCare
        prepass.colorAttachments[0].storeAction = .store
        guard let prepassEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: prepass) else {
            return nil
        }
        prepassEncoder.label = "offscreen prepass"
        prepassEncoder.setRenderPipelineState(context.prepassPipeline)
        prepassEncoder.setFragmentTexture(placeholder, index: 0)
        prepassEncoder.setFragmentBytes(&localUniforms, length: uniformLength, index: 0)
        prepassEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        prepassEncoder.endEncoding()

        if let blit = commandBuffer.makeBlitCommandEncoder() {
            blit.generateMipmaps(for: pyramid)
            blit.endEncoding()
        }

        let composite = MTLRenderPassDescriptor()
        composite.colorAttachments[0].texture = target
        composite.colorAttachments[0].loadAction = .dontCare
        composite.colorAttachments[0].storeAction = .store
        guard let compositeEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: composite) else {
            return nil
        }
        compositeEncoder.label = "offscreen composite"
        compositeEncoder.setRenderPipelineState(context.compositePipeline)
        compositeEncoder.setFragmentTexture(placeholder, index: 0)
        compositeEncoder.setFragmentTexture(pyramid, index: 1)
        compositeEncoder.setFragmentBytes(&localUniforms, length: uniformLength, index: 0)
        compositeEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        compositeEncoder.endEncoding()

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        guard commandBuffer.status == .completed else { return nil }

        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        pixels.withUnsafeMutableBytes { raw in
            target.getBytes(raw.baseAddress!, bytesPerRow: bytesPerRow,
                            from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        }

        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        // **必须带 byteOrder32Little**：我们的字节序是 BGRA，只写 `.noneSkipFirst`
        // 会让 CoreGraphics 按 [skip, R, G, B] 解释，结果是 R/G 互换、第三通道变成 alpha。
        // 这个 bug 很隐蔽 —— 灰度图上完全看不出来，彩色图上颜色错位，而读通道时
        // 会得出"变暗只有 0.34、模糊半径恒为 1.0"这类彻底误导的结论。
        // `.byteOrder32Little | .noneSkipFirst` 是标准的 BGRA 声明方式。
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue)
            .union(.byteOrder32Little)
        return CGImage(
            width: width, height: height,
            bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo,
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )
    }

    /// 把一帧离屏渲染写成 PNG 文件
    @discardableResult
    public func writeFrame(
        to path: String,
        uniforms: FoldUniforms,
        size: CGSize
    ) -> Bool {
        guard let image = renderOffscreen(uniforms: uniforms, size: size) else { return false }
        let url = URL(fileURLWithPath: path)
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, "public.png" as CFString, 1, nil
        ) else { return false }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination)
    }

    /// 释放纹理资源（显示器变更或停止时调用）
    public func releaseResources() {
        pyramid = nil
        pyramidPixelSize = .zero
    }
}
