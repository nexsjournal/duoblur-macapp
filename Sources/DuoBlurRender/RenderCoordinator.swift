import Foundation
import AppKit
import QuartzCore
import Metal
import DuoBlurCore

/// 单显示器的编排者：显示链接 → 读转向 → 推进弹簧 → 编码渲染 → 按需显示覆盖层。
///
/// **弹簧在这里推进，不在 25Hz 的传感器回调里推进。** 这是刻意的：
/// AirPods 固定 25Hz，若在传感器回调里推进，25Hz 的阶梯会直接暴露成视觉上的卡顿。
/// 在显示帧率上推进（并用真实的帧间隔）才能得到连续的运动。
@MainActor
public final class RenderCoordinator {

    // MARK: 依赖

    public let display: DisplayInfo
    private let context: MetalContext
    private let window: OverlayWindowController
    private let capture: CaptureController
    private let renderer: FoldRenderer

    // MARK: 输入（由引擎设置）

    /// 效果参数
    public var parameters: FoldParameters = FoldPreset.duoSweep.parameters {
        didSet { if parameters != oldValue { mapper.hysteresisDeg = mapper.hysteresisDeg } }
    }

    /// 手动折叠量（无耳机时用）。非 nil 时优先于 turnProvider。
    public var manualAmount: Double?
    public var manualSide: TurnSide = .right

    /// 转向映射阈值（死区/满量程/迟滞）。改参时保留映射器的锁存状态。
    public var turnMapping = TurnMappingConfig() {
        didSet { mapper.apply(turnMapping) }
    }

    /// 调试模式。非 `.off` 时始终显示覆盖层（不受折叠量影响），
    /// 用于验证覆盖/对齐/无反馈回路，以及在授权前调参。
    ///
    /// 切进/切出 `.pattern` 时会相应停掉/建立捕获流：图案模式完全不需要读屏幕，
    /// 让它照样去申请 TCC 权限是错的（而且用户没授权时会被拒绝、白白报一次错）。
    public var debugMode: FoldDebugMode = .off {
        didSet {
            guard debugMode != oldValue else { return }
            let needsCapture = debugMode != .pattern && debugMode != .channels
            if !needsCapture {
                lastError = nil
                Task { await self.capture.stop() }
            } else if isCaptureStarted {
                Task { await self.capture.start() }
            }
        }
    }

    /// 是否需要用捕获帧工作。测试图案与通道可视化模式都不需要。
    private var needsCapture: Bool { debugMode != .pattern && debugMode != .channels }
    private var isCaptureStarted = false

    /// 转向角来源（度，"向右为正"）。返回 nil 表示无数据 → fail-open 到清晰。
    public var turnProvider: (@Sendable () -> Double?)?

    /// 总开关
    public var isEnabled: Bool = false

    /// 省电：零效果时完全跳过编码，也可以顺手降低捕获帧率
    public var isCaptureSuspended: Bool = false

    // MARK: 状态

    public private(set) var amount: Double = 0
    public private(set) var side: TurnSide = .right
    public private(set) var targetAmount: Double = 0
    public private(set) var isCompositing: Bool = false
    public private(set) var lastError: String?
    public private(set) var displayLinkTicks: UInt64 = 0
    public private(set) var lastFrameInterval: TimeInterval = 0
    public private(set) var isStale: Bool = false

    private var mapper = TurnMapper()
    private var spring = DampedSpring(initial: 0, omega: 14, zeta: 1)
    private var displayLink: CADisplayLink?
    private var lastTickTimestamp: CFTimeInterval = 0

    /// 无数据超过这个时长就判为陈旧 → 200ms 内动画归零（fail-open）
    private let staleAfter: TimeInterval = 0.6

    /// 渲染帧率上限。0 表示跟随显示器刷新率。
    public var frameRateCap: Double = 60
    private var lastSampleHostTime: TimeInterval = 0

    public init(display: DisplayInfo, context: MetalContext) {
        self.display = display
        self.context = context
        self.window = OverlayWindowController(display: display, device: context.device)
        self.capture = CaptureController(display: display, device: context.device)
        self.renderer = FoldRenderer(context: context, display: display)
    }

