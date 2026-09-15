import XCTest
@testable import DuoBlurCore

/// DampedSpring 的行为测试。
final class DampedSpringTests: XCTestCase {

    /// 阶跃响应无过冲（ζ = 1 临界阻尼）
    func testStepResponseHasNoOvershoot() {
        var spring = DampedSpring(initial: 0, omega: 14, zeta: 1)
        var peak = 0.0
        for _ in 0..<1000 {
            let v = spring.step(towards: 1, dt: 1.0 / 60.0)
            peak = max(peak, v)
        }
        XCTAssertLessThanOrEqual(peak, 1.02, "临界阻尼下出现了过冲，峰值 \(peak)")
        XCTAssertGreaterThan(peak, 0.99, "根本没有到位，峰值 \(peak)")
    }

    /// 收敛
    func testConvergesWithinOneSecond() {
        var spring = DampedSpring(initial: 0, omega: 14, zeta: 1)
        for _ in 0..<60 { spring.step(towards: 1, dt: 1.0 / 60.0) }
        XCTAssertEqual(spring.current, 1.0, accuracy: 1e-3)
    }

    /// 帧率无关：不同帧率下曲线必须一致
    func testFrameRateIndependence() {
        func run(dt: Double, duration: Double) -> (mid: Double, end: Double) {
            var spring = DampedSpring(initial: 0, omega: 14, zeta: 1)
            let steps = Int((duration / dt).rounded())
            var mid = 0.0
            for i in 1...steps {
                let v = spring.step(towards: 1, dt: dt)
                if abs(Double(i) * dt - 0.2) < dt / 2 { mid = v }
            }
            return (mid, spring.current)
        }

        let rates = [1.0 / 30, 1.0 / 60, 1.0 / 120, 1.0 / 144]
        let results = rates.map { run(dt: $0, duration: 1.0) }
        let ends = results.map(\.end)
        let mids = results.map(\.mid)

        XCTAssertLessThan((ends.max()! - ends.min()!), 2e-3, "1 秒后的终值随帧率变化：\(ends)")
        XCTAssertLessThan((mids.max()! - mids.min()!), 0.03, "0.2 秒处的值随帧率变化：\(mids)")
    }

    /// 巨大 dt（休眠唤醒）不产生 NaN、不爆炸
    func testHugeDeltaTimeIsClamped() {
        var spring = DampedSpring(initial: 0, omega: 14, zeta: 1)
        let v = spring.step(towards: 1, dt: 10)
        XCTAssertTrue(v.isFinite, "巨大 dt 产生了非有限输出")
        XCTAssertGreaterThanOrEqual(v, 0)
        XCTAssertLessThanOrEqual(v, 1)
    }

    /// 非法 dt（0 / 负数 / NaN）被忽略而不是污染状态
    func testInvalidDeltaTimeIsIgnored() {
        var spring = DampedSpring(initial: 0.5, omega: 14, zeta: 1)
        XCTAssertEqual(spring.step(towards: 1, dt: 0), 0.5)
        XCTAssertEqual(spring.step(towards: 1, dt: -1), 0.5)
        XCTAssertEqual(spring.step(towards: 1, dt: .nan), 0.5)
        _ = spring.step(towards: 1, dt: 1.0 / 60.0)
        XCTAssertGreaterThan(spring.current, 0.5, "正常 dt 应继续推进")
    }

    /// 目标快速翻转时输出连续，且始终在范围内
    func testFlippingTargetStaysContinuousAndInRange() {
        var spring = DampedSpring(initial: 0, omega: 14, zeta: 1)
        var previous = 0.0
        for i in 0..<100 {
            let target = i % 2 == 0 ? 1.0 : 0.0
            let v = spring.step(towards: target, dt: 1.0 / 60.0)
            XCTAssertGreaterThanOrEqual(v, 0, "第 \(i) 步越界")
            XCTAssertLessThanOrEqual(v, 1, "第 \(i) 步越界")
            XCTAssertLessThan(abs(v - previous), 0.15, "第 \(i) 步出现跳变")
            previous = v
        }
    }

    /// snap 直接对齐且不残留速度
    func testSnapClearsVelocity() {
        var spring = DampedSpring(initial: 0, omega: 14, zeta: 1)
        for _ in 0..<10 { spring.step(towards: 1, dt: 1.0 / 60.0) }
        spring.snap(to: 0)
        XCTAssertEqual(spring.current, 0, accuracy: 1e-12)
        let after = spring.step(towards: 0, dt: 1.0 / 60.0)
        XCTAssertEqual(after, 0, accuracy: 1e-12, "snap 之后不应有残留动量")
    }

    /// 输出范围可钳制，越界的目标值被裁到边界
    func testTargetIsClampedToOutputRange() {
        var spring = DampedSpring(initial: 0, omega: 14, zeta: 1)
        for _ in 0..<300 { spring.step(towards: 5, dt: 1.0 / 60.0) }
        XCTAssertLessThanOrEqual(spring.current, 1.0)
    }
}
