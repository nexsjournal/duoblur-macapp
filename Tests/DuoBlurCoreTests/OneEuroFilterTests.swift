import XCTest
@testable import DuoBlurCore

/// OneEuroFilter 的行为测试。
final class OneEuroFilterTests: XCTestCase {

    /// 静止去抖：输出标准差必须与单极点低通的理论值相符
    ///
    /// 期望值不是拍脑袋定的。单极点 `alpha` 对白噪声的方差传递比为 `alpha / (2 − alpha)`，
    /// 所以断言"实测标准差 ≈ 理论标准差"既验证了去抖有效，也验证了实现没写错。
    func testStaticNoiseIsAttenuated() {
        let minCutoff = 1.0
        let dt = 1.0 / 25.0
        var filter = OneEuroFilter(minCutoff: minCutoff, beta: 0.02, dCutoff: 1.0)
        var generator = SeededGenerator(seed: 42)

        // 先跑 1 秒让滤波器进入稳态
        for _ in 0..<25 { _ = filter.update(0, dt: dt) }

        var outputs: [Double] = []
        for _ in 0..<1000 {
            let noise = Double.random(in: -0.5...0.5, using: &generator)
            outputs.append(filter.update(noise, dt: dt))
        }

        let mean = outputs.reduce(0, +) / Double(outputs.count)
        let variance = outputs.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(outputs.count)
        let measuredStdDev = variance.squareRoot()

        // 均匀分布 ±0.5 的标准差是 1/√12 ≈ 0.2887
        let inputStdDev = 1.0 / (12.0).squareRoot()
        let alpha = OneEuroFilter.alpha(cutoff: minCutoff, dt: dt)
        let theoreticalStdDev = inputStdDev * (alpha / (2 - alpha)).squareRoot()

        XCTAssertEqual(measuredStdDev, theoreticalStdDev, accuracy: theoreticalStdDev * 0.25,
                       "实测去抖 \(measuredStdDev) 与理论值 \(theoreticalStdDev) 不符")
        XCTAssertLessThan(measuredStdDev, inputStdDev * 0.5, "去抖不足：输出标准差 \(measuredStdDev)")
    }

    /// 跟随：阶跃输入应快速走完 90%
    ///
    /// 以 200Hz 采样测量，而不是 25Hz —— 25Hz 的采样间隔是 40ms，
    /// 用它测量"80ms 内到位"只有 2 个采样点，量化误差比被测量还大。
    /// 滤波器本身是帧率无关的，所以在高采样率下测出的时间更能反映真实响应。
    ///
    /// 期望值的来源：beta = 0.02 时，30° 阶跃让速度估计达到约 166°/s，
    /// 截止频率打开到约 4.3Hz（τ ≈ 37ms），因此 90% 到位约需 85–100ms。
    func testStepResponseTracksQuickly() {
        let dt = 1.0 / 200.0
        var filter = OneEuroFilter(minCutoff: 1.0, beta: 0.02, dCutoff: 1.0)
        _ = filter.update(0, dt: dt)

        var elapsed = 0.0
        var reached90At: Double?
        for _ in 0..<400 {
            let v = filter.update(30, dt: dt)
            elapsed += dt
            if reached90At == nil, v >= 27 { reached90At = elapsed }
        }

        guard let t = reached90At else {
            return XCTFail("阶跃输入始终没有到达 90%")
        }
        XCTAssertLessThan(t, 0.12, "90% 到位时间 \(t)s 过长")
        XCTAssertGreaterThan(t, 0.02, "90% 到位太快（\(t)s），滤波器似乎没有生效")
    }

