import Foundation
import Combine
import SwiftUI
import DuoBlurCore
import DuoBlurMotion
import DuoBlurRender

/// 运动探针的视图模型。
///
/// 探针的目标是把头部姿态的符号与量级实测清楚：yaw 的正负、pitch/roll 的方向与幅度，
/// 都只能上机确认。在这些量被实测确认之前，任何效果参数都只是猜测。
@MainActor
public final class MotionProbeModel: ObservableObject {

    // MARK: 输出

    @Published public private(set) var status: MotionStatus = .idle
    @Published public private(set) var sample: HeadSample?
    @Published public private(set) var measuredHz: Double = 0
    @Published public private(set) var authorization: MotionAuthorization = .notDetermined
    @Published public private(set) var deviceAvailable: Bool = false
    @Published public private(set) var isRunning: Bool = false

    /// 转向映射器的实时输出，用于确认"死区/满量程"的手感是否合理。
    /// 也可被探针界面的滑杆/模拟按钮直接写入（没有耳机时用它验证整套方向与曲线逻辑）。
    @Published public var turnAmount: Double = 0 {
        didSet { pushDriveToEngine() }
    }
    @Published public private(set) var turnSide: TurnSide = .right

    // MARK: 屏幕效果

    /// 效果引擎。初始化可能失败（没有 Metal 设备 / 找不到着色器），所以是可选。
    private var engine: FoldEffectEngine?
    @Published public private(set) var engineStatusText: String = "未启用"
    @Published public private(set) var isScreenEffectOn = false
    /// 正在启用（用于禁用按钮、防止重复建引擎）
    @Published public private(set) var isEnablingEffect = false
    @Published public private(set) var hasScreenRecording = false
    @Published public private(set) var shaderSourceDescription = "—"
    @Published public private(set) var displayDiagnostics: [CoordinatorDiagnostics] = []

    /// 菜单栏那几行文字的低频快照（2Hz，菜单展开期间冻结）。
    /// 存在的理由：菜单内容绝不能直接读 25Hz 的传感器状态，否则 SwiftUI 会把打开的
    /// NSMenu 反复重建 —— 表现为菜单项闪烁、点不中（实测缺陷）。
    public let menuState = MenuState()

    /// 调试模式。见 `FoldDebugMode`：
    /// - `.passthrough` 一眼确认"覆盖窗在最上层 / 几何逐像素对齐 / 没有反馈回路"
    /// - `.pattern` 自己生成测试图案，**不需要屏幕录制权限**就能验证效果与调参
    @Published public var debugMode: FoldDebugMode = .off {
        didSet { engine?.debugMode = debugMode }
    }

    /// 手动驱动：忽略耳机数据，直接用探针里的折叠量。
    ///
    /// **默认关**：自动跟随头部才是产品行为；打开它只是没有耳机时的调参/演示路径。
    /// （曾经默认开，后果是"启用了效果但转头没反应"，看起来像坏了。）
    @Published public var useManualDrive = false {
        didSet { pushDriveToEngine() }
    }

    /// 当前默认音频输出设备对应的机型档案（D4：靠 CoreAudio 设备名识别机型）
    @Published public private(set) var headphoneProfile = HeadphoneProfile.current

    private var diagnosticsTimer: Timer?

    @Published public var parameters: FoldParameters = FoldPreset.duoSweep.parameters {
        didSet { engine?.parameters = parameters }
    }
    @Published public var responsiveness: ResponsivenessTier = .balanced
    @Published public var invertDirection: Bool = false {
        didSet { pushConfiguration() }
    }
    /// 转向映射阈值（死区/满量程/迟滞）。探针里的滑杆直接改它，实时生效。
    @Published public var turnMapping = TurnMappingConfig() {
        didSet {
            mapper.apply(turnMapping)
            engine?.turnMapping = turnMapping
        }
    }

    public struct ProbeEvent: Identifiable, Sendable {
        public let id = UUID()
        public let time: Date
        public let message: String
        public let isWarning: Bool
    }

    /// 最近的事件日志（连接、断连、陈旧、重建、重新锚定）。
    @Published public private(set) var events: [ProbeEvent] = []

