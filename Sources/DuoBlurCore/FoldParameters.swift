import Foundation

/// 空间分布模式。决定模糊如何在屏幕上铺开。
public enum SpatialMode: String, Sendable, CaseIterable, Codable {
    /// 整屏同一模糊半径，像磨砂玻璃。经典磨砂观感。
    case uniform
    /// 整屏当作一块折叠面板：铰链处绝对锐利，越往自由边越糊（慢起陡尾）。最纯粹的 Duo。
    case ramp
    /// **默认**。把 Duo 的渐进曲线"重新锚定"在扫过的窗口里：模糊从自由边长出，
    /// 折痕线随折叠量在屏幕上移动；折叠量 → 1 时自动退化为 `ramp`。
    case sweep

    /// 着色器 uniform 值，必须与 `DuoFold.metal` 里的 `SpatialMode` 枚举一致。
    public var shaderValue: Int32 {
        switch self {
        case .uniform: return 0
        case .ramp: return 1
        case .sweep: return 2
        }
    }

    public var localizedName: String {
        switch self {
        case .uniform: return "均匀磨砂"
        case .ramp: return "折叠"
        case .sweep: return "扫过"
        }
    }
}

/// 折页效果的**全部可调参数**。
///
/// 这是全项目的"单一事实源"：着色器不硬编码任何常数，UI 直接绑定这个结构体的字段。
/// 开发原则之一就是"代码里不允许出现裸的 0.035 / 2.1 / 0.85"。
///
/// 下方的 `panelProgress` / `blurSigmaPt` / `dimFactor` 等函数是**着色器公式的 Swift 镜像**。
/// 存在的意义是让模糊半径的单调性、有界性、铰链零模糊等性质可以被属性测试覆盖，
/// 而不用去 GPU 上跑。着色器与这些函数的一致性由黄金图像测试守护。
public struct FoldParameters: Sendable, Equatable, Hashable, Codable {

    // MARK: 几何与模糊

    /// 空间分布模式。
    public var spatialMode: SpatialMode
    /// 最大模糊半径，单位 pt（σ）。在 2× Retina 上 125pt = 250px。
    public var maxRadiusPt: Double
    /// 最低模糊占最大模糊的比例。0 = 铰链绝对锐利；0.25 = 整屏始终带一层薄雾（Cinematic）。
    public var blurFloor: Double
    /// 渐进曲线的拐点：在面板内的哪一比例处达到满强度。
    public var rampKnee: Double
    /// 渐进曲线的指数。> 1 是"慢起陡尾"（Duo 的特征）；1 为线性。
    public var rampExp: Double

    // MARK: 变暗

    /// 变暗强度（0 = 不变暗）。
    public var dimAmount: Double
    /// 变暗到达满强度时在面板内的比例。
    public var dimReach: Double
    /// 铰链处的变暗下限。0 = 铰链完全不变暗。
    public var dimHingeFloor: Double

    // MARK: 高光

    /// 折痕亮线强度。极窄的一条高斯带，是"折痕"读感的关键。
    public var hingeLineStrength: Double
    /// 镜面边缘光强度。宽高斯带，模拟玻璃掠射反射。
    public var rimStrength: Double
    /// 掠过变暗强度：折得越深，自由边越暗。
    public var grazingStrength: Double
    /// 全局高光乘子（0–1）。一键关掉折痕线与镜面光。
    public var reflection: Double

    // MARK: 屏幕与几何

    /// 顶部留白（pt）：该区域内完全不施加效果，用于保护菜单栏。
    public var topInsetPt: Double
    /// 当折叠量达到此值时，整屏进入均匀磨砂（放弃铰链可读性，换取整屏不透明的隐私观感）。
    /// `nil` = 关闭（Duo 的铰链始终保留可读性）。
    public var fullFrostAt: Double?

    // MARK: 渲染校准常数

