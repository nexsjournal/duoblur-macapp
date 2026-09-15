import Foundation
import DuoBlurCore

/// 数据陈旧看门狗与自愈决策。
///
/// **为什么必须有它**：AirPods 有多种失效模式会在 iOS/macOS 上静默发生——
/// 自动入耳检测关闭时不发断连事件、耳机被 iPhone 抢占路由、以及 macOS 特有的
/// "系统报告已连接但实际 0Hz"。这些都只能靠"多久没收到样本"来发现，不能依赖事件。
///
/// 纯值类型 + 显式 `now` 入参，因此可以用假时钟瞬间推进测试，不用 `sleep`。
public struct StalenessWatchdog: Sendable {

    /// 多久没样本算陈旧。
    public var staleAfter: TimeInterval
    /// 连接后等首个样本的宽限期。首个样本延迟实测 0.25s ~ 10s+，**不是固定值**。
    public var firstSampleGrace: TimeInterval
    /// 陈旧持续多久后发起会话重建。
    public var rebuildAfter: TimeInterval
    /// 最多重建几次。
    public var maxRebuildAttempts: Int

    public enum Verdict: Sendable, Equatable {
        /// 一切正常。
        case ok
        /// 没有可用设备（耳机没连上 / 没戴上 / 不是当前音频输出）。
        case waitingForDevice
        /// 已连接，等首个样本且在宽限期内。
        case waitingForFirstSample
        /// 数据陈旧。
        case stale(since: TimeInterval)
        /// 应当重建会话。
        case shouldRebuild(attempt: Int)
        /// 重建次数用尽。
        case giveUp
    }

    private var lastSampleTime: TimeInterval?
    private var connectedAt: TimeInterval?
    private var rebuildAttempts = 0
    private var lastRebuildRequestTime: TimeInterval?
    private var hasGivenUp = false

    public init(
        staleAfter: TimeInterval = 0.6,
        firstSampleGrace: TimeInterval = 20,
        rebuildAfter: TimeInterval = 2.0,
        maxRebuildAttempts: Int = 3
    ) {
        self.staleAfter = staleAfter
        self.firstSampleGrace = firstSampleGrace
        self.rebuildAfter = rebuildAfter
        self.maxRebuildAttempts = maxRebuildAttempts
    }

    public var attempts: Int { rebuildAttempts }

    public mutating func noteSample(at now: TimeInterval) {
        lastSampleTime = now
        hasGivenUp = false
    }

    public mutating func noteConnect(at now: TimeInterval) {
        connectedAt = now
        lastSampleTime = nil
        rebuildAttempts = 0
        lastRebuildRequestTime = nil
        hasGivenUp = false
    }

    public mutating func noteDisconnect() {
        connectedAt = nil
        lastSampleTime = nil
    }

    /// 会话重建完成后调用。重置"最后样本时间"，给新会话一个完整的宽限期。
    public mutating func noteRebuildCompleted(at now: TimeInterval) {
        lastSampleTime = nil
        connectedAt = now
        lastRebuildRequestTime = now
    }

    public mutating func reset() {
        lastSampleTime = nil
        connectedAt = nil
        rebuildAttempts = 0
        lastRebuildRequestTime = nil
        hasGivenUp = false
    }

    /// 评估当前状态。同一个 `now` 重复调用是幂等的（除了重建请求的时间门槛）。
    public mutating func evaluate(now: TimeInterval, isConnected: Bool) -> Verdict {
        if hasGivenUp { return .giveUp }

        guard isConnected else {
            return .waitingForDevice
        }

        guard let connectedAt else {
            // 已连接但没记录连接时刻（例如启动时耳机已经连着）
            return .waitingForFirstSample
        }

        // 还没收到过任何样本
        guard let lastSampleTime else {
            if now - connectedAt < firstSampleGrace {
                return .waitingForFirstSample
            }
            return requestRebuildIfAllowed(now: now)
        }

        let since = now - lastSampleTime
        if since <= staleAfter { return .ok }

        if since > rebuildAfter {
            return requestRebuildIfAllowed(now: now)
        }

        return .stale(since: since)
    }

    private mutating func requestRebuildIfAllowed(now: TimeInterval) -> Verdict {
        if rebuildAttempts >= maxRebuildAttempts {
            hasGivenUp = true
            return .giveUp
        }
        // 两次重建之间至少隔 rebuildAfter，避免每个 tick 都请求一次
        if let last = lastRebuildRequestTime, now - last < rebuildAfter {
            return .stale(since: now - (lastSampleTime ?? now))
        }
        rebuildAttempts += 1
        lastRebuildRequestTime = now
        return .shouldRebuild(attempt: rebuildAttempts)
    }
}
