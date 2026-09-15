import Foundation

/// 哪只耳机正在推流。左右耳切换时姿态可能跳变，需要重新锚定基线。
public enum SensorSide: String, Sendable, Equatable, Codable {
    case left
    case right
    case unknown

    public var localizedName: String {
        switch self {
        case .left: return "左耳"
        case .right: return "右耳"
        case .unknown: return "未知"
        }
    }
}

/// 运动数据授权状态。在 Core 层定义（而不是直接用 `CMAuthorizationStatus`），
/// 目的是让 Core 不依赖 CoreMotion —— 这是 Core 可 100% 单测的前提。
public enum MotionAuthorization: String, Sendable, Equatable, Codable {
    case notDetermined
    case restricted
    case denied
    case authorized

    public var localizedName: String {
        switch self {
        case .notDetermined: return "尚未请求"
        case .restricted: return "受系统限制"
        case .denied: return "已拒绝"
        case .authorized: return "已授权"
        }
    }
}

/// 运动数据源的运行状态。
public enum MotionStatus: Sendable, Equatable {
    /// 未启动。
    case idle
    /// 缺少"运动与健身"权限。
    case unauthorized(MotionAuthorization)
    /// 已启动，但系统报告没有可用设备（耳机没连上/没戴上/不是当前音频输出）。
    case waitingForDevice
    /// 已连接，正在等第一个有效样本。首个样本延迟实测 0.25s ~ 10s+，不是固定值。
    case waitingForFirstSample
    /// 正常追踪中。
    case tracking
    /// 数据中断。`since` 是已中断的秒数（宿主时钟）。
    case stale(since: TimeInterval)
    /// 正在重建会话（应对 macOS 特有"报告已连接但 0Hz"的卡死）。
    case rebuilding(attempt: Int)
    /// 重建次数用尽，已放弃。
    case failed(reason: String)

    public var isUsable: Bool {
        if case .tracking = self { return true }
        return false
    }

    public var localizedDescription: String {
        switch self {
        case .idle:
            return "未启动"
        case .unauthorized(let auth):
            return "缺少运动与健身权限（\(auth.localizedName)）"
        case .waitingForDevice:
            return "未检测到 AirPods。请戴上支持头部追踪的 AirPods（Pro / Max / 3 / 4 等），并确认它是 Mac 当前的音频输出设备。"
        case .waitingForFirstSample:
            return "正在等待 AirPods 数据…（首次连接可能需要几秒）"
        case .tracking:
            return "追踪中"
        case .stale(let since):
            return String(format: "AirPods 数据中断（%.1fs），效果已暂停。请确认耳机仍戴在耳中。", since)
        case .rebuilding(let attempt):
            return "正在重建 AirPods 连接…（第 \(attempt) 次）"
        case .failed(let reason):
            return "AirPods 连接失败：\(reason)"
        }
    }
}

/// 一次头部运动采样，已经过相对化与滤波。
///
/// 同时携带原始值与处理后值：原始值用于探针界面填写"实测符号/量级"表，
/// 处理后的值用于驱动效果。
public struct HeadSample: Sendable, Equatable {

    /// 宿主时钟的时刻（`CFAbsoluteTimeGetCurrent()`）。
    /// **不能用 `CMDeviceMotion.timestamp`** —— 那是远端设备时间基，只能用于算 dt。
    public var hostTime: TimeInterval

    /// 采集间隔（秒，由远端时间戳差值得到，已 clamp）。
    public var deltaTime: TimeInterval

    // 原始姿态（度）。数据流启动时的任意参考系，**启动时不为零**。
    public var rawYawDeg: Double
    public var rawPitchDeg: Double
    public var rawRollDeg: Double

    // 相对基线后的姿态（度）。
    public var relativeYawDeg: Double
    public var relativePitchDeg: Double
    public var relativeRollDeg: Double

    // One Euro 滤波后的姿态（度）。驱动效果用的是这三个。
    public var yawDeg: Double
    public var pitchDeg: Double
    public var rollDeg: Double

    /// 相对化后的四元数（诊断用，也便于将来做四元数级滤波）。
    public var relativeQuaternion: Quat

    /// 原始四元数。
    public var rawQuaternion: Quat

    /// 当前推流的耳机侧。
    public var sensorSide: SensorSide

    /// "向右转"为正的转向角（度）。已应用符号归一化与可选的"方向反转"。
    public var turnDegrees: Double

    public init(
        hostTime: TimeInterval,
        deltaTime: TimeInterval,
        rawYawDeg: Double,
        rawPitchDeg: Double,
        rawRollDeg: Double,
        relativeYawDeg: Double,
        relativePitchDeg: Double,
        relativeRollDeg: Double,
        yawDeg: Double,
        pitchDeg: Double,
        rollDeg: Double,
        relativeQuaternion: Quat,
        rawQuaternion: Quat,
        sensorSide: SensorSide,
        turnDegrees: Double
    ) {
        self.hostTime = hostTime
        self.deltaTime = deltaTime
        self.rawYawDeg = rawYawDeg
        self.rawPitchDeg = rawPitchDeg
        self.rawRollDeg = rawRollDeg
        self.relativeYawDeg = relativeYawDeg
        self.relativePitchDeg = relativePitchDeg
        self.relativeRollDeg = relativeRollDeg
        self.yawDeg = yawDeg
        self.pitchDeg = pitchDeg
        self.rollDeg = rollDeg
        self.relativeQuaternion = relativeQuaternion
        self.rawQuaternion = rawQuaternion
        self.sensorSide = sensorSide
        self.turnDegrees = turnDegrees
    }
}
