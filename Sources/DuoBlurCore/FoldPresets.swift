import Foundation

/// 四个效果预设。参数集中定义在这里，是预设的唯一事实源。
///
/// 单测 `FoldParametersTests.testPresetsMatchExpectedValues` 会断言预设参数
/// 与这里的取值一致——改代码忘了同步会被测试拦住。
public enum FoldPreset: String, Sendable, CaseIterable, Codable {
    /// **默认。** 折痕随转头在屏幕上移动，模糊从自由边长出。
    case duoSweep
    /// 整屏即面板，最纯粹的 Duo。
    case duoClassic
    /// 整屏均匀磨砂 + 轻微变暗，最"磨砂玻璃"的一档。
    case frost
    /// 更重、始终带一层薄雾、高光更强。
    case cinematic

    public var localizedName: String {
        switch self {
        case .duoSweep: return "Duo Sweep"
        case .duoClassic: return "Duo Classic"
        case .frost: return "Frost"
        case .cinematic: return "Cinematic"
        }
    }

    public var summary: String {
        switch self {
        case .duoSweep: return "折痕随转头移动，模糊从屏幕边缘长出"
        case .duoClassic: return "整屏当作一块折叠面板，铰链处始终清晰"
        case .frost: return "整屏均匀磨砂，轻微变暗"
        case .cinematic: return "更重、始终带一层薄雾、高光更强"
        }
    }

    public var parameters: FoldParameters {
        switch self {
        case .duoSweep:
            return FoldParameters(
                spatialMode: .sweep,
                maxRadiusPt: 125,
                blurFloor: 0.0,
                rampKnee: 0.85,
                rampExp: 1.25,
                // 变暗只做"轻微光损失"。着色器里 dim 会再乘折叠量，
                // 所以小角度几乎不变暗，满折叠时自由边也仍保留可见内容（不是纯黑）。
                dimAmount: 0.5,
                dimReach: 0.55,
                dimHingeFloor: 0.0,
                hingeLineStrength: 0.035,
                rimStrength: 0.025,
                grazingStrength: 0.10,
                reflection: 1.0,
                topInsetPt: 0,
                fullFrostAt: nil
            )

        case .duoClassic:
            return FoldParameters(
                spatialMode: .ramp,
                maxRadiusPt: 125,
                blurFloor: 0.0,
                rampKnee: 0.85,
                rampExp: 1.25,
                dimAmount: 0.5,
                dimReach: 0.55,
                dimHingeFloor: 0.0,
                hingeLineStrength: 0.035,
                rimStrength: 0.025,
                grazingStrength: 0.10,
                reflection: 1.0,
                topInsetPt: 0,
                fullFrostAt: nil
            )

        case .frost:
            return FoldParameters(
                spatialMode: .uniform,
                maxRadiusPt: 90,
                blurFloor: 0.0,
                // uniform 模式下 knee/exp 不参与运算，填中性值以保持结构可比对
                rampKnee: 1.0,
                rampExp: 1.0,
                // frost 的观感是"整屏磨砂 + 轻微变暗"，所以这里的变暗最轻
                dimAmount: 0.4,
                dimReach: 1.0,
                dimHingeFloor: 0.0,
                hingeLineStrength: 0.0,
                rimStrength: 0.0,
                grazingStrength: 0.08,
                reflection: 1.0,
                topInsetPt: 0,
                fullFrostAt: 0.0
            )

        case .cinematic:
            return FoldParameters(
                spatialMode: .sweep,
                maxRadiusPt: 160,
                blurFloor: 0.25,
                rampKnee: 0.80,
                rampExp: 1.10,
                // 刻意最重的预设：变暗明显强于其它三个，但同样随折叠量收敛
                dimAmount: 0.7,
                dimReach: 0.45,
                dimHingeFloor: 0.18,
                hingeLineStrength: 0.035,
                rimStrength: 0.045,
                grazingStrength: 0.15,
                reflection: 1.0,
                topInsetPt: 0,
                fullFrostAt: nil
            )
        }
    }

    /// 找出与给定参数完全一致（在浮点容差内）的预设。用于设置界面显示"当前是哪个预设"。
    /// 返回 `nil` 表示用户改过参数，处于"自定义"状态。
    public static func matching(_ parameters: FoldParameters, tolerance: Double = 1e-9) -> FoldPreset? {
        allCases.first { preset in
            let a = preset.parameters
            let b = parameters
            guard a.spatialMode == b.spatialMode else { return false }
            guard (a.fullFrostAt == nil) == (b.fullFrostAt == nil) else { return false }
            if let fa = a.fullFrostAt, let fb = b.fullFrostAt, abs(fa - fb) > tolerance { return false }

            func eq(_ x: Double, _ y: Double) -> Bool { abs(x - y) <= tolerance }
            return eq(a.maxRadiusPt, b.maxRadiusPt)
                && eq(a.blurFloor, b.blurFloor)
                && eq(a.rampKnee, b.rampKnee)
                && eq(a.rampExp, b.rampExp)
                && eq(a.dimAmount, b.dimAmount)
                && eq(a.dimReach, b.dimReach)
                && eq(a.dimHingeFloor, b.dimHingeFloor)
                && eq(a.hingeLineStrength, b.hingeLineStrength)
                && eq(a.rimStrength, b.rimStrength)
                && eq(a.grazingStrength, b.grazingStrength)
                && eq(a.reflection, b.reflection)
                && eq(a.topInsetPt, b.topInsetPt)
        }
    }
}

/// 响应度档位：在"抖动"与"延迟"之间做主观取舍的单一开关。
/// 三档联动调整 One Euro 与弹簧参数。
public enum ResponsivenessTier: String, Sendable, CaseIterable, Codable {
    case steady      // 稳：几乎无抖动，快速转头时略"黏"
    case balanced    // 平衡（默认）
    case responsive  // 灵敏：跟手，静止时能看到极轻微抖动

    public var localizedName: String {
        switch self {
        case .steady: return "稳"
        case .balanced: return "平衡"
        case .responsive: return "灵敏"
        }
    }

    /// One Euro 的最低截止频率（Hz）。
    public var minCutoff: Double {
        switch self {
        case .steady: return 0.6
        case .balanced: return 1.0
        case .responsive: return 1.8
        }
    }

    /// One Euro 的速度自适应系数。
    public var beta: Double {
        switch self {
        case .steady: return 0.010
        case .balanced: return 0.020
        case .responsive: return 0.040
        }
    }

    /// 弹簧固有频率（rad/s）。
    public var springOmega: Double {
        switch self {
        case .steady: return 8
        case .balanced: return 14
        case .responsive: return 20
        }
    }
}
