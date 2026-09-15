import XCTest
@testable import DuoBlurMotion
import DuoBlurCore

/// 姿态管线的集成行为。
///
/// 全部用合成的四元数序列驱动，不需要耳机、不需要权限。
final class OrientationPipelineTests: XCTestCase {

    private let degrees = { (d: Double) in AngleUtils.radians(fromDegrees: d) }

    private func yawRotation(_ deg: Double) -> Quat {
        Quat(axis: (0, 0, 1), angle: degrees(deg))
    }

    /// 启动时的基线必须被采纳：第一个样本不能产生非零的相对量
    ///
    /// 这是"AirPods 的 attitude 启动时不为零"的直接后果 —— 不做这一步，一启动屏幕就是糊的。
    func testFirstSampleBecomesBaselineAndYieldsZeroRelativeAngle() {
        var pipeline = OrientationPipeline()
        let sample = pipeline.process(
            rawQuaternion: yawRotation(12.3),      // 任意的启动参考系
            remoteTimestamp: 0,
            hostTime: 0,
            sensorSide: .right
        )

        XCTAssertEqual(sample.relativeYawDeg, 0, accuracy: 1e-6, "首个样本的相对 yaw 应为 0")
        XCTAssertEqual(sample.yawDeg, 0, accuracy: 1e-6, "滤波后的输出也应为 0")
        XCTAssertEqual(sample.rawYawDeg, 12.3, accuracy: 0.01, "原始值应保留真实读数")
        XCTAssertTrue(pipeline.hasEstablishedBaseline)
    }

    /// 相对旋转被正确提取
    ///
    /// 注意末尾要**保持**几帧再断言：One Euro 对斜坡输入有稳态滞后
    /// （滞后量 = 输入角速度 × 时间常数），直接对运动中的值断言会把它误判成误差。
    /// 真实转头也是"转到位后保持"，所以这样测更贴近实际。
    func testRelativeRotationIsTracked() {
        var pipeline = OrientationPipeline()
        _ = pipeline.process(rawQuaternion: yawRotation(10), remoteTimestamp: 0, hostTime: 0, sensorSide: .right)

        var timestamp = 0.0
        // 1.5 秒内匀速转到相对基线 +30°（向左转）
        for i in 1...38 {
            timestamp = Double(i) * 0.04
            _ = pipeline.process(
                rawQuaternion: yawRotation(10 + Double(i) * 0.79),
                remoteTimestamp: timestamp,
                hostTime: timestamp,
                sensorSide: .right
            )
        }

        // 保持 1 秒让滤波器稳定
        var last: HeadSample!
        for _ in 0..<25 {
            timestamp += 0.04
            last = pipeline.process(
                rawQuaternion: yawRotation(40),
                remoteTimestamp: timestamp,
                hostTime: timestamp,
                sensorSide: .right
            )
        }

        XCTAssertEqual(last.relativeYawDeg, 30, accuracy: 0.3)
        // AirPods 原始 yaw 以左转为正 ⇒ 语义值应为 −30°（向右为正）
        XCTAssertEqual(last.turnDegrees, -30, accuracy: 0.3, "语义符号约定错误")
    }

    /// 平稳正视（含噪声）不应产生可感知的折叠量
    func testStaticForwardWithNoiseProducesNoTurn() {
        var pipeline = OrientationPipeline()
        var mapper = TurnMapper()
        var generator = SeededGenerator(seed: 99)

        _ = pipeline.process(rawQuaternion: yawRotation(0), remoteTimestamp: 0, hostTime: 0, sensorSide: .right)

        var maxAmount = 0.0
        for i in 1...250 {   // 10 秒 @25Hz
            let noise = Double.random(in: -0.5...0.5, using: &generator)
            let sample = pipeline.process(
                rawQuaternion: yawRotation(noise),
                remoteTimestamp: Double(i) * 0.04,
                hostTime: Double(i) * 0.04,
                sensorSide: .right
            )
            let (amount, _) = mapper.update(turnDegrees: sample.turnDegrees)
            maxAmount = max(maxAmount, amount)
        }

        XCTAssertLessThan(maxAmount, 0.001, "正视静置时产生了 \(maxAmount) 的折叠量，死区/滤波不生效")
    }

    /// 手动回中后立即归零
    func testRecenterResetsToZero() {
        var pipeline = OrientationPipeline()
        _ = pipeline.process(rawQuaternion: yawRotation(0), remoteTimestamp: 0, hostTime: 0, sensorSide: .right)

        let turned = pipeline.process(
            rawQuaternion: yawRotation(25), remoteTimestamp: 0.04, hostTime: 0.04, sensorSide: .right
        )
        XCTAssertGreaterThan(abs(turned.relativeYawDeg), 20)

        // 把当前姿态设为基线
        pipeline.setBaseline(to: turned.rawQuaternion)
        let afterRecenter = pipeline.process(
            rawQuaternion: turned.rawQuaternion, remoteTimestamp: 0.08, hostTime: 0.08, sensorSide: .right
        )
        XCTAssertEqual(afterRecenter.relativeYawDeg, 0, accuracy: 1e-6, "回中后相对角度应为 0")
        XCTAssertEqual(afterRecenter.yawDeg, 0, accuracy: 1e-6)
    }