    /// 帧率无关：不同采样率喂同一条轨迹，对应时刻的输出必须接近
    func testFrameRateIndependence() {
        func run(hz: Double) -> [Double] {
            var filter = OneEuroFilter(minCutoff: 1.0, beta: 0.02, dCutoff: 1.0)
            let dt = 1.0 / hz
            let steps = Int(hz)   // 跑满 1 秒
            return (0..<steps).map { i in
                let t = Double(i) * dt
                // 一条连续轨迹：0.5Hz 正弦，振幅 30°
                let value = 30 * sin(2 * Double.pi * 0.5 * t)
                return filter.update(value, dt: dt)
            }
        }

        let at25 = run(hz: 25)
        let at100 = run(hz: 100)

        // 比较 t = 0.5s 附近的输出（25Hz 下是第 12 个点，100Hz 下是第 50 个点）
        let a = at25[12]
        let b = at100[50]
        XCTAssertEqual(a, b, accuracy: 0.5, "25Hz 与 100Hz 下的输出差 \(abs(a - b))°，说明滤波器依赖帧率")
    }

    /// 慢速漂移几乎无衰减、滞后可接受
    ///
    /// 关于滤波器的物理事实（决定了这条测试的期望值）：固定截止频率 `fc` 的单极点低通，
    /// 对频率 `f` 的信号有 `atan(f / fc)` 的相位滞后。所以 1Hz 截止频率下，
    /// 0.2Hz 的慢速漂移会被滞后约 157ms 但几乎不衰减。
    /// 真实转头是**阶跃**而非正弦，而 One Euro 的速度自适应会让快速运动时截止频率自动打开，
    /// 因此阶跃响应的表现（见上一条测试）比正弦响应更能代表实际手感。
    func testSlowDriftPassesThroughWithMildAttenuation() {
        let dt = 1.0 / 25.0
        var filter = OneEuroFilter(minCutoff: 1.0, beta: 0.02, dCutoff: 1.0)
        let frequency = 0.2
        let amplitude = 10.0
        let hz = 1.0 / dt

        var maxOutput = 0.0
        for i in 0..<Int(hz * 15) {
            let t = Double(i) * dt
            let input = amplitude * sin(2 * Double.pi * frequency * t)
            let output = filter.update(input, dt: dt)
            if t > 5 { maxOutput = max(maxOutput, abs(output)) }
        }

        XCTAssertGreaterThan(maxOutput, amplitude * 0.9,
                             "慢速漂移被过度衰减：峰值 \(maxOutput) vs 输入 \(amplitude)")
    }

    /// 相位滞后的量级必须与理论一致（atan(f/fc)），既不过大也不为零
    func testPhaseLagMatchesTheory() {
        let dt = 1.0 / 200.0
        var filter = OneEuroFilter(minCutoff: 1.0, beta: 0.0, dCutoff: 1.0)   // beta=0 退化为固定低通
        let frequency = 0.5
        let amplitude = 30.0
        let hz = 1.0 / dt

        var inputCrossings: [Double] = []
        var outputCrossings: [Double] = []
        var previousInput = 0.0
        var previousOutput = 0.0

        for i in 0..<Int(hz * 10) {
            let t = Double(i) * dt
            let input = amplitude * sin(2 * Double.pi * frequency * t)
            let output = filter.update(input, dt: dt)
            // 记录上升沿过零点（跳过前 2 秒的瞬态）
            if t > 2 {
                if previousInput < 0, input >= 0 { inputCrossings.append(t) }
                if previousOutput < 0, output >= 0 { outputCrossings.append(t) }
            }
            previousInput = input
            previousOutput = output
        }

        guard let inCross = inputCrossings.first, let outCross = outputCrossings.first else {
            return XCTFail("没有捕获到过零点")
        }
        let measuredLag = outCross - inCross
        let period = 1.0 / frequency
        let theoreticalLag = period * atan(frequency / 1.0) / (2 * Double.pi)

        XCTAssertEqual(measuredLag, theoreticalLag, accuracy: dt * 4,
                       "实测滞后 \(measuredLag)s 与理论 \(theoreticalLag)s 不符")
        XCTAssertLessThan(measuredLag, period * 0.15, "滞后超过周期的 15%，过大")
    }

