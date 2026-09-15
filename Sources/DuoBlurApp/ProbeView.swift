import SwiftUI
import AppKit
import CoreGraphics
import DuoBlurCore
import DuoBlurMotion
import DuoBlurRender

/// 把 `FoldParameters` 的公式画成一张强度图。
///
/// **这不是渲染结果的替代**。它跑的是**同一份公式**（`FoldParameters` 里的 Swift 实现），
/// 所以用它调出来的方向、渐进曲线、折痕位置、变暗分布可以直接搬进着色器。
///
/// 亮度 = 清晰度（白 = 完全清晰，黑 = 完全糊）；折痕线画成一条青色带。
enum FoldPreviewRenderer {

    static func image(
        parameters: FoldParameters,
        amount: Double,
        side: TurnSide,
        width: Int = 512,
        height: Int = 144
    ) -> CGImage? {
        let a = AngleUtils.clampUnit(amount)

        // 竖直方向不参与折叠（等值线是竖直线），所以每列的清晰度只算一次
        var columnValue = [Double](repeating: 1, count: width)
        for x in 0..<width {
            let uvx = (Double(x) + 0.5) / Double(width)
            let d = side.hingeOnRight ? (1 - uvx) : uvx
            let sigma = parameters.blurSigmaPt(d: d, amount: a)
            let normalized = parameters.maxRadiusPt > 0 ? sigma / parameters.maxRadiusPt : 0
            let sharpness = 1 - AngleUtils.clampUnit(normalized)
            let dim = parameters.dimFactor(d: d, amount: a)
            let grazing = parameters.grazingFactor(d: d, amount: a)
            columnValue[x] = AngleUtils.clampUnit(sharpness * dim * grazing)
        }

        // 折痕线：一条窄的亮带，位置随折叠量移动
        if a > 0.01, parameters.hingeLineStrength > 0, parameters.reflection > 0 {
            let creaseD = parameters.creaseDistanceFromHinge(amount: a)
            let creaseUvX = side.hingeOnRight ? 1 - creaseD : creaseD
            let centerX = Int((creaseUvX * Double(width)).rounded())
            let bandHalfWidth = max(Int(Double(width) * 0.006), 1)
            let strength = parameters.hingeLineStrength * parameters.reflection
                * parameters.bendSine(amount: a) * 40   // 视觉放大，与着色器的物理强度不同量纲

            for offset in -bandHalfWidth...bandHalfWidth {
                let x = centerX + offset
                guard x >= 0, x < width else { continue }
                let falloff = exp(-pow(Double(offset) / Double(bandHalfWidth * 2), 2))
                columnValue[x] = AngleUtils.clampUnit(columnValue[x] + strength * falloff)
            }
        }

        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        for y in 0..<height {
            for x in 0..<width {
                let v = UInt8(AngleUtils.clampUnit(columnValue[x]) * 255)
                let index = y * bytesPerRow + x * 4
                pixels[index + 0] = v        // B
                pixels[index + 1] = v        // G
                pixels[index + 2] = v        // R
                pixels[index + 3] = 255      // A
            }
        }

        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue)
            .union(.byteOrder32Little)
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
    }
}

// MARK: - 设计语言

/// 版面常量集中在这里，避免每处各写一个数字（"规整"来自一致性，不是来自单点调参）。
private enum DS {
    static let pageSpacing: CGFloat = 16
    static let cardSpacing: CGFloat = 14
    static let cardPadding: CGFloat = 16
    static let cardRadius: CGFloat = 12
    static let labelWidth: CGFloat = 76
    static let controlSpacing: CGFloat = 10
    static let titleSize: CGFloat = 13
    static let bodySize: CGFloat = 12
    static let captionSize: CGFloat = 11
}

private extension View {
    /// 统一的卡片外观：圆角 + 底色 + 1px 描边。
    func cardStyle() -> some View {
        self
            .padding(DS.cardPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: DS.cardRadius, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.cardRadius, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            )
    }
}

/// 卡片：可选标题 + 可选右上角附加内容 + 内容。
private struct SectionCard<Content: View, Accessory: View>: View {
    var title: String?
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: DS.cardSpacing) {
            if let title {
                HStack(alignment: .firstTextBaseline) {
                    Text(title)
                        .font(.system(size: DS.titleSize, weight: .semibold))
                    Spacer(minLength: 8)
                    accessory
                }
            }
            content
        }
        .cardStyle()
    }
}