    /// 金字塔每提升一级所增加的 σ（以 level-0 像素为单位）。
    ///
    /// **这是实测校准值，不是推导值。** 教科书式的 2×2 box 链按方差叠加，系数应在
    /// 0.29~0.33 之间（3×3 二项式给 level 0 贡献 σ≈0.707px）；但实测比这个推导值大了
    /// 一倍以上，说明 `MTLBlitCommandEncoder.generateMipmaps` 的实际滤波行为与教科书上的
    /// box 链不同，所以只能直接实测，不能照公式推。
    ///
    /// **当前值 0.90 仍是未正式标定的估计，不要当成权威数字。**
    ///
    /// 正式标定的做法：
    /// - 专门的测试图案：**大块阶跃边缘 + 充裕边距**（边距 ≥ 6σ_max），阶跃两侧各 1500px 以上
    /// - 用边缘扩散函数（ESF）求导得线扩散函数（LSF），对 LSF 做高斯拟合求 σ
    /// - 在 σ = 2/4/8/16/32/64/128/256px 上逐点扫描测量
    /// - 顺带确认 `radius < 0.75` 的锐利短路确实逐像素一致
    public var sigmaPerLevel: Double

    public init(
        spatialMode: SpatialMode = .sweep,
        maxRadiusPt: Double = 125,
        blurFloor: Double = 0,
        rampKnee: Double = 0.85,
        rampExp: Double = 1.25,
        dimAmount: Double = 1.0,
        dimReach: Double = 0.55,
        dimHingeFloor: Double = 0,
        hingeLineStrength: Double = 0.035,
        rimStrength: Double = 0.025,
        grazingStrength: Double = 0.20,
        reflection: Double = 1.0,
        topInsetPt: Double = 0,
        fullFrostAt: Double? = nil,
        sigmaPerLevel: Double = 0.90
    ) {
        self.spatialMode = spatialMode
        self.maxRadiusPt = maxRadiusPt
        self.blurFloor = blurFloor
        self.rampKnee = rampKnee
        self.rampExp = rampExp
        self.dimAmount = dimAmount
        self.dimReach = dimReach
        self.dimHingeFloor = dimHingeFloor
        self.hingeLineStrength = hingeLineStrength
        self.rimStrength = rimStrength
        self.grazingStrength = grazingStrength
        self.reflection = reflection
        self.topInsetPt = topInsetPt
        self.fullFrostAt = fullFrostAt
        self.sigmaPerLevel = sigmaPerLevel
    }

    /// 合法范围。越界说明 UI 或存档出了问题，单测会断言所有预设都在范围内。
    public static let validRanges: [String: ClosedRange<Double>] = [        "maxRadiusPt": 0...200,
        "blurFloor": 0...0.5,
        "rampKnee": 0.5...1.0,
        "rampExp": 0.0...2.0,
        "dimAmount": 0...1,
        "dimReach": 0.05...1.0,
        "dimHingeFloor": 0...1,
        "hingeLineStrength": 0...0.15,
        "rimStrength": 0...0.15,
        "grazingStrength": 0...0.5,
        "reflection": 0...1,
        "topInsetPt": 0...120,
        "sigmaPerLevel": 0.4...2.0,
    ]

    /// 返回所有越界字段的说明。空数组表示合法。
    public func validationErrors() -> [String] {
        var errors: [String] = []
        func check(_ name: String, _ value: Double) {
            guard let range = Self.validRanges[name] else { return }
            if !value.isFinite || !range.contains(value) {
                errors.append("\(name) = \(value) 超出 \(range)")
            }
        }
        check("maxRadiusPt", maxRadiusPt)
        check("blurFloor", blurFloor)
        check("rampKnee", rampKnee)
        check("rampExp", rampExp)
        check("dimAmount", dimAmount)
        check("dimReach", dimReach)
        check("dimHingeFloor", dimHingeFloor)
        check("hingeLineStrength", hingeLineStrength)
        check("rimStrength", rimStrength)
        check("grazingStrength", grazingStrength)
        check("reflection", reflection)
        check("topInsetPt", topInsetPt)
        check("sigmaPerLevel", sigmaPerLevel)
        if let frost = fullFrostAt, !(0...1).contains(frost) {
            errors.append("fullFrostAt = \(frost) 超出 0...1")
        }
        return errors
    }

    // MARK: - 着色器公式的 Swift 镜像