    // MARK: 生命周期

    public func start() async {
        // 覆盖窗在 stop() 里被真正 close() 掉了（不 close 会被 AppKit 永久保留，
        // 每次启用/停用都泄漏一个全屏窗口），这里先重建窗口 ——
        // 显示链接依赖"视图在屏幕上"才回调（见 OverlayWindowController 的类注释）。
        window.reopenWindow()
        if needsCapture {
            isCaptureStarted = true
            await capture.start()
        }
        if displayLink == nil {
            let link = window.makeDisplayLink(target: self, selector: #selector(handleDisplayLink(_:)))
            // 限帧。ProMotion 屏上 CADisplayLink 默认会跟着最高刷新率跑
            // （实测 105Hz 左右），而这个效果不需要那么高的时间分辨率，
            // 白白多耗一倍电。默认 60，可在设置里放开到跟随显示器。
            if let link, #available(macOS 14.0, *) {
                link.preferredFrameRateRange = CAFrameRateRange(
                    minimum: 30,
                    maximum: Float(frameRateCap),
                    preferred: Float(frameRateCap)
                )
            }
            link?.add(to: .main, forMode: .common)
            displayLink = link
        }
    }

    public func stop() async {
        displayLink?.invalidate()
        displayLink = nil
        window.closeWindow()
        isCompositing = false
        await capture.stop()
        isCaptureStarted = false
        renderer.releaseResources()
        amount = 0
        spring.snap(to: 0)
    }

    public func updateFrame(for display: DisplayInfo) {
        window.updateFrame(for: display)
    }

    // MARK: 显示链接

    @objc private func handleDisplayLink(_ link: CADisplayLink) {
        displayLinkTicks &+= 1

        // 帧间隔优先用系统给出的预测值，它比"两次回调的时间差"更稳
        var dt = link.targetTimestamp - link.timestamp
        if !dt.isFinite || dt <= 0 {
            dt = lastTickTimestamp > 0 ? link.timestamp - lastTickTimestamp : 1.0 / 60.0
        }
        lastTickTimestamp = link.timestamp
        lastFrameInterval = dt

        advance(dt: dt)
        presentIfNeeded()
    }

    /// 推进状态机一步。拆出来是为了能脱离显示链接做单元测试。
    func advance(dt: TimeInterval) {
        guard isEnabled else {
            targetAmount = 0
            amount = spring.step(towards: 0, dt: dt)
            if amount < 0.001 { spring.snap(to: 0); amount = 0 }
            return
        }

        if let manualAmount {
            targetAmount = AngleUtils.clampUnit(manualAmount)
            side = manualSide
            // 手动模式下不走映射器，但要让映射器的锁存状态跟上，切回自动时不跳变
            mapper.reset(keepSide: true)
            isStale = false
        } else if let turn = turnProvider?() {
            (targetAmount, side) = mapper.update(turnDegrees: turn)
            lastSampleHostTime = CFAbsoluteTimeGetCurrent()
            isStale = false
        } else {
            // 无数据：fail-open。不是硬切，仍然走弹簧，200ms 左右回到清晰。
            targetAmount = 0
            isStale = true
        }

        amount = spring.step(towards: targetAmount, dt: dt)
    }

    // 静态内容下的按需重绘。
    //
    // 测试图案模式的内容是**固定的**（着色器自己生成），所以没必要按显示帧率重绘 ——
    // 只在折叠量/参数变了、或者隔了一段时间需要refresh时才编码一帧。
    // 这既省 GPU，也避免"每帧都在呈现"这种持续活动（它会干扰系统的窗口截图路径，
    // 实测表现为截图工具报 "WindowServer window ordering changed"）。
    private var lastRenderedAmount: Double = -1
    private var lastRenderTime: CFTimeInterval = 0
    private let patternRefreshInterval: TimeInterval = 0.5

