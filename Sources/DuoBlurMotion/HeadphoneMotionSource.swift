import Foundation
import os
import DuoBlurCore
@preconcurrency import CoreMotion

#if canImport(CoreMotion)

/// 真实的 AirPods 头部姿态数据源。
///
/// 除了核心的读取，这里集中处理了实际上机踩过的全部坑：
///
/// | 坑 | 处理 |
/// |---|---|
/// | 首个样本延迟 0.25s~10s+，非固定值 | 20s 宽限期，期间状态为 `.waitingForFirstSample` |
/// | 每次回调都可能带 `nil` + error | 两者都 guard |
/// | 自动入耳检测关闭时静默断流 | 0.6s 陈旧看门狗（不依赖事件） |
/// | macOS"报告已连接但 0Hz"卡死 | 2s 后**重建为一个新的 `CMHeadphoneMotionManager` 实例**（唯一能脱离卡死的办法） |
/// | `attitude` 启动时不为零 | 首样本即取基线（在 `OrientationPipeline` 里） |
/// | 推流的耳机会中途切换且姿态跳变 | `sensorLocation` 变化时重新锚定基线 |
/// | 陈旧判定不能用 `motion.timestamp`（远端时间基） | 用 `CFAbsoluteTimeGetCurrent()` |
/// | `authorizationStatus()` 无变更回调 | 未决定时 0.5s 轮询一次 |
///
/// 线程模型：所有可变状态都在 `stateLock` 保护下；CoreMotion 的回调在后台队列到达，
/// 状态流通过 `AsyncStream.Continuation`（本身线程安全）投递给消费者。
public final class HeadphoneMotionSource: NSObject, MotionSource, CMHeadphoneMotionManagerDelegate, @unchecked Sendable {

    // MARK: 内部状态

    private struct State: Sendable {
        var pipeline = OrientationPipeline()
        var watchdog = StalenessWatchdog()
        var status: MotionStatus = .idle
        var latest: HeadSample?
        var isConnected = false
        var isRunning = false
        var lastAuthorizationPoll: TimeInterval = 0
    }

    /// `CMHeadphoneMotionManager` 与 `CMDeviceMotion` 都早于 Swift 并发标注，
    /// 无法声明为 Sendable。这里用一个受锁保护的盒子显式承担这个"不安全"，
    /// 而不是把整个类标成 `@unchecked Sendable` 后在各处散落裸访问。
    private final class ManagerBox: @unchecked Sendable {
        var manager: CMHeadphoneMotionManager?
        func teardown() {
            manager?.stopDeviceMotionUpdates()
            manager?.stopConnectionStatusUpdates()
            manager?.delegate = nil
            manager = nil
        }
    }

    private let stateLock = OSAllocatedUnfairLock(initialState: State())
    private let managerBox = ManagerBox()
    private let samplesContinuation: AsyncStream<HeadSample>.Continuation
    private let statusesContinuation: AsyncStream<MotionStatus>.Continuation

    public let samples: AsyncStream<HeadSample>
    public let statuses: AsyncStream<MotionStatus>

    /// CoreMotion 回调队列。串行，且不与主线程互等。
    private let motionQueue: OperationQueue = {
        let q = OperationQueue()
        q.name = "com.duoblur.app.headphone-motion"
        q.maxConcurrentOperationCount = 1
        q.qualityOfService = .userInteractive
        return q
    }()

    private let watchdogQueue = DispatchQueue(label: "com.duoblur.app.watchdog", qos: .utility)
    private var watchdogTimer: DispatchSourceTimer?

    // MARK: 初始化

    public override init() {
        (samples, samplesContinuation) = AsyncStream.makeStream(
            of: HeadSample.self,
            bufferingPolicy: .bufferingNewest(2)
        )
        (statuses, statusesContinuation) = AsyncStream.makeStream(
            of: MotionStatus.self,
            bufferingPolicy: .bufferingNewest(4)
        )
        super.init()
    }

    deinit {
        watchdogTimer?.cancel()
        managerBox.teardown()
        samplesContinuation.finish()
        statusesContinuation.finish()
    }

    // MARK: 只读快照

    public var currentStatus: MotionStatus { stateLock.withLock { $0.status } }

    public var latestSample: HeadSample? { stateLock.withLock { $0.latest } }

    public var measuredHz: Double { stateLock.withLock { $0.pipeline.measuredHz } }

