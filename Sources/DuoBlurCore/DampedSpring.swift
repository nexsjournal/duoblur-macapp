import Foundation

/// 临界阻尼弹簧（半隐式欧拉）。
///
/// 参数取自 mac-duo 的 `DampedSpring`（ω = 14 rad/s，ζ = 1）：实测无过冲、约 0.35s 到位。
///
/// **必须在显示帧率上推进**（由 CADisplayLink 驱动），不能在 25Hz 的传感器回调里推进——
/// 否则 25Hz 的阶梯会直接暴露成视觉上的卡顿。
///
/// **必须传入真实的帧间隔**：dt 先被钳到 [1/240, 1/20]。
/// 不钳的话，休眠唤醒后的一个巨大 dt 会让弹簧直接爆掉。
public struct DampedSpring: Sendable {

    /// 固有频率（rad/s）。越大越快到位，也越"抢"。
    public var omega: Double
    /// 阻尼比。1.0 = 临界阻尼（阶跃响应无过冲）。
    public var zeta: Double
    /// 输出被钳制的范围。防止目标在运动中反向时出现越界（阶跃本身不会过冲，但移动目标会）。
    public var outputRange: ClosedRange<Double>

    private var value: Double
    private var velocity: Double = 0

    public init(
        initial: Double = 0,
        omega: Double = 14,
        zeta: Double = 1,
        outputRange: ClosedRange<Double> = 0...1
    ) {
        self.value = AngleUtils.clamp(initial, outputRange.lowerBound, outputRange.upperBound)
        self.omega = omega
        self.zeta = zeta
        self.outputRange = outputRange
    }

    public var current: Double { value }

    /// 推进一步并返回新值。`dt` 单位为秒。
    @discardableResult
    public mutating func step(towards target: Double, dt: Double) -> Double {
        guard target.isFinite else { return value }
        guard dt.isFinite, dt > 0 else { return value }

        let h = AngleUtils.clamp(dt, 1.0 / 240, 1.0 / 20)
        let w = omega.isFinite ? AngleUtils.clamp(omega, 0, 200) : 14
        let z = zeta.isFinite ? AngleUtils.clamp(zeta, 0, 4) : 1

        let clampedTarget = AngleUtils.clamp(target, outputRange.lowerBound, outputRange.upperBound)

        // a = ω²·(target − x) − 2ζω·v
        let acceleration = w * w * (clampedTarget - value) - 2 * z * w * velocity
        velocity += acceleration * h
        let next = value + velocity * h

        if !next.isFinite || !velocity.isFinite {
            // 数值异常时安全复位，而不是让 NaN 传播到渲染层
            value = clampedTarget
            velocity = 0
            return value
        }

        // 钳制并吸收向外的动量（否则会出现"贴边黏住"或"顶出去再弹回来"）
        if next < outputRange.lowerBound {
            value = outputRange.lowerBound
            velocity = Swift.max(velocity, 0)
        } else if next > outputRange.upperBound {
            value = outputRange.upperBound
            velocity = Swift.min(velocity, 0)
        } else {
            value = next
        }

        return value
    }

    /// 直接跳到目标值（用于校准、重新锚定、从暂停恢复等场景，避免可见的过渡）。
    public mutating func snap(to newValue: Double) {
        value = AngleUtils.clamp(newValue, outputRange.lowerBound, outputRange.upperBound)
        velocity = 0
    }
}