    private func presentIfNeeded() {
        let shouldComposite = isEnabled && (debugMode != .off || amount > 0.001)

        if !needsCapture, isCompositing {
            let now = CACurrentMediaTime()
            let amountChanged = abs(amount - lastRenderedAmount) > 0.0005
            let needsRefresh = now - lastRenderTime > patternRefreshInterval
            if !amountChanged && !needsRefresh { return }
        }

        guard shouldComposite else {
            if window.setCompositing(false) { isCompositing = false }
            // 不需要画面时把"尚未收到捕获帧"这类过渡态错误清掉，否则它会一直粘着，
            // 让诊断面板永远显示一条早已不成立的错误。
            if !needsCapture || capture.lastError == nil {
                lastError = nil
            }
            return
        }

        // 测试图案模式不需要捕获帧，用一个 1×1 占位纹理即可（着色器不读它）。
        // 这让"覆盖层与着色器对不对"可以完全脱离屏幕录制权限来验证。
        let frame: CapturedFrame
        if !needsCapture {
            guard let placeholder = placeholderFrame() else {
                lastError = "无法创建占位纹理"
                return
            }
            frame = placeholder
        } else if let captured = capture.latestFrame {
            frame = captured
        } else {
            // 没有捕获帧就不显示：宁可让用户看到真实屏幕（fail-open），
            // 也不要显示一块空白或陈旧的画面。
            lastError = capture.lastError ?? "尚未收到捕获帧"
            if window.setCompositing(false) { isCompositing = false }
            return
        }

        guard let drawable = window.metalLayer.nextDrawable() else {
            // 2 个 drawable 都在飞行中：跳过这一帧，不要阻塞等待。
            // 图层不透明度保持现状，下一帧自然会追上。
            return
        }

        // 先切不透明度再渲染：本帧渲染出的内容会立即被合成，
        // 不会出现"窗口已显示但内容还是上一帧"的一帧闪烁。
        window.setCompositing(true)
        isCompositing = true

        let uniforms = FoldUniforms(
            parameters: parameters,
            viewportPx: window.drawableSize,
            pointPixelScale: display.scale,
            amount: amount,
            hingeOnRight: side.hingeOnRight,
            levels: display.pyramidLevels,
            geometry: frame.geometry,
            debugMode: debugMode
        )

        lastRenderedAmount = amount
        lastRenderTime = CACurrentMediaTime()

        if !renderer.render(frame: frame, to: drawable, uniforms: uniforms) {
            lastError = renderer.lastRenderError
            // 渲染失败：立刻把图层藏起来，绝不让用户看到残影或黑块
            window.setCompositing(false)
            isCompositing = false
        } else {
            // 捕获错误只在"确实需要捕获"时才算错误。
            // 图案模式下捕获流本来就不该存在，它的错误与效果无关。
            lastError = needsCapture ? capture.lastError : nil
        }
    }

    /// 1×1 占位帧，仅在测试图案模式下使用：着色器在那个模式下不读捕获纹理，
    /// 但管线仍然需要一个绑定的输入纹理。预分配并复用，渲染路径上不做分配。
    private var placeholder: CapturedFrame?