    /// 当前的授权状态（直通 CoreMotion，因为它是类方法）。
    public static var authorization: MotionAuthorization {
        switch CMHeadphoneMotionManager.authorizationStatus() {
        case .authorized: return .authorized
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .notDetermined
        @unknown default: return .notDetermined
        }
    }

    /// 系统是否报告有可用设备。注意：**它不代表真的有数据在流**（见"0Hz 卡死"）。
    public var isDeviceAvailable: Bool {
        managerBox.manager?.isDeviceMotionAvailable ?? false
    }

    /// 一组决定性的 API 事实。
    ///
    /// 为什么要有它：当"读不到头部数据"时，可能的根因有五六种
    /// （机型不支持 / 没戴 / 不是当前音频输出 / 权限被拒 / 会话卡死 / 入耳检测关闭），
    /// 而从外部完全看不出来。把这几个字段一次性摊出来，就能直接定位到具体哪一种，
    /// 不用来回猜。用户排查时只需要复制这一行。
    public var diagnosticFacts: String {
        let manager = managerBox.manager
        let authorization = HeadphoneMotionSource.authorization
        let available = manager?.isDeviceMotionAvailable
        let connectionActive = manager?.isConnectionStatusActive
        let motionActive = manager?.isDeviceMotionActive
        let side = stateLock.withLock { $0.latest?.sensorSide.localizedName } ?? "无数据"
        let profile = HeadphoneProfile.current

        func flag(_ value: Bool?) -> String {
            guard let value else { return "无管理器" }
            return value ? "是" : "否"
        }

        return [
            profile.diagnosticLine,
            "运动权限=\(authorization.localizedName)",
            "设备可用(isDeviceMotionAvailable)=\(flag(available))",
            "连接活跃(isConnectionStatusActive)=\(flag(connectionActive))",
            "数据流活跃(isDeviceMotionActive)=\(flag(motionActive))",
            "采样=\(String(format: "%.1f", measuredHz))Hz",
            "推流耳=\(side)",
        ].joined(separator: " | ")
    }

    // MARK: 生命周期

    public func start() {
        let alreadyRunning = stateLock.withLock { state -> Bool in
            if state.isRunning { return true }
            state.isRunning = true
            return false
        }
        guard !alreadyRunning else { return }

        publish(status: .waitingForDevice)
        startWatchdogTimer()
        buildSession(noteRebuildCompleted: false)
    }

    public func stop() {
        let wasRunning = stateLock.withLock { state -> Bool in
            if !state.isRunning { return false }
            state.isRunning = false
            state.latest = nil
            state.isConnected = false
            return true
        }
        guard wasRunning else { return }

        watchdogTimer?.cancel()
        watchdogTimer = nil
        managerBox.teardown()
        publish(status: .idle)
    }

    public func recenter() {
        let sample: HeadSample? = stateLock.withLock { state in
            guard let latest = state.latest else { return nil }
            // 用手里的原始四元数作为新基线，而不是相对四元数——避免相对化被叠加两次
            state.pipeline.setBaseline(to: latest.rawQuaternion)
            return latest
        }
        // 立刻用新基线重算一次，让 UI 马上回到 0，而不是等下一个样本
        if let sample {
            reprocess(sample)
        }
    }

    /// 设置响应度档位 / 方向反转。
    public func applyConfiguration(_ configuration: OrientationPipeline.Configuration) {
        stateLock.withLock { $0.pipeline.configuration = configuration }
    }

    /// 建流完成后调用一次，把 API 事实交给调用方去记录。
    /// 用回调而不是直接打印，是为了让日志落在应用层的事件流里（用户能一键复制）。
    public var onDiagnosticFacts: (@Sendable (String) -> Void)?

    private func reportDiagnosticFacts() {
        let facts = diagnosticFacts
        let handler = onDiagnosticFacts
        DispatchQueue.main.async { handler?(facts) }
    }

    // MARK: 会话管理

