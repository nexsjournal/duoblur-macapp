import Metal
import Foundation

// ============================================================================
//  端到端 σ 标定（T-3.2 的验收口径）
//
//  请求一个目标 σ → 跑真实的 prepass + generateMipmaps + **composite** 着色器
//  → 量输出画面里阶跃边缘的实际 σ。这才是"125pt 到底有多糊"的答案。
//
//  与逐级测量相比的好处：不受单级纹理太小 / 8bit 量化的影响，且直接覆盖整条链路。
//  LSF 用**前向差分**求（v1 用中心差分把核形状抹歪了），σ 取 LSF 的二阶中心矩
//  —— 这是 σ 的定义，对任何核都成立，不依赖"假设高斯"。
// ============================================================================

struct FoldUniforms {
    var viewportWidth: Float = 0, viewportHeight: Float = 0, maxRadiusPx: Float = 0, amount: Float = 0
    var blurFloor: Float = 0, rampKnee: Float = 0.85, rampExp: Float = 1.25, dimAmount: Float = 1
    var dimReach: Float = 0.55, dimHingeFloor: Float = 0, hingeLineStrength: Float = 0.035
    var rimStrength: Float = 0.025, grazingStrength: Float = 0.2, reflection: Float = 1
    var topInsetPx: Float = 0, sigmaPerLevel: Float = 0.9
    var captureUVScaleX: Float = 1, captureUVScaleY: Float = 1
    var captureUVOffsetX: Float = 0, captureUVOffsetY: Float = 0
    var spatialMode: Int32 = 2, hingeOnRight: Int32 = 1, levels: Int32 = 10, debugMode: Int32 = 0
}

let dev = MTLCreateSystemDefaultDevice()!, q = dev.makeCommandQueue()!
let lib: MTLLibrary
if let l = try? dev.makeLibrary(URL: URL(fileURLWithPath: "build/default.metallib")) { lib = l }
else { lib = try! dev.makeLibrary(source: try! String(contentsOfFile: "Sources/DuoBlurRender/Shaders/DuoFold.metal", encoding: .utf8), options: nil) }

func makePSO(_ frag: String) -> MTLRenderPipelineState {
    let d = MTLRenderPipelineDescriptor()
    d.vertexFunction = lib.makeFunction(name: "foldFullscreenVertex")!
    d.fragmentFunction = lib.makeFunction(name: frag)!
    d.colorAttachments[0].pixelFormat = .bgra8Unorm
    return try! dev.makeRenderPipelineState(descriptor: d)
}
let prepassPSO = makePSO("foldPrepass")
let compositePSO = makePSO("foldComposite")

let W = 16384, H = 512, EX = W / 2
let DARK: UInt8 = 13, LIGHT: UInt8 = 242
var src = [UInt8](repeating: 0, count: W * H * 4)
for y in 0..<H { for x in 0..<W {
    let v: UInt8 = x < EX ? DARK : LIGHT
    let i = (y * W + x) * 4; src[i] = v; src[i+1] = v; src[i+2] = v; src[i+3] = 255
} }
let sd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: W, height: H, mipmapped: false)
sd.usage = [.shaderRead]; sd.storageMode = .shared
let srcTex = dev.makeTexture(descriptor: sd)!
srcTex.replace(region: MTLRegionMake2D(0, 0, W, H), mipmapLevel: 0, withBytes: src, bytesPerRow: W * 4)

let LEVELS: Int32 = 12          // 验证修正后的层数需求
let pd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: W, height: H, mipmapped: true)
pd.mipmapLevelCount = Int(LEVELS)
pd.usage = [.shaderRead, .renderTarget]; pd.storageMode = .private
let pyramid = dev.makeTexture(descriptor: pd)!

// 输出纹理（composite 的目标），_shared 才能读回
let od = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: W, height: H, mipmapped: false)
od.usage = [.shaderRead, .renderTarget]; od.storageMode = .shared
let outTex = dev.makeTexture(descriptor: od)!

func buildPyramid() {
    var u = FoldUniforms()
    u.viewportWidth = Float(W); u.viewportHeight = Float(H); u.levels = LEVELS
    let cb = q.makeCommandBuffer()!
    let rp = MTLRenderPassDescriptor()
    rp.colorAttachments[0].texture = pyramid; rp.colorAttachments[0].level = 0
    rp.colorAttachments[0].loadAction = .dontCare; rp.colorAttachments[0].storeAction = .store
    let e = cb.makeRenderCommandEncoder(descriptor: rp)!
    e.setRenderPipelineState(prepassPSO); e.setFragmentTexture(srcTex, index: 0)
    withUnsafeBytes(of: u) { e.setFragmentBytes($0.baseAddress!, length: MemoryLayout<FoldUniforms>.stride, index: 0) }
    e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3); e.endEncoding()
    let bl = cb.makeBlitCommandEncoder()!; bl.generateMipmaps(for: pyramid); bl.endEncoding()
    cb.commit(); cb.waitUntilCompleted()
}
buildPyramid()

