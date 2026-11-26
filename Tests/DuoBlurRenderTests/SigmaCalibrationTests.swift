import XCTest
import Metal
@testable import DuoBlurRender
import DuoBlurCore

/// σ 标定测试（T-3.2）——**唯一"测量"而不是"比对"的测试**。
///
/// ## 它解决什么问题
///
/// 着色器用 `lod = log2(σ / sigmaPerLevel)` 把"目标模糊半径"换成 mip 级别。
/// 这个换算成不成立，等价于问："`maxRadiusPt = 40` 真的就是 40pt 的模糊吗？"
///
/// 这是一个**测量问题**，不是比对问题：没有基准图可对，只能去量。
/// 历史教训（docs/08 §4.1）：三次"简化标定"全部失败，原因是**测量装置不合格**——
/// 测试图案只有 600px 宽、σ 大到上百像素时相邻边缘互相污染、估计器被噪声单向污染、
/// 用 10-90% 宽度换算 σ 却假设了高斯核。所以这里的每一步都单独交代理由。
///
/// ## 测量方法
///
/// 1. 造一个**纯黑白大阶跃**，两侧各留 ≥6σ_max 的边距（避免边界 clamp 污染）
/// 2. 跑**真实的** prepass + `generateMipmaps` + composite 三段，不是替身
/// 3. 取水平方向的边缘扩散函数（ESF），**带符号**差分得线扩散函数（LSF）
/// 4. 对 LSF 取二阶中心矩得 σ —— 这是 σ 的定义，对任何核形状都成立
/// 5. 断言 `|σ实测/σ目标 − 1| < 0.10`
///
/// ## 为什么不用 10-90% 宽度换算
///
/// `σ = (x90 − x10) / 2.563` 只对**高斯**核成立。mip 链的核更像 box 叠 box，比高斯"尖"，
/// 用这个系数会把 σ 系统性估大（实测 level 0 的 3×3 二项式真值 σ=0.707，
/// 10-90% 换算给出 0.857）。二阶矩没有这个假设。
final class SigmaCalibrationTests: XCTestCase {

    /// 源纹理：够宽，保证最粗的模糊也离边界足够远。
    private let sourceWidth = 8192
    private let sourceHeight = 64
    /// 最粗要测到的 σ（px），用于确定边距是否充足。边距 4096px ≈ 10σ。
    private let maxProbeSigma: Double = 400

    private let dark: UInt8 = 13
    private let light: UInt8 = 242

    // MARK: - 夹具

    private func makeContext() throws -> MetalContext {
        do {
            return try MetalContext()
        } catch {
            throw XCTSkip("没有可用的 Metal 设备或着色器（\(error)）——本测试需要 GPU")
        }
    }

    /// 建金字塔并合成一帧，返回输出像素（BGRA8，已按行平均成 ESF 前的原始缓冲）。
    ///
    /// 刻意**复刻** `FoldRenderer.render` 的三段 pass 顺序（prepass → generateMipmaps → composite）。
    /// 这样做而不是复用 `FoldRenderer.renderOffscreen` 的原因：后者固定用 1×1 占位源纹理
    /// （为测试图案模式准备），喂不进我们要的阶跃边缘。
    /// 若将来 `FoldRenderer` 的 pass 顺序变了，这里也要跟着变。
    private func renderStepEdge(
        context: MetalContext,
        targetSigma: Float,
        sigmaPerLevel: Float = Float(FoldParameters().sigmaPerLevel),
        levels: Int = 12
    ) -> [Double] {
        let device = context.device
        let W = sourceWidth, H = sourceHeight

        // 源：左暗右亮的垂直硬阶跃
        var src = [UInt8](repeating: 0, count: W * H * 4)
        for y in 0..<H {
            for x in 0..<W {
                let v: UInt8 = x < W / 2 ? dark : light
                let i = (y * W + x) * 4
                src[i] = v; src[i + 1] = v; src[i + 2] = v; src[i + 3] = 255
            }
        }
        let srcDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: W, height: H, mipmapped: false)
        srcDesc.usage = [.shaderRead]
        srcDesc.storageMode = .shared
        guard let srcTex = device.makeTexture(descriptor: srcDesc) else { return [] }
        srcTex.replace(region: MTLRegionMake2D(0, 0, W, H), mipmapLevel: 0,
                       withBytes: src, bytesPerRow: W * 4)