private extension SectionCard where Accessory == EmptyView {
    init(title: String? = nil, @ViewBuilder content: () -> Content) {
        self.init(title: title, accessory: { EmptyView() }, content: content)
    }
}

/// 表单行：固定宽度标签 + 控件（+ 右对齐读数），多行纵向对齐。
private struct FormRow<Content: View>: View {
    var label: String
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.controlSpacing) {
            Text(label)
                .font(.system(size: DS.bodySize))
                .foregroundStyle(.secondary)
                .frame(width: DS.labelWidth, alignment: .leading)
            content
            Spacer(minLength: 0)
        }
    }
}

/// 只读信息行。
private struct InfoRow: View {
    var label: String
    var value: String
    var valueColor: Color = .primary

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.controlSpacing) {
            Text(label)
                .font(.system(size: DS.bodySize))
                .foregroundStyle(.secondary)
                .frame(width: DS.labelWidth, alignment: .leading)
            Text(value)
                .font(.system(size: DS.bodySize))
                .foregroundStyle(valueColor)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}

/// KPI 磁贴：图标 + 标题 + 大号数值 + 副标题。参考 B 端仪表盘的指标卡。
private struct KPITile: View {
    var icon: String
    var title: String
    var value: String
    var caption: String
    var tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(tint.opacity(0.15))
                    Image(systemName: icon)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(tint)
                }
                .frame(width: 24, height: 24)
                Text(title)
                    .font(.system(size: DS.captionSize))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            Text(value)
                .font(.system(size: 19, weight: .semibold).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(caption)
                .font(.system(size: DS.captionSize))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DS.cardRadius, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.cardRadius, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }
}

/// 状态胶囊。
private struct StatusPill: View {
    var text: String
    var color: Color

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text).font(.system(size: DS.captionSize, weight: .medium))
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(Capsule().fill(color.opacity(0.14)))
        .foregroundStyle(color)
    }
}

/// 提示条：只在需要用户处理时出现。
private struct Banner<Actions: View>: View {
    var text: String
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(.orange)
            Text(text)
                .font(.system(size: DS.captionSize))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            actions.font(.system(size: DS.captionSize))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.orange.opacity(0.12))
        )
    }
}

private extension Banner where Actions == EmptyView {
    init(text: String) { self.init(text: text, actions: { EmptyView() }) }
}

/// 把控制面板的窗口层级钉在覆盖层之上。
///
/// 覆盖层（层级 100）高于普通窗口（0），而捕获又**排除本应用自己的窗口** ——
/// 两者相加的后果是：效果一开始合成，控制面板就被"画成背景的模糊"而看不见了。
/// 所以效果开着时把面板抬到覆盖层之上（101 = 弹出菜单层级），关掉时恢复普通层级。
private struct WindowLevelAccessor: NSViewRepresentable {
    var aboveOverlay: Bool

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { apply(to: view) }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { apply(to: view) }
    }

    private func apply(to view: NSView) {
        guard let window = view.window else { return }
        let target = NSWindow.Level(rawValue: aboveOverlay ? 101 : NSWindow.Level.normal.rawValue)
        if window.level != target { window.level = target }
        // 标题栏保持不透明并显式写标题：否则标题文字会被"透明标题栏"吞掉，
        // 窗口顶上留下一块空荡荡的灰条（看起来像没做完）。
        if window.titlebarAppearsTransparent { window.titlebarAppearsTransparent = false }
        let title = "DuoBlur 控制面板"
        if window.title != title { window.title = title }
    }
}

// MARK: - 控制面板

/// 「高级」区里的四张视图，用分段控件切换（而不是四个各自折叠的分组）。
private enum AdvancedTab: String, CaseIterable, Identifiable {
    case metrics = "实时读数"
    case preview = "分布预览"
    case debug = "屏幕效果"
    case events = "事件"

    var id: String { rawValue }
}

/// DuoBlur 控制面板。
///
/// 版面按"仪表盘 + 设置页"组织：
/// 顶部是身份与主操作，接着是三块指标磁贴，然后是效果参数卡片，
/// 诊断类内容统一收进底部的「高级」卡片（内部分页切换）。
struct ProbeView: View {

