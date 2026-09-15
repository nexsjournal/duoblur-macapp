import Foundation
import Metal
import DuoBlurCore

/// Metal 设备、队列与管线状态的共享集合。
///
/// 着色器加载走**两条路**，这是刻意的健壮性设计：
///
/// 1. **优先加载预编译的 `default.metallib`**（由 `make metallib` 离线生成）。
///    这是发布路径：着色器语法错误在构建期就暴露，运行时零编译开销。
/// 2. **退回到从 `.metal` 源码运行时编译**。Xcode 26 把 Metal 编译器拆成了
///    可下载组件（`xcodebuild -downloadComponent MetalToolchain`），没装的话
///    连 `swift build` 阶段都生不出 metallib。既然 `swift test`、CI、以及新机器上的
///    第一次 `make` 都可能撞上这种情况，就不能让整条渲染链路因此不可用。
///    代价是一次性的几十到几百毫秒编译，且只发生一次。
public final class MetalContext: @unchecked Sendable {

    public let device: MTLDevice
    public let commandQueue: MTLCommandQueue
    public let prepassPipeline: MTLRenderPipelineState
    public let compositePipeline: MTLRenderPipelineState

    /// 着色器实际来自哪里。诊断面板会显示它——如果显示"运行时编译"，
    /// 说明这台机器缺 Metal 工具链，或者 `make app` 没把 metallib 放进 bundle。
    public enum ShaderSource: Sendable, Equatable {
        case precompiledLibrary(URL)
        case runtimeCompiled
    }
    public let shaderSource: ShaderSource

    public init() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw MetalContextError.noDevice
        }
        guard let queue = device.makeCommandQueue() else {
            throw MetalContextError.noCommandQueue
        }
        self.device = device
        self.commandQueue = queue

        let library: MTLLibrary
        let resolvedSource: ShaderSource

        if let url = Self.locateMetallib(), let precompiled = try? device.makeLibrary(URL: url) {
            library = precompiled
            resolvedSource = .precompiledLibrary(url)
        } else {
            guard let sourceURL = Self.locateMetalSource(),
                  let source = try? String(contentsOf: sourceURL, encoding: .utf8) else {
                throw MetalContextError.shaderNotFound
            }
            library = try device.makeLibrary(source: source, options: nil)
            resolvedSource = .runtimeCompiled
        }
        self.shaderSource = resolvedSource

        guard let vertexFunction = library.makeFunction(name: "foldFullscreenVertex"),
              let prepassFunction = library.makeFunction(name: "foldPrepass"),
              let compositeFunction = library.makeFunction(name: "foldComposite") else {
            throw MetalContextError.missingShaderFunction
        }

        // 两个 pass 都用同一个全屏三角形顶点函数。只有片元函数不同，
        // 所以拆成两个管线状态（Metal 的管线状态包含片元函数，不能共用）。
        func makePipeline(_ fragment: MTLFunction, label: String) throws -> MTLRenderPipelineState {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.label = label
            descriptor.vertexFunction = vertexFunction
            descriptor.fragmentFunction = fragment
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            return try device.makeRenderPipelineState(descriptor: descriptor)
        }

        self.prepassPipeline = try makePipeline(prepassFunction, label: "foldPrepass")
        self.compositePipeline = try makePipeline(compositeFunction, label: "foldComposite")
    }

    /// 单通道渲染，`label` 只用于 GPU 调试器里辨认。
    /// 返回 nil 表示调用方应放弃这一帧（而不是崩溃）。
    public func makeCommandBuffer(label: String) -> MTLCommandBuffer? {
        let buffer = commandQueue.makeCommandBuffer()
        buffer?.label = label
        return buffer
    }

    // MARK: 着色器定位

    /// 查找顺序覆盖三种运行形态：`.app` bundle、`swift run` 的可执行文件旁边、以及测试。
    private static func locateMetallib() -> URL? {
        var candidates: [URL] = []
        if let override = ProcessInfo.processInfo.environment["DUOBLUR_METALLIB"] {
            candidates.append(URL(fileURLWithPath: override))
        }
        if let resource = Bundle.main.url(forResource: "default", withExtension: "metallib") {
            candidates.append(resource)
        }
        candidates.append(Bundle.main.bundleURL.appendingPathComponent("default.metallib"))
        candidates.append(
            Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("default.metallib")
        )
        // 仓库根目录下的 build/default.metallib（`make metallib` 的产物）
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        candidates.append(cwd.appendingPathComponent("build/default.metallib"))
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    private static func locateMetalSource() -> URL? {
        var candidates: [URL] = []
        if let override = ProcessInfo.processInfo.environment["DUOBLUR_METAL_SOURCE"] {
            candidates.append(URL(fileURLWithPath: override))
        }
        if let resource = Bundle.main.url(forResource: "DuoFold", withExtension: "metal") {
            candidates.append(resource)
        }
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        candidates.append(cwd.appendingPathComponent("Sources/DuoBlurRender/Shaders/DuoFold.metal"))
        // 从可执行文件位置往上找仓库根（应对在别的目录启动）
        var directory = Bundle.main.bundleURL
        for _ in 0..<4 {
            candidates.append(
                directory.appendingPathComponent("Sources/DuoBlurRender/Shaders/DuoFold.metal")
            )
            directory = directory.deletingLastPathComponent()
        }
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }
}

