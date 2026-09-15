import XCTest
@testable import DuoBlurCore

/// 属性测试 + 预设校验。
final class FoldParametersTests: XCTestCase {

    private var allPresets: [FoldPreset] { FoldPreset.allCases }

    /// 所有预设的字段都在合法范围内
    func testAllPresetsAreWithinValidRanges() {
        for preset in allPresets {
            let errors = preset.parameters.validationErrors()
            XCTAssertTrue(errors.isEmpty, "预设 \(preset.rawValue) 有越界字段：\(errors.joined(separator: "; "))")
        }
    }

    /// 铰链零模糊：在**空间渐变**的模式（`ramp` / `sweep`）下，
    /// `d = 0` 处的模糊必须严格为 0 —— 这是"清晰区绝对清晰"的数学保证。
    ///
    /// 两种例外，都是有意的设计而非缺陷：
    /// - `uniform`（`Frost` 预设）就是要整屏均匀磨砂，所以铰链处**必然**是糊的
    /// - `blurFloor > 0`（`Cinematic`）有意让整屏带一层薄雾
    func testHingeHasZeroBlurInSpatiallyVaryingModes() {
        for preset in allPresets {
            let p = preset.parameters
            guard p.spatialMode != .uniform, p.blurFloor == 0 else { continue }

            let hinge = p.blurSigmaPt(d: 0, amount: 1.0)
            XCTAssertEqual(hinge, 0, accuracy: 1e-12,
                           "预设 \(preset.rawValue) 在铰链处仍有 \(hinge)pt 模糊，清晰区被污染")
        }
    }

    /// `uniform` 模式下整屏模糊必须完全一致 —— 这就是"均匀磨砂"的定义
    func testUniformModeIsFlatAcrossTheScreen() {
        let p = FoldPreset.frost.parameters
        let reference = p.blurSigmaPt(d: 0, amount: 0.7)
        XCTAssertGreaterThan(reference, 0)
        for i in 0...20 {
            let d = Double(i) / 20
            XCTAssertEqual(p.blurSigmaPt(d: d, amount: 0.7), reference, accuracy: 1e-9,
                           "uniform 模式在 d=\(d) 处不一致")
        }
    }

    /// 设了 `blurFloor` 的预设，铰链必须比自由边更清晰（而不是同样糊）
    func testBlurFloorPresetKeepsHingeCleanerThanFreeEdge() {
        let p = FoldPreset.cinematic.parameters
        XCTAssertGreaterThan(p.blurFloor, 0)
        let hinge = p.blurSigmaPt(d: 0, amount: 1.0)
        let freeEdge = p.blurSigmaPt(d: 1, amount: 1.0)
        XCTAssertGreaterThan(hinge, 0, "blurFloor 应让整屏都有薄雾")
        XCTAssertLessThan(hinge, freeEdge, "铰链处应比自由边更清晰")
    }

    /// 模糊半径对 `d` 单调不减
    func testBlurIsMonotonicInDistance() {
        for preset in allPresets {
            let p = preset.parameters
            for amount in stride(from: 0.0, through: 1.0, by: 0.1) {
                var previous = -1.0
                for i in 0...100 {
                    let d = Double(i) / 100
                    let sigma = p.blurSigmaPt(d: d, amount: amount)
                    XCTAssertGreaterThanOrEqual(
                        sigma, previous - 1e-9,
                        "\(preset.rawValue) amount=\(amount) 时 d=\(d) 处模糊回退了"
                    )
                    previous = sigma
                }
            }
        }
    }

    /// 模糊半径对 `amount` 单调不减
    func testBlurIsMonotonicInAmount() {
        for preset in allPresets {
            let p = preset.parameters
            for i in 0...50 {
                let d = Double(i) / 50
                var previous = -1.0
                for j in 0...100 {
                    let amount = Double(j) / 100
                    let sigma = p.blurSigmaPt(d: d, amount: amount)
                    XCTAssertGreaterThanOrEqual(
                        sigma, previous - 1e-9,
                        "\(preset.rawValue) d=\(d) 处模糊随 amount 回退"
                    )
                    previous = sigma
                }
            }
        }
    }

