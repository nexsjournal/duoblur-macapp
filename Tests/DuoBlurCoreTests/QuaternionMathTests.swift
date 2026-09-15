import XCTest
@testable import DuoBlurCore

/// 四元数与角度工具的行为测试。
final class QuaternionMathTests: XCTestCase {

    private let degrees = { (d: Double) in AngleUtils.radians(fromDegrees: d) }

    /// 相对化
    func testRelativeToSelfIsIdentity() {
        let q = Quat(axis: (0.3, 0.5, -0.8), angle: degrees(37)).normalized
        let relative = QuaternionMath.relative(q, to: q)
        XCTAssertEqual(relative.w, 1, accuracy: 1e-9)
        XCTAssertEqual(relative.x, 0, accuracy: 1e-9)
        XCTAssertEqual(relative.y, 0, accuracy: 1e-9)
        XCTAssertEqual(relative.z, 0, accuracy: 1e-9)
    }

    /// 已知旋转 → 欧拉角
    ///
    /// AirPods 佩戴时体坐标系的 **z 轴竖直向上**（静止时 `gravity ≈ (0,0,−1)`），
    /// 所以"绕 z 轴旋转"就是左右转头，对应 `yaw`。
    /// 三轴的映射关系：x → pitch（点头）、y → roll（侧倾）、z → yaw（转头）。
    func testAxisToEulerMapping() {
        // 绕 z 轴 +30° → yaw = +30°（即向**左**转，AirPods 原始 yaw 以左转为正）
        let yawCase = QuaternionMath.euler(from: Quat(axis: (0, 0, 1), angle: degrees(30)))
        XCTAssertEqual(AngleUtils.degrees(fromRadians: yawCase.yaw), 30, accuracy: 0.01)
        XCTAssertEqual(AngleUtils.degrees(fromRadians: yawCase.pitch), 0, accuracy: 0.01)
        XCTAssertEqual(AngleUtils.degrees(fromRadians: yawCase.roll), 0, accuracy: 0.01)

        // 绕 x 轴 +20° → pitch = +20°（抬头）
        let pitchCase = QuaternionMath.euler(from: Quat(axis: (1, 0, 0), angle: degrees(20)))
        XCTAssertEqual(AngleUtils.degrees(fromRadians: pitchCase.pitch), 20, accuracy: 0.01)
        XCTAssertEqual(AngleUtils.degrees(fromRadians: pitchCase.yaw), 0, accuracy: 0.01)

        // 绕 y 轴 +25° → roll = +25°（向右肩倾）
        let rollCase = QuaternionMath.euler(from: Quat(axis: (0, 1, 0), angle: degrees(25)))
        XCTAssertEqual(AngleUtils.degrees(fromRadians: rollCase.roll), 25, accuracy: 0.01)
        XCTAssertEqual(AngleUtils.degrees(fromRadians: rollCase.yaw), 0, accuracy: 0.01)
    }

    /// 相对化之后角度应该是差值（这是"启动时基线不为零"的解法）
    func testRelativeRotationEqualsAngleDifference() {
        let baseline = Quat(axis: (0, 0, 1), angle: degrees(12))     // 模拟启动时的任意参考系
        let current = Quat(axis: (0, 0, 1), angle: degrees(42))      // 又向左转了 30°
        let relative = QuaternionMath.relative(current, to: baseline)
        let euler = QuaternionMath.euler(from: relative)
        XCTAssertEqual(AngleUtils.degrees(fromRadians: euler.yaw), 30, accuracy: 0.05)
    }

    /// 万向节边界不产生 NaN
    func testGimbalEdgeCasesDoNotProduceNaN() {
        for pitchDeg in [-90.0, -89.999, 0, 89.999, 90.0] {
            let q = Quat(axis: (1, 0, 0), angle: degrees(pitchDeg))
            let euler = QuaternionMath.euler(from: q)
            XCTAssertTrue(euler.yaw.isFinite && euler.pitch.isFinite && euler.roll.isFinite,
                          "pitch = \(pitchDeg)° 时产生了非有限欧拉角")
        }
    }

    /// unwrap：跨过 ±180° 时保持单调
    func testUnwrapKeepsContinuityAcrossPi() {
        var previous = AngleUtils.radians(fromDegrees: 170)
        for step in 0...10 {
            let raw = AngleUtils.radians(fromDegrees: 170 + Double(step) * 2)   // 170° → 190°
            let unwrapped = AngleUtils.unwrap(raw, near: previous)
            XCTAssertGreaterThan(unwrapped, previous - 1e-9, "解缠后在 \(170 + step * 2)° 处回退了")
            previous = unwrapped
        }
        XCTAssertEqual(AngleUtils.degrees(fromRadians: previous), 190, accuracy: 0.001)
    }

    /// slerp 走最短路径
    func testSlerpTakesShortestPath() {
        let from = Quat(axis: (0, 0, 1), angle: degrees(170))
        let to = Quat(axis: (0, 0, 1), angle: degrees(-170))
        let middle = from.slerp(to: to, t: 0.5)
        let yaw = AngleUtils.degrees(fromRadians: QuaternionMath.euler(from: middle).yaw)
        // 最短路径的中点应在 ±180° 附近，而不是 0°
        XCTAssertGreaterThan(abs(yaw), 175, "slerp 走了远路，中点 yaw = \(yaw)°")
    }

