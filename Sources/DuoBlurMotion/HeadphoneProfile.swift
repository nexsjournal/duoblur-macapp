import Foundation
import CoreAudio
import DuoBlurCore

/// 通过 CoreAudio 读取默认输出设备名，用来识别耳机机型。
///
/// 需要的理由：**系统 API 拿不到耳机型号**
/// （`CMDeviceMotion` 里没有任何型号字段），但默认音频输出设备的名称就是
/// "AirPods Pro"、"AirPods Max"、"AirPods 4" 这类人类可读的名字。据此可以做三件事：
///
/// 1. 在探针与菜单栏显示真实机型，而不是笼统的"AirPods"
/// 2. 对**非入耳式**机型（AirPods 3/4、Beats Fit Pro）给出更大的死区建议
///    —— 它们佩戴时相对头部会轻微移动，需要比默认 30° 更大的死区（建议 34°）
/// 3. 对不支持头部追踪的机型（AirPods 2 及更早）直接说明原因，
///    而不是让用户反复排查"为什么没数据"
///
/// 不需要任何权限：这是读默认输出设备名，不是录音频。
public enum AudioOutputDevice {

    /// 当前默认输出设备的名称，例如 "MacBook Pro 扬声器" 或 "AirPods Pro"。
    public static var defaultOutputName: String? {
        guard let deviceID = defaultOutputDeviceID() else { return nil }
        return name(of: deviceID)
    }

    private static func defaultOutputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        )
        return status == noErr && deviceID != 0 ? deviceID : nil
    }

    private static func name(of deviceID: AudioDeviceID) -> String? {
        stringProperty(deviceID, selector: kAudioObjectPropertyName)
    }

    /// 型号标识（例如 AirPods 上报的 `AirPods4,1` 之类）。
    ///
    /// **为什么必须读它**：用户可以在系统设置里把耳机改名（实测遇到把 AirPods 4 改名为"艾白"），
    /// 于是按设备名匹配关键词的机型识别直接失效。ModelUID 由设备自身上报、不受改名影响。
    public static var defaultOutputModelUID: String? {
        guard let deviceID = defaultOutputDeviceID() else { return nil }
        return stringProperty(deviceID, selector: kAudioDevicePropertyModelUID)
    }

    /// 传输类型（`blue` = 蓝牙）。用来在型号未识别时至少判断"这是个蓝牙音频设备"。
    public static var defaultOutputTransport: String? {
        guard let deviceID = defaultOutputDeviceID() else { return nil }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &transport)
        guard status == noErr else { return nil }
        // 四字符码转字符串
        let bytes = [
            UInt8((transport >> 24) & 0xFF), UInt8((transport >> 16) & 0xFF),
            UInt8((transport >> 8) & 0xFF), UInt8(transport & 0xFF),
        ]
        return String(bytes: bytes, encoding: .ascii)
    }

    private static func stringProperty(_ deviceID: AudioDeviceID, selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer -> OSStatus in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, pointer)
        }
        guard status == noErr else { return nil }
        let result = value as String
        return result.isEmpty ? nil : result
    }
}

/// 按机型名推断出的设备特征。
public struct HeadphoneProfile: Sendable, Equatable {

    public enum Fit: String, Sendable {
        /// 入耳式：佩戴稳定，运动数据质量最好
        case inEar
        /// 非入耳式：相对头部会轻微移动，建议更大的死区
        case openFit
        /// 头戴式（AirPods Max）：用头部检测而非入耳检测，断连事件时机不同
        case overEar
        /// 未知
        case unknown
    }

    /// 头部追踪支持情况。
    ///
    /// **三态而不是布尔**：型号识别靠的是设备名关键词与产品 ID 表，两者都可能认不出
    /// （实测：用户把 AirPods 4 改名成"艾白"，且 macOS 上报的 ModelUID 是产品 ID
    /// `201b 4c` 而非营销名）。此时**不能说"不支持"** —— 那是错误的结论。
    /// 唯一权威的答案是真去读一次数据，所以未识别就如实说"未识别，试一次即可确认"。
    public enum HeadTrackingSupport: Sendable, Equatable {
        case yes
        case unknown
        case no

        public var localizedName: String {
            switch self {
            case .yes: return "支持头部追踪"
            case .unknown: return "型号未识别 —— 点「开始监听 AirPods」实测即可确认"
            case .no: return "该机型不支持头部追踪（无运动传感器）"
            }
        }
    }

    public let rawName: String
    /// 设备上报的型号标识（不受用户改名影响）。Apple 设备形如 `201b 4c`：
    /// 前段是蓝牙产品 ID，后段是厂商标识（`4c` = 0x004C = Apple）。
    public let modelUID: String?
    /// 传输类型四字符码
    public let transport: String?
    public let fit: Fit
    /// 从 ModelUID 解析出的蓝牙产品 ID（如 0x201B）
    public let bluetoothProductID: UInt16?
    public let headTracking: HeadTrackingSupport
    /// 建议的死区角度（度）
    public let suggestedDeadZoneDeg: Double

    /// 设备名里出现这些关键词就认为支持头部追踪。
    /// 名单来源：Apple 个性化空间音频支持页 + 多个在售 macOS 头部追踪应用的机型列表。
    private static let supportedKeywords = [
        "airpods pro", "airpods max", "airpods 3", "airpods 4",
        "beats fit pro", "beats studio pro", "beats solo 4",
        "powerbeats pro 2", "powerbeats fit",
    ]