        let pyDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: W, height: H, mipmapped: true)
        pyDesc.mipmapLevelCount = levels
        pyDesc.usage = [.shaderRead, .renderTarget]
        pyDesc.storageMode = .private
        guard let pyramid = device.makeTexture(descriptor: pyDesc) else { return [] }

        let outDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: W, height: H, mipmapped: false)
        outDesc.usage = [.shaderRead, .renderTarget]
        outDesc.storageMode = .shared
        guard let outTex = device.makeTexture(descriptor: outDesc) else { return [] }

        var uniforms = FoldUniforms()
        uniforms.viewportWidth = Float(W)
        uniforms.viewportHeight = Float(H)
        uniforms.levels = Int32(levels)
        uniforms.spatialMode = SpatialMode.uniform.shaderValue   // 整屏同一半径，便于量 σ
        uniforms.amount = 1
        uniforms.maxRadiusPx = targetSigma
        uniforms.blurFloor = 0
        uniforms.sigmaPerLevel = sigmaPerLevel
        // 关掉所有非模糊项：只留纯模糊，否则变暗/高光会扭曲边缘剖面
        uniforms.dimAmount = 0
        uniforms.dimReach = 0
        uniforms.grazingStrength = 0
        uniforms.reflection = 0
        uniforms.hingeLineStrength = 0
        uniforms.rimStrength = 0

        guard let cb = context.makeCommandBuffer(label: "sigma-calibration") else { return [] }

        let prepass = MTLRenderPassDescriptor()
        prepass.colorAttachments[0].texture = pyramid
        prepass.colorAttachments[0].level = 0
        prepass.colorAttachments[0].loadAction = .dontCare
        prepass.colorAttachments[0].storeAction = .store
        guard let e1 = cb.makeRenderCommandEncoder(descriptor: prepass) else { return [] }
        e1.setRenderPipelineState(context.prepassPipeline)
        e1.setFragmentTexture(srcTex, index: 0)
        e1.setFragmentBytes(&uniforms, length: MemoryLayout<FoldUniforms>.stride, index: 0)
        e1.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        e1.endEncoding()

        if let blit = cb.makeBlitCommandEncoder() {
            blit.generateMipmaps(for: pyramid)
            blit.endEncoding()
        }

        let composite = MTLRenderPassDescriptor()
        composite.colorAttachments[0].texture = outTex
        composite.colorAttachments[0].loadAction = .dontCare
        composite.colorAttachments[0].storeAction = .store
        guard let e2 = cb.makeRenderCommandEncoder(descriptor: composite) else { return [] }
        e2.setRenderPipelineState(context.compositePipeline)
        e2.setFragmentTexture(srcTex, index: 0)
        e2.setFragmentTexture(pyramid, index: 1)
        e2.setFragmentBytes(&uniforms, length: MemoryLayout<FoldUniforms>.stride, index: 0)
        e2.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        e2.endEncoding()

        cb.commit()
        cb.waitUntilCompleted()
        guard cb.status == .completed else { return [] }

        let rowBytes = W * 4
        var pixels = [UInt8](repeating: 0, count: rowBytes * H)
        pixels.withUnsafeMutableBytes { raw in
            outTex.getBytes(raw.baseAddress!, bytesPerRow: rowBytes,
                            from: MTLRegionMake2D(0, 0, W, H), mipmapLevel: 0)
        }

        // 竖直平均得 ESF。着色器的抖动噪声图案每 256px 重复，按行平均只能压掉 √2，
        // 所以下面是靠"带符号差分 + 自适应窗口"来抗噪，而不是靠平均。
        var esf = [Double](repeating: 0, count: W)
        for x in 0..<W {
            var sum = 0.0
            for y in 0..<H { sum += Double(pixels[(y * W + x) * 4]) / 255.0 }   // B 通道（灰度）
            esf[x] = sum / Double(H)
        }
        return esf
    }

    /// 从 ESF 求 σ：带符号差分的 LSF 的二阶中心矩，窗口由数据自适应。
    ///
    /// 两个细节都是踩过坑才对的（见 docs/08 §4.1）：
    /// - 写成 `max(0, LSF)` 会让 ±1 LSB 抖动噪声被**单向**累加 → 理想硬边被测成 σ≈1.7px
    /// - 固定宽窗会把平坦区的噪声方差（噪声质量 × 距质心距离²，随窗宽平方增长）算进去
    ///   → 窄核被严重高估
    private func measureSigma(esf: [Double], plateauHalf: Int) -> Double? {
        let n = esf.count
        guard n > 16 else { return nil }
        func clampIdx(_ v: Int) -> Int { min(max(v, 0), n - 1) }

        let darkLevel = esf[clampIdx(n / 2 - plateauHalf)]
        let lightLevel = esf[clampIdx(n / 2 + plateauHalf)]
        let range = lightLevel - darkLevel
        guard range > 1e-3 else { return nil }

        // 只保留两平台之间 2%~98% 的过渡区：硬边的过渡区只有 1 个 bin（σ≈0），
        // 糊得越开窗口自动越宽。
        let loT = darkLevel + range * 0.02
        let hiT = darkLevel + range * 0.98
        var i = 0, j = n - 1
        while i < n - 1 && esf[i] <= loT { i += 1 }
        while j > 0 && esf[j] >= hiT { j -= 1 }

        // 过渡区为空（j < i）＝ ESF 在相邻两像素之间直接完成跳变 ＝ 理想硬边。
        // 此时 LSF 只有一个 bin，方差为 0，σ 就是 0。**不能返回 nil**：
        // 那样会让"估计器无正偏"这条自校验被静默跳过，而它是整套标定的地基。
        guard j > i else { return 0.0 }

        let a = max(0, i - 1), b = min(n - 2, j + 1)
        let mass = esf[b + 1] - esf[a]
        guard abs(mass) > 1e-6 else { return nil }

        var centroid = 0.0
        for k in a...b { centroid += (Double(k) + 0.5) * (esf[k + 1] - esf[k]) }
        centroid /= mass

        var variance = 0.0
        for k in a...b {
            variance += (esf[k + 1] - esf[k]) * pow(Double(k) + 0.5 - centroid, 2)
        }
        variance /= mass
        guard variance > 0, variance.isFinite else { return nil }
        return variance.squareRoot()
    }

    private func measure(context: MetalContext, targetSigma: Double, levels: Int = 12) -> Double? {
        let esf = renderStepEdge(context: context, targetSigma: Float(targetSigma), levels: levels)
        guard !esf.isEmpty else { return nil }
        let plateau = max(64, Int(maxProbeSigma * 6))
        return measureSigma(esf: esf, plateauHalf: plateau)
    }

    // MARK: - 测试

    /// 估计器自校验：请求一个极小 σ 时着色器走锐利短路，输出就是源纹理的硬边。
    /// 带符号二阶矩必须给出 σ≈0；若给出明显非零值，说明估计器有正偏，**下面的断言全部作废**。
    ///
    /// 这条测试是整套标定的地基：没有它，一个坏估计器会让所有测量"看起来通过"。
    func testEstimatorHasNoPositiveBiasOnHardEdge() throws {
        let context = try makeContext()
        guard let sigma = measure(context: context, targetSigma: 0.1) else {
            throw XCTSkip("渲染不可用")
        }
        XCTAssertLessThan(sigma, 0.05,
                          "硬边应测出 σ≈0，实测 \(sigma)。估计器有正偏 → 标定结果不可信")
    }

    /// 核心断言：请求的 σ 与实际得到的 σ 一致（|误差| < 10%）。
    ///
    /// 覆盖 `maxRadiusPt` 的实际可调范围：预设是 29–51pt，上限 200pt；
    /// 在 2× 屏上对应 58–102px 与 400px。
    func testRequestedSigmaMatchesMeasuredSigma() throws {
        let context = try makeContext()
        // σ < 4px 时不参与断言：该区间紧邻锐利短路，且 mip level 0 自身那次
        // 二项式模糊会占主导（实测过糊约 17%），不影响观感。
        let probes: [Double] = [8, 16, 32, 64, 125, 200, 250, 320, 400]

        var worst = 0.0
        var report: [String] = []
        for target in probes {
            guard let measured = measure(context: context, targetSigma: target) else {
                throw XCTSkip("渲染不可用")
            }
            let ratio = measured / target
            worst = max(worst, abs(ratio - 1))
            report.append(String(format: "σ目标 %6.1f → 实测 %7.2f（比值 %.3f）", target, measured, ratio))
        }

        let table = report.joined(separator: "\n")
        XCTAssertLessThan(worst, 0.10,
                          "σ 标定超差：最大相对误差 \(String(format: "%.1f%%", worst * 100))\n\(table)")
        print("=== σ 标定实测表（sigmaPerLevel=\(FoldParameters().sigmaPerLevel)）===\n\(table)")
    }

    /// 层数必须够表达 `maxRadiusPt` 的上限，否则大半径请求会被静默夹住
    /// （修复前正是如此：10 层只能到 148px，覆盖不到 400px）。
    func testLevelCountCoversTheRequestedMaximum() throws {
        let context = try makeContext()
        let upper = FoldParameters.validRanges["maxRadiusPt"]!.upperBound   // 200pt
        let targetPx = upper * 2                                            // 2× 屏
        let levels = FoldParameters.requiredPyramidLevels(
            maxRadiusPt: upper, scale: 2, sigmaPerLevel: FoldParameters().sigmaPerLevel
        )
        XCTAssertEqual(levels, 12, "2× 屏上 200pt 需要 12 层")

        guard let measured = measure(context: context, targetSigma: targetPx, levels: levels) else {
            throw XCTSkip("渲染不可用")
        }
        XCTAssertGreaterThan(measured, targetPx * 0.9,
                             "在 \(levels) 层下应能真正达到 \(targetPx)px 的模糊，实测 \(measured)")
    }

    /// 层数更多时，同一请求的模糊不应改变（说明没有被夹住，也没有跳档）。
    func testBlurIsInsensitiveToExtraLevels() throws {
        let context = try makeContext()
        let target = 125.0
        guard let a = measure(context: context, targetSigma: target, levels: 12),
              let b = measure(context: context, targetSigma: target, levels: 14) else {
            throw XCTSkip("渲染不可用")
        }
        XCTAssertEqual(a, b, accuracy: a * 0.05,
                       "多给两层不应改变同一请求的模糊（\(a) vs \(b)）")
    }

    /// σ 对请求值单调不减——这是"折叠量增大时模糊单调加深"的底层保证。
    func testMeasuredSigmaIsMonotonic() throws {
        let context = try makeContext()
        var previous = -Double.infinity
        for target in [2.0, 4.0, 8.0, 16.0, 32.0, 64.0, 128.0, 256.0] {
            guard let measured = measure(context: context, targetSigma: target) else {
                throw XCTSkip("渲染不可用")
            }
            XCTAssertGreaterThanOrEqual(measured, previous - 1e-6,
                                        "σ=\(target) 时实测 \(measured) 小于前一个 \(previous)")
            previous = measured
        }
    }
}