/// 从一行/多行平均的 ESF 求 σ。
///
/// 两个必须的细节（都踩过）：
///
/// 1. **用带符号的差分**。写成"只累加 d>0 的 bin"会让 ±1 LSB 抖动噪声被单向累加，
///    理想硬边会被测成 σ≈1.7px。
/// 2. **窗口必须由数据自适应**，不能固定宽度。着色器的抖动图案是
///    `fmod(floor(p),256)`，**每 256 像素重复一次**，所以按行平均消不掉它；
///    固定宽窗会把平坦区的噪声方差全部算进去（噪声质量 × 距质心距离²，随窗宽平方增长），
///    窄核因此被严重高估。
///
/// 做法：先取两端平台，再只保留 ESF 位于两平台之间 2%~98% 的过渡区作为窗口。
/// 硬边的过渡区只有 1 个 bin → σ≈0；糊得越开，窗口自动越宽。
func measureSigma(esf: [Double], plateauHalf: Int) -> (sigma: Double, transitionPx: Int)? {
    let n = esf.count
    guard n > 16 else { return nil }
    let dark = esf[clampIndex(n / 2 - plateauHalf, n)]
    let light = esf[clampIndex(n / 2 + plateauHalf, n)]
    let range = light - dark
    guard range > 1e-3 else { return nil }

    let loT = dark + range * 0.02
    let hiT = dark + range * 0.98
    var i = 0, j = n - 1
    while i < n - 1 && esf[i] <= loT { i += 1 }
    while j > 0 && esf[j] >= hiT { j -= 1 }
    guard j > i else { return nil }

    let a = max(0, i - 1), b = min(n - 2, j + 1)
    let mass = esf[b + 1] - esf[a]
    guard abs(mass) > 1e-6 else { return nil }

    var centroid = 0.0
    for k in a...b { centroid += (Double(k) + 0.5) * (esf[k + 1] - esf[k]) }
    centroid /= mass

    var variance = 0.0
    for k in a...b { variance += (esf[k + 1] - esf[k]) * pow(Double(k) + 0.5 - centroid, 2) }
    variance /= mass
    guard variance > 0, variance.isFinite else { return nil }
    return (variance.squareRoot(), b - a + 1)
}

private func clampIndex(_ v: Int, _ n: Int) -> Int { min(max(v, 0), n - 1) }

func renderAndMeasure(targetSigma: Float, sigmaPerLevel: Float) -> (sigma: Double, transitionPx: Int) {
    var u = FoldUniforms()
    u.viewportWidth = Float(W); u.viewportHeight = Float(H)
    u.levels = LEVELS
    u.spatialMode = 0            // uniform：整屏同一半径
    u.amount = 1
    u.maxRadiusPx = targetSigma
    u.blurFloor = 0
    u.dimAmount = 0              // 关掉变暗/高光/掠射，只留纯模糊
    u.grazingStrength = 0
    u.reflection = 0
    u.hingeLineStrength = 0
    u.rimStrength = 0
    u.sigmaPerLevel = sigmaPerLevel
    u.debugMode = 0
    let cb = q.makeCommandBuffer()!
    let rp = MTLRenderPassDescriptor()
    rp.colorAttachments[0].texture = outTex
    rp.colorAttachments[0].loadAction = .dontCare; rp.colorAttachments[0].storeAction = .store
    let e = cb.makeRenderCommandEncoder(descriptor: rp)!
    e.setRenderPipelineState(compositePSO)
    e.setFragmentTexture(srcTex, index: 0)
    e.setFragmentTexture(pyramid, index: 1)
    withUnsafeBytes(of: u) { e.setFragmentBytes($0.baseAddress!, length: MemoryLayout<FoldUniforms>.stride, index: 0) }
    e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3); e.endEncoding()
    cb.commit(); cb.waitUntilCompleted()

    let rowBytes = W * 4
    var buf = [UInt8](repeating: 0, count: rowBytes * H)
    buf.withUnsafeMutableBytes { outTex.getBytes($0.baseAddress!, bytesPerRow: rowBytes, from: MTLRegionMake2D(0, 0, W, H), mipmapLevel: 0) }
    var esf = [Double](repeating: 0, count: W)
    for x in 0..<W { var s = 0.0; for y in 0..<H { s += Double(buf[(y * W + x) * 4]) / 255.0 }; esf[x] = s / Double(H) }

    // 平台采样点取在离边缘足够远处（但要在地图内），用于估计暗/亮电平
    let plateau = max(64, Int(targetSigma * 6))
    return measureSigma(esf: esf, plateauHalf: plateau) ?? (0, 0)
}

