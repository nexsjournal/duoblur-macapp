import Foundation
import AppKit
import Combine

/// 菜单栏菜单里那几行文字的**低频快照**。
///
/// 存在的理由（实测缺陷）：菜单内容原来直接读 `MotionProbeModel` 的实时状态
/// （`sample` / `turnAmount` 以 25Hz 更新），SwiftUI 于是把已经展开的 NSMenu
/// 反复重建 —— 表现就是菜单项闪烁、高亮被重置、鼠标松开时落不到原来那一项上，
/// 也就是"选都选不中"。
///
/// 两条约束一起用：
/// 1. 只以 ≤2Hz 更新，且**值不变就不发布**（避免无意义的 objectWillChange）
/// 2. 菜单展开期间**完全冻结**（`NSMenu.didBeginTracking/didEndTracking` 通知），
///    只在关闭后补发一次 —— 这是"菜单展开期间绝对稳定"的保证
@MainActor
public final class MenuState: ObservableObject {

    /// 第一行：状态 + 关键读数（如"运行中 · 右耳 · 折叠 176°"）
    @Published public private(set) var statusText: String = "未启动"
    /// 第二行：姿态明细
    @Published public private(set) var detailText: String = ""
    /// 主按钮用：整体是否在运行
    @Published public private(set) var isRunning = false
    /// "把当前姿态设为正中"是否可用
    @Published public private(set) var isTrackable = false

    private var isMenuOpen = false
    private var pending: Snapshot?

    private struct Snapshot: Equatable {
        var statusText: String
        var detailText: String
        var isRunning: Bool
        var isTrackable: Bool
    }

    public init() {
        let center = NotificationCenter.default
        // 这两个通知对本进程内打开的任何菜单都会发出，包括状态栏菜单。
        // 观察者不显式移除：本对象与进程同生命周期，闭包对 self 是弱引用。
        center.addObserver(
            forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.isMenuOpen = true }
        }
        center.addObserver(
            forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isMenuOpen = false
                if let pending = self.pending {
                    self.pending = nil
                    self.apply(pending)
                }
            }
        }
    }

    /// 由模型以 ≤2Hz 调用。菜单展开期间只暂存，不发布。
    public func update(statusText: String, detailText: String, isRunning: Bool, isTrackable: Bool) {
        let snapshot = Snapshot(
            statusText: statusText, detailText: detailText,
            isRunning: isRunning, isTrackable: isTrackable
        )
        if isMenuOpen {
            pending = snapshot
            return
        }
        apply(snapshot)
    }

    private func apply(_ snapshot: Snapshot) {
        // 逐字段比较后再写：@Published 不比较相等性，无条件赋值也会发布
        if statusText != snapshot.statusText { statusText = snapshot.statusText }
        if detailText != snapshot.detailText { detailText = snapshot.detailText }
        if isRunning != snapshot.isRunning { isRunning = snapshot.isRunning }
        if isTrackable != snapshot.isTrackable { isTrackable = snapshot.isTrackable }
    }
}
