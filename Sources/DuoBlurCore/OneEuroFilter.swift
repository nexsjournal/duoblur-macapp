import Foundation

/// One Euro 滤波器（Casiez / Roussel / Vogel, CHI 2012）。
///
/// 为什么不用固定低通：固定低通在"抖动"与"延迟"之间只能二选一。
/// One Euro 让截止频率随信号速度自适应——**慢时重滤波（去抖）、快时轻滤波（跟手）**，
/// 因此同等抖动下延迟更低。头部追踪的标准选择。
///
/// 关键实现细节：**alpha 必须由 dt 算出（`1 − exp(−2π·fc·dt)`）而不能用固定的每样本系数**，
/// 否则滤波器在 25Hz 输入与 60Hz 输出下行为不同。单测断言了帧率无关性。
public struct OneEuroFilter: Sendable {

    // MARK: 参数

    /// 静止时的截止频率（Hz）。越小越稳、越大越跟手。
    public var minCutoff: Double
    /// 速度自适应系数。越大则快速运动时越跟手（同时引入的抖动也越多）。
    public var beta: Double
    /// 用于估计速度的截止频率（Hz）。
    public var dCutoff: Double

    // MARK: 状态

    private var hasPrevious = false
    private var previousRaw: Double = 0
    private var previousFiltered: Double = 0
    private var previousDerivative: Double = 0

    public init(minCutoff: Double = 1.0, beta: Double = 0.02, dCutoff: Double = 1.0) {
        self.minCutoff = minCutoff
        self.beta = beta
        self.dCutoff = dCutoff
    }

    /// 把 `cutoff`(Hz) 与 `dt`(s) 换算成单极点低通的混合系数。
    ///
    /// 用连续时间的精确解 `1 − exp(−2π·fc·dt)`，而不是论文里的近似式 `1/(1 + τ/dt)`。
    /// 两者都帧率无关，但前者是精确的，且对极端 dt 更稳健。
    public static func alpha(cutoff: Double, dt: Double) -> Double {
        guard cutoff.isFinite, dt.isFinite, dt > 0 else { return 1 }
        guard cutoff > 0 else { return 0 }
        let a = 1 - exp(-2 * Double.pi * cutoff * dt)
        return AngleUtils.clamp(a, 0, 1)
    }

    /// 推进一步。`dt` 单位为秒，必须来自单调时钟的差值。
    public mutating func update(_ value: Double, dt: Double) -> Double {
        guard value.isFinite else { return previousFiltered }
        guard dt.isFinite, dt > 0 else { return previousFiltered }
        // 极小的 dt 会让导数爆炸，钳一个下限；上限由调用方（弹簧/渲染循环）负责。
        let step = AngleUtils.clamp(dt, 1.0 / 1000, 1.0)

        guard hasPrevious else {
            hasPrevious = true
            previousRaw = value
            previousFiltered = value
            previousDerivative = 0
            return value
        }

        // 1) 原始导数（带符号，单位/秒），再用固定截止频率低通
        let rawDerivative = (value - previousRaw) / step
        let aD = Self.alpha(cutoff: dCutoff, dt: step)
        let derivative = previousDerivative + aD * (rawDerivative - previousDerivative)

        // 2) 用速度调制截止频率——这是 One Euro 的全部要点
        let cutoff = minCutoff + beta * abs(derivative)

        // 3) 对信号本身做低通
        let a = Self.alpha(cutoff: cutoff, dt: step)
        let filtered = previousFiltered + a * (value - previousFiltered)

        previousRaw = value
        previousFiltered = filtered.isFinite ? filtered : previousFiltered
        previousDerivative = derivative.isFinite ? derivative : previousDerivative

        return previousFiltered
    }

    /// 丢弃历史，下一次 `update` 会直接采信输入值。
    /// 用于重新锚定基线或数据流重建之后——否则滤波器会把"跳变"当成一次极快的运动。
    public mutating func reset() {
        hasPrevious = false
        previousRaw = 0
        previousFiltered = 0
        previousDerivative = 0
    }

    /// 只重置输出值，保留导数历史。用于基线改变时避免滤波器把变化当成真实运动。
    public mutating func rebase(to value: Double) {
        guard value.isFinite else { return }
        hasPrevious = true
        previousRaw = value
        previousFiltered = value
        previousDerivative = 0
    }
}