    /// 推流耳机侧切换时重新锚定，输出不应跳变
    func testSensorSideChangeReanchorsWithoutJump() {
        var pipeline = OrientationPipeline()
        _ = pipeline.process(rawQuaternion: yawRotation(0), remoteTimestamp: 0, hostTime: 0, sensorSide: .left)

        // 左耳推流，头转了 20°
        _ = pipeline.process(rawQuaternion: yawRotation(20), remoteTimestamp: 0.04, hostTime: 0.04, sensorSide: .left)

        // 切换到右耳，且姿态参考系跳变了 50°
        let afterSwitch = pipeline.process(
            rawQuaternion: yawRotation(70), remoteTimestamp: 0.08, hostTime: 0.08, sensorSide: .right
        )

        XCTAssertEqual(afterSwitch.relativeYawDeg, 0, accuracy: 1e-6,
                       "切换推流耳后应重新锚定基线，相对角度归零")
    }

    /// 采样率被正确估算（AirPods 约 25Hz）
    func testMeasuredSampleRate() {
        var pipeline = OrientationPipeline()
        for i in 0...100 {
            _ = pipeline.process(
                rawQuaternion: yawRotation(Double(i) * 0.1),
                remoteTimestamp: Double(i) * 0.04,
                hostTime: Double(i) * 0.04,
                sensorSide: .right
            )
        }
        XCTAssertEqual(pipeline.measuredHz, 25, accuracy: 1.0, "实测采样率应接近 25Hz")
    }

    /// 远端时间戳缺失时退化到宿主时钟，不会产生非有限 dt
    func testFallsBackToHostClock() {
        var pipeline = OrientationPipeline()
        var last: HeadSample!
        for i in 0...20 {
            last = pipeline.process(
                rawQuaternion: yawRotation(Double(i)),
                remoteTimestamp: nil,
                hostTime: Double(i) * 0.04,
                sensorSide: .right
            )
        }
        XCTAssertTrue(last.deltaTime.isFinite)
        XCTAssertGreaterThan(last.deltaTime, 0)
        XCTAssertLessThanOrEqual(last.deltaTime, 0.5)
    }

    /// 非有限的原始四元数被拒绝，不污染姿态
    func testNonFiniteQuaternionIsRejected() {
        var pipeline = OrientationPipeline()
        _ = pipeline.process(rawQuaternion: yawRotation(5), remoteTimestamp: 0, hostTime: 0, sensorSide: .right)

        let bad = Quat(w: .nan, x: .nan, y: .nan, z: .nan)
        // normalized 会把非有限四元数退化为单位四元数，因此这里不会崩也不会产生 NaN
        let sample = pipeline.process(rawQuaternion: bad, remoteTimestamp: 0.04, hostTime: 0.04, sensorSide: .right)
        XCTAssertTrue(sample.yawDeg.isFinite)
        XCTAssertTrue(sample.turnDegrees.isFinite)
    }

    /// yaw 漂移不应转化为折叠量（在手动/自动回中缺席时，
    /// 这里验证的是"漂移被当作真实转动"这一点在滤波后仍然平滑，不会跳变）
    func testSlowDriftProducesSmoothOutput() {
        var pipeline = OrientationPipeline()
        _ = pipeline.process(rawQuaternion: yawRotation(0), remoteTimestamp: 0, hostTime: 0, sensorSide: .right)

        var previous = 0.0
        for i in 1...300 {   // 30°/12 秒的缓慢漂移
            let drift = Double(i) * 0.1
            let sample = pipeline.process(
                rawQuaternion: yawRotation(drift),
                remoteTimestamp: Double(i) * 0.04,
                hostTime: Double(i) * 0.04,
                sensorSide: .right
            )
            XCTAssertLessThan(abs(sample.yawDeg - previous), 1.0,
                              "第 \(i) 步出现了跳变：\(previous) → \(sample.yawDeg)")
            previous = sample.yawDeg
        }
    }

    /// 方向反转
    func testInvertDirection() {
        var pipeline = OrientationPipeline(configuration: .init(invertDirection: true))
        _ = pipeline.process(rawQuaternion: yawRotation(0), remoteTimestamp: 0, hostTime: 0, sensorSide: .right)

        var timestamp = 0.0
        for i in 1...30 {
            timestamp = Double(i) * 0.04
            _ = pipeline.process(
                rawQuaternion: yawRotation(Double(i) * 1.0),
                remoteTimestamp: timestamp,
                hostTime: timestamp,
                sensorSide: .right
            )
        }
        // 保持一段让滤波器稳定
        var last: HeadSample!
        for _ in 0..<25 {
            timestamp += 0.04
            last = pipeline.process(
                rawQuaternion: yawRotation(30),
                remoteTimestamp: timestamp,
                hostTime: timestamp,
                sensorSide: .right
            )
        }
        // 原始向左转 30° ⇒ 正常语义 −30°，反转后 +30°
        XCTAssertEqual(last.turnDegrees, 30, accuracy: 0.3)
    }
}

/// 可复现的随机数发生器（每个测试模块各持一份，避免为一个小工具引入共享 target）。
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