    /// 输出有界：随机参数组合下模糊与变暗都在合法区间
    func testOutputsAreBoundedForRandomInput() {
        var generator = SeededGenerator(seed: 7)
        for _ in 0..<2000 {
            let p = FoldParameters(
                spatialMode: SpatialMode.allCases.randomElement(using: &generator)!,
                maxRadiusPt: Double.random(in: 0...200, using: &generator),
                blurFloor: Double.random(in: 0...0.5, using: &generator),
                rampKnee: Double.random(in: 0.5...1, using: &generator),
                rampExp: Double.random(in: 0...2, using: &generator),
                dimAmount: Double.random(in: 0...1, using: &generator),
                dimReach: Double.random(in: 0.05...1, using: &generator),
                dimHingeFloor: Double.random(in: 0...1, using: &generator),
                fullFrostAt: Bool.random(using: &generator) ? Double.random(in: 0...1, using: &generator) : nil
            )
            let d = Double.random(in: -0.5...1.5, using: &generator)
            let amount = Double.random(in: -0.5...1.5, using: &generator)

            let sigma = p.blurSigmaPt(d: d, amount: amount)
            XCTAssertTrue(sigma.isFinite, "非有限模糊半径")
            XCTAssertGreaterThanOrEqual(sigma, 0)
            XCTAssertLessThanOrEqual(sigma, p.maxRadiusPt + 1e-9)

            let dim = p.dimFactor(d: d, amount: amount)
            XCTAssertTrue(dim.isFinite && dim >= 0 && dim <= 1, "变暗系数越界：\(dim)")

            let grazing = p.grazingFactor(d: d, amount: amount)
            XCTAssertTrue(grazing.isFinite && grazing >= 0 && grazing <= 1.5, "掠过系数越界：\(grazing)")
        }
    }

    /// 变暗必须随折叠量收敛，且自由边在满折叠时仍保留可见内容。
    ///
    /// 这条性质曾经只在 Swift 镜像里成立、着色器里漏乘了 amount：只要越过死区，
    /// 自由边就被直接压成纯黑，表现为"稍微一转头，屏幕一侧出现一条黑带"。
    /// 现在两侧公式一致，这条测试把语义钉住（着色器一致性由黄金图像测试守护）。
    func testDimScalesWithAmountAndKeepsContentVisibleAtFullFold() {
        for preset in allPresets {
            let p = preset.parameters
            let light = p.dimFactor(d: 1.0, amount: 0.2)
            let heavy = p.dimFactor(d: 1.0, amount: 1.0)
            XCTAssertGreaterThan(light, 0.55,
                                 "\(preset.rawValue)：折叠量 0.2 时自由边就被压暗到 \(light)")
            XCTAssertGreaterThan(heavy, 0.05,
                                 "\(preset.rawValue)：满折叠时自由边几乎全黑（\(heavy)）")
            XCTAssertLessThan(heavy, light, "\(preset.rawValue)：变暗没有随折叠量单调加深")
        }
    }

    /// 连续性：amount 上以极小步长扫过，模糊半径不应跳档
    func testBlurIsContinuousInAmount() {
        for preset in allPresets {
            let p = preset.parameters
            let step = 1e-4
            var previous: Double?
            for i in 0...10000 {
                let amount = Double(i) * step
                let sigma = p.blurSigmaPt(d: 0.6, amount: amount)
                if let previous {
                    let delta = abs(sigma - previous)
                    // 一阶差分应该很小；出现阶跃说明有硬边或 mip 档位泄漏到公式里
                    XCTAssertLessThan(delta, p.maxRadiusPt * 0.01 + 1e-6,
                                      "\(preset.rawValue) 在 amount=\(amount) 处出现跳档：Δ\(delta)pt")
                }
                previous = sigma
            }
        }
    }

