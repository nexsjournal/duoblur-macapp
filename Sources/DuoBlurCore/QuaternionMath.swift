import Foundation

/// 四元数 ↔ 欧拉角，以及与"头部转向"语义的映射。
public enum QuaternionMath {

    /// 姿态相对化：`q` 相对于基线 `baseline` 的姿态。
    ///
    /// 等价于 Apple 官方推荐的 `CMAttitude.multiply(byInverseOf:)`。
    /// 必须做这一步：AirPods 的 `attitude` 参考系是**数据流启动时任意捕获**的重力对齐系，
    /// 启动时并不为零（实测基线约 0.1 rad）——不相对化的话一启动屏幕就是糊的。
    public static func relative(_ q: Quat, to baseline: Quat) -> Quat {
        (q * baseline.inverse).normalized
    }

    /// 从四元数提取欧拉角（弧度）。
    ///
    /// 采用的是 CoreMotion 自己的 `CMAttitude` 约定，即三个绕体轴的基本旋转：
    ///
    /// | 分量 | 轴 | 头戴时的物理含义 |
    /// |---|---|---|
    /// | `yaw` | z（竖直向上） | 左右转头 |
    /// | `pitch` | x（左右耳连线） | 点头 |
    /// | `roll` | y（前后方向） | 耳到肩的侧倾 |
    ///
    /// AirPods 佩戴时体坐标系的 z 轴竖直向上（静止时 `gravity ≈ (0,0,−1)` 即为佐证），
    /// 所以"绕 z 轴 = 左右转头"成立。
    ///
    /// 公式来源：多个生产级 macOS/iOS 头部追踪项目共用的实现，本项目的单测会验证
    /// "绕 z 轴 +30° → yaw = +30°"等三条基线行为。
    public static func euler(from q: Quat) -> (yaw: Double, pitch: Double, roll: Double) {
        let q = q.normalized
        let (w, x, y, z) = (q.w, q.x, q.y, q.z)

        let pitch = asin(AngleUtils.clamp(2 * (y * z + w * x), -1, 1))
        let yaw = atan2(2 * (w * z - x * y), 1 - 2 * (x * x + z * z))
        let roll = atan2(2 * (w * y - x * z), 1 - 2 * (x * x + y * y))

        return (yaw.isFinite ? yaw : 0, pitch.isFinite ? pitch : 0, roll.isFinite ? roll : 0)
    }

    /// 头部"向右转"的量，单位为度，**正值 = 向右转**。
    ///
    /// AirPods 的原始 yaw 是"向左转为正"，与我们的语义相反，所以取负号。
    /// 这个符号需要上机实测确认；实测若相反，改这里一处即可，
    /// 或者在设置里用"方向反转"开关覆盖（`invert`）。
    public static func headTurnDegrees(yawDegrees: Double, invert: Bool = false) -> Double {
        guard yawDegrees.isFinite else { return 0 }
        return invert ? yawDegrees : -yawDegrees
    }
}