    // MARK: 私有

    private let source: HeadphoneMotionSource
    private var mapper = TurnMapper()
    private var consumerTask: Task<Void, Never>?
    private var statusTask: Task<Void, Never>?
    private var menuTimer: Timer?
    private var uiThrottleClock: TimeInterval = 0
    private let sourceIsHeadphones: Bool

    /// 进程内单例。
    ///
    /// App 层持有它时**刻意不用 `@StateObject`**：App 的 body 一旦随模型变化重新求值，
    /// `MenuBarExtra` 的内容闭包就会被反复重建 —— 那正是菜单闪烁的成因之一。
    /// 需要观察的地方各自按需观察（探针窗口观察整个模型，菜单只观察 `menuState`）。
    public static let shared = MotionProbeModel()

    public init(useHeadphones: Bool = true) {
        sourceIsHeadphones = useHeadphones
        source = HeadphoneMotionSource()
        startMenuStateTimer()
    }

    /// 应用启动参数。由 `DuoBlurApp` 在启动时调用 `applyLaunchOptions()` 注入。
    public private(set) var launchOptions = LaunchOptions()

    /// 启动期的一次性动作（注入启动参数、打开探针窗口、安排自动退出）是否已执行。
    ///
    /// **存在的理由（真实缺陷）**：这些动作原来挂在菜单栏图标的 `.task` 上，
    /// 而那个图标依赖会频繁变化的状态（采样率/状态），于是 SwiftUI 反复重建该视图、
    /// `.task` 反复触发 → `openWindow` + `NSApp.activate(ignoringOtherApps:)` 被反复调用
    /// → **应用反复抢走键盘焦点**，用户打字时字符落到别的窗口去。
    /// 用一个显式守卫让这些动作每次启动只发生一次，不再依赖 SwiftUI 的视图生命周期。
    public private(set) var didRunLaunchSetup = false
    public private(set) var launchSetupRunCount = 0

    /// 标记启动期动作已执行。返回 false 表示之前已经执行过（调用方应直接返回）。
    public func beginLaunchSetup() -> Bool {
        launchSetupRunCount += 1
        if didRunLaunchSetup { return false }
        didRunLaunchSetup = true
        return true
    }

    /// 应用启动参数：设定初始状态，`--effect` 时自动启用屏幕效果。
    ///
    /// 这条路让"启用 → 设参数 → 截图 → 退出"完全无需点击界面，
    /// 既是自动验证的工具，也是给别人演示时不需要任何权限的入口。
    public func applyLaunchOptions(_ options: LaunchOptions) async {
        launchOptions = options
        guard options.hasAnyOption else { return }

        if let preset = options.preset {
            parameters = preset.parameters
        }
        if let amount = options.amount {
            turnAmount = amount
        }
        setTurnSide(options.side)
        // 只有显式给了折叠量才切到手动驱动；否则保持自动跟随头部。
        if options.amount != nil {
            useManualDrive = options.useManualDrive
        }
        debugMode = options.debugMode

        log("启动参数：\(options.description)")

        if options.enableEffect {
            await enableScreenEffect()
        }

        if let path = options.captureFrame {
            // 只需等到显示链接跑起来；折叠量由 settleToTarget() 直接对齐，
            // 不依赖弹簧用多久走到位（否则导出结果不可复现）
            try? await Task.sleep(for: .milliseconds(300))
            if let engine, engine.exportFrame(to: path) {
                log("已导出离屏渲染帧：\(path)")
            } else {
                log("导出离屏渲染帧失败：\(path)", isWarning: true)
            }
        }
    }

    // 刻意不写 deinit 去 cancel 那些 Task：`@MainActor` 类的 deinit 是 nonisolated 的，
    // 在里面访问 actor 隔离状态在 Swift 6 严格并发下会报错，而绕过去（nonisolated(unsafe)）
    // 会让"安全"这件事变成谎言。这个模型活到应用退出，不需要清理路径；
    // 需要显式停止时调用 stop()。

    // MARK: 生命周期

