import Foundation
import AppKit
import QuartzCore
import CoreGraphics
import Metal

/// 承载 `CAMetalLayer` 的视图。
///
/// 用 `makeBackingLayer()` 而不是给普通 NSView 赋 `layer`：后者在 AppKit 重建
/// 图层树时可能被替换掉，导致我们往一个已经不在屏幕上的图层里渲染（画面不更新）。
final class MetalHostView: NSView {

    let metalLayer = CAMetalLayer()

    /// 图层尺寸变化时回调（显示器分辨率/缩放变更）
    var onBackingChange: ((CGSize) -> Void)?

    override func makeBackingLayer() -> CALayer { metalLayer }

    override var isOpaque: Bool { false }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        applyBackingScale()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        applyBackingScale()
    }

    private func applyBackingScale() {
        let scale = window?.backingScaleFactor ?? 2
        metalLayer.contentsScale = scale
        let pixelSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        guard pixelSize.width > 0, pixelSize.height > 0 else { return }
        if metalLayer.drawableSize != pixelSize {
            metalLayer.drawableSize = pixelSize
            onBackingChange?(pixelSize)
        }
    }
}

/// 一台显示器上的覆盖窗。
///
/// ## 为什么窗口始终 `orderFront`，而用图层不透明度控制可见性
///
/// 最初的做法是"effect == 0 时 `orderOut` 覆盖窗，保证零延迟"。但
/// `NSView.displayLink` 的文档明确写着"视图被隐藏或不在任何显示器上时回调不会被调用"——
/// 窗口一旦 `orderOut`，驱动整个状态机的时钟就停了，形成一个死锁：需要时钟才能知道
/// 该不该显示，而需要显示才能有时钟。
///
/// 解法是把"窗口在不在"和"画面可不可见"解耦：
///
/// - 窗口**始终** `orderFrontRegardless`，视图永不隐藏 → `CADisplayLink` 一直回调
/// - 用 `metalLayer.opacity` 在 0 / 1 之间切换 → 不透明度为 0 时 WindowServer
///   不合成这一层，用户看到的是真实屏幕，**延迟为零**，与 `orderOut` 的等效
/// - 不透明度为 0 时**跳过整个渲染编码**，只在需要显示时渲染 → 正视屏幕时开销接近零
///
/// 代价是多了一个常驻的全屏透明窗口。它点击穿透、无阴影、不参与循环切换，
/// 对系统而言基本不存在。
@MainActor
public final class OverlayWindowController {

    public let display: DisplayInfo
    public let metalLayer: CAMetalLayer
    public private(set) var drawableSize: CGSize

    /// 窗口是可选的：停止时会真的 `close()` 掉（见 `closeWindow()` 的说明），
    /// 再次启动时由 `reopenWindow()` 重建。
    private var window: NSWindow?
    private let hostView: MetalHostView

    /// 当前是否正在合成我们的画面（= 图层不透明度为 1）。
    public private(set) var isCompositing = false

    /// 不透明度切换次数，诊断用。
    public private(set) var transitions: Int = 0

    public init(display: DisplayInfo, device: MTLDevice) {
        self.display = display
        self.drawableSize = display.pixelSize

        let hostView = MetalHostView(frame: CGRect(origin: .zero, size: display.pointSize))
        hostView.wantsLayer = true
        self.hostView = hostView

        // 显式把图层挂到视图上，**不依赖 `makeBackingLayer()` 的调用时机**。
        //
        // 这是一个真实踩过的坑：只设置 `wantsLayer = true` 并让 `makeBackingLayer()`
        // 返回我们的 CAMetalLayer 时，AppKit 有可能自己造一个普通 CALayer 当背衬，
        // 于是我们的金属图层成了一棵孤立的层——它照样能申请 drawable、照样能渲染、
        // `isVisible` / `occlusionState` / `opacity` 全都报正常，但屏幕上永远什么都不显示。
        // 直接赋值 `view.layer` 就没有这个不确定性。
        hostView.layer = hostView.metalLayer

        let layer = hostView.metalLayer
        layer.device = device
        layer.pixelFormat = .bgra8Unorm
        // 我们只渲染不读回，声明出来让驱动选择更省的布局
        layer.framebufferOnly = true
        // 2 个 drawable 足够，且能压低呈现延迟（3 个会引入一帧排队）
        layer.maximumDrawableCount = 2
        layer.presentsWithTransaction = false
        layer.isOpaque = false
        layer.opacity = 0
        layer.contentsScale = display.scale
        layer.drawableSize = display.pixelSize
        layer.allowsNextDrawableTimeout = true
        self.metalLayer = layer

        // 窗口的创建/置前统一走 openWindow()（首次与"停止后再启动"共用同一条路径），
        // 这里不再内联建窗 —— 否则会出现两份建窗代码，其中一份永远不会执行。
        hostView.onBackingChange = { [weak self] size in
            self?.drawableSize = size
        }

        openWindow()
    }