    /// 折痕（焦点边界）在屏幕上的位置。
    /// `sweep` 模式下随折叠量移动；其它模式固定在自由边。
    public func sweepFront(amount: Double) -> Double {
        spatialMode == .sweep ? 1 - AngleUtils.clampUnit(amount) : 0
    }

    /// 面板内的归一化进度 `t`。0 = 折痕处，1 = 自由边。与着色器同名表达式完全一致。
    public func panelProgress(d: Double, amount: Double) -> Double {
        let front = sweepFront(amount: amount)
        guard front < 1 else { return 0 }
        return AngleUtils.clampUnit((d - front) / (1 - front))
    }

    /// "全屏磨砂"在给定折叠量下的介入程度（0–1）。
    public func frostBlend(amount: Double) -> Double {
        guard let threshold = fullFrostAt else { return 0 }
        let span = Swift.max(1 - threshold, 1e-6)
        return AngleUtils.smoothstep((AngleUtils.clampUnit(amount) - threshold) / span)
    }

    /// 自由边方向的渐进曲线（0–1）。慢起陡尾。
    public func ramp(t: Double) -> Double {
        pow(AngleUtils.smoothstep(AngleUtils.clampUnit(t / Swift.max(rampKnee, 1e-6))), rampExp)
    }

    /// 空间分布因子（0–1）。`uniform` 模式下恒为 1。
    public func spatialFactor(d: Double, amount: Double) -> Double {
        switch spatialMode {
        case .uniform: return 1
        case .ramp, .sweep: return ramp(t: panelProgress(d: d, amount: amount))
        }
    }

    /// 目标模糊 σ，单位 pt。
    ///
    /// 不变式（由单测断言）：
    /// - `d = 0`（铰链）时为 0 —— 这是"清晰区绝对清晰"的数学保证
    /// - 对 `d` 单调不减
    /// - 对 `amount` 单调不减
    ///
    /// `blurFloor`（Cinematic 的"常驻薄雾"）乘一个 0→1 的短包络：渲染层在
    /// `amount ≤ 0.001` 时完全不合成，若 floor 不随 amount 收敛，第一帧可见时
    /// 就会从"绝对清晰"直接跳到整屏 40pt 模糊（实测的硬跳变）。
    public func blurSigmaPt(d: Double, amount: Double) -> Double {
        let a = AngleUtils.clampUnit(amount)
        let frost = frostBlend(amount: a)
        let envelope = AngleUtils.smoothstep(Swift.min(a / Self.floorRampAmount, 1))
        let floor = AngleUtils.clampUnit((blurFloor + (1 - blurFloor) * frost) * envelope)
        let spatial = spatialFactor(d: AngleUtils.clampUnit(d), amount: a)
        return maxRadiusPt * (floor + (1 - floor) * a * spatial)
    }

    /// `blurFloor` 在折叠量的前 12% 内升到满值 —— 短到察觉不出，
    /// 又足以避免"越过合成阈值时整屏跳一层雾"。着色器里是同一个常数。
    public static let floorRampAmount = 0.12

    /// 变暗系数，直接乘在颜色上（≤ 1）。
    public func dimFactor(d: Double, amount: Double) -> Double {
        let t = panelProgress(d: AngleUtils.clampUnit(d), amount: AngleUtils.clampUnit(amount))
        let curve = Swift.max(dimHingeFloor, AngleUtils.smoothstep(t / Swift.max(dimReach, 1e-6)))
        let a = AngleUtils.clampUnit(amount)
        return pow(Swift.max(1 - dimAmount * curve * a, 0), 2.1)
    }

    /// 掠过变暗的乘数（≤ 1）。
    public func grazingFactor(d: Double, amount: Double) -> Double {
        let a = AngleUtils.clampUnit(amount)
        let t = panelProgress(d: AngleUtils.clampUnit(d), amount: a)
        return 1 - grazingStrength * bendSine(amount: a) * pow(t, 1.5)
    }

    /// 高光的时间包络：`sin(amount·π/2)`。折叠量为 0 时完全无高光。
    public func bendSine(amount: Double) -> Double {
        sin(AngleUtils.clampUnit(amount) * .pi / 2)
    }

