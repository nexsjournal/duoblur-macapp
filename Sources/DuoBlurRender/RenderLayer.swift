import Foundation
import AppKit
import DuoBlurCore

/// 捕获与渲染层。
///
/// 这一层由以下对象协作：
///
/// | 类型 | 职责 |
/// |---|---|
/// | `DisplayInventory` | 枚举显示器，监听热插拔/分辨率变更 |
/// | `CaptureController` | 每屏一路 `SCStream`，排除自身进程，处理 `.idle` 与 DRM 黑帧 |
/// | `OverlayWindowController` | 无边框 + `.screenSaver` 层级 + 点击穿透的覆盖窗 |
/// | `FoldRenderer` | 合成 pass（Duo 折页着色器），支持离屏渲染以做黄金图像测试 |
/// | `RenderCoordinator` | 每屏一个 `CADisplayLink` 驱动，推进弹簧并提交 |
///
/// 把这一层做成**库**（而不是 App 内部的一部分）的唯一目的，是让着色器能离屏运行，
/// 从而在 CI 里做黄金图像回归。
public enum DuoBlurRender {

    /// 覆盖窗的层级。`.screenSaver` 高于菜单栏（24）与普通窗口，是"整屏模糊"的必要条件。
    ///
    /// 从 `NSWindow.Level.screenSaver` 取值而不是硬编码 1000，是为了跟随系统定义。
    public static let overlayWindowLevel: Int = NSWindow.Level.screenSaver.rawValue
}
