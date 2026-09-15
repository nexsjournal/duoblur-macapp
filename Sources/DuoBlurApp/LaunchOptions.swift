import Foundation
import DuoBlurCore
import DuoBlurRender

/// 启动参数。
///
/// 存在的理由有两个：
/// 1. **自动验证**：让"启用效果 → 切到测试图案 → 设定折叠量 → 截图 → 自动退出"
///    可以一条命令跑完，不需要点界面。这是截图回归测试的基础设施。
/// 2. **给别人演示**：`--effect --debug-mode pattern` 不需要任何权限就能看到效果。
///
/// 用法示例：
/// ```
/// open build/DuoBlur.app --args --effect --debug-mode pattern --amount 0.65 --exit-after 12
/// ```
public struct LaunchOptions: Sendable {

    public var enableEffect = false
    public var debugMode: FoldDebugMode = .off
    public var amount: Double?
    public var side: TurnSide = .right
    public var preset: FoldPreset?
    public var useManualDrive = true
    /// 跑满这么多秒后自动退出。**验证/演示时必须带上**，避免在别人机器上留下一层覆盖窗。
    public var exitAfter: TimeInterval?
    /// 抑制首次启动自动打开探针窗口
    public var suppressProbeWindow = false
    /// 把事件日志写到这个文件（自动验证时拿不到 stdout，只能靠文件回读）
    public var logFile: String?
    /// 启动后把当前参数下的一帧离屏渲染写成 PNG（定量验证着色器输出）
    public var captureFrame: String?

    public static func parse(_ arguments: [String] = CommandLine.arguments) -> LaunchOptions {
        var options = LaunchOptions()
        var index = 1
        func nextValue() -> String? {
            index += 1
            return index < arguments.count ? arguments[index] : nil
        }

        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--effect":
                options.enableEffect = true
                options.suppressProbeWindow = true
            case "--debug-mode":
                if let raw = nextValue() {
                    switch raw.lowercased() {
                    case "pattern", "2": options.debugMode = .pattern
                    case "channels", "3": options.debugMode = .channels
                    case "passthrough", "1": options.debugMode = .passthrough
                    default: options.debugMode = .off
                    }
                }
            case "--amount":
                if let raw = nextValue(), let value = Double(raw) {
                    options.amount = AngleUtils.clampUnit(value)
                }
            case "--side":
                if let raw = nextValue() {
                    options.side = raw.lowercased() == "left" ? .left : .right
                }
            case "--preset":
                if let raw = nextValue() {
                    options.preset = FoldPreset.allCases.first {
                        $0.rawValue.lowercased() == raw.lowercased()
                    }
                }
            case "--auto-drive":
                options.useManualDrive = false
            case "--exit-after":
                if let raw = nextValue(), let value = Double(raw) {
                    options.exitAfter = value
                }
            case "--log-file":
                options.logFile = nextValue()
            case "--capture-frame":
                options.captureFrame = nextValue()
            case "--keep-probe":
                options.suppressProbeWindow = false
            default:
                break
            }
            index += 1
        }
        return options
    }

    public var hasAnyOption: Bool {
        enableEffect || debugMode != .off || amount != nil || preset != nil || exitAfter != nil
    }

    public var description: String {
        var parts: [String] = []
        if enableEffect { parts.append("启用效果") }
        if debugMode != .off { parts.append("调试模式=\(debugMode.localizedName)") }
        if let amount { parts.append(String(format: "折叠量=%.2f", amount)) }
        parts.append("铰链侧=\(side.localizedName)")
        if let preset { parts.append("预设=\(preset.localizedName)") }
        if let exitAfter { parts.append(String(format: "%.0fs 后退出", exitAfter)) }
        if let logFile { parts.append("日志=\(logFile)") }
        return parts.joined(separator: " · ")
    }
}
