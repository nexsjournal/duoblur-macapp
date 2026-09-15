import Foundation
import DuoBlurCore

/// 姿态管线：原始四元数 → 相对化 → 欧拉提取与解缠 → One Euro 滤波 → "向右为正"的转向角。
///
/// 纯值类型 + 显式时间入参，因此可以在假时钟下完全单测。
public struct OrientationPipeline: Sendable {

    public struct Configuration: Sendable, Equatable {
        /// 响应度档位，联动 One Euro 参数。
        public var tier: ResponsivenessTier
        /// 速度估计的截止频率（Hz）。
        public var dCutoff: Double
        /// 方向反转。上机实测发现符号与预期相反时的兜底。
        public var invertDirection: Bool

        public init(
            tier: ResponsivenessTier = .balanced,
            dCutoff: Double = 1.0,
            invertDirection: Bool = false
        ) {
            self.tier = tier
            self.dCutoff = dCutoff
            self.invertDirection = invertDirection
        }
    }

    public var configuration: Configuration {
        didSet {
            guard configuration != oldValue else { return }
            reconfigureFilters()
        }
    }

    // MARK: 状态

    private var baseline: Quat = .identity
    private var hasBaseline = false

    private var yawFilter: OneEuroFilter
    private var pitchFilter: OneEuroFilter
    private var rollFilter: OneEuroFilter

    /// 上一次解缠后的 yaw（弧度）。用于消除 ±π 回绕。
    private var lastUnwrappedYaw: Double?
    /// 上一次采样的远端时间戳，用于求 dt。
    private var lastRemoteTimestamp: TimeInterval?
    private var lastHostTime: TimeInterval?
    private var previousSensorSide: SensorSide = .unknown

    /// 采样率的指数移动平均。
    public private(set) var measuredHz: Double = 0

    public init(configuration: Configuration = .init()) {
        self.configuration = configuration
        let tier = configuration.tier
        self.yawFilter = OneEuroFilter(minCutoff: tier.minCutoff, beta: tier.beta, dCutoff: configuration.dCutoff)
        self.pitchFilter = OneEuroFilter(minCutoff: tier.minCutoff, beta: tier.beta, dCutoff: configuration.dCutoff)
        self.rollFilter = OneEuroFilter(minCutoff: tier.minCutoff, beta: tier.beta, dCutoff: configuration.dCutoff)
    }

    private mutating func reconfigureFilters() {
        let tier = configuration.tier
        yawFilter.minCutoff = tier.minCutoff
        yawFilter.beta = tier.beta
        yawFilter.dCutoff = configuration.dCutoff
        pitchFilter.minCutoff = tier.minCutoff
        pitchFilter.beta = tier.beta
        pitchFilter.dCutoff = configuration.dCutoff
        rollFilter.minCutoff = tier.minCutoff
        rollFilter.beta = tier.beta
        rollFilter.dCutoff = configuration.dCutoff
    }

    /// 当前基线姿态。
    public var currentBaseline: Quat { baseline }

    /// 是否已经建立了基线（即已经收到过至少一个样本）。
    public var hasEstablishedBaseline: Bool { hasBaseline }

    /// 把指定姿态设为"正视"基线。
    ///
    /// 基线必须存在，因为 AirPods 的 `attitude` 参考系是数据流启动时任意捕获的，
    /// **启动时并不为零**（实测约 0.1 rad）。不相对化的话一启动屏幕就是糊的。
    public mutating func setBaseline(to quaternion: Quat) {
        baseline = quaternion.normalized
        hasBaseline = true
        // 基线改变会让所有相对值整体平移，此时必须重置滤波器状态，
        // 否则滤波器会把这次平移当成一次极快的运动，产生一个假的折叠脉冲。
        yawFilter.reset()
        pitchFilter.reset()
        rollFilter.reset()
        lastUnwrappedYaw = nil
    }