public enum MetalContextError: Error, CustomStringConvertible {
    case noDevice
    case noCommandQueue
    case shaderNotFound
    case missingShaderFunction
    case pyramidCreationFailed

    public var description: String {
        switch self {
        case .noDevice: return "没有可用的 Metal 设备"
        case .noCommandQueue: return "无法创建 Metal 命令队列"
        case .shaderNotFound:
            return "找不到着色器：既没有 default.metallib，也没有 DuoFold.metal 源码。"
                + "请运行 make metallib（需要 Metal 工具链：xcodebuild -downloadComponent MetalToolchain）"
        case .missingShaderFunction: return "着色器缺少必要的函数入口"
        case .pyramidCreationFailed: return "无法创建模糊金字塔纹理"
        }
    }
}

/// 调试模式，与 `DuoFold.metal` 里的 `debugMode` 对应。
///
/// `pattern` 模式的价值：**验证覆盖层与着色器不需要屏幕录制权限**。
/// 有了它，"覆盖层对不对"和"捕获通不通"两件事可以分开排查，
/// 也可以在授权之前先把模糊强度/曲线/折痕调到位。
public enum FoldDebugMode: Int32, Sendable, CaseIterable {
    /// 正常：捕获 → 折页模糊
    case off = 0
    /// 直通自检：捕获 → 原样贴回 + 边框标记（验证对齐与反馈回路）
    case passthrough = 1
    /// 合成测试图案：不读捕获，着色器自己生成图案后再模糊
    case pattern = 2
    /// 通道可视化：R=面板进度 t，G=变暗系数，B=归一化模糊半径
    case channels = 3

    public var localizedName: String {
        switch self {
        case .off: return "正常"
        case .passthrough: return "直通自检"
        case .pattern: return "合成测试图案"
        case .channels: return "通道可视化"
        }
    }

    public var explanation: String {
        switch self {
        case .off: return "读取真实屏幕并生成折页模糊"
        case .passthrough: return "原样贴回捕获内容并画标记，用来确认覆盖层在最上层、几何对齐、没有自我捕获的反馈回路"
        case .pattern: return "不读取屏幕，着色器自行生成测试图案（含 1px 细网格、灰阶渐变、彩块）后再模糊。可在授权屏幕录制之前调参"
        case .channels: return "把内部的 t / 变暗系数 / 模糊半径直接画成 R/G/B，用于像素级核对着色器内部量"
        }
    }
}

/// 与 `DuoFold.metal` 里的 `struct FoldUniforms` **逐字段、逐顺序**对应。
///
/// 刻意全部使用 4 字节标量（不用 SIMD2/SIMD4）：这样两边都不存在对齐填充，
/// 不可能因为 padding 差异而错位。顺序改了必须同时改 MSL 那边——
/// `FoldUniformsTests.testLayoutMatchesShader` 会把总大小钉住。
public struct FoldUniforms: Sendable, Equatable {
    public var viewportWidth: Float = 0
    public var viewportHeight: Float = 0
    public var maxRadiusPx: Float = 0
    public var amount: Float = 0
    public var blurFloor: Float = 0
    public var rampKnee: Float = 0.85
    public var rampExp: Float = 1.25
    public var dimAmount: Float = 1
    public var dimReach: Float = 0.55
    public var dimHingeFloor: Float = 0
    public var hingeLineStrength: Float = 0.035
    public var rimStrength: Float = 0.025
    public var grazingStrength: Float = 0.2
    public var reflection: Float = 1
    public var topInsetPx: Float = 0
    public var sigmaPerLevel: Float = 0.9
    public var captureUVScaleX: Float = 1
    public var captureUVScaleY: Float = 1
    public var captureUVOffsetX: Float = 0
    public var captureUVOffsetY: Float = 0
    public var spatialMode: Int32 = 2
    public var hingeOnRight: Int32 = 1
    public var levels: Int32 = 10
    public var debugMode: Int32 = 0

    /// 4 字节 × 24 个字段 = 96 字节，不存在任何填充。
    /// 这个常量是"MSL 与 Swift 布局一致"的锚点，由单测钉住。
    public static let strideInBytes = 96

    public init() {}

