import Foundation
import AppKit
import CoreMotion
import DuoBlurCore

/// 权限申请与状态检查。
///
/// 两个权限，没有第三个：屏幕录制（TCC `ScreenCapture`）与运动与健身（TCC `Motion`）。
/// 全局热键走 Carbon `RegisterEventHotKey`，**不需要辅助功能权限** —— 它让我们能少要一个权限。
public enum Permissions {

    // MARK: 运动与健身

    /// 当前运动权限状态（映射到 `DuoBlurCore` 的类型，避免 Core 依赖 CoreMotion）。
    ///
    /// `authorizationStatus()` 是**类方法且没有变更回调**，所以 UI 需要轮询它。
    public static var motion: MotionAuthorization {
        switch CMHeadphoneMotionManager.authorizationStatus() {
        case .authorized: return .authorized
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .notDetermined
        @unknown default: return .notDetermined
        }
    }

    /// 是否应该主动触发运动权限弹窗。
    ///
    /// 注意：**弹窗只会在真正签名且经 LaunchServices 启动的 .app 里出现**。
    /// 直接跑裸二进制（`swift run`）不会触发任何提示，运动数据会永远静默失败 ——
    /// 这就是 `make run` 用 `open` 而不是直接执行二进制的原因。
    public static var shouldRequestMotion: Bool { motion == .notDetermined }

    // MARK: 屏幕录制

    /// 预检屏幕录制权限（不会弹窗）。
    public static var hasScreenRecording: Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// 主动申请屏幕录制权限。首次调用会弹窗；已被拒绝时不会重复弹窗，只能去系统设置改。
    @discardableResult
    public static func requestScreenRecording() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    // MARK: 系统设置深链

    public static func openMotionSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Motion")
    }

    public static func openScreenRecordingSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    }

    private static func open(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }
}