    /// 预设数值必须与代码中定义的预设参数一致
    ///
    /// 这条测试的作用是拦住"改了代码忘了同步期望值"。下面的期望值是从预设定义逐格抄下来的。
    func testPresetsMatchExpectedValues() {
        typealias Expected = (
            mode: SpatialMode, radius: Double, floor: Double, knee: Double, exp: Double,
            dim: Double, dimReach: Double, dimHingeFloor: Double,
            hingeLine: Double, rim: Double, grazing: Double, frost: Double?
        )

        let expected: [FoldPreset: Expected] = [
            .duoSweep:   (.sweep,   125, 0.0,  0.85, 1.25, 0.5,  0.55, 0.0,  0.035, 0.025, 0.10, nil),
            .duoClassic: (.ramp,    125, 0.0,  0.85, 1.25, 0.5,  0.55, 0.0,  0.035, 0.025, 0.10, nil),
            .frost:      (.uniform,  90, 0.0,  1.00, 1.00, 0.4,  1.00, 0.0,  0.0,   0.0,   0.08, 0.0),
            .cinematic:  (.sweep,   160, 0.25, 0.80, 1.10, 0.7,  0.45, 0.18, 0.035, 0.045, 0.15, nil),
        ]

        for (preset, e) in expected {
            let p = preset.parameters
            XCTAssertEqual(p.spatialMode, e.mode, "\(preset.rawValue).spatialMode")
            XCTAssertEqual(p.maxRadiusPt, e.radius, accuracy: 1e-9, "\(preset.rawValue).maxRadiusPt")
            XCTAssertEqual(p.blurFloor, e.floor, accuracy: 1e-9, "\(preset.rawValue).blurFloor")
            XCTAssertEqual(p.rampKnee, e.knee, accuracy: 1e-9, "\(preset.rawValue).rampKnee")
            XCTAssertEqual(p.rampExp, e.exp, accuracy: 1e-9, "\(preset.rawValue).rampExp")
            XCTAssertEqual(p.dimAmount, e.dim, accuracy: 1e-9, "\(preset.rawValue).dimAmount")
            XCTAssertEqual(p.dimReach, e.dimReach, accuracy: 1e-9, "\(preset.rawValue).dimReach")
            XCTAssertEqual(p.dimHingeFloor, e.dimHingeFloor, accuracy: 1e-9, "\(preset.rawValue).dimHingeFloor")
            XCTAssertEqual(p.hingeLineStrength, e.hingeLine, accuracy: 1e-9, "\(preset.rawValue).hingeLineStrength")
            XCTAssertEqual(p.rimStrength, e.rim, accuracy: 1e-9, "\(preset.rawValue).rimStrength")
            XCTAssertEqual(p.grazingStrength, e.grazing, accuracy: 1e-9, "\(preset.rawValue).grazingStrength")
            if let frost = e.frost {
                XCTAssertEqual(p.fullFrostAt ?? -1, frost, accuracy: 1e-9, "\(preset.rawValue).fullFrostAt")
            } else {
                XCTAssertNil(p.fullFrostAt, "\(preset.rawValue).fullFrostAt 应为 nil")
            }
        }
    }

    /// 序列化往返
    func testCodableRoundTrip() throws {
        for preset in allPresets {
            let original = preset.parameters
            let data = try JSONEncoder().encode(original)
            let restored = try JSONDecoder().decode(FoldParameters.self, from: data)
            XCTAssertEqual(original, restored, "预设 \(preset.rawValue) 序列化往返后不一致")
        }
    }

    /// 旧存档缺字段时能加载（向前兼容）
    func testDecodingLegacyJSONFillsDefaults() throws {
        // 只有最早期的三个字段
        let legacy = #"{"spatialMode":"sweep","maxRadiusPt":100,"blurFloor":0}"#
        let data = Data(legacy.utf8)
        let decoded = try JSONDecoder().decode(FoldParameters.self, from: data)
        XCTAssertEqual(decoded.maxRadiusPt, 100)
        XCTAssertEqual(decoded.spatialMode, .sweep)
        // 未出现的字段应取默认值
        XCTAssertEqual(decoded.dimAmount, FoldParameters().dimAmount)
        XCTAssertEqual(decoded.rampKnee, FoldParameters().rampKnee)
    }

    /// `matching` 能找到预设，改一个字段后返回 nil
    func testPresetMatching() {
        for preset in allPresets {
            XCTAssertEqual(FoldPreset.matching(preset.parameters), preset,
                           "预设 \(preset.rawValue) 无法被 matching 识别")
        }

        var custom = FoldPreset.duoSweep.parameters
        custom.maxRadiusPt += 1
        XCTAssertNil(FoldPreset.matching(custom), "改过参数后不应再匹配到预设")

        var customFrost = FoldPreset.duoSweep.parameters
        customFrost.fullFrostAt = 0.5
        XCTAssertNil(FoldPreset.matching(customFrost))
    }

    /// fullFrostAt 生效：到达阈值后整屏进入均匀磨砂
    func testFullFrostBlendsInUniformly() {
        var p = FoldPreset.duoSweep.parameters
        p.fullFrostAt = 0.9

        // 阈值以下：铰链仍然是零模糊
        XCTAssertEqual(p.blurSigmaPt(d: 0, amount: 0.5), 0, accuracy: 1e-9)

        // 阈值以上：铰链处也开始模糊，且在 amount = 1 时整屏等于最大半径
        let hingeAtFull = p.blurSigmaPt(d: 0, amount: 1.0)
        XCTAssertGreaterThan(hingeAtFull, 0, "全屏磨砂应在铰链处也产生模糊")
        XCTAssertEqual(hingeAtFull, p.maxRadiusPt, accuracy: 1e-6)

        // 整屏一致（这就是"均匀磨砂"的定义）
        XCTAssertEqual(p.blurSigmaPt(d: 0.3, amount: 1.0), p.blurSigmaPt(d: 1.0, amount: 1.0), accuracy: 1e-6)
    }

