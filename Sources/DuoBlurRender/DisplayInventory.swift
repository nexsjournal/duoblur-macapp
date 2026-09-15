import Foundation
import AppKit
import CoreGraphics

/// 一台显示器的全部相关几何。
///
/// 同时提供 Cocoa 坐标（给 `NSWindow.setFrame`，原点在左下、y 向上）与
/// CoreGraphics 坐标（给捕获层，原点在左上、y 向下）——这两种约定混用是
/// macOS 窗口代码里最常见的 bug 来源，所以在这里一次性算清楚，别处不再换算。
public struct DisplayInfo: Identifiable, Hashable, Sendable {
    public let id: CGDirectDisplayID
    /// Cocoa 全局坐标（左下原点）。直接喂给 `NSWindow.setFrame`。
    public let cocoaFrame: CGRect
    /// CoreGraphics 全局坐标（左上原点）。给捕获/几何计算用。
    public let cgBounds: CGRect
    /// 尺寸（pt）
    public let pointSize: CGSize
    /// 物理像素尺寸（= pointSize × scale）
    public let pixelSize: CGSize
    /// 每 pt 对应的像素数（Retina 上为 2）
    public let scale: Double
    public let name: String
    public let isMain: Bool

    public var pixelCount: Int { Int(pixelSize.width * pixelSize.height) }

    /// 金字塔层数：够表达最大模糊半径即可，并能被 `FoldParameters` 的上限约束。
    ///
    /// 需要 `σ_max = sigmaPerLevel · 2^(levels-1)` 覆盖 `maxRadiusPt · scale`
    /// （200pt × 2 = 400px）。σ 每级 0.9 时需要 log2(400/0.9) ≈ 8.8 → 10 层。
    public var pyramidLevels: Int {
        let needed = Int(ceil(log2(max(pixelSize.width, pixelSize.height)))) + 1
        return max(1, min(10, needed))
    }
}

/// 显示器清单，并在显示器热插拔 / 分辨率变更 / 排列变更时通知。
///
/// 继承 `NSObject` 是为了能用 target/selector 形式的通知观察：block 形式的
/// token 是 non-Sendable 的，而 `@MainActor` 类的 `deinit` 是 nonisolated 的，
/// 在 deinit 里访问它会触发 Swift 6 的并发检查。用 `self` 当观察者则完全不需要
/// 存 token，也就没有这个问题。
@MainActor
public final class DisplayInventory: NSObject {

    public private(set) var displays: [DisplayInfo] = []

    /// 变更回调。参数是新的清单。引擎据此为新增显示器建立覆盖窗与捕获流、
    /// 为移除的显示器拆掉它们。
    public var onChange: (([DisplayInfo]) -> Void)?

    public override init() {
        super.init()
        refresh()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleScreenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func handleScreenParametersChanged() {
        // 通知可能在屏幕参数尚未稳定时到达，延到下一条 runloop 再读，
        // 否则会拿到一组过渡态尺寸（表现为覆盖窗短暂错位）。
        Task { @MainActor in
            self.refresh()
            self.onChange?(self.displays)
        }
    }

    public func refresh() {
        let mainID = CGMainDisplayID()
        let cocoaMainTop = NSScreen.screens.first?.frame.maxY ?? 0

        displays = NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")
            ] as? NSNumber else { return nil }

            let displayID = CGDirectDisplayID(number.uint32Value)
            let scale = screen.backingScaleFactor
            let pointSize = screen.frame.size

            return DisplayInfo(
                id: displayID,
                cocoaFrame: screen.frame,
                cgBounds: CGRect(
                    x: screen.frame.minX,
                    y: cocoaMainTop - screen.frame.maxY,
                    width: screen.frame.width,
                    height: screen.frame.height
                ),
                pointSize: pointSize,
                pixelSize: CGSize(width: pointSize.width * scale, height: pointSize.height * scale),
                scale: scale,
                name: screen.localizedName,
                isMain: displayID == mainID
            )
        }
    }
}