    /// 处理一个原始姿态，产出可直接驱动效果的采样。
    ///
    /// - Parameters:
    ///   - rawQuaternion: `CMAttitude.quaternion` 转换来的原始姿态
    ///   - remoteTimestamp: `CMDeviceMotion.timestamp`（远端设备时间基，**只用于求 dt**）
    ///   - hostTime: 宿主时钟（`CFAbsoluteTimeGetCurrent()`），用于陈旧判定
    ///   - sensorSide: 当前推流的耳机侧
    public mutating func process(
        rawQuaternion: Quat,
        remoteTimestamp: TimeInterval?,
        hostTime: TimeInterval,
        sensorSide: SensorSide
    ) -> HeadSample {
        let raw = rawQuaternion.normalized

        // 首个样本：把当前姿态当作基线（否则会立刻产生一个假的折叠量）
        if !hasBaseline {
            baseline = raw
            hasBaseline = true
        }

        // 推流的耳机侧切换时，姿态参考系可能跳变。做法照生产实践：把当前姿态重新锚定为基线。
        // （另一种做法是保持相对姿态不变、反解新基线；但两侧 IMU 的装配朝向不同时会传递错误偏移，
        //   所以选更稳的这一种。切换会在探针界面记录一条事件。）
        var didReanchor = false
        if sensorSide != previousSensorSide, previousSensorSide != .unknown {
            baseline = raw
            yawFilter.reset()
            pitchFilter.reset()
            rollFilter.reset()
            lastUnwrappedYaw = nil
            didReanchor = true
        }
        previousSensorSide = sensorSide

        // 1) 相对化
        let relative = QuaternionMath.relative(raw, to: baseline)

        // 2) 欧拉提取（弧度 → 度）
        let rawEuler = QuaternionMath.euler(from: raw)
        let relEuler = QuaternionMath.euler(from: relative)

        // 3) yaw 解缠：否则从 +179° 到 −179° 会被滤波器当成一次巨大跳变
        let yawRadians: Double
        if let last = lastUnwrappedYaw {
            yawRadians = AngleUtils.unwrap(relEuler.yaw, near: last)
        } else {
            yawRadians = relEuler.yaw
        }
        let yawDegrees = AngleUtils.degrees(fromRadians: yawRadians)
        let pitchDegrees = AngleUtils.degrees(fromRadians: relEuler.pitch)
        let rollDegrees = AngleUtils.degrees(fromRadians: relEuler.roll)

        // 4) dt：优先用远端时间戳的差值，退化到宿主时钟
        let dt: TimeInterval
        if let remoteTimestamp, let lastRemoteTimestamp, remoteTimestamp > lastRemoteTimestamp {
            dt = AngleUtils.clamp(remoteTimestamp - lastRemoteTimestamp, 1.0 / 1000, 0.5)
        } else if let lastHostTime {
            dt = AngleUtils.clamp(hostTime - lastHostTime, 1.0 / 1000, 0.5)
        } else {
            dt = 1.0 / 25.0   // AirPods 的标称采样间隔
        }
        lastRemoteTimestamp = remoteTimestamp
        lastHostTime = hostTime

        // 采样率的指数移动平均（只在 dt 合理时更新）
        let instantHz = 1.0 / dt
        measuredHz = measuredHz == 0 ? instantHz : measuredHz * 0.9 + instantHz * 0.1

        // 5) One Euro 滤波
        let filteredYaw = yawFilter.update(yawDegrees, dt: dt)
        let filteredPitch = pitchFilter.update(pitchDegrees, dt: dt)
        let filteredRoll = rollFilter.update(rollDegrees, dt: dt)
        lastUnwrappedYaw = AngleUtils.radians(fromDegrees: filteredYaw)

        // 6) 语义化转向角（向右为正）
        let turn = QuaternionMath.headTurnDegrees(
            yawDegrees: filteredYaw,
            invert: configuration.invertDirection
        )

        _ = didReanchor

        return HeadSample(
            hostTime: hostTime,
            deltaTime: dt,
            rawYawDeg: AngleUtils.degrees(fromRadians: rawEuler.yaw),
            rawPitchDeg: AngleUtils.degrees(fromRadians: rawEuler.pitch),
            rawRollDeg: AngleUtils.degrees(fromRadians: rawEuler.roll),
            relativeYawDeg: yawDegrees,
            relativePitchDeg: pitchDegrees,
            relativeRollDeg: rollDegrees,
            yawDeg: filteredYaw,
            pitchDeg: filteredPitch,
            rollDeg: filteredRoll,
            relativeQuaternion: relative,
            rawQuaternion: raw,
            sensorSide: sensorSide,
            turnDegrees: turn
        )
    }
}