print("")
print("先验证估计器本身：目标 σ 极小 → 着色器走锐利短路、输出就是源纹理的硬边。")
print("此时带符号二阶矩应给出 σ≈0（若给出明显非零值，说明估计器有正偏，全表作废）")
let sanity = renderAndMeasure(targetSigma: 0.1, sigmaPerLevel: 0.9)
print(String(format: "  目标 σ=0.1 → 实测 %.4f px（期望 ≈0）", sanity.sigma))

print("")
print("=== 端到端：现有公式 lod = log2(σ_target / sigmaPerLevel), sigmaPerLevel=0.90 ===")
print("  目标σ(px) |  实测σ(px) |  σ实/σ目 |  等效 log2 比值")
print(String(repeating: "-", count: 62))
var rows: [(Double, Double)] = []
for t in [1.0, 2.0, 4.0, 8.0, 16.0, 24.0, 32.0, 48.0, 64.0, 96.0, 128.0, 192.0, 250.0, 400.0] {
    let r = renderAndMeasure(targetSigma: Float(t), sigmaPerLevel: 0.9)
    rows.append((t, r.sigma))
    print(String(format: "  %9.1f | %9.2f | %7.3f | %@",
                 t, r.sigma, r.sigma / t,
                 r.sigma > 0.5 && t > 0.5 ? String(format: "%.3f", log2(r.sigma / t)) : "—"))
}

print("")
print("=== 选常数：扫候选 sigmaPerLevel，取最大相对误差最小者 ===")
print("  sigmaPerLevel | 最大相对误差(σ≥4px) | 最大相对误差(含2px)")
print(String(repeating: "-", count: 62))
let probes: [Double] = [4, 8, 16, 32, 64, 125, 200, 250, 320, 400]
var bestC: (c: Double, worst: Double) = (0.28, .infinity)
for c in [0.27, 0.28, 0.29, 0.295, 0.30, 0.31, 0.32, 0.33] {
    var w = 0.0
    for t in probes {
        let r = renderAndMeasure(targetSigma: Float(t), sigmaPerLevel: Float(c))
        w = max(w, abs(r.sigma / t - 1))
    }
    let r2 = renderAndMeasure(targetSigma: 2, sigmaPerLevel: Float(c))
    let w2 = max(w, abs(r2.sigma / 2 - 1))
    if w < bestC.worst { bestC = (c, w) }
    print(String(format: "  %13.3f | %19.1f%% | %17.1f%%", c, w * 100, w2 * 100))
}
print(String(format: "\n  最优：sigmaPerLevel = %.3f（σ≥4px 最大误差 %.1f%%）", bestC.c, bestC.worst * 100))

print("")
print("=== 用最优常数复核（T-3.2 验收口径：|σ实/σ目 − 1| < 0.10）===")
print("  目标σ(px) |  实测σ(px) |  σ实/σ目 |  判定")
print(String(repeating: "-", count: 56))
var worst = 0.0
for t in [2.0, 4.0, 8.0, 16.0, 32.0, 64.0, 125.0, 200.0, 250.0, 320.0, 400.0] {
    let r = renderAndMeasure(targetSigma: Float(t), sigmaPerLevel: Float(bestC.c))
    let ratio = r.sigma / t
    if t >= 4 { worst = max(worst, abs(ratio - 1)) }
    print(String(format: "  %9.1f | %9.2f | %7.3f | %@",
                 t, r.sigma, ratio, abs(ratio - 1) < 0.10 ? "✅" : "❌"))
}
print(String(format: "\n  σ≥4px 最大相对误差 = %.1f%%（阈值 10%%）→ %@", worst * 100, worst < 0.10 ? "通过" : "未通过"))

print("")
print("=== 层数需求：σ_max = sigmaPerLevel · 2^(levels-1) ===")
for levels in [10, 11, 12, 13] {
    let maxSigma = bestC.c * pow(2.0, Double(levels - 1))
    print(String(format: "  levels=%d → 可表达最大 σ = %7.1f px = %6.1f pt@2x", levels, maxSigma, maxSigma / 2))
}