    /// 从效果参数与当前屏几何生成 uniforms。
    ///
    /// - Parameters:
    ///   - parameters: 效果参数（pt 单位）
    ///   - viewportPx: 输出的物理像素尺寸
    ///   - pointPixelScale: 每 pt 对应多少像素（Retina 上为 2）
    ///   - amount: 已含弹簧的折叠量
    ///   - hingeOnRight: 铰链是否在屏幕右边缘
    ///   - levels: 金字塔层数
    ///   - geometry: 捕获帧与显示器的映射，用来填 captureUV* 那四个字段
    ///   - debugMode: 调试模式
    public init(
        parameters: FoldParameters,
        viewportPx: CGSize,
        pointPixelScale: Double,
        amount: Double,
        hingeOnRight: Bool,
        levels: Int,
        geometry: DisplayGeometry,
        debugMode: FoldDebugMode = .off
    ) {
        viewportWidth = Float(viewportPx.width)
        viewportHeight = Float(viewportPx.height)
        maxRadiusPx = Float(parameters.maxRadiusPt * pointPixelScale)
        self.amount = Float(AngleUtils.clampUnit(amount))
        blurFloor = Float(parameters.blurFloor)
        rampKnee = Float(parameters.rampKnee)
        rampExp = Float(parameters.rampExp)
        dimAmount = Float(parameters.dimAmount)
        dimReach = Float(parameters.dimReach)
        dimHingeFloor = Float(parameters.dimHingeFloor)
        hingeLineStrength = Float(parameters.hingeLineStrength)
        rimStrength = Float(parameters.rimStrength)
        grazingStrength = Float(parameters.grazingStrength)
        reflection = Float(parameters.reflection)
        topInsetPx = Float(parameters.topInsetPt * pointPixelScale)
        sigmaPerLevel = Float(parameters.sigmaPerLevel)
        captureUVScaleX = Float(geometry.captureUVScale.width)
        captureUVScaleY = Float(geometry.captureUVScale.height)
        captureUVOffsetX = Float(geometry.captureUVOffset.x)
        captureUVOffsetY = Float(geometry.captureUVOffset.y)
        spatialMode = parameters.spatialMode.shaderValue
        self.hingeOnRight = hingeOnRight ? 1 : 0
        self.levels = Int32(levels)
        self.debugMode = debugMode.rawValue
    }
}

/// 捕获帧 ↔ 显示器 的映射。**绝不假设 1:1。**
///
/// 需要它的原因：`SCContentFilter.includeMenuBar`（14.2+）、`contentRect`、
/// `contentScale` 都会让捕获帧与显示器尺寸/原点不一致。不处理的话表现是画面整体
/// 偏移或拉伸——一种很难从症状倒推到原因的 bug。所以映射只在这一个类型里算，
/// 并以"纯缩放 + 平移"的仿射形式传给着色器。
public struct DisplayGeometry: Sendable, Equatable {

    /// 显示器尺寸（pt）
    public let displayPointSize: CGSize
    /// 捕获内容在显示器坐标系中的位置与大小（pt，左上原点）
    public let contentRect: CGRect
    /// 捕获倍率（px per pt）
    public let contentScale: Double
    /// 捕获纹理的像素尺寸
    public let capturePixelSize: CGSize

    /// 显示器 uv → 捕获 uv 的缩放。
    public var captureUVScale: CGSize {
        guard contentRect.width > 0, contentRect.height > 0 else { return CGSize(width: 1, height: 1) }
        return CGSize(
            width: displayPointSize.width / contentRect.width,
            height: displayPointSize.height / contentRect.height
        )
    }

    /// 显示器 uv → 捕获 uv 的平移。
    public var captureUVOffset: CGPoint {
        guard contentRect.width > 0, contentRect.height > 0 else { return .zero }
        return CGPoint(
            x: -contentRect.origin.x / contentRect.width,
            y: -contentRect.origin.y / contentRect.height
        )
    }

    /// 是否逐像素 1:1（正常情况应为 true；不为 true 时会在诊断面板里显示出来）。
    public var isPixelExact: Bool {
        abs(captureUVScale.width - 1) < 1e-6
            && abs(captureUVScale.height - 1) < 1e-6
            && abs(captureUVOffset.x) < 1e-6
            && abs(captureUVOffset.y) < 1e-6
    }

    /// 捕获像素与显示器像素是否同尺寸（用于判断要不要走缩放路径）
    public var isSamePixelSize: Bool {
        abs(capturePixelSize.width - displayPointSize.width * contentScale) < 1.5
            && abs(capturePixelSize.height - displayPointSize.height * contentScale) < 1.5
    }

    public static func identity(pointSize: CGSize, scale: Double) -> DisplayGeometry {
        DisplayGeometry(
            displayPointSize: pointSize,
            contentRect: CGRect(origin: .zero, size: pointSize),
            contentScale: scale,
            capturePixelSize: CGSize(width: pointSize.width * scale, height: pointSize.height * scale)
        )
    }
}