    private func buildSession(noteRebuildCompleted: Bool) {
        let now = CFAbsoluteTimeGetCurrent()

        // 与 stop() 的竞态：tick() 是在锁内决定"要重建"、在锁外执行重建的，
        // 期间用户可能已经停止了监听。这里先复核，避免停掉之后又被悄悄拉起一个会话。
        let stillRunning = stateLock.withLock { $0.isRunning }
        guard stillRunning else { return }

        stateLock.withLock { state in
            if noteRebuildCompleted {
                state.watchdog.noteRebuildCompleted(at: now)
            } else {
                state.watchdog.reset()
            }
        }

        // 必须先拆干净再建：同一个实例在卡死后无法复活，必须换新的。
        managerBox.teardown()

        let manager = CMHeadphoneMotionManager()
        manager.delegate = self
        managerBox.manager = manager

        // 先注册连接状态更新，再请求数据 —— 这样不需要轮询就能拿到连接/断开事件。
        manager.startConnectionStatusUpdates()

        let connected = manager.isConnectionStatusActive
        let available = manager.isDeviceMotionAvailable
        stateLock.withLock { state in
            // **必须把连接状态写回 state**：只看 delegate 回调是不够的 ——
            // 设备在我们 start 之前就已经连着时，`headphoneMotionManagerDidConnect`
            // 可能永远不来，于是 tick() 用 isConnected=false 判成"等待设备"，
            // 而 25Hz 的样本又把状态改成"追踪中"，两个写者让状态以 10Hz 反复翻面
            // （菜单文字乱跳、日志刷屏）。
            state.isConnected = connected
            // 重建路径**不能**再 noteConnect：那个函数会把 rebuildAttempts 清零，
            // 于是"连上了但 0Hz"永远重试 3 次的上限被绕过 → 每 20s 无限重建。
            if connected, !noteRebuildCompleted {
                state.watchdog.noteConnect(at: now)
            }
        }
        publish(status: available ? .waitingForFirstSample : .waitingForDevice)

        // 稍等片刻让 CoreMotion 完成连接状态评估，再报告事实
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.reportDiagnosticFacts()
        }

