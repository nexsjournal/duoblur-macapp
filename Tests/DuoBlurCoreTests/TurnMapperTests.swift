import XCTest
@testable import DuoBlurCore

/// TurnMapper 的行为测试。
final class TurnMapperTests: XCTestCase {

    private func mapper(
        dead: Double = 4, full: Double = 32, hysteresis: Double = 3, invert: Bool = false
    ) -> TurnMapper {
        TurnMapper(deadZoneDeg: dead, fullScaleDeg: full, hysteresisDeg: hysteresis, invertDirection: invert)
    }

    /// 死区内不触发
    func testDeadZoneProducesNoEffect() {
        var m = mapper()
        for angle in stride(from: -3.9, through: 3.9, by: 0.3) {
            let (amount, _) = m.update(turnDegrees: angle)
            XCTAssertEqual(amount, 0, accuracy: 1e-12, "|\(angle)| 在死区内，折叠量应为 0")
            XCTAssertFalse(m.isActive)
        }
    }

    /// 效果量为 0 时 side 保持不变
    func testSideIsRetainedWhileInactive() {
        var m = mapper()
        _ = m.update(turnDegrees: 30)          // 锁定到右侧
        XCTAssertEqual(m.side, .right)
        let (amount, side) = m.update(turnDegrees: 0)
        XCTAssertEqual(amount, 0)
        XCTAssertEqual(side, .right, "效果不可见时不应改变铰链侧，否则会闪跳")
    }

    /// 单调性
    func testMonotonicInMagnitude() {
        var m = mapper()
        var previous = -1.0
        for angle in stride(from: 0.0, through: 90.0, by: 1.0) {
            let (amount, _) = m.update(turnDegrees: angle)
            XCTAssertGreaterThanOrEqual(amount, previous - 1e-12, "折叠量在 \(angle)° 处回退了")
            previous = amount
        }
    }

    /// 饱和
    func testSaturatesAtFullScale() {
        var m = mapper()
        let (amount, _) = m.update(turnDegrees: 32)
        XCTAssertEqual(amount, 1.0, accuracy: 1e-12)
        let (beyond, _) = m.update(turnDegrees: 90)
        XCTAssertEqual(beyond, 1.0, accuracy: 1e-12, "超过满量程后应保持饱和")
    }

    /// 输出有界（含 NaN / 无穷）
    func testOutputStaysBoundedForPathologicalInput() {
        var m = mapper()
        for angle in [Double.nan, .infinity, -.infinity, 1e300, -1e300, 0] {
            let (amount, _) = m.update(turnDegrees: angle)
            XCTAssertTrue(amount.isFinite, "输入 \(angle) 产生了非有限输出")
            XCTAssertGreaterThanOrEqual(amount, 0)
            XCTAssertLessThanOrEqual(amount, 1)
        }
    }

    /// 迟滞：在阈值附近往复不应高频翻转
    func testHysteresisPreventsChatter() {
        var m = mapper(dead: 4, full: 32, hysteresis: 3)
        var activations = 0
        var wasActive = false
        // 在 3.5°–4.5° 之间往复（跨过 dead=4，但未跨过 enter=7 / exit=1）
        for i in 0..<40 {
            let angle = i % 2 == 0 ? 3.5 : 4.5
            _ = m.update(turnDegrees: angle)
            if m.isActive && !wasActive { activations += 1 }
            wasActive = m.isActive
        }
        XCTAssertLessThanOrEqual(activations, 1, "在死区阈值附近产生了 \(activations) 次翻转，迟滞失效")
    }

    /// 符号对称
    func testSymmetricForBothDirections() {
        for angle in stride(from: 5.0, through: 60.0, by: 5.0) {
            var left = mapper()
            var right = mapper()
            let (aLeft, sLeft) = left.update(turnDegrees: -angle)
            let (aRight, sRight) = right.update(turnDegrees: angle)
            XCTAssertEqual(aLeft, aRight, accuracy: 1e-12, "|\(angle)|° 时两侧折叠量不对称")
            XCTAssertEqual(sLeft, .left)
            XCTAssertEqual(sRight, .right)
        }
    }

    /// 方向反转
    func testInvertDirectionMirrorsResult() {
        var normal = mapper(invert: false)
        var inverted = mapper(invert: true)
        let (a, s) = normal.update(turnDegrees: 25)
        let (b, t) = inverted.update(turnDegrees: 25)
        XCTAssertEqual(a, b, accuracy: 1e-12)
        XCTAssertEqual(s, .right)
        XCTAssertEqual(t, .left, "反转后同一转向应得到相反方向")
    }

    /// 退化参数（dead == full）不崩溃、不除零
    func testDegenerateThresholdsDoNotCrash() {
        var m = mapper(dead: 10, full: 10, hysteresis: 0)
        let (below, _) = m.update(turnDegrees: 5)
        XCTAssertEqual(below, 0)
        let (above, _) = m.update(turnDegrees: 20)
        XCTAssertTrue(above.isFinite)
        XCTAssertGreaterThanOrEqual(above, 0)
        XCTAssertLessThanOrEqual(above, 1)
        XCTAssertEqual(above, 1, accuracy: 1e-9, "死区与满量程重合时，越过死区应直接饱和")
    }

    /// 方向语义：`side` 表达"头转向哪边"，而效果要求"头右转 → 铰链在屏幕右边缘"
    func testSideMapsToCorrectHingeEdge() {
        XCTAssertTrue(TurnSide.right.hingeOnRight, "头向右转 ⇒ 铰链在屏幕右边缘（左侧最糊）")
        XCTAssertFalse(TurnSide.left.hingeOnRight, "头向左转 ⇒ 铰链在屏幕左边缘（右侧最糊）")
    }

    /// 起步必须慢（smoothstep 缓动）：刚越死区几乎无效果，中段才明显。
    ///
    /// 这条性质曾经缺失（只有线性归一化），表现为"稍微一转头屏幕就有反应"。
    func testOnsetIsGentleJustPastDeadZone() {
        var m = mapper(dead: 10, full: 45)
        let (justPast, _) = m.update(turnDegrees: 12)
        XCTAssertLessThan(justPast, 0.03, "越过死区 2° 就产生了 \(justPast) 的折叠量，起步太陡")

        var mid = mapper(dead: 10, full: 45)
        let (midAmount, _) = mid.update(turnDegrees: 30)
        XCTAssertGreaterThan(midAmount, 0.4, "30° 的折叠量只有 \(midAmount)，中段响应过弱")
    }

    /// 运行中改阈值必须保留锁存状态，否则拖滑杆会让铰链侧闪跳。
    func testApplyingConfigPreservesLatch() {
        var m = mapper(dead: 10, full: 45)
        _ = m.update(turnDegrees: -30)
        XCTAssertEqual(m.side, .left)
        m.apply(TurnMappingConfig(deadZoneDeg: 6, fullScaleDeg: 40, hysteresisDeg: 3))
        XCTAssertTrue(m.isActive)
        XCTAssertEqual(m.side, .left)
    }
}