    /// 建窗并置前（首次与"停止后再启动"共用）。
    private func openWindow() {
        guard window == nil else { return }

        let window = OverlayNSWindow(
            contentRect: display.cocoaFrame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostView
        // 层级：**刻意低于弹出菜单**（kCGPopUpMenuWindowLevel = 101）。
        //
        // 原来用 .screenSaver(1000)，后果是系统菜单栏展开的菜单、右键菜单
        // 全被压在覆盖层下面 —— 菜单看不见、点不中（实测缺陷："选都选不中"）。
        // 100 仍然高于菜单栏(24) 和普通窗口(0)，"整屏模糊"的覆盖面不受影响，
        // 只是各种弹出菜单/系统对话框保持清晰可用。
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.popUpMenuWindow)) - 1)
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        window.ignoresMouseEvents = true        // 点击穿透
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.isMovable = false
        // 关键：不设 .none 的话 AppKit 会给窗口加 0.2s 淡入，
        // 模糊出现时会变成"先灰一下再变清"
        window.animationBehavior = .none
        window.acceptsMouseMovedEvents = false
        window.isReleasedWhenClosed = false
        self.window = window

        window.orderFrontRegardless()
    }

    deinit {
        // deinit 是 nonisolated；窗口清理不能碰 actor 隔离状态。
        // OverlayNSWindow 自己负责在关闭时把窗口从屏幕上摘掉。
    }

    /// 切换是否合成我们的画面。返回是否发生了变化。
    @discardableResult
    public func setCompositing(_ on: Bool) -> Bool {
        guard isCompositing != on else { return false }
        isCompositing = on
        transitions += 1
        // 用隐式动画会看到淡入淡出，这里必须显式禁用
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        metalLayer.opacity = on ? 1 : 0
        CATransaction.commit()
        return true
    }

    public func makeDisplayLink(target: Any, selector: Selector) -> CADisplayLink? {
        // 用 NSView（而不是 NSScreen）的显示链接：视图永不隐藏，
        // 因此回调一定会持续，并且它跟随视图所在显示器的刷新率。
        hostView.displayLink(target: target, selector: selector)
    }

    /// 窗口级诊断。渲染成功但屏幕上看不到时，问题一定在这几个字段里 ——
    /// 所以把它们摊出来，而不是靠猜。
    public var windowDiagnostics: String {
        guard let window else { return "窗口[已关闭]" }
        let occlusion = window.occlusionState.contains(.visible) ? "可见" : "被遮挡"
        return String(
            format: "窗口[isVisible=%@ frame=%.0fx%.0f@(%.0f,%.0f) 屏幕=%@ 空间=%@ 遮挡=%@ 层级=%.0f] "
                  + "图层[opacity=%.2f bounds=%.0fx%.0f drawable=%.0fx%.0f scale=%.1f]",
            window.isVisible ? "是" : "否",
            window.frame.width, window.frame.height, window.frame.origin.x, window.frame.origin.y,
            window.screen?.localizedName ?? "无",
            window.isOnActiveSpace ? "当前" : "其他",
            occlusion,
            Double(window.level.rawValue),
            Double(metalLayer.opacity),
            metalLayer.bounds.width, metalLayer.bounds.height,
            metalLayer.drawableSize.width, metalLayer.drawableSize.height,
            Double(metalLayer.contentsScale)
        ) + " 挂载[视图.layer===金属层=\(hostView.layer === metalLayer ? "是" : "否")"
          + " contentView===宿主视图=\(window.contentView === hostView ? "是" : "否")]"
    }

    /// 关闭窗口并把它从 AppKit 的窗口列表里摘掉。
    ///
    /// **为什么必须真的 `close()`**：`orderOut` 之后窗口仍被 AppKit 的窗口列表强引用
    /// （`isReleasedWhenClosed = false`），于是每次「启用→停用」循环、每次显示器移除
    /// 都会永久多出一个全屏窗口 + 其 drawable 池（5K 屏上每块 drawable 数十 MB）。
    /// 实测：`orderOut` 后即使控制器被释放，窗口仍留在 `NSApp.windows` 里。
    public func closeWindow() {
        setCompositing(false)
        window?.orderOut(nil)
        window?.contentView = nil
        window?.close()
        window = nil
    }

    /// 停止之后再次启动时重建窗口。
    public func reopenWindow() {
        openWindow()
    }

    /// 窗口尺寸/位置重算（显示器排列或分辨率变更后）
    public func updateFrame(for display: DisplayInfo) {
        window?.setFrame(display.cocoaFrame, display: false)
    }
}

/// 无边框覆盖窗。
///
/// 三个 override 都是必需的：默认的 NSWindow 会尝试成为 key/main 窗口并接受
/// 鼠标事件，这两件事对这个覆盖层都是错的。
private final class OverlayNSWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override var acceptsFirstResponder: Bool { false }
}
