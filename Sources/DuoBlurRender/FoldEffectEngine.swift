import Foundation
import AppKit
import Metal
import DuoBlurCore

/// 效果引擎：把"捕获 + 覆盖窗 + 渲染"编排到每台显示器上。
///
/// 对外的职责边界：
/// - 显示器集合变化时增删协调者（热插拔、分辨率变更、排列变更）
/// - 统一的开关、参数、手动折叠量、自检模式
/// - 汇总诊断信息
///
/// 真正的每帧工作都在 `RenderCoordinator` 里。
@MainActor
public final class FoldEffectEngine {

    // MARK: 对外可读

    public private(set) var isRunning = false
    public private(set) var lastError: String?
    public private(set) var shaderSourceDescription: String = "未初始化"

    // MARK: 对外可写

    public var parameters: FoldParameters = FoldPreset.duoSweep.parameters {
        didSet { forEachCoordinator { $0.parameters = parameters } }
    }
    public var manualAmount: Double? {
        didSet { forEachCoordinator { $0.manualAmount = manualAmount } }
    }
    public var manualSide: TurnSide = .right {
        didSet { forEachCoordinator { $0.manualSide = manualSide } }
    }
    /// 调试模式：直通自检 / 合成测试图案（不需要屏幕录制权限）
    public var debugMode: FoldDebugMode = .off {
        didSet { forEachCoordinator { $0.debugMode = debugMode } }
    }
    /// 转向角来源（度，"向右为正"）
    public var turnProvider: (@Sendable () -> Double?)? {
        didSet { forEachCoordinator { $0.turnProvider = turnProvider } }
    }
    /// 转向映射阈值（死区/满量程/迟滞）
    public var turnMapping = TurnMappingConfig() {
        didSet { forEachCoordinator { $0.turnMapping = turnMapping } }
    }
    /// 只作用于这些显示器；空集合表示全部
    public var enabledDisplayIDs: Set<CGDirectDisplayID> = []

    // MARK: 内部

    private let context: MetalContext
    private let inventory = DisplayInventory()
    private var coordinators: [CGDirectDisplayID: RenderCoordinator] = [:]
    private var isBuilt = false

    public init() throws {
        self.context = try MetalContext()
        switch context.shaderSource {
        case .precompiledLibrary(let url):
            shaderSourceDescription = "预编译 metallib（\(url.lastPathComponent)）"
        case .runtimeCompiled:
            shaderSourceDescription = "运行时编译（本机缺 Metal 工具链或 bundle 里没有 metallib）"
        }

        inventory.onChange = { [weak self] displays in
            guard let self else { return }
            Task { @MainActor in await self.reconcile(displays: displays) }
        }
    }

    // MARK: 生命周期

    public func start() async {
        guard !isRunning else { return }
        isRunning = true

        if !isBuilt {
            inventory.refresh()
            await reconcile(displays: inventory.displays)
            isBuilt = true
        }

        forEachCoordinator { $0.isEnabled = true }
        for coordinator in coordinators.values {
            await coordinator.start()
        }
    }

    public func stop() async {
        guard isRunning else { return }
        isRunning = false
        forEachCoordinator { $0.isEnabled = false }
        for coordinator in coordinators.values {
            await coordinator.stop()
        }
        lastError = nil
    }

    /// 显示器集合变化时，为新增的建、为移除的拆。
    /// 不重建未变化的显示器，避免打断正在显示的效果。
    private func reconcile(displays: [DisplayInfo]) async {
        let wanted = displays.filter { enabledDisplayIDs.isEmpty || enabledDisplayIDs.contains($0.id) }
        let wantedIDs = Set(wanted.map(\.id))

        for (id, coordinator) in coordinators where !wantedIDs.contains(id) {
            await coordinator.stop()
            coordinators.removeValue(forKey: id)
        }

        for display in wanted {
            if let existing = coordinators[display.id] {
                // 分辨率或缩放变了（改缩放模式、插拔外接屏、合盖）：几何映射、
                // 捕获流的分辨率、模糊半径的 px 换算全都会失效 —— 必须重建协调者，
                // 而不是只挪一下窗口。这是"外接屏 + 合盖"这类场景最容易踩到的点。
                let geometryChanged = existing.display.pixelSize != display.pixelSize
                    || existing.display.scale != display.scale
                if geometryChanged {
                    await existing.stop()
                    coordinators.removeValue(forKey: display.id)
                } else {
                    existing.updateFrame(for: display)
                    continue
                }
            }
            let coordinator = RenderCoordinator(display: display, context: context)
            coordinator.parameters = parameters
            coordinator.manualAmount = manualAmount
            coordinator.manualSide = manualSide
            coordinator.turnMapping = turnMapping
            coordinator.debugMode = debugMode
            coordinator.turnProvider = turnProvider
            coordinator.isEnabled = isRunning
            coordinators[display.id] = coordinator
            if isRunning {
                await coordinator.start()
            }
        }
    }

    private func forEachCoordinator(_ body: (RenderCoordinator) -> Void) {
        for coordinator in coordinators.values { body(coordinator) }
    }

    // MARK: 诊断

    public var diagnostics: EngineDiagnostics {
        let list = coordinators.values
            .map(\.diagnostics)
            .sorted { $0.displayID < $1.displayID }

        // 任一屏出错就反映到引擎层，UI 只需要看一个字段
        lastError = list.compactMap(\.error).first

        return EngineDiagnostics(
            isRunning: isRunning,
            shaderSource: shaderSourceDescription,
            displays: list,
            debugMode: debugMode,
            error: lastError
        )
    }

    /// 导出主显示器当前参数下的一帧 PNG（离屏，不经过窗口合成）。
    /// 用于定量验证着色器输出，也是黄金图像测试的入口。
    @discardableResult
    public func exportFrame(to path: String) -> Bool {
        guard let coordinator = coordinators.values.first(where: { $0.display.isMain })
                ?? coordinators.values.first else { return false }
        return coordinator.exportFrame(to: path)
    }
}

public struct EngineDiagnostics: Sendable {
    public let isRunning: Bool
    public let shaderSource: String
    public let displays: [CoordinatorDiagnostics]
    public let debugMode: FoldDebugMode
    public let error: String?

    public var summary: String {
        guard isRunning else { return "未启用" }
        if let error { return "错误：\(error)" }
        guard !displays.isEmpty else { return "没有可用显示器" }
        return displays
            .map { d in
                String(format: "%@ 折叠 %.2f · 捕获 %llu 帧 · 渲染 %llu 帧",
                       d.displayName, d.amount, d.captureFrameCount, d.renderedFrames)
            }
            .joined(separator: "\n")
    }
}
