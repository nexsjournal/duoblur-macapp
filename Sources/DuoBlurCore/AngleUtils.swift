import Foundation

/// 角度工具集。
///
/// 全项目约定：**内部一律用弧度做三角运算，用「度」做参数与展示**。
/// 参数（死区、满量程角度等）都用度，因为它们要显示给用户；运算用弧度，因为 `atan2`/`asin` 输出弧度。
public enum AngleUtils {

    public static func degrees(fromRadians r: Double) -> Double { r * 180.0 / .pi }
    public static func radians(fromDegrees d: Double) -> Double { d * .pi / 180.0 }

    public static func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double {
        guard v.isFinite else { return lo }
        return Swift.min(Swift.max(v, lo), hi)
    }

    public static func clampUnit(_ v: Double) -> Double { clamp(v, 0, 1) }

    /// 把 `angle` 解缠到与 `reference` 最近的等价角，消除 ±π 回绕。
    ///
    /// yaw 会跨过 ±180°，如果不解缠，从 179° 到 181° 会表现为从 +179° 跳到 −179°。
    /// 用 while 而不是取模是为了保持可读性；NaN 会提前返回，不会死循环。
    public static func unwrap(_ angle: Double, near reference: Double) -> Double {
        guard angle.isFinite else { return reference }
        guard reference.isFinite else { return angle }
        var a = angle
        // 先做一次粗对齐，避免用 O(n) 循环处理极端输入
        if abs(a - reference) > 4 * .pi {
            let turns = ((a - reference) / (2 * .pi)).rounded()
            a -= turns * 2 * .pi
        }
        while a - reference > .pi { a -= 2 * .pi }
        while a - reference < -.pi { a += 2 * .pi }
        return a
    }

    /// `from → to` 的最短角差，结果落在 (−π, π]。
    public static func shortestDelta(from: Double, to: Double) -> Double {
        unwrap(to - from, near: 0)
    }

    /// 标准的 smoothstep：t²(3−2t)，两端一阶导为零。
    /// 与参考实现（chuspeeism 的图片切换）用的是同一条曲线。
    public static func smoothstep(_ t: Double) -> Double {
        let x = clampUnit(t)
        return x * x * (3 - 2 * x)
    }

    /// 环形平均（用于对角度做低通，规避回绕）。
    public static func circularMean(_ angles: [Double]) -> Double {
        guard !angles.isEmpty else { return 0 }
        var sx = 0.0, sy = 0.0
        for a in angles where a.isFinite {
            sx += cos(a); sy += sin(a)
        }
        return atan2(sy, sx)
    }
}