    private func placeholderFrame() -> CapturedFrame? {
        if let placeholder { return placeholder }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: 1, height: 1, mipmapped: false
        )
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .private
        guard let texture = context.device.makeTexture(descriptor: descriptor) else { return nil }
        texture.label = "DuoBlur placeholder"
        let frame = CapturedFrame(
            texture: texture,
            retained: nil,
            geometry: .identity(pointSize: display.pointSize, scale: display.scale),
            displayTime: 0,
            receivedAt: CFAbsoluteTimeGetCurrent(),
            isIdle: false
        )
        placeholder = frame
        return frame
    }

    /// 把弹簧直接对齐到当前目标量，跳过动画。
    ///
    /// 导出与黄金图像测试必须这么做：否则导出的折叠量取决于"导出那一刻弹簧走到哪了"，
    /// 结果不可复现（实测过：预期 amount=1.0 实际导出的是 0.83）。
    public func settleToTarget() {
        // 先用一个极小的 dt 推一步，让 targetAmount 按当前输入刷新
        advance(dt: 1.0 / 60.0)
        spring.snap(to: targetAmount)
        amount = targetAmount
    }

    /// 用当前参数离屏渲染一帧并写成 PNG。定量验证着色器输出用。
    @discardableResult
    public func exportFrame(to path: String, size: CGSize? = nil, settle: Bool = true) -> Bool {
        if settle { settleToTarget() }
        let pixelSize = size ?? display.pixelSize
        let uniforms = FoldUniforms(
            parameters: parameters,
            viewportPx: pixelSize,
            pointPixelScale: display.scale,
            amount: amount,
            hingeOnRight: side.hingeOnRight,
            levels: display.pyramidLevels,
            geometry: .identity(pointSize: display.pointSize, scale: display.scale),
            debugMode: debugMode
        )
        return renderer.writeFrame(to: path, uniforms: uniforms, size: pixelSize)
    }

    // MARK: 诊断

    public var diagnostics: CoordinatorDiagnostics {
        CoordinatorDiagnostics(
            displayName: display.name,
            displayID: display.id,
            pixelSize: display.pixelSize,
            pointPixelScale: display.scale,
            captureCallbackCount: capture.callbackCount,
            captureFrameCount: capture.frameCount,
            firstFrameLatency: capture.firstFrameLatency,
            renderedFrames: renderer.renderedFrames,
            pyramidLevels: display.pyramidLevels,
            displayLinkTicks: displayLinkTicks,
            frameInterval: lastFrameInterval,
            amount: amount,
            targetAmount: targetAmount,
            side: side,
            isCompositing: isCompositing,
            isStale: isStale,
            geometryIsPixelExact: capture.latestFrame?.geometry.isPixelExact ?? false,
            geometryIsSamePixelSize: capture.latestFrame?.geometry.isSamePixelSize ?? false,
            needsCapture: needsCapture,
            windowDiagnostics: window.windowDiagnostics,
            // 直接在这里取，而不是依赖 `presentIfNeeded` 的副作用。
            //
            // 曾经踩过的坑：捕获错误只在"这一帧要合成"时才被赋值，
            // 而捕获失败 → 没有转向数据 → 折叠量恒为 0 → 永远不合成
            // → 错误永远不上报，形成一个自我掩盖的诊断死锁。
            // 结果就是"零错误、零帧、零解释"，白查了很久。
            error: lastError ?? (needsCapture ? capture.lastError : nil),
            droppedFrames: capture.droppedFrames
        )
    }
}

/// 单显示器的诊断快照。
public struct CoordinatorDiagnostics: Sendable, Identifiable, Equatable {
    public var id: CGDirectDisplayID { displayID }
    public let displayName: String
    public let displayID: CGDirectDisplayID
    public let pixelSize: CGSize
    public let pointPixelScale: Double
    // SCK 回调次数（用来区分没推帧与帧被丢弃）
    public let captureCallbackCount: UInt64
    public let captureFrameCount: UInt64
    public let firstFrameLatency: TimeInterval?
    public let renderedFrames: UInt64
    public let pyramidLevels: Int
    public let displayLinkTicks: UInt64
    public let frameInterval: TimeInterval
    public let amount: Double
    public let targetAmount: Double
    public let side: TurnSide
    public let isCompositing: Bool
    public let isStale: Bool
    /// 捕获帧与显示器是否逐像素一致（几何自检）
    public let geometryIsPixelExact: Bool
    /// 捕获像素尺寸是否等于显示器像素尺寸
    public let geometryIsSamePixelSize: Bool
    /// 当前模式是否需要捕获流（测试图案模式为 false）
    public let needsCapture: Bool
    /// 覆盖窗的可见性/遮挡/图层几何 —— "渲染了但看不见"时看这里
    public let windowDiagnostics: String
    public let error: String?
    /// 被丢弃的捕获帧数（>0 说明帧到了但没能用上）
    public let droppedFrames: UInt64
}
