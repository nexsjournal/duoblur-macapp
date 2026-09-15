import XCTest
@testable import DuoBlurMotion

/// 机型档案的判定逻辑。
///
/// 这些测试的存在理由来自一个实测踩过的坑：用户把 AirPods 4 改名成"艾白"，
/// 而 macOS 上报的 ModelUID 是产品 ID（`201b 4c`）而不是营销名 ——
/// 只按设备名匹配关键词就完全认不出来，而且会**错误地**报告"不支持头部追踪"。
final class HeadphoneProfileTests: XCTestCase {

    /// ModelUID 解析：`"201b 4c"` → 产品 0x201B / 厂商 0x004C(Apple)
    func testProductIDParsing() {
        XCTAssertEqual(HeadphoneProfile.parseProductID("201b 4c"), 0x201B)
        XCTAssertEqual(HeadphoneProfile.parseProductID("2014 4c"), 0x2014)
        XCTAssertEqual(HeadphoneProfile.parseProductID("201b"), 0x201B)
        XCTAssertNil(HeadphoneProfile.parseProductID("not-hex"))
        XCTAssertNil(HeadphoneProfile.parseProductID(nil))

        XCTAssertTrue(HeadphoneProfile.isAppleVendor("201b 4c"))
        XCTAssertFalse(HeadphoneProfile.isAppleVendor("201b 05"))   // 非 Apple 厂商
        XCTAssertFalse(HeadphoneProfile.isAppleVendor("201b"))
        XCTAssertFalse(HeadphoneProfile.isAppleVendor(nil))
    }

    /// 改名后的 AirPods 4 必须仍被识别为"支持"，而不是"不支持"
    func testRenamedAirPods4IsRecognizedViaProductID() {
        let profile = HeadphoneProfile(deviceName: "艾白", modelUID: "201b 4c", transport: "blue")
        XCTAssertEqual(profile.headTracking, .yes, "产品 ID 0x201B 应被识别为支持头部追踪的机型")
        XCTAssertEqual(profile.headTracking, .yes)
        XCTAssertEqual(profile.fit, .openFit, "AirPods 4 是非入耳式，应给更大的建议死区")
        XCTAssertEqual(profile.suggestedDeadZoneDeg, 34, accuracy: 1e-9)
        XCTAssertEqual(profile.bluetoothProductID, 0x201B)
    }

    /// 型号与名字都认不出时必须是 `unknown`，**绝不能**是 `no`
    ///
    /// 这是最重要的一条：认不出来就说"不支持"是错误的断言，会把"未识别"
    /// 变成"你以为你的设备不能用"，从而放弃实测。
    func testUnrecognizedModelReportsUnknownNotUnsupported() {
        let profile = HeadphoneProfile(deviceName: "艾白", modelUID: "ffff 4c", transport: "blue")
        XCTAssertEqual(profile.headTracking, .unknown)
        XCTAssertTrue(profile.headTracking.localizedName.contains("实测"))
    }

    /// 明确不支持的老机型才判 `no`
    func testLegacyAirPodsReportUnsupported() {
        let airPods2 = HeadphoneProfile(deviceName: "AirPods 2", transport: "blue")
        XCTAssertEqual(airPods2.headTracking, .no)

        // 但 "AirPods Pro 2" 不能被 "airpods 2" 这个子串误伤
        let pro2 = HeadphoneProfile(deviceName: "AirPods Pro 2", transport: "blue")
        XCTAssertEqual(pro2.headTracking, .yes)

        // AirPods Max 同理
        let max = HeadphoneProfile(deviceName: "AirPods Max", transport: "blue")
        XCTAssertEqual(max.headTracking, .yes)
        XCTAssertEqual(max.fit, .overEar)
    }

    /// 默认输出不是蓝牙设备时，能判断出"当前没有戴耳机"
    func testNonBluetoothOutputLooksLikeNoHeadphones() {
        let speakers = HeadphoneProfile(deviceName: "MacBook Pro 扬声器", transport: "built")
        XCTAssertTrue(speakers.looksLikeNoHeadphones)
    }

    /// 没有任何信息时不崩溃、不误判
    func testEmptyInputIsSafe() {
        let profile = HeadphoneProfile(deviceName: nil, modelUID: nil, transport: nil)
        XCTAssertEqual(profile.rawName, "未知设备")
        XCTAssertEqual(profile.headTracking, .unknown, "信息全无时只能是 unknown")
        XCTAssertFalse(profile.looksLikeNoHeadphones)
    }

    /// 诊断行必须包含排错需要的全部字段
    func testDiagnosticLineContainsKeyFacts() {
        let profile = HeadphoneProfile(deviceName: "艾白", modelUID: "201b 4c", transport: "blue")
        let line = profile.diagnosticLine
        XCTAssertTrue(line.contains("艾白"))
        XCTAssertTrue(line.contains("0x201B"))
        XCTAssertTrue(line.contains("blue"))
        XCTAssertTrue(line.contains("支持头部追踪"))
    }
}