    // MARK: 屏幕空间（d 空间）的高光位置
    //
    // 折痕与镜面光都用"离铰链的距离"表达，因为它们是**屏幕上的**光学特征，
    // 带宽应当是屏宽的固定比例。用 t 空间会让带宽随折叠量缩放：
    // 低折叠量时带被拉宽、峰值被稀释，折痕会淡到看不见（实测踩过）。

    /// 折痕离铰链的距离（0 = 铰链，1 = 自由边）。UI 与预览用它把折痕画到屏幕上。
    ///
    /// sweep 模式下随折叠量从自由边走向铰链；ramp 模式固定在铰链处。
    public func creaseDistanceFromHinge(amount: Double) -> Double {
        sweepFront(amount: amount)
    }

    /// 折痕线的半宽（屏宽比例）。恒定值 —— 这正是"在 d 空间表达"的意义。
    public let creaseBandHalfWidth = 0.06

    /// 镜面边缘光中心离铰链的距离：面板 65% 处。
    public func rimDistanceFromHinge(amount: Double) -> Double {
        let front = sweepFront(amount: amount)
        return front + 0.65 * (1 - front)
    }

    /// 镜面光的 σ（屏宽比例）。
    public let rimSigma = 0.35

    /// 等效物理折叠角，单位度。176° = 完全平展（清晰），20° = 接近闭合（全糊）。
    ///
    /// 借自 Duo 的物理语义：真实折叠屏铰链静止在 176–179°，可见工作区约 20°–172°。
    /// UI 显示"折叠 176° → 92°"比显示"amount 0.42"直观得多。
    public func equivalentHingeAngleDeg(amount: Double) -> Double {
        176 - AngleUtils.clampUnit(amount) * 156
    }
}

// MARK: - 带默认值的解码

/// 手写 `init(from:)` 的目的：**Swift 合成的 `Codable` 不会为缺失的键填充默认值**，
/// 而是直接抛 `keyNotFound`。参数结构体会随版本增删字段，如果每次加字段都让旧存档无法加载，
/// 用户的自定义参数就会在升级后丢失。所以所有字段都走 `decodeIfPresent` + 默认值。
extension FoldParameters {

    enum CodingKeys: String, CodingKey {
        case spatialMode, maxRadiusPt, blurFloor, rampKnee, rampExp
        case dimAmount, dimReach, dimHingeFloor
        case hingeLineStrength, rimStrength, grazingStrength, reflection
        case topInsetPt, fullFrostAt, sigmaPerLevel
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = FoldParameters()

        // `try?` 在 Swift 5+ 会压平嵌套可选，因此这里直接得到 Double?
        func double(_ key: CodingKeys, _ fallback: Double) -> Double {
            guard let value = try? container.decodeIfPresent(Double.self, forKey: key) else { return fallback }
            return value
        }

        self.init(
            spatialMode: (try? container.decodeIfPresent(SpatialMode.self, forKey: .spatialMode))
                ?? defaults.spatialMode,
            maxRadiusPt: double(.maxRadiusPt, defaults.maxRadiusPt),
            blurFloor: double(.blurFloor, defaults.blurFloor),
            rampKnee: double(.rampKnee, defaults.rampKnee),
            rampExp: double(.rampExp, defaults.rampExp),
            dimAmount: double(.dimAmount, defaults.dimAmount),
            dimReach: double(.dimReach, defaults.dimReach),
            dimHingeFloor: double(.dimHingeFloor, defaults.dimHingeFloor),
            hingeLineStrength: double(.hingeLineStrength, defaults.hingeLineStrength),
            rimStrength: double(.rimStrength, defaults.rimStrength),
            grazingStrength: double(.grazingStrength, defaults.grazingStrength),
            reflection: double(.reflection, defaults.reflection),
            topInsetPt: double(.topInsetPt, defaults.topInsetPt),
            fullFrostAt: (try? container.decodeIfPresent(Double.self, forKey: .fullFrostAt))
                ?? defaults.fullFrostAt,
            sigmaPerLevel: double(.sigmaPerLevel, defaults.sigmaPerLevel)
        )
    }
}