        manager.startDeviceMotionUpdates(to: motionQueue) { [weak self] motion, error in
            guard let self else { return }
            if let error {
                self.handleMotionError(error)
                return
            }
            // 每次回调都可能带 nil，必须 guard
            guard let motion else { return }
            self.ingest(motion)
        }
    }

    private func rebuildSession(attempt: Int) {
        publish(status: .rebuilding(attempt: attempt))
        // 在锁外重建：manager 的方法可能同步回调 delegate，而 stateLock 不是递归锁
        buildSession(noteRebuildCompleted: true)
    }

    // MARK: 采样处理

    private func ingest(_ motion: CMDeviceMotion) {
        let hostTime = CFAbsoluteTimeGetCurrent()
        let side = Self.side(from: motion.sensorLocation)
        let q = Self.quaternion(from: motion.attitude.quaternion)
        guard q.isFinite else { return }

        let sample: HeadSample? = stateLock.withLock { state in
            state.watchdog.noteSample(at: hostTime)
            let s = state.pipeline.process(
                rawQuaternion: q,
                remoteTimestamp: motion.timestamp,
                hostTime: hostTime,
                sensorSide: side
            )
            state.latest = s
            state.status = .tracking
            return s
        }

        guard let sample else { return }
        samplesContinuation.yield(sample)
        statusesContinuation.yield(.tracking)
    }

    /// 基线变化后用同一个原始姿态重算一份采样，让下游立刻看到新值。
    private func reprocess(_ previous: HeadSample) {
        let hostTime = CFAbsoluteTimeGetCurrent()
        let sample: HeadSample? = stateLock.withLock { state in
            let s = state.pipeline.process(
                rawQuaternion: previous.rawQuaternion,
                remoteTimestamp: nil,
                hostTime: hostTime,
                sensorSide: previous.sensorSide
            )
            state.latest = s
            return s
        }
        if let sample { samplesContinuation.yield(sample) }
    }

    private func handleMotionError(_ error: Error) {
        let ns = error as NSError
        guard ns.domain == CMErrorDomain else {
            // 未知错误：交给看门狗按"无数据"处理，不在这里做判断
            publish(status: .stale(since: 0))
            return
        }

        switch ns.code {
        case CMErrorCode.motionActivityNotAuthorized, CMErrorCode.notAuthorized:
            publish(status: .unauthorized(HeadphoneMotionSource.authorization))
        case CMErrorCode.notAvailable:
            publish(status: .waitingForDevice)
        case CMErrorCode.nilData:
            // 数据为空是正常的过渡态（首个样本前会反复出现），不改变状态
            break
        default:
            publish(status: .stale(since: 0))
        }
    }

    // MARK: 看门狗

    private func startWatchdogTimer() {
        let timer = DispatchSource.makeTimerSource(queue: watchdogQueue)
        // 0.1s 的检查间隔：足够快地发现 0.6s 的陈旧，又不产生可测的功耗
        timer.schedule(deadline: .now() + 0.1, repeating: 0.1, leeway: .milliseconds(20))
        timer.setEventHandler { [weak self] in self?.tick() }
        watchdogTimer = timer
        timer.resume()
    }

    private func tick() {
        let now = CFAbsoluteTimeGetCurrent()

        enum Action {
            case none
            case publish(MotionStatus)
            case rebuild(Int)
        }

        let action: Action = stateLock.withLock { state in
            guard state.isRunning else { return .none }

            // 权限轮询：authorizationStatus() 没有变更回调，未决定时必须轮询。
            let authorization = HeadphoneMotionSource.authorization
            if authorization != .authorized {
                if now - state.lastAuthorizationPoll >= 0.5 {
                    state.lastAuthorizationPoll = now
                    let next: MotionStatus = authorization == .notDetermined
                        ? .waitingForDevice
                        : .unauthorized(authorization)
                    if state.status != next {
                        state.status = next
                        return .publish(next)
                    }
                }
                // 未授权时不推进看门狗，否则会误报"数据陈旧"
                return .none
            }

            let connected = state.isConnected
            let verdict = state.watchdog.evaluate(now: now, isConnected: connected)

            switch verdict {
            case .ok:
                return .none

            case .waitingForDevice:
                if state.status == .waitingForDevice { return .none }
                state.status = .waitingForDevice
                return .publish(.waitingForDevice)

            case .waitingForFirstSample:
                if state.status == .waitingForFirstSample { return .none }
                state.status = .waitingForFirstSample
                return .publish(.waitingForFirstSample)

            case .stale(let since):
                if case .stale = state.status { return .none }
                let next = MotionStatus.stale(since: since)
                state.status = next
                return .publish(next)

            case .shouldRebuild(let attempt):
                // 状态由 rebuildSession 统一发布，这里只把动作交给锁外执行。
                // 重建必须在锁外：manager 的方法可能同步回调 delegate，而 stateLock 不是递归锁。
                return .rebuild(attempt)

            case .giveUp:
                if case .failed = state.status { return .none }
                let next = MotionStatus.failed(
                    reason: "多次重建后仍未收到数据。请确认 AirPods 戴在耳中，且是这台 Mac 的音频输出设备。"
                )
                state.status = next
                return .publish(next)
            }
        }

        switch action {
        case .none:
            break
        case .publish(let status):
            statusesContinuation.yield(status)
        case .rebuild(let attempt):
            rebuildSession(attempt: attempt)
        }
    }

    private func publish(status: MotionStatus) {
        let changed = stateLock.withLock { state -> Bool in
            guard state.status != status else { return false }
            state.status = status
            return true
        }
        guard changed else { return }
        statusesContinuation.yield(status)
    }

    // MARK: CMHeadphoneMotionManagerDelegate

    public func headphoneMotionManagerDidConnect(_ manager: CMHeadphoneMotionManager) {
        let now = CFAbsoluteTimeGetCurrent()
        stateLock.withLock { state in
            state.isConnected = true
            state.watchdog.noteConnect(at: now)
        }
        publish(status: .waitingForFirstSample)
    }

    public func headphoneMotionManagerDidDisconnect(_ manager: CMHeadphoneMotionManager) {
        stateLock.withLock { state in
            state.isConnected = false
            state.latest = nil
            state.watchdog.noteDisconnect()
        }
        publish(status: .waitingForDevice)
    }

    // MARK: 类型转换

    private static func quaternion(from q: CMQuaternion) -> Quat {
        Quat(w: q.w, x: q.x, y: q.y, z: q.z)
    }

    private static func side(from location: CMDeviceMotion.SensorLocation) -> SensorSide {
        switch location {
        case .headphoneLeft: return .left
        case .headphoneRight: return .right
        default: return .unknown
        }
    }
}

/// `CMError` 是一个纯 C 枚举（`typedef enum { … } CMError`），
/// Swift 对它的导入形态没有稳定的符号名可依赖，所以直接用数值 + 注释表。
/// 来源：`MacOSX.sdk/.../CoreMotion.framework/Headers/CMError.h`
///
/// | 值 | 常量 |
/// |---|---|
/// | 105 | CMErrorMotionActivityNotAuthorized |
/// | 109 | CMErrorNotAvailable |
/// | 111 | CMErrorNotAuthorized |
/// | 112 | CMErrorNilData |
private enum CMErrorCode {
    static let motionActivityNotAuthorized = 105
    static let notAvailable = 109
    static let notAuthorized = 111
    static let nilData = 112
}

#endif