    /// 明确不支持头部追踪的关键词（AirPods 1/2 无 IMU）
    private static let unsupportedKeywords = ["airpods 1", "airpods 2"]

    /// 蓝牙产品 ID → 机型。**这是 best-effort 表，不是权威数据**：
    /// Apple 从未公开完整映射，社区整理的表也不一致，所以只用来**改进建议值**，
    /// 绝不用来断言"不支持"（断言错了会比不知道更糟）。
    ///
    /// 已知：`0x004C` 是 Apple 的蓝牙厂商标识。
    private static let productIDTable: [UInt16: String] = [
        0x2002: "AirPods (1st gen)",
        0x200F: "AirPods (2nd gen)",
        0x2013: "AirPods Pro (1st gen)",
        0x2014: "AirPods Pro (2nd gen)",
        0x2019: "AirPods (3rd gen)",
        0x201B: "AirPods 4",
        0x200D: "AirPods Max",
    ]

    /// 解析 ModelUID 里的蓝牙产品 ID：`"201b 4c"` → `0x201B`
    static func parseProductID(_ modelUID: String?) -> UInt16? {
        guard let modelUID else { return nil }
        let first = modelUID.split(separator: " ").first.map(String.init) ?? modelUID
        return UInt16(first, radix: 16)
    }

    /// 厂商标识是否为 Apple（`4c` = 0x004C）
    static func isAppleVendor(_ modelUID: String?) -> Bool {
        guard let modelUID else { return false }
        let parts = modelUID.lowercased().split(separator: " ")
        guard parts.count >= 2 else { return false }
        return UInt16(parts[1], radix: 16) == 0x004C
    }

    /// - Parameters:
    ///   - deviceName: 用户可见的设备名（**可能被用户改过**，例如改成"艾白"）
    ///   - modelUID: 设备上报的型号标识（不受改名影响）
    ///   - transport: 传输类型四字符码（`blue` = 蓝牙）
    public init(deviceName: String?, modelUID: String? = nil, transport: String? = nil) {
        let name = deviceName?.isEmpty == false ? deviceName! : "未知设备"
        self.rawName = name
        self.modelUID = modelUID
        self.transport = transport
        self.bluetoothProductID = Self.parseProductID(modelUID)

        // 判定信号按可信度排序：产品 ID 表 > 设备名关键词 > 什么都不确定
        let productName = self.bluetoothProductID.flatMap { Self.productIDTable[$0] }
        let lower = (name + " " + (productName ?? "") + " " + (modelUID ?? "")).lowercased()

        let matchedSupported = Self.supportedKeywords.contains { lower.contains($0) }
        let matchedUnsupported = Self.unsupportedKeywords.contains {
            lower.contains($0) && !lower.contains("pro") && !lower.contains("max")
        }

        if matchedUnsupported {
            self.headTracking = .no
        } else if matchedSupported || productName != nil {
            self.headTracking = .yes
        } else {
            // 名字被改过、产品 ID 也不在表里 —— 如实说"未识别"。
            // 尤其不能因为"认不出"就说"不支持"。
            self.headTracking = .unknown
        }

        // 佩戴形态决定建议死区（默认死区是 30°，见 TurnMappingConfig）
        if lower.contains("max") {
            self.fit = .overEar
            self.suggestedDeadZoneDeg = 30
        } else if lower.contains("airpods 3") || lower.contains("airpods 4")
                    || lower.contains("beats fit pro") {
            self.fit = .openFit
            // 非入耳式佩戴时耳机相对头部会动，需要比默认更大的死区，
            // 否则"耳机本身晃动"会被当成转头
            self.suggestedDeadZoneDeg = 34
        } else if self.headTracking == .yes {
            self.fit = .inEar
            self.suggestedDeadZoneDeg = 30
        } else {
            self.fit = .unknown
            self.suggestedDeadZoneDeg = 30
        }
    }

    /// 默认输出**明确**不是蓝牙设备（例如内建扬声器）—— 常见的"为什么没数据"原因。
    ///
    /// 语义上刻意保守：拿不到传输类型时返回 false（"不知道就不说"），
    /// 而不是默认断言"你没连耳机"。少一个错误的提示，比多一个提示更有价值。
    public var looksLikeNoHeadphones: Bool {
        guard let transport, !transport.isEmpty else { return false }
        return transport.lowercased() != "blue" && headTracking != .yes
    }

    public var localizedSummary: String {
        let fitName: String
        switch fit {
        case .inEar: fitName = "入耳式"
        case .openFit: fitName = "非入耳式 · 建议死区 \(String(format: "%.1f", suggestedDeadZoneDeg))°"
        case .overEar: fitName = "头戴式（用头部检测而非入耳检测）"
        case .unknown: fitName = "佩戴形态未知"
        }
        return "\(fitName) · \(headTracking.localizedName)"
    }

    /// 当前默认输出设备对应的档案。
    public static var current: HeadphoneProfile {
        HeadphoneProfile(
            deviceName: AudioOutputDevice.defaultOutputName,
            modelUID: AudioOutputDevice.defaultOutputModelUID,
            transport: AudioOutputDevice.defaultOutputTransport
        )
    }

    /// 供诊断日志用的一行摘要。
    public var diagnosticLine: String {
        "设备名=\(rawName) 型号=\(modelUID ?? "无") 传输=\(transport ?? "无") "
            + "产品ID=\(bluetoothProductID.map { String(format: "0x%04X", $0) } ?? "无") "
            + "Apple厂商=\(Self.isAppleVendor(modelUID) ? "是" : "否") "
            + "判定=\(headTracking.localizedName)"
    }
}