    public func start() {
        guard !isRunning else { return }
        isRunning = true
        refreshAuthorization()
        log("开始监听 AirPods（采样率约 25Hz）")
        ensureConsumers()

        if sourceIsHeadphones {
            source.onDiagnosticFacts = { [weak self] facts in
                Task { @MainActor in self?.log("耳机诊断：\(facts)") }
            }
            source.applyConfiguration(
                .init(tier: responsiveness, dCutoff: 1.0, invertDirection: invertDirection)
            )
            source.start()
        }
    }

    /// 采样/状态流的消费者**只建一次**，与 start/stop 解耦。
    ///
    /// 这是一条真实缺陷的修复：`AsyncStream` 是单次的 —— 消费者任务一旦被取消，
    /// 流就终止了，之后的 `for await` 立刻返回 nil。原实现把这两个任务放在 start() 里建、
    /// stop() 里取消，于是"停止监听 → 再开始监听"后应用显示运行中却永远收不到样本
    /// （用户视角就是"点了开始没反应，得多点几次"）。
    private func ensureConsumers() {
        guard consumerTask == nil else { return }
        consumerTask = Task { [weak self] in
            guard let self else { return }
            for await sample in self.source.samples {
                if Task.isCancelled { return }
                self.handle(sample)
            }
        }
        statusTask = Task { [weak self] in
            guard let self else { return }
            for await status in self.source.statuses {
                if Task.isCancelled { return }
                self.handle(status)
            }
        }
    }

    public func stop() {
        guard isRunning else { return }
        isRunning = false
        source.stop()
        sample = nil
        measuredHz = 0
        turnAmount = 0
        // 直接归位，而不是等 `.idle` 事件：那个事件在 stop 之后才 yield，
        // 有落进已结束的流的风险，否则界面会一直停在"追踪中"。
        status = .idle
        log("已停止监听")
    }

    public func toggle() { isRunning ? stop() : start() }

    // MARK: 一键开始 / 停止
    //
    // 用户视角里"启动"是一个动作，不该先点「开始监听 AirPods」再点「启用」。
    // 这两个入口在菜单栏和探针窗口里都指向下面的方法。

    public var isEverythingOn: Bool { isRunning || isScreenEffectOn }

    /// 开始监听 + 打开屏幕效果（自动跟随头部，不用手动驱动）。
    public func startEverything() async {
        useManualDrive = false
        if !isRunning { start() }
        await enableScreenEffect()
    }

    public func stopEverything() async {
        await disableScreenEffect()
        if isRunning { stop() }
    }

    public func toggleEverything() async {
        if isEverythingOn { await stopEverything() } else { await startEverything() }
    }

    /// 启动时自动开始（持久化）。默认开：菜单栏工具打开就该起作用，而不是等人点两次。
    /// 但只在运动权限**已经**授权时才自动开始，免得每次登录都弹系统权限框。
    @Published public var autoStartOnLaunch: Bool =
        (UserDefaults.standard.object(forKey: "autoStartOnLaunch") as? Bool) ?? true {
        didSet { UserDefaults.standard.set(autoStartOnLaunch, forKey: "autoStartOnLaunch") }
    }

    /// 设置手动驱动时的铰链侧（同时也会影响模拟按钮的语义）
    public func setTurnSide(_ side: TurnSide) {
        turnSide = side
        pushDriveToEngine()
    }

    /// 把当前头部姿态设为"正视"基线。
    public func recenter() {
        source.recenter()
        mapper.reset(keepSide: true)
        log("已把当前姿态设为正中（基线）")
    }

    public func refreshAuthorization() {
        authorization = Permissions.motion
        deviceAvailable = source.isDeviceAvailable
        hasScreenRecording = Permissions.hasScreenRecording
        headphoneProfile = HeadphoneProfile.current
    }

    // MARK: 屏幕效果