    @ObservedObject var model: MotionProbeModel
    @State private var previewImage: CGImage?
    @State private var advancedTab: AdvancedTab = .metrics

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.pageSpacing) {
                header
                kpiRow
                deviceCard
                effectCard
                advancedCard
            }
            .padding(DS.pageSpacing)
        }
        // 初始滚动位置钉在顶部：内容比窗口高时，macOS 会恢复上次的滚动偏移，
        // 结果一打开就看到中间（实测：标题行与指标磁贴被滚出视野，像是"没渲染"）。
        .defaultScrollAnchor(.top)
        .frame(minWidth: 640, minHeight: 600)
        .background(Color(nsColor: .windowBackgroundColor))
        .background(WindowLevelAccessor(aboveOverlay: model.isScreenEffectOn))
        .task(id: previewKey) {
            previewImage = FoldPreviewRenderer.image(
                parameters: model.parameters,
                amount: model.turnAmount,
                side: model.turnSide
            )
        }
    }

    /// 预览的重绘键：`Equatable` 结构体（不用字符串插值走反射），
    /// 折叠量量化到 1/50 —— 25Hz 的传感器数据不需要 25Hz 重画一张诊断图。
    private struct PreviewKey: Equatable {
        let amountBucket: Int
        let side: TurnSide
        let parameters: FoldParameters
    }

    private var previewKey: PreviewKey {
        PreviewKey(
            amountBucket: Int((model.turnAmount * 50).rounded()),
            side: model.turnSide,
            parameters: model.parameters
        )
    }

    // MARK: 顶部：身份 + 主操作

    private var header: some View {
        SectionCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center, spacing: 12) {
                    Image(nsImage: NSApp.applicationIconImage ?? NSImage())
                        .resizable()
                        .frame(width: 44, height: 44)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text("DuoBlur")
                                .font(.system(size: 17, weight: .semibold))
                            StatusPill(text: model.status.localizedDescription, color: statusColor)
                        }
                        Text("戴上 AirPods：正视屏幕（左右 \(Int(model.turnMapping.deadZoneDeg))° 以内）完全清晰；超过后屏幕按折页方式模糊，转回即恢复。")
                            .font(.system(size: DS.captionSize))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }

                HStack(spacing: 12) {
                    Button {
                        Task { await model.toggleEverything() }
                    } label: {
                        Text(model.isEverythingOn ? "停止" : "开始（监听 + 屏幕效果）")
                            .font(.system(size: 13, weight: .semibold))
                            .frame(minWidth: 200)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .tint(model.isEverythingOn ? .red : .accentColor)
                    .disabled(model.isEnablingEffect)

                    if model.isEnablingEffect {
                        ProgressView().controlSize(.small)
                    }

                    Toggle("启动时自动开始", isOn: $model.autoStartOnLaunch)
                        .toggleStyle(.checkbox)
                        .font(.system(size: DS.bodySize))

                    Spacer(minLength: 0)

                    Button("复制实测记录") { copyReport() }
                        .font(.system(size: DS.bodySize))
                        .disabled(model.sample == nil)
                }
            }
        }
    }

    // MARK: 指标磁贴

    private var kpiRow: some View {
        HStack(spacing: DS.pageSpacing) {
            KPITile(
                icon: "waveform",
                title: "采样率",
                value: model.measuredHz > 0 ? String(format: "%.1f Hz", model.measuredHz) : "—",
                caption: model.isRunning ? "监听中" : "未监听",
                tint: .blue
            )
            KPITile(
                icon: "rectangle.split.2x1",
                title: "折叠量",
                value: String(format: "%.2f", model.turnAmount),
                caption: "等效折叠角 \(String(format: "%.0f°", model.parameters.equivalentHingeAngleDeg(amount: model.turnAmount)))",
                tint: .orange
            )
            KPITile(
                icon: model.hasScreenRecording ? "checkmark.seal" : "exclamationmark.triangle",
                title: "屏幕效果",
                value: model.isScreenEffectOn ? "已启用" : "未启用",
                caption: model.hasScreenRecording ? "屏幕录制已授权" : "缺屏幕录制权限",
                tint: model.hasScreenRecording ? .green : .orange
            )
        }
    }

    // MARK: 设备与权限

    private var deviceCard: some View {
        SectionCard(title: "设备与权限") {
            VStack(alignment: .leading, spacing: 8) {
                InfoRow(
                    label: "耳机",
                    value: model.headphoneProfile.rawName + " · " + model.headphoneProfile.localizedSummary,
                    valueColor: color(for: model.headphoneProfile.headTracking)
                )
                InfoRow(
                    label: "推流",
                    value: model.sample.map { "\($0.sensorSide.localizedName) · 链路 \(model.engineStatusText)" } ?? "无数据"
                )
                InfoRow(
                    label: "运动权限",
                    value: model.authorization.localizedName,
                    valueColor: model.authorization == .authorized ? .primary : .orange
                )
                InfoRow(
                    label: "屏幕录制",
                    value: model.hasScreenRecording ? "已授权" : "未授权",
                    valueColor: model.hasScreenRecording ? .primary : .orange
                )
            }

            if model.authorization != .authorized {
                Banner(text: "需要「运动与健身」权限才能读取 AirPods 姿态。") {
                    Button("打开系统设置") { Permissions.openMotionSettings() }
                }
            }
            if !model.hasScreenRecording {
                Banner(text: "需要「屏幕录制」权限才能模糊真实屏幕内容。") {
                    Button("重新检测") { model.recheckPermissions() }
                    Button("打开系统设置") { Permissions.openScreenRecordingSettings() }
                }
            }
            if model.status == .waitingForDevice {
                Banner(text: "AirPods 需戴在耳中、且是这台 Mac 的当前音频输出设备才会推送数据（空间音频不必开启）。")
            }
        }
    }

    // MARK: 效果

    private var effectCard: some View {
        SectionCard(title: "效果") {
            VStack(alignment: .leading, spacing: 12) {
                FormRow(label: "预设") {
                    Picker("预设", selection: Binding(
                        get: { FoldPreset.matching(model.parameters) ?? .duoSweep },
                        set: { model.parameters = $0.parameters }
                    )) {
                        ForEach(FoldPreset.allCases, id: \.self) { preset in
                            Text(preset.localizedName).tag(preset)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 150)
                    Text(FoldPreset.matching(model.parameters)?.summary ?? "自定义参数")
                        .font(.system(size: DS.captionSize))
                        .foregroundStyle(.secondary)
                }

                FormRow(label: "响应度") {
                    Picker("响应度", selection: Binding(
                        get: { model.responsiveness },
                        set: { model.setResponsiveness($0) }
                    )) {
                        ForEach(ResponsivenessTier.allCases, id: \.self) { tier in
                            Text(tier.localizedName).tag(tier)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 190)
                    Text("越灵敏越跟手，静止时可能看到极轻微抖动")
                        .font(.system(size: DS.captionSize))
                        .foregroundStyle(.secondary)
                }

                // 死区 / 满量程：决定"多小的转头算正视"。
                HStack(alignment: .firstTextBaseline, spacing: DS.controlSpacing) {
                    Text("触发范围")
                        .font(.system(size: DS.bodySize))
                        .foregroundStyle(.secondary)
                        .frame(width: DS.labelWidth, alignment: .leading)
                    Text("死区").font(.system(size: DS.bodySize)).foregroundStyle(.secondary)
                    Slider(value: Binding(
                        get: { model.turnMapping.deadZoneDeg },
                        set: { model.turnMapping.deadZoneDeg = $0 }
                    ), in: TurnMappingConfig.deadZoneRange)
                    .frame(width: 150)
                    Text(String(format: "%.0f°", model.turnMapping.deadZoneDeg))
                        .font(.system(size: DS.bodySize).monospacedDigit())
                        .frame(width: 36, alignment: .trailing)
                    Text("满量程").font(.system(size: DS.bodySize)).foregroundStyle(.secondary)
                    Slider(value: Binding(
                        get: { model.turnMapping.fullScaleDeg },
                        set: { model.turnMapping.fullScaleDeg = $0 }
                    ), in: TurnMappingConfig.fullScaleRange)
                    .frame(width: 150)
                    Text(String(format: "%.0f°", model.turnMapping.fullScaleDeg))
                        .font(.system(size: DS.bodySize).monospacedDigit())
                        .frame(width: 36, alignment: .trailing)
                    Spacer(minLength: 0)
                }
                Text("头部在 ±\(Int(model.turnMapping.deadZoneDeg))° 内完全不触发；超过后按慢起曲线增长，到 \(Int(model.turnMapping.fullScaleDeg))° 折叠量饱和。")
                    .font(.system(size: DS.captionSize))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, DS.labelWidth + DS.controlSpacing)

                FormRow(label: "铰链侧") {
                    Picker("铰链侧", selection: Binding(
                        get: { model.turnSide },
                        set: { model.setTurnSide($0) }
                    )) {
                        Text("左（头向左转）").tag(TurnSide.left)
                        Text("右（头向右转）").tag(TurnSide.right)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 220)
                    Toggle("反转左右", isOn: $model.invertDirection)
                        .toggleStyle(.checkbox)
                        .font(.system(size: DS.bodySize))
                }

                FormRow(label: "手动折叠量") {
                    Slider(value: $model.turnAmount, in: 0...1)
                        .frame(width: 400)
                    Text(String(format: "%.2f", model.turnAmount))
                        .font(.system(size: DS.bodySize).monospacedDigit())
                        .frame(width: 36, alignment: .trailing)
                }

                HStack(spacing: 8) {
                    Button("模拟右转 25°") { simulate(turn: 25) }
                    Button("模拟左转 25°") { simulate(turn: -25) }
                    Button("回到正视") { simulate(turn: 0) }
                    Spacer(minLength: 0)
                    Button("把当前姿态设为正中") { model.recenter() }
                        .disabled(!model.status.isUsable)
                }
                .font(.system(size: DS.bodySize))
                .padding(.leading, DS.labelWidth + DS.controlSpacing)
            }
        }
    }

    // MARK: 高级（分页）

    private var advancedCard: some View {
        SectionCard(title: "高级") {
            VStack(alignment: .leading, spacing: 12) {
                Picker("高级", selection: $advancedTab) {
                    ForEach(AdvancedTab.allCases) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                switch advancedTab {
                case .metrics: liveReadout
                case .preview: foldPreview
                case .debug: screenEffectAdvanced
                case .events: eventLog
                }
            }
        }
    }

    // MARK: 实时读数

    private var liveReadout: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 32) {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 22, verticalSpacing: 5) {
                    GridRow {
                        Text("").font(.system(size: DS.captionSize))
                        Text("yaw").font(.system(size: DS.captionSize).monospaced()).foregroundStyle(.secondary)
                        Text("pitch").font(.system(size: DS.captionSize).monospaced()).foregroundStyle(.secondary)
                        Text("roll").font(.system(size: DS.captionSize).monospaced()).foregroundStyle(.secondary)
                    }
                    row("原始", model.sample?.rawYawDeg, model.sample?.rawPitchDeg, model.sample?.rawRollDeg)
                    row("相对基线", model.sample?.relativeYawDeg, model.sample?.relativePitchDeg, model.sample?.relativeRollDeg)
                    row("滤波后", model.sample?.yawDeg, model.sample?.pitchDeg, model.sample?.rollDeg)
                }
                VStack(alignment: .leading, spacing: 8) {
                    metric("「向右转」语义值", String(format: "%+.2f°", model.sample?.turnDegrees ?? 0))
                    metric("折叠量", String(format: "%.3f", model.turnAmount))
                    metric("等效折叠角", String(format: "%.0f°", model.parameters.equivalentHingeAngleDeg(amount: model.turnAmount)))
                }
                Spacer(minLength: 0)
            }

            Text(model.turnSide == .right
                 ? "头向右转 → 铰链在屏幕右边缘，左侧最糊"
                 : "头向左转 → 铰链在屏幕左边缘，右侧最糊")
                .font(.system(size: DS.captionSize))
                .foregroundStyle(.secondary)

            if model.sample == nil {
                Text("尚无数据。点上面的「开始」，并确认 AirPods 已连接、已戴上。")
                    .font(.system(size: DS.captionSize))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func row(_ label: String, _ a: Double?, _ b: Double?, _ c: Double?) -> some View {
        GridRow {
            Text(label).font(.system(size: DS.captionSize)).foregroundStyle(.secondary)
            valueCell(a); valueCell(b); valueCell(c)
        }
    }

    private func valueCell(_ v: Double?) -> some View {
        Text(v.map { String(format: "%+8.2f°", $0) } ?? "       —")
            .font(.system(size: DS.bodySize).monospacedDigit())
    }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: DS.captionSize)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 15, weight: .medium).monospacedDigit())
        }
    }

    // MARK: 分布预览

    private var foldPreview: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("强度分布图：亮 = 清晰，暗 = 模糊，青线 = 折痕（不是画面预览）")
                    .font(.system(size: DS.captionSize))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }

            Group {
                if let previewImage {
                    Image(decorative: previewImage, scale: 1)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fill)
                } else {
                    Color(nsColor: .textBackgroundColor)
                }
            }
            .frame(height: 140)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.primary.opacity(0.1), lineWidth: 1)
            )
            .overlay(alignment: .bottom) {
                Text(model.turnSide == .right
                     ? "← 自由边（最糊）                          铰链（清晰）→"
                     : "← 铰链（清晰）                          自由边（最糊）→")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.8))
                    .padding(.bottom, 4)
            }
        }
    }

    // MARK: 屏幕效果与调试

    private var screenEffectAdvanced: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                if model.isScreenEffectOn {
                    Button("停用屏幕效果") { Task { await model.disableScreenEffect() } }
                } else {
                    Button("单独启用屏幕效果") { Task { await model.enableScreenEffect() } }
                        .disabled(model.isEnablingEffect)
                }
                Button("重新检测权限") { model.recheckPermissions() }
                Spacer(minLength: 0)
            }
            .font(.system(size: DS.bodySize))

            FormRow(label: "调试模式") {
                Picker("调试模式", selection: $model.debugMode) {
                    ForEach(FoldDebugMode.allCases, id: \.self) { mode in
                        Text(mode.localizedName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 400)
                .disabled(!model.isScreenEffectOn)
            }

            Text(model.debugMode.explanation)
                .font(.system(size: DS.captionSize))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, DS.labelWidth + DS.controlSpacing)

            FormRow(label: "手动驱动") {
                Toggle("忽略耳机数据，只用「手动折叠量」", isOn: $model.useManualDrive)
                    .toggleStyle(.checkbox)
                    .font(.system(size: DS.bodySize))
                    .disabled(!model.isScreenEffectOn)
            }

            if !model.displayDiagnostics.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(model.displayDiagnostics) { d in
                        Text(diagnosticLine(d))
                            .font(.system(size: 10).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.primary.opacity(0.04))
                )
            }
        }
    }

    // MARK: 事件

    private var eventLog: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.events.isEmpty {
                Text("暂无事件").font(.system(size: DS.captionSize)).foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(model.events) { event in
                            HStack(alignment: .top, spacing: 8) {
                                Text(event.time, style: .time)
                                    .font(.system(size: DS.captionSize).monospacedDigit())
                                    .foregroundStyle(.secondary)
                                Text(event.message)
                                    .font(.system(size: DS.captionSize))
                                    .foregroundStyle(event.isWarning ? .orange : .primary)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 120)
            }
        }
    }

    // MARK: 辅助

    private var statusColor: Color {
        if model.status.isUsable { return .green }
        switch model.status {
        case .idle: return .secondary
        case .unauthorized, .failed: return .red
        case .stale, .rebuilding: return .orange
        default: return .yellow
        }
    }

    private func color(for support: HeadphoneProfile.HeadTrackingSupport) -> Color {
        switch support {
        case .yes: return .primary
        case .unknown: return .orange   // 未识别不是错误，但需要用户实测确认
        case .no: return .red
        }
    }

    private func diagnosticLine(_ d: CoordinatorDiagnostics) -> String {
        var parts: [String] = []
        parts.append("\(d.displayName) \(Int(d.pixelSize.width))×\(Int(d.pixelSize.height))@\(String(format: "%.0f", d.pointPixelScale))x")
        parts.append("回调 \(d.captureCallbackCount) 次")
        parts.append("捕获 \(d.captureFrameCount) 帧")
        parts.append("渲染 \(d.renderedFrames) 帧")
        parts.append(String(format: "折叠 %.3f", d.amount))
        parts.append("链路 \(String(format: "%.1f", d.frameInterval * 1000))ms")
        parts.append(d.isCompositing ? "覆盖中" : "透明")
        if !d.geometryIsPixelExact { parts.append("⚠ 几何非 1:1") }
        if !d.geometryIsSamePixelSize { parts.append("⚠ 捕获尺寸不符") }
        if let latency = d.firstFrameLatency {
            parts.append("首帧 \(Int(latency * 1000))ms")
        }
        if let error = d.error { parts.append("✗ \(error)") }
        return parts.joined(separator: " · ")
    }

    /// 用一条合成的转向角走一遍完整映射链（死区 → 归一化 → 缓动），
    /// 这是没有耳机时验证方向语义的最快方式。
    private func simulate(turn: Double) {
        var mapper = TurnMapper(
            deadZoneDeg: model.turnMapping.deadZoneDeg,
            fullScaleDeg: model.turnMapping.fullScaleDeg,
            hysteresisDeg: model.turnMapping.hysteresisDeg,
            invertDirection: model.invertDirection
        )
        let (amount, side) = mapper.update(turnDegrees: turn)
        model.setTurnSide(side)
        model.turnAmount = amount
        model.log("模拟转向 \(String(format: "%+.0f", turn))° → 折叠量 \(String(format: "%.3f", amount))，"
                  + "铰链在屏幕\(side == .right ? "右" : "左")边缘")
    }

    private func copyReport() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(model.measurementReport(), forType: .string)
        model.log("实测记录已复制到剪贴板")
    }
}
