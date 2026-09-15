import SwiftUI
import AppKit
import DuoBlurCore

/// DuoBlur —— 菜单栏应用。
///
/// 应用形态是"菜单栏常驻 + 全屏覆盖窗"。本文件负责菜单栏入口与运动探针窗口，
/// 覆盖窗与折页渲染由 `DuoBlurRender` 提供。
///
/// 注意 `Info.plist` 里的 `LSUIElement = true`：**不显示 Dock 图标**。
/// 这类工具应用应该"隐形"，只在菜单栏留一个安静的入口。
@main
struct DuoBlurApp: App {

    /// 模型**刻意不用 `@StateObject`**：那样 App 的 body 会随模型变化重新求值，
    /// `MenuBarExtra` 的内容闭包随之反复重建 —— 这是菜单项闪烁的成因之一。
    /// 需要观察的地方各自按需观察：探针窗口观察整个模型，菜单只观察 `menuState`。
    private let model = MotionProbeModel.shared
    @Environment(\.openWindow) private var openWindow

    /// 启动参数（自动验证 / 免权限演示用，见 `LaunchOptions`）
    private let launch = LaunchOptions.parse()

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent(model: model, state: model.menuState)
        } label: {
            // 菜单栏图标**刻意保持静态**，不依赖任何会变化的状态。
            //
            // 之前的版本让它读 `model.status` 来"用图标反映状态"，后果是：
            // 追踪期间状态/采样率以 25Hz 变化 → 图标视图被反复重建 →
            // 挂在它上面的 `.task` 反复触发 → 反复 `openWindow` + `NSApp.activate`
            // → **反复抢键盘焦点**，严重干扰输入。
            // 状态信息放在展开后的菜单里（下面 MenuBarContent），图标只做入口。
            Image(systemName: "rectangle.split.2x1")
                .task { await runLaunchSetupOnce() }
        }
        .menuBarExtraStyle(.menu)

        Window("DuoBlur 控制面板", id: WindowID.probe) {
            ProbeView(model: model)
        }
        .defaultSize(width: 760, height: 900)
        .windowResizability(.contentMinSize)
    }

    enum WindowID {
        static let probe = "probe"
    }

    /// 带上 `--exit-after` 时必须自动退出：这个应用会在屏幕上盖一层覆盖窗，
    /// 自动验证跑完不能把别人机器留在"屏幕被盖住"的状态。
    private func scheduleAutoExitIfNeeded() {
        guard let seconds = launch.exitAfter else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            await model.disableScreenEffect()
            NSApp.terminate(nil)
        }
    }

    /// 启动时打开探针窗口。
    ///
    /// **M0 阶段每次启动都开**：这个应用常驻菜单栏、没有 Dock 图标，
    /// 只留一个菜单栏图标会让人找不到入口（实测反馈："探针里的开始监听在哪"）。
    /// 等它变成正式产品（M3 起）再改回"仅在菜单里按需打开"。
    ///
    /// （`defaultLaunchBehavior` 是 macOS 15+ 的 API，这里手动实现以保持 14.0 部署目标。）
    /// 打开探针窗口。
    ///
    /// 只在"当前没有任何自己的窗口可见"时才激活应用 —— 避免把用户正在打字的
    /// 前台应用抢走焦点。窗口已经开着就什么都不做。
    private func openProbeWindow() {
        guard !launch.suppressProbeWindow else { return }
        openWindow(id: WindowID.probe)

        let hasVisibleWindow = NSApp.windows.contains { $0.isVisible && $0.level == .normal }
        if !hasVisibleWindow {
            NSApp.activate(ignoringOtherApps: true)
            model.log("已打开探针窗口（本次启动的第 \(model.launchSetupRunCount) 次启动期调用）")
        } else {
            model.log("探针窗口已存在，不重复激活（避免抢焦点）")
        }
    }

    /// 启动期的一次性动作。
    ///
    /// 用显式守卫（`beginLaunchSetup`）而不是依赖 SwiftUI 的 `.task` 只跑一次 ——
    /// 后者在菜单栏标签这种会被反复重建的宿主里没有保证（这正是一个真实缺陷的成因）。
    private func runLaunchSetupOnce() async {
        guard model.beginLaunchSetup() else { return }
        await model.applyLaunchOptions(launch)
        scheduleAutoExitIfNeeded()
        // 让场景先就绪，否则 openWindow 可能落空
        try? await Task.sleep(for: .milliseconds(150))
        openProbeWindow()

        // 启动时自动开始：只在运动权限**已经**授权时（不会弹系统权限框），
        // 且用户没有给启动参数（那说明是脚本化验证，不该自动改状态）。
        if model.autoStartOnLaunch, !launch.hasAnyOption, Permissions.motion == .authorized {
            await model.startEverything()
            model.log("已按「启动时自动开始」启动（监听 + 屏幕效果）")
        }

        // 2 秒后报告 .task 实际被触发了多少次。
        // 这是为了**验证那个抢焦点缺陷的成因**：如果这个数字远大于 1，
        // 说明菜单栏标签确实被反复重建、.task 被反复触发，守卫是必需的。
        try? await Task.sleep(for: .seconds(2))
        model.log("启动期动作统计：.task 共被触发 \(model.launchSetupRunCount) 次"
                  + "（=1 表示只在启动时触发一次；>1 说明菜单栏标签被反复重建）")
        // 窗口自检：面板"看不见"时要知道是 AppKit 没显示它，还是显示后被盖住了
        for w in NSApp.windows {
            model.log("窗口自检：\"\(w.title.isEmpty ? "(无标题)" : w.title)\" 层级=\(w.level.rawValue)"
                      + " isVisible=\(w.isVisible)"
                      + " 遮挡可见=\(w.occlusionState.contains(.visible))"
                      + " 尺寸=\(Int(w.frame.width))x\(Int(w.frame.height))")
        }
    }
}

/// 菜单栏展开后的内容。
///
/// **只观察 `MenuState`（≤2Hz，展开期间冻结），不观察模型** —— 这是"菜单不闪烁"的关键。
/// 模型只作为普通引用传入，用来触发动作，不参与观察。
private struct MenuBarContent: View {

    let model: MotionProbeModel
    @ObservedObject var state: MenuState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(state.statusText)
        if !state.detailText.isEmpty {
            Text(state.detailText)
        }

        Divider()

        // 一个按钮完成"开始监听 + 打开屏幕效果"。用户视角里启动就是一个动作。
        Button(state.isRunning ? "停止（监听 + 屏幕效果）" : "开始（监听 + 屏幕效果）") {
            Task { await model.toggleEverything() }
        }

        Button("把当前姿态设为正中") { model.recenter() }
            .disabled(!state.isTrackable)

        Divider()

        Button("打开控制面板…") {
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: DuoBlurApp.WindowID.probe)
        }

        Divider()

        Button("打开「运动与健身」设置…") { Permissions.openMotionSettings() }
        Button("打开「屏幕录制」设置…") { Permissions.openScreenRecordingSettings() }

        Divider()

        Button("退出 DuoBlur") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