    /// 启用屏幕效果。**不会自动请求权限**：先看状态，缺权限时提示用户去点按钮。
    /// 自动弹权限框（而且是在用户没预期的时候弹）是很糟糕的体验。
    public func enableScreenEffect() async {
        // 防重入：按钮双击 / 命令行与界面同时触发时，会建出两个引擎 ——
        // 第二个覆盖第一个的引用，第一个的覆盖窗留在屏幕上且再也关不掉。
        guard !isScreenEffectOn, !isEnablingEffect else { return }
        isEnablingEffect = true
        defer { isEnablingEffect = false }

        // 刻意**不**用 `CGPreflightScreenCaptureAccess()` 做硬门禁。
        //
        // 理由：preflight 会给出假阴性 —— 实测遇到过"系统设置里开关明明是开的，
        // preflight 却返回 false"，于是应用在真正尝试之前就把自己挡住了，
        // 而真正的答案只有 `SCStream.startCapture` 才知道。
        // 所以这里直接尝试；失败时把 SCK 的错误翻译成权限指引（见 refreshDiagnostics）。
        //
        // 唯一的例外：合成测试图案与通道可视化完全不读屏幕，不该走捕获这条链路。
        hasScreenRecording = Permissions.hasScreenRecording

        do {
            let engine = try FoldEffectEngine()
            shaderSourceDescription = engine.shaderSourceDescription
            engine.parameters = parameters
            engine.turnMapping = turnMapping
            engine.debugMode = debugMode
            engine.turnProvider = Self.makeTurnProvider(source: source)
            applyDrive(to: engine)
            await engine.start()
            self.engine = engine
            isScreenEffectOn = true
            engineStatusText = "已启用"
            log("屏幕效果已启用（着色器：\(engine.shaderSourceDescription)）")
            startDiagnosticsTimer()
        } catch {
            let message = (error as? MetalContextError)?.description ?? error.localizedDescription
            engineStatusText = "启用失败：\(message)"
            log("启用屏幕效果失败：\(message)", isWarning: true)
        }
    }

    public func disableScreenEffect() async {
        guard let engine else { return }
        await engine.stop()
        self.engine = nil
        isScreenEffectOn = false
        engineStatusText = "已停用"
        displayDiagnostics = []
        stopDiagnosticsTimer()
        log("屏幕效果已停用")
    }

    public func requestScreenRecordingPermission() {
        let granted = Permissions.requestScreenRecording()
        hasScreenRecording = granted || Permissions.hasScreenRecording
        log(hasScreenRecording
            ? "已获得屏幕录制权限"
            : "尚未获得屏幕录制权限。系统只会在首次申请时弹窗，之后需要在系统设置里手动打开。",
            isWarning: !hasScreenRecording)
    }

    /// 把最新的折叠量与方向推给引擎。
    private func pushDriveToEngine() {
        guard let engine else { return }
        applyDrive(to: engine)
    }

    private func applyDrive(to engine: FoldEffectEngine) {
        engine.manualSide = turnSide
        if useManualDrive {
            engine.manualAmount = turnAmount
            engine.turnProvider = nil
        } else {
            engine.manualAmount = nil
            engine.turnProvider = Self.makeTurnProvider(source: source)
        }
    }

    /// 构造转向角来源。**关键：必须自己判陈旧并返回 nil。**
    ///
    /// `latestSample` 在数据中断后仍然保留最后一个值（用于诊断显示），
    /// 如果直接返回它，效果会冻结在最后的折叠量上，而不是按 fail-open 恢复到清晰。
    /// 所以这里显式检查两件事：状态可用 + 样本足够新（宿主时钟）。
    private static func makeTurnProvider(
        source: HeadphoneMotionSource
    ) -> @Sendable () -> Double? {
        {
            guard source.currentStatus.isUsable else { return nil }
            guard let sample = source.latestSample else { return nil }
            guard CFAbsoluteTimeGetCurrent() - sample.hostTime < 0.6 else { return nil }
            return sample.turnDegrees
        }
    }

    /// SCK 在权限不足时的报错文案不稳定（中英文、不同系统版本措辞不同），
    /// 所以按关键词判断，而不是精确匹配。
    private static func looksLikePermissionError(_ message: String) -> Bool {
        let lower = message.lowercased()
        return lower.contains("tcc")
            || lower.contains("denied")
            || lower.contains("not authorized")
            || lower.contains("拒绝了")
            || lower.contains("权限")
            || lower.contains("declined")
    }