    /// 参数极端值不产生 NaN / 除零
    func testExtremeParametersDoNotProduceNaN() {
        var zeroCutoff = OneEuroFilter(minCutoff: 0, beta: 0, dCutoff: 0)
        for i in 0..<50 {
            let v = zeroCutoff.update(Double(i) * 0.1, dt: 1.0 / 25.0)
            XCTAssertTrue(v.isFinite, "minCutoff=0 产生了非有限输出")
        }

        var hugeBeta = OneEuroFilter(minCutoff: 1, beta: 1e6, dCutoff: 1)
        for i in 0..<50 {
            let v = hugeBeta.update(Double(i % 7), dt: 1.0 / 25.0)
            XCTAssertTrue(v.isFinite, "巨大 beta 产生了非有限输出")
            XCTAssertGreaterThanOrEqual(v, 0)
        }
    }

    /// `alpha` 是帧率无关的关键公式，且必须等于解析值
    ///
    /// 注意：`a1 / a2` **不等于** 2。`1 − exp(−x)` 是凹函数，
    /// `(1−e^(−2x))/(1−e^(−x))` 在 x = 0.126 时约为 1.88 而不是 2。
    /// 断言"等于解析值"才是正确的检查；断言"比值恰为 2"会误判正确的实现。
    func testAlphaMatchesAnalyticValue() {
        let x = 2 * Double.pi * 1.0 / 25.0
        let a1 = OneEuroFilter.alpha(cutoff: 1.0, dt: 1.0 / 25.0)
        let a2 = OneEuroFilter.alpha(cutoff: 1.0, dt: 1.0 / 50.0)

        XCTAssertEqual(a1, 1 - exp(-x), accuracy: 1e-12)
        XCTAssertEqual(a2, 1 - exp(-x / 2), accuracy: 1e-12)
        XCTAssertGreaterThan(a1, a2)

        // 比值必须落在解析值附近（1.88），并且明显偏离 1（否则就是帧率相关）
        XCTAssertEqual(a1 / a2, (1 - exp(-x)) / (1 - exp(-x / 2)), accuracy: 1e-9)
        XCTAssertGreaterThan(a1 / a2, 1.8)

        // 小 x 时才近似线性（此时比值 → 2）
        let small1 = OneEuroFilter.alpha(cutoff: 1.0, dt: 1.0 / 1000.0)
        let small2 = OneEuroFilter.alpha(cutoff: 1.0, dt: 1.0 / 2000.0)
        XCTAssertEqual(small1 / small2, 2.0, accuracy: 0.01)

        // 非法输入退化到安全值而不是 NaN
        XCTAssertEqual(OneEuroFilter.alpha(cutoff: 1.0, dt: 0), 1)
        XCTAssertEqual(OneEuroFilter.alpha(cutoff: 0, dt: 0.04), 0)
        XCTAssertTrue(OneEuroFilter.alpha(cutoff: .nan, dt: 0.04).isFinite)
    }

    /// reset 之后第一个样本被直接采信（用于重新锚定基线）
    func testResetAdoptsNextSample() {
        var filter = OneEuroFilter()
        _ = filter.update(0, dt: 1.0 / 25.0)
        filter.reset()
        XCTAssertEqual(filter.update(42, dt: 1.0 / 25.0), 42, accuracy: 1e-12)
    }

    /// rebase 把当前值当作新起点，不产生"假运动"
    func testRebaseDoesNotProduceSpuriousMotion() {
        var filter = OneEuroFilter(minCutoff: 1.0, beta: 0.02, dCutoff: 1.0)
        _ = filter.update(0, dt: 1.0 / 25.0)
        filter.rebase(to: 20)
        let next = filter.update(20, dt: 1.0 / 25.0)
        XCTAssertEqual(next, 20, accuracy: 0.5, "rebase 后的静止输入不应产生运动")
    }
}

/// 可复现的随机数发生器，让统计类测试不会偶发失败。
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed &* 6364136223846793005 &+ 1442695040888963407 }

    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}