    /// `sweep` 模式在 amount → 1 时应退化为 `ramp`
    func testSweepDegeneratesToRampAtFullAmount() {
        var sweep = FoldPreset.duoSweep.parameters
        sweep.fullFrostAt = nil
        var ramp = FoldPreset.duoClassic.parameters
        ramp.fullFrostAt = nil

        for i in 0...20 {
            let d = Double(i) / 20
            XCTAssertEqual(
                sweep.blurSigmaPt(d: d, amount: 1.0),
                ramp.blurSigmaPt(d: d, amount: 1.0),
                accuracy: 1e-9,
                "d=\(d) 处 sweep 在满折叠量下未退化为 ramp"
            )
        }
    }

    /// 折痕必须位于**面板起点**（t 空间），镜面光中心在面板 65% 处。
    ///
    /// 这两条是坐标系不变式：`creaseCenter` 在 t 空间，`front` 在 d 空间，
    /// 混用会把折痕画到面板中间 —— 这个 bug 真实发生过，用测试钉住。
    func testHighlightBandsAreConstantWidthInScreenSpace() {
        for preset in allPresets {
            let p = preset.parameters
            // 这两个常量是"带宽不随折叠量变化"的保证。写在参数里而不是着色器里，
            // 就是为了让这条测试能钉住它。
            XCTAssertEqual(p.creaseBandHalfWidth, 0.06, accuracy: 1e-12)
            XCTAssertEqual(p.rimSigma, 0.35, accuracy: 1e-12)

            for amount in stride(from: 0.0, through: 1.0, by: 0.1) {
                // 折痕位于面板起点（d 空间 = sweepFront），镜面光在面板 65% 处
                XCTAssertEqual(p.creaseDistanceFromHinge(amount: amount),
                               p.sweepFront(amount: amount), accuracy: 1e-12,
                               "\(preset.rawValue)：折痕必须在 d 空间的 front 处")
                let front = p.sweepFront(amount: amount)
                XCTAssertEqual(p.rimDistanceFromHinge(amount: amount),
                               front + 0.65 * (1 - front), accuracy: 1e-12,
                               "\(preset.rawValue)：镜面光必须在面板 65% 处")
                // 镜面光必须落在折痕与自由边之间，否则会跑到画面外
                XCTAssertGreaterThanOrEqual(p.rimDistanceFromHinge(amount: amount), front)
                XCTAssertLessThanOrEqual(p.rimDistanceFromHinge(amount: amount), 1.0 + 1e-12)
            }
        }
    }

    /// 折痕在**屏幕上**的位置（d 空间）随折叠量移动：sweep 模式从自由边走向铰链
    func testCreaseMovesTowardHingeInSweepMode() {
        let sweep = FoldPreset.duoSweep.parameters
        XCTAssertEqual(sweep.creaseDistanceFromHinge(amount: 1.0), 0, accuracy: 1e-12,
                       "折叠到底时折痕应到达铰链")

        var previous = sweep.creaseDistanceFromHinge(amount: 1.0 / 50)
        for i in 2...50 {
            let d = sweep.creaseDistanceFromHinge(amount: Double(i) / 50)
            XCTAssertLessThanOrEqual(d, previous + 1e-12, "折叠量增大时折痕应朝铰链单调移动")
            previous = d
        }

        // ramp 模式折痕固定在铰链处
        let ramp = FoldPreset.duoClassic.parameters
        for amount in stride(from: 0.0, through: 1.0, by: 0.25) {
            XCTAssertEqual(ramp.creaseDistanceFromHinge(amount: amount), 0, accuracy: 1e-12,
                           "ramp 模式的折痕应固定在铰链")
        }
    }

    /// 等效折叠角的映射范围
    func testEquivalentHingeAngleRange() {
        let p = FoldPreset.duoSweep.parameters
        XCTAssertEqual(p.equivalentHingeAngleDeg(amount: 0), 176, accuracy: 1e-9)
        XCTAssertEqual(p.equivalentHingeAngleDeg(amount: 1), 20, accuracy: 1e-9)
        XCTAssertEqual(p.equivalentHingeAngleDeg(amount: 0.5), 98, accuracy: 1e-9)
    }
}
