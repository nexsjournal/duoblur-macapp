import Foundation

/// 单位四元数（双精度）。
///
/// 为什么不直接用 `simd_quatd`：① 参考实现里所有公式都写成 `w/x/y/z` 的形式，直接对应更不容易抄错；
/// ② DuoBlurCore 保持零依赖（连 simd 也不 import），单测不需要任何平台模块；
/// ③ 四元数乘法/求逆的实现只有十几行，自己写反而比猜 simd 的运算符重载更可靠。
///
/// 布局与 `CMQuaternion` 一致：`q = w + xi + yj + zk`，其中 `w = cos(θ/2)`。
public struct Quat: Sendable, Equatable {
    public var w: Double
    public var x: Double
    public var y: Double
    public var z: Double

    public static let identity = Quat(w: 1, x: 0, y: 0, z: 0)

    public init(w: Double, x: Double, y: Double, z: Double) {
        self.w = w; self.x = x; self.y = y; self.z = z
    }

    /// 绕单位轴 `axis` 旋转 `angle` 弧度。
    public init(axis: (x: Double, y: Double, z: Double), angle: Double) {
        let n = (axis.x * axis.x + axis.y * axis.y + axis.z * axis.z).squareRoot()
        guard n > 0, n.isFinite else { self = .identity; return }
        let s = sin(angle / 2) / n
        self.init(w: cos(angle / 2), x: axis.x * s, y: axis.y * s, z: axis.z * s)
    }

    public var isFinite: Bool { w.isFinite && x.isFinite && y.isFinite && z.isFinite }

    public var length: Double { (w * w + x * x + y * y + z * z).squareRoot() }

    public var normalized: Quat {
        let n = length
        guard n > 1e-12, n.isFinite else { return .identity }
        return Quat(w: w / n, x: x / n, y: y / n, z: z / n)
    }

    /// 共轭。对单位四元数而言等于逆。
    public var conjugated: Quat { Quat(w: w, x: -x, y: -y, z: -z) }

    public var inverse: Quat {
        let n2 = w * w + x * x + y * y + z * z
        guard n2 > 1e-24, n2.isFinite else { return .identity }
        return Quat(w: w / n2, x: -x / n2, y: -y / n2, z: -z / n2)
    }

    /// 四元数乘法（Hamilton 积）。`a * b` 表示"先施加 b，再施加 a"。
    public static func * (a: Quat, b: Quat) -> Quat {
        Quat(
            w: a.w * b.w - a.x * b.x - a.y * b.y - a.z * b.z,
            x: a.w * b.x + a.x * b.w + a.y * b.z - a.z * b.y,
            y: a.w * b.y - a.x * b.z + a.y * b.w + a.z * b.x,
            z: a.w * b.z + a.x * b.y - a.y * b.x + a.z * b.w
        )
    }

    public func dot(_ o: Quat) -> Double { w * o.w + x * o.x + y * o.y + z * o.z }

    /// 沿最短路径球面插值。t 已被 clamp 到 [0,1]。
    ///
    /// 最短路径（`dot < 0` 时翻转符号）是必须的：否则从 +170° 到 −170° 会绕远路经过 0°，
    /// 视觉上表现为"头部姿态绕了一圈"。
    public func slerp(to other: Quat, t: Double) -> Quat {
        let a = normalized
        var b = other.normalized
        var cosTheta = a.dot(b)

        if cosTheta < 0 {
            b = Quat(w: -b.w, x: -b.x, y: -b.y, z: -b.z)
            cosTheta = -cosTheta
        }

        let k = AngleUtils.clampUnit(t)

        // 夹角极小时退化为线性插值（sin θ → 0 会让公式数值不稳定）
        if cosTheta > 0.9995 {
            return Quat(
                w: a.w + (b.w - a.w) * k,
                x: a.x + (b.x - a.x) * k,
                y: a.y + (b.y - a.y) * k,
                z: a.z + (b.z - a.z) * k
            ).normalized
        }

        let theta = acos(AngleUtils.clamp(cosTheta, -1, 1))
        let sinTheta = sin(theta)
        let wa = sin((1 - k) * theta) / sinTheta
        let wb = sin(k * theta) / sinTheta
        return Quat(
            w: a.w * wa + b.w * wb,
            x: a.x * wa + b.x * wb,
            y: a.y * wa + b.y * wb,
            z: a.z * wa + b.z * wb
        ).normalized
    }

    /// 与另一个姿态之间的最短角距离（弧度）。忽略符号歧义（q 与 −q 表示同一姿态）。
    public func angularDistance(to other: Quat) -> Double {
        let d = abs(normalized.dot(other.normalized))
        return 2 * acos(AngleUtils.clamp(d, -1, 1))
    }
}