    /// 重新检测权限（用户可能刚在系统设置里改过）。无需重启应用。
    public func recheckPermissions() {
        refreshAuthorization()
        log("权限复检：屏幕录制=\(hasScreenRecording ? "已授权" : "未授权")，"
            + "运动与健身=\(authorization.localizedName)")
    }

    private func startDiagnosticsTimer() {
        stopDiagnosticsTimer()
        let timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshDiagnostics() }
        }
        RunLoop.main.add(timer, forMode: .common)
        diagnosticsTimer = timer
    }

    // MARK: 菜单栏状态快照

    /// 2Hz 把低频快照推给菜单。菜单展开期间 `MenuState` 会自行冻结（见其注释）。
    private func startMenuStateTimer() {
        let timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.publishMenuSnapshot() }
        }
        RunLoop.main.add(timer, forMode: .common)
        menuTimer = timer
    }

    private func publishMenuSnapshot() {
        let statusText: String
        if status.isUsable {
            let side = turnSide == .right ? "右耳铰链" : "左耳铰链"
            statusText = "运行中 · \(side) · 折叠 \(Int(parameters.equivalentHingeAngleDeg(amount: turnAmount).rounded()))°"
        } else {
            statusText = status.localizedDescription
        }

        let detailText: String
        if let s = sample {
            detailText = String(format: "yaw %+.1f° · pitch %+.1f° · roll %+.1f°",
                                s.yawDeg, s.pitchDeg, s.rollDeg)
        } else {
            detailText = isRunning ? "等待数据…" : ""
        }

        menuState.update(
            statusText: statusText,
            detailText: detailText,
            isRunning: isEverythingOn,
            isTrackable: status.isUsable
        )
    }

    private func stopDiagnosticsTimer() {
        diagnosticsTimer?.invalidate()
        diagnosticsTimer = nil
    }

    private func refreshDiagnostics() {
        guard let engine else { return }
        let diagnostics = engine.diagnostics

        // 只在真的变了才写 @Published。无条件赋值会让所有观察者（包括打开的菜单）
        // 以 4Hz 被无意义地作废重建。
        if displayDiagnostics != diagnostics.displays {
            displayDiagnostics = diagnostics.displays
        }
        appendDiagnosticsToLogFile(diagnostics)

        // 权威信号：真的收到了捕获帧就说明屏幕录制权限是通的。
        // 只信 `CGPreflightScreenCaptureAccess()` 会假阴性（已实测），
        // 于是出现"屏幕已经被模糊了，面板还在喊未授权"的自相矛盾状态。
        if !hasScreenRecording,
           diagnostics.displays.contains(where: { $0.needsCapture && $0.captureFrameCount > 0 }) {
            hasScreenRecording = true
            log("屏幕录制权限确认可用（已收到捕获帧）")
        }

        let error = diagnostics.error
        // "尚未收到捕获帧"是过渡态（首帧要等 SCK 建流），不是错误
        let isPendingFirstFrame = error?.hasPrefix("尚未收到捕获帧") ?? false
        let text: String
        if let error, !isPendingFirstFrame {
            text = Self.looksLikePermissionError(error) ? "缺少屏幕录制权限" : "错误：\(error)"
        } else if isPendingFirstFrame {
            text = "等待首帧…"
        } else {
            text = "运行中"
        }

        if engineStatusText != text {
            let previous = engineStatusText
            engineStatusText = text
            // 只在文案真的变化时记一条，避免 4Hz 刷屏
            if let error, !isPendingFirstFrame {
                if Self.looksLikePermissionError(error) {
                    log("屏幕录制权限被拒绝（系统原话：\(error)）。"
                        + "请在系统设置 → 隐私与安全性 → 录屏与系统录音 中打开 DuoBlur；"
                        + "若开关已是开的，请关掉再打开一次。", isWarning: true)
                } else {
                    log("渲染错误：\(error)（原状态：\(previous)）", isWarning: true)
                }
            } else if previous == "错误：\(error ?? "")" {
                log("渲染错误已恢复")
            }
        }
        // **刻意不在这里自动停用效果。** 曾经的实现是"任何错误 → 250ms 后停用"，
        // 而"尚未收到捕获帧"这类过渡态也会命中，于是用户点「启用」之后效果自己消失，
        // 观感是"点一次没反应，要点第二次"。真正的失效路径由渲染层自己处理
        // （渲染失败/无帧时把图层藏起来，屏幕立即恢复真实内容）。
    }

    public func setResponsiveness(_ tier: ResponsivenessTier) {
        responsiveness = tier
        pushConfiguration()
        log("响应度 → \(tier.localizedName)（ω=\(tier.springOmega) rad/s）")
    }

    private func pushConfiguration() {
        source.applyConfiguration(
            .init(tier: responsiveness, dCutoff: 1.0, invertDirection: invertDirection)
        )
    }

    // MARK: 事件处理

    private func handle(_ sample: HeadSample) {
        self.sample = sample
        measuredHz = source.measuredHz

        // 手动驱动时**必须**忽略耳机数据 —— 这是复选框 "手动驱动折叠量（忽略耳机数据）"
        // 的字面承诺。曾经这里照样写入 turnAmount，导致开着手动模式时
        // 折叠量仍被 25Hz 的转头数据持续覆盖，滑杆根本按不住。
        // （真实渲染路径的手动模式本来就不读耳机，只有探针 UI 漏了这道闸。）
        guard !useManualDrive else { return }

        let (amount, side) = mapper.update(turnDegrees: sample.turnDegrees)
        turnAmount = amount
        turnSide = side
    }

    private func handle(_ status: MotionStatus) {
        guard status != self.status else { return }
        let previous = self.status
        self.status = status
        deviceAvailable = source.isDeviceAvailable

        // 只在"进入"某个状态时记一条日志，避免刷屏
        switch status {
        case .tracking:
            if case .tracking = previous {} else {
                log("已开始追踪（首个有效样本已到达）")
            }
        case .waitingForDevice:
            if case .waitingForDevice = previous {} else {
                log("等待 AirPods 连接…", isWarning: true)
            }
        case .waitingForFirstSample:
            if case .waitingForFirstSample = previous {} else {
                log("已连接，等待首个数据样本…")
            }
        case .stale:
            if case .stale = previous {} else {
                log("数据中断", isWarning: true)
            }
        case .rebuilding(let attempt):
            log("重建 AirPods 会话（第 \(attempt) 次）", isWarning: true)
        case .unauthorized(let auth):
            log("缺少运动权限：\(auth.localizedName)", isWarning: true)
        case .failed(let reason):
            log("放弃重试：\(reason)", isWarning: true)
        case .idle:
            break
        }
    }

    public func log(_ message: String, isWarning: Bool = false) {
        let event = ProbeEvent(time: Date(), message: message, isWarning: isWarning)
        events.insert(event, at: 0)
        if events.count > 200 { events.removeLast(events.count - 200) }
        appendToLogFile(event)
    }

    /// 把日志同时写到 `--log-file` 指定的文件。
    /// 自动验证时用 `open --args` 启动拿不到 stdout，只能靠文件回读。
    /// 诊断快照写文件。只走文件、不进事件列表 —— 4Hz 的快照会把事件列表刷掉。
    private func appendDiagnosticsToLogFile(_ diagnostics: EngineDiagnostics) {
        guard let path = launchOptions.logFile else { return }
        var lines: [String] = []
        lines.append("诊断：运行中=\(diagnostics.isRunning) 着色器=\(diagnostics.shaderSource) 错误=\(diagnostics.error ?? "无")")
        for d in diagnostics.displays {
            lines.append(String(
                format: "  屏 %@ %dx%d scale=%.0f | 显示链接 %llu 次 | 回调 %llu 次 | 捕获 %llu 帧 | 渲染 %llu 帧 | 折叠 %.3f/%.3f | 合成=%@ | 陈旧=%@ | 几何1:1=%@ | 需捕获=%@ | 丢弃=%llu",
                d.displayName,
                Int(d.pixelSize.width), Int(d.pixelSize.height), d.pointPixelScale,
                d.displayLinkTicks, d.captureCallbackCount, d.captureFrameCount, d.renderedFrames,
                d.amount, d.targetAmount,
                d.isCompositing ? "是" : "否",
                d.isStale ? "是" : "否",
                d.geometryIsPixelExact ? "是" : "否",
                d.needsCapture ? "是" : "否",
                d.droppedFrames
            ))
        }
        for d in diagnostics.displays { lines.append("  " + d.windowDiagnostics) }
        let text = lines.joined(separator: "\n") + "\n"
        guard let data = text.data(using: .utf8) else { return }
        let url = URL(fileURLWithPath: path)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }

    private func appendToLogFile(_ event: ProbeEvent) {
        guard let path = launchOptions.logFile else { return }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        let line = "\(formatter.string(from: event.time)) \(event.isWarning ? "⚠" : "·") \(event.message)\n"
        guard let data = line.data(using: .utf8) else { return }
        let url = URL(fileURLWithPath: path)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }

    // MARK: 实测记录导出

    /// 生成一段便于核对与归档的实测记录：把诊断事实、原始/相对/滤波后的三组角度
    /// 和驱动效果用的折叠量一次性摊开，用于排查方向或量级是否正确。
    public func measurementReport() -> String {
        guard let s = sample else {
            return "（尚无数据。请先戴上 AirPods 并点击「开始监听」）"
        }
        return """
        AirPods 运动实测记录  \(ISO8601DateFormatter().string(from: Date()))
        ---------------------------------------------------------------
        耳机诊断  \(source.diagnosticFacts)
        ---------------------------------------------------------------
        状态                \(status.localizedDescription)
        运动权限            \(authorization.localizedName)
        设备可用            \(deviceAvailable)
        实测采样率          \(String(format: "%.1f", measuredHz)) Hz
        推流耳机侧          \(s.sensorSide.localizedName)
        ---------------------------------------------------------------
        原始姿态（未相对化）
          raw yaw           \(fmt(s.rawYawDeg))°
          raw pitch         \(fmt(s.rawPitchDeg))°
          raw roll          \(fmt(s.rawRollDeg))°
        相对基线
          rel yaw           \(fmt(s.relativeYawDeg))°
          rel pitch         \(fmt(s.relativePitchDeg))°
          rel roll          \(fmt(s.relativeRollDeg))°
        滤波后（驱动效果用）
          yaw               \(fmt(s.yawDeg))°
          pitch             \(fmt(s.pitchDeg))°
          roll              \(fmt(s.rollDeg))°
        ---------------------------------------------------------------
        「向右转」语义值   \(fmt(s.turnDegrees))°   （正值 = 向右转）
        折叠量             \(String(format: "%.3f", turnAmount))
        铰链侧             \(turnSide.localizedName)转 → 铰链在屏幕\(turnSide == .right ? "右" : "左")边缘
        等效折叠角         \(String(format: "%.0f", parameters.equivalentHingeAngleDeg(amount: turnAmount)))°
        ---------------------------------------------------------------
        方向自检（记录实测值，与期望值核对）：
          头向左转 30° → yaw 应为 +0.52 rad（≈ +30°）  实测：______
          头向右转 30° → yaw 应为 −0.52 rad（≈ −30°）  实测：______
          低头 20°     → pitch 应为 −0.35 rad（≈ −20°） 实测：______
          头向右肩倾   → roll 应为正                     实测：______
          静止正视     → |yaw| 应很小但可能非零          实测：______
        """
    }

    private func fmt(_ v: Double) -> String {
        String(format: "%+7.2f", v)
    }

    /// 当前效果的简短描述，显示在菜单栏与探针顶部。
    public var summaryLine: String {
        guard let s = sample else { return "无数据" }
        return "\(s.sensorSide.localizedName) · \(fmt(s.yawDeg))° · 折叠 \(String(format: "%.0f", parameters.equivalentHingeAngleDeg(amount: turnAmount)))°"
    }
}