    /// 小角度下与逐轴角度差一致
    func testSmallAngleCompositionMatchesEulerDifference() {
        let a = Quat(axis: (0, 0, 1), angle: degrees(5))
        let b = Quat(axis: (0, 0, 1), angle: degrees(8))
        let combined = QuaternionMath.relative(b, to: a)
        let yaw = AngleUtils.degrees(fromRadians: QuaternionMath.euler(from: combined).yaw)
        XCTAssertEqual(yaw, 3, accuracy: 0.02)
    }

    /// 四元数乘法与逆的基本性质
    func testMultiplicationAndInverse() {
        let q = Quat(axis: (1, 1, 1), angle: degrees(50)).normalized
        let product = q * q.inverse
        XCTAssertEqual(product.w, 1, accuracy: 1e-9)
        XCTAssertEqual(product.length, 1, accuracy: 1e-9)

        // 单位四元数的共轭等于逆
        let conjugated = q.conjugated
        XCTAssertEqual(conjugated.w, q.inverse.w, accuracy: 1e-9)
        XCTAssertEqual(conjugated.x, q.inverse.x, accuracy: 1e-9)
    }

    /// 非有限输入不会污染状态
    func testNonFiniteQuaternionIsRejected() {
        let bad = Quat(w: .nan, x: 0, y: 0, z: 0)
        XCTAssertFalse(bad.isFinite)
        XCTAssertEqual(bad.normalized, .identity, "非有限四元数应退化为单位四元数而不是 NaN")
    }

    /// "向右转"语义：AirPods 原始 yaw 以左转为正，所以需要取负
    func testHeadTurnSignConvention() {
        // 原始 yaw = +30° 表示向左转 ⇒ 语义值应为 −30°（向右为负）
        XCTAssertEqual(QuaternionMath.headTurnDegrees(yawDegrees: 30), -30, accuracy: 1e-12)
        // 原始 yaw = −30° 表示向右转 ⇒ 语义值应为 +30°
        XCTAssertEqual(QuaternionMath.headTurnDegrees(yawDegrees: -30), 30, accuracy: 1e-12)
        // 反转开关
        XCTAssertEqual(QuaternionMath.headTurnDegrees(yawDegrees: 30, invert: true), 30, accuracy: 1e-12)
        // 非有限输入
        XCTAssertEqual(QuaternionMath.headTurnDegrees(yawDegrees: .nan), 0)
    }
}

/// AngleUtils 的补充测试
final class AngleUtilsTests: XCTestCase {

    func testClampHandlesNonFinite() {
        XCTAssertEqual(AngleUtils.clamp(.nan, 0, 1), 0)
        XCTAssertEqual(AngleUtils.clamp(.infinity, 0, 1), 0, "非有限输入退化到下界而不是传播")
        XCTAssertEqual(AngleUtils.clamp(0.5, 0, 1), 0.5)
        XCTAssertEqual(AngleUtils.clamp(-3, 0, 1), 0)
    }

    func testSmoothstepProperties() {
        XCTAssertEqual(AngleUtils.smoothstep(0), 0, accuracy: 1e-12)
        XCTAssertEqual(AngleUtils.smoothstep(1), 1, accuracy: 1e-12)
        XCTAssertEqual(AngleUtils.smoothstep(0.5), 0.5, accuracy: 1e-12)
        // 越界输入被裁剪
        XCTAssertEqual(AngleUtils.smoothstep(-5), 0)
        XCTAssertEqual(AngleUtils.smoothstep(5), 1)
        // 单调
        var previous = -1.0
        for i in 0...100 {
            let v = AngleUtils.smoothstep(Double(i) / 100)
            XCTAssertGreaterThanOrEqual(v, previous)
            previous = v
        }
    }

    func testShortestDelta() {
        XCTAssertEqual(
            AngleUtils.degrees(fromRadians: AngleUtils.shortestDelta(
                from: AngleUtils.radians(fromDegrees: 170),
                to: AngleUtils.radians(fromDegrees: -170)
            )),
            20, accuracy: 1e-9, "170° → −170° 的最短角差应为 +20°"
        )
    }

    /// unwrap 遇到极大输入不应死循环（内部先做一次粗对齐）
    func testUnwrapDoesNotHangOnHugeInput() {
        let result = AngleUtils.unwrap(1e9, near: 0)
        XCTAssertTrue(result.isFinite)
        XCTAssertLessThan(abs(result), 4 * .pi)
    }

    func testCircularMean() {
        // 350° 与 10° 的环形平均应为 0°，而不是 180°
        let mean = AngleUtils.circularMean([
            AngleUtils.radians(fromDegrees: 350),
            AngleUtils.radians(fromDegrees: 10)
        ])
        XCTAssertEqual(abs(AngleUtils.degrees(fromRadians: mean)), 0, accuracy: 1e-6)
    }
}
