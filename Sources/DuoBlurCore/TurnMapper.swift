import Foundation

/// 头部转向的哪一侧。决定屏幕的"铰链"（清晰锚点）在哪一边。
public enum TurnSide: Sendable, Equatable, CaseIterable {
    /// 头向左转 → 铰链在屏幕左边缘，越往右越糊
    case left
    /// 头向右转 → 铰链在屏幕右边缘，越往左越糊
    case right

    public var opposite: TurnSide { self == .left ? .right : .left }

    /// 着色器 uniform：`hingeOnRight`。1 表示铰链在右边缘（即 `d = 1 − uv.x`）。
    public var hingeOnRight: Bool { self == .right }

    public var localizedName: String { self == .left ? "向左" : "向右" }
}

/// 把连续的头部转向角映射成离散的"折叠量 + 方向"。
///
/// 四层处理，缺一不可：
/// 1. **死区**（默认 30°）—— 正视附近完全不触发，否则点头、打字、轻微转头都会引起可见效果
/// 2. **迟滞**（默认 3°）—— 在阈值附近缓慢往复时不会高频翻转
/// 3. **锁存方向**—— 一旦越过阈值就锁定方向，直到回到死区以下；避免 yaw 穿过 0 时铰链侧闪跳
/// 4. **缓动**（smoothstep）—— 越过死区后"慢起、中段快、到顶缓"，即
///    `t' = smoothstep(t)`。少了它，刚过死区折叠量就会线性爬起来，观感是"稍微一转就有效果"。
///
/// 纯值类型 + 显式 `dt`，因此可以完全单测。
public struct TurnMapper: Sendable {

    // MARK: 参数

    /// 死区（度）。|转向| 小于此值时不产生效果。
    public var deadZoneDeg: Double
    /// 满量程（度）。到达此角度后折叠量饱和为 1。
    public var fullScaleDeg: Double
    /// 迟滞（度）。进入/退出死区使用不同的阈值。
    public var hysteresisDeg: Double
    /// 方向反转。用于上机实测发现符号与预期相反时的兜底。
    public var invertDirection: Bool

    // MARK: 状态

    private var isLatched = false
    private var latchedSide: TurnSide = .right

    public init(
        deadZoneDeg: Double = 30,
        fullScaleDeg: Double = 60,
        hysteresisDeg: Double = 3,
        invertDirection: Bool = false
    ) {
        self.deadZoneDeg = deadZoneDeg
        self.fullScaleDeg = fullScaleDeg
        self.hysteresisDeg = hysteresisDeg
        self.invertDirection = invertDirection
    }

    /// 应用一组新阈值，**保留锁存状态**（改滑杆时不会引起方向闪跳/效果跳变）。
    public mutating func apply(_ config: TurnMappingConfig) {
        deadZoneDeg = config.deadZoneDeg
        fullScaleDeg = config.fullScaleDeg
        hysteresisDeg = config.hysteresisDeg
    }

    /// 当前锁存的方向。效果量为 0 时仍然有意义——保持它可以让着色器在不可见时不改变铰链侧。
    public var side: TurnSide { latchedSide }

    /// 当前是否已越过死区（锁存中）。
    public var isActive: Bool { isLatched }

    /// 输入**已经过符号归一化**的"向右为正"的转向角（度），输出折叠量（0…1）与当前方向。
    ///
    /// 注意 `side` 的语义：`side == .right` 表示"头向右转"，而对应的屏幕铰链在**右**边缘
    /// （即最模糊处在左边缘）。
    public mutating func update(turnDegrees: Double) -> (amount: Double, side: TurnSide) {
        let raw = turnDegrees.isFinite ? turnDegrees : 0
        let signed = invertDirection ? -raw : raw
        let magnitude = abs(signed)

        // 进入阈值就是死区本身（这样设置里的"死区角度"滑杆才名副其实：
        // 效果从死区角度开始，而不是从死区 + 迟滞开始），
        // 迟滞只作用于**退出**阈值，形成 deadZone→(deadZone−hysteresis) 的回滞带。
        let enterThreshold = deadZoneDeg
        let exitThreshold = Swift.max(deadZoneDeg - hysteresisDeg, 0)

        if isLatched {
            if magnitude < exitThreshold { isLatched = false }
        } else {
            if magnitude > enterThreshold {
                isLatched = true
                latchedSide = signed >= 0 ? .right : .left
            }
        }

        // 锁存期间方向不再改变——即使 yaw 在死区内穿到另一侧
        let side = isLatched ? (signed >= 0 ? .right : .left) : latchedSide
        if isLatched { latchedSide = side }

        guard isLatched else { return (0, latchedSide) }

        let span = Swift.max(fullScaleDeg - deadZoneDeg, 1e-6)
        let normalized = AngleUtils.clampUnit((magnitude - deadZoneDeg) / span)
        // 缓动：越过分区后慢起（两端一阶导为零），
        // 所以"刚过死区"几乎无效果，中段才明显起来。
        return (AngleUtils.smoothstep(normalized), side)
    }

    /// 立即回到"未激活"状态，不产生效果。用于暂停、重新校准、方向反转切换。
    public mutating func reset(keepSide: Bool = true) {
        isLatched = false
        if !keepSide { latchedSide = .right }
    }
}

/// 转向映射的可调阈值集合。UI 通过它改参，`TurnMapper` 不必重建（锁存状态得以保留）。
public struct TurnMappingConfig: Sendable, Equatable {
    /// 死区（度）：正视附近完全不触发。
    ///
    /// 默认 **30°**：读文档、打字时的正常头部摆动都在 ±20° 量级，
    /// 死区太小会让屏幕边缘在"直视"时也不断轻微发糊（实测反馈："影响工作"）。
    public var deadZoneDeg: Double
    /// 满量程（度）：到此角度折叠量饱和为 1。
    public var fullScaleDeg: Double
    /// 迟滞（度）：只作用于退出阈值。
    public var hysteresisDeg: Double

    public init(
        deadZoneDeg: Double = 30,
        fullScaleDeg: Double = 60,
        hysteresisDeg: Double = 3
    ) {
        self.deadZoneDeg = deadZoneDeg
        self.fullScaleDeg = fullScaleDeg
        self.hysteresisDeg = hysteresisDeg
    }

    /// UI 滑杆的合法范围。
    public static let deadZoneRange: ClosedRange<Double> = 2...45
    public static let fullScaleRange: ClosedRange<Double> = 20...90
}
