#include <metal_stdlib>
using namespace metal;

// ============================================================================
//  DuoBlur 折页着色器
//
//  三个 pass：
//    ① foldPrepass   — 3×3 二项式预过滤，把捕获帧搬进我们自己的可写纹理
//    ② generateMipmaps（在 Swift 侧用 blit encoder 调用）— 生成整个模糊金字塔
//    ③ foldComposite — 逐像素按"离铰链的距离"选 LOD，叠加变暗/折痕/镜面光
//
//  为什么走金字塔而不是"扩大采样盘半径"：后者是色散不是模糊，亮文字会出现
//  多个离散鬼影。这是 lqSky7 的源码注释里明确记录过的教训，同类实现也无一例外地
//  这样做。
//
//  为什么铰链处要短路到捕获原图：铰链处的模糊半径严格为 0，而金字塔 level 0
//  已经带了一次 3×3 二项式（σ≈0.7px）。不短路的话整屏都会蒙一层薄雾，
//  "清晰区绝对清晰"这条视觉原则就没了。
// ============================================================================

// 与 Swift 侧 FoldUniforms 逐字段对应。
//
// 刻意**全部使用 4 字节标量**（不用 float2/float4）：这样 MSL 与 Swift 的结构体
// 布局都不存在对齐填充，两边不可能因为 padding 差异而错位。
// 顺序也必须完全一致。
struct FoldUniforms {
    float viewportWidth;
    float viewportHeight;
    float maxRadiusPx;        // 最大模糊 σ，单位：捕获纹理像素
    float amount;             // 0..1 折叠量（已含弹簧）
    float blurFloor;          // 最低模糊占比
    float rampKnee;           // 渐进拐点，默认 0.85
    float rampExp;            // 渐进指数，默认 1.25
    float dimAmount;
    float dimReach;
    float dimHingeFloor;
    float hingeLineStrength;
    float rimStrength;
    float grazingStrength;
    float reflection;         // 0..1 全局高光乘子
    float topInsetPx;         // 顶部留白（不施加效果）
    float sigmaPerLevel;      // 金字塔每级的 σ（实测校准常数）
    // 显示器 uv → 捕获纹理 uv 的仿射映射（纯缩放 + 平移）。
    // 绝不假设捕获帧与显示器 1:1：includeMenuBar / contentRect / contentScale
    // 都会让它们不一致。全屏捕获时这组值是 (1,1)/(0,0)。
    float captureUVScaleX;
    float captureUVScaleY;
    float captureUVOffsetX;
    float captureUVOffsetY;
    int   spatialMode;        // 0 uniform / 1 ramp / 2 sweep
    int   hingeOnRight;       // 1: 铰链在右边缘（d = 1 - uv.x）
    int   levels;             // mip 层数
    int   debugMode;          // 0 正常 / 1 直通自检 / 2 合成测试图案（不需要捕获）
};

struct FoldVertexOut {
    float4 position [[position]];
    float2 uv;
};

// 全屏三角形：不需要顶点缓冲，比全屏四边形少一次光栅化接缝
vertex FoldVertexOut foldFullscreenVertex(uint vertexID [[vertex_id]])
{
    const float2 positions[3] = { float2(-1.0, -3.0), float2(-1.0, 1.0), float2(3.0, 1.0) };
    const float2 uvs[3]       = { float2( 0.0,  2.0), float2( 0.0, 0.0), float2(2.0, 0.0) };
    FoldVertexOut out;
    out.position = float4(positions[vertexID], 0.0, 1.0);
    out.uv = uvs[vertexID];
    return out;
}

// ---------------------------------------------------------------------------
//  合成测试图案（debugMode == 2）
//
//  存在的理由：验证覆盖窗、着色器、参数**不需要屏幕录制权限**。
//  有了它，"覆盖层对不对"和"捕获通不通"这两件事可以分开排查；
//  你也可以在授权之前就把模糊强度、曲线、折痕调到位。
//
//  图案刻意包含四类最容易暴露问题的内容：
//    ① 1px 细网格   —— 色散/离散鬼影在这里最明显
//    ② 模拟文字行   —— 检验模糊下限与可读性边界
//    ③ 水平灰阶渐变 —— 检验 dither 是否消除了 8bit 色带
//    ④ 彩色块       —— 检验是否引入色偏
// ---------------------------------------------------------------------------
static inline float3 duoTestPattern(float2 uv, float2 sizePx)
{
    float2 px = uv * sizePx;
    float3 color = float3(0.06);

    // ① 1px 细网格（铺满全屏，先画，后面被其它元素覆盖）
    float2 gridMod = fmod(px, 24.0);
    if (gridMod.x < 1.0 || gridMod.y < 1.0) {
        color = float3(0.30);
    }

    // 大标题块
    if (px.y > 36.0 && px.y < 92.0 && px.x > 36.0 && px.x < sizePx.x * 0.52) {
        color = float3(0.93);
    }

    // ② 模拟文字行：每行长度不一，行间留白
    float bodyTop = sizePx.y * 0.16;
    if (px.y > bodyTop && px.y < sizePx.y * 0.56) {
        float row = floor((px.y - bodyTop) / 14.0);
        float rowY = fmod(px.y - bodyTop, 14.0);
        if (rowY < 6.0) {
            float len = 0.25 + 0.6 * fract(sin(row * 12.9898 + 4.1) * 43758.5453);
            if (px.x > 36.0 && px.x < 36.0 + sizePx.x * 0.62 * len) {
                color = float3(0.74);
            }
        }
    }

    // ③ 水平灰阶渐变条：dither 的验收项
    if (px.y > sizePx.y * 0.62 && px.y < sizePx.y * 0.72) {
        color = float3(px.x / max(sizePx.x, 1.0));
    }

    // ④ 彩色块：检验色偏
    if (px.y > sizePx.y * 0.78 && px.y < sizePx.y * 0.94) {
        float band = floor(px.x / max(sizePx.x / 6.0, 1.0));
        float3 palette[6] = {
            float3(0.90, 0.20, 0.20), float3(0.20, 0.80, 0.30), float3(0.20, 0.40, 0.95),
            float3(0.95, 0.80, 0.20), float3(0.80, 0.30, 0.90), float3(0.20, 0.85, 0.90)
        };
        color = palette[int(clamp(band, 0.0, 5.0))];
    }

    return color;
}

// ---------------------------------------------------------------------------
// ① 预过滤：分离核 [1 2 1]/4 ⊗ [1 2 1]/4 = 权重 /16
//    比 generateMipmaps 的 2×2 box 更好的第 0 级，也顺便把 SCK 的纹理
//    拷进我们自己的、可以生成 mip 的纹理里。
// ---------------------------------------------------------------------------
fragment float4 foldPrepass(FoldVertexOut in [[stage_in]],
                            texture2d<float> source [[texture(0)]],
                            constant FoldUniforms& u [[buffer(0)]])
{
    const float2 sizePx = float2(u.viewportWidth, u.viewportHeight);

    // 测试图案模式：直接把图案写进金字塔 level 0，
    // 后续的 mip 链与合成逻辑与真实捕获完全一致（所以调出来的参数可以直接用）。
    if (u.debugMode == 2 || u.debugMode == 3) {
        return float4(duoTestPattern(in.uv, sizePx), 1.0);
    }

    constexpr sampler smp(filter::linear, address::clamp_to_edge);
    const float2 texel = 1.0 / float2(float(source.get_width()), float(source.get_height()));
    const float2 o = texel;

    // 显示器 uv → 捕获纹理 uv
    const float2 uv = in.uv * float2(u.captureUVScaleX, u.captureUVScaleY)
                    + float2(u.captureUVOffsetX, u.captureUVOffsetY);

    float4 sum = source.sample(smp, uv + float2(-o.x, -o.y)) * 1.0
               + source.sample(smp, uv + float2( 0.0, -o.y)) * 2.0
               + source.sample(smp, uv + float2( o.x, -o.y)) * 1.0
               + source.sample(smp, uv + float2(-o.x,  0.0)) * 2.0
               + source.sample(smp, uv                        ) * 4.0
               + source.sample(smp, uv + float2( o.x,  0.0)) * 2.0
               + source.sample(smp, uv + float2(-o.x,  o.y)) * 1.0
               + source.sample(smp, uv + float2( 0.0,  o.y)) * 2.0
               + source.sample(smp, uv + float2( o.x,  o.y)) * 1.0;
    return sum * (1.0 / 16.0);
}

// 三角分布的白噪声抖动。
//
// 变暗斜坡跨整屏，8bit 下必然出现色带；±1/255 的三角分布抖动把台阶的**轮廓**
// 打散成噪声，肉眼就不再读出条带。用哈希而不是蓝噪声纹理是为了零资源依赖。
// （升级路径：换成 64×64 蓝噪声纹理，同样幅度下观感更好。）
//
// **坐标必须先取模再哈希**：像素坐标能到 3600 这个量级，float32 在那里的
// ULP 约 0.03，`fract(p * 123.34)` 这一类写法会只剩几十个离散值 ——
// 抖动退化成规则条纹甚至常量，实测表现为暗区出现 600+ 像素的平坦色带。
// 先 fmod 到 0..256 再做整数域哈希，精度才够。
static inline float hash21(float2 p, float seed)
{
    float3 p3 = fract(float3(fmod(floor(p), 256.0), fmod(floor(p.x + p.y), 256.0))
                      * 0.1031 + seed);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

// ---------------------------------------------------------------------------
// ③ 合成：Duo 折页
// ---------------------------------------------------------------------------
fragment float4 foldComposite(FoldVertexOut in [[stage_in]],
                              texture2d<float> sharp   [[texture(0)]],   // 捕获原图
                              texture2d<float> pyramid [[texture(1)]],   // 带 mip 链的预过滤副本
                              constant FoldUniforms& u [[buffer(0)]])
{
    constexpr sampler smp(filter::linear, mip_filter::linear, address::clamp_to_edge);
    const float2 uv = in.uv;

    // 显示器 uv → 捕获纹理 uv（见 uniforms 里的说明）
    const float2 captureUV = uv * float2(u.captureUVScaleX, u.captureUVScaleY)
                           + float2(u.captureUVOffsetX, u.captureUVOffsetY);

    // ---- 自检直通模式：原样输出 + 四边标记 ----
    // 用于验证覆盖窗是否真的在最上层、几何是否逐像素对齐、有没有自我捕获的
    // 反馈回路（若有回路，标记会逐帧累积变亮）。
    if (u.debugMode == 1) {
        float4 base = sharp.sample(smp, captureUV);
        float2 px = uv * float2(u.viewportWidth, u.viewportHeight);
        float2 toEdge = min(px, float2(u.viewportWidth, u.viewportHeight) - px);
        float edge = min(toEdge.x, toEdge.y);
        if (edge < 4.0) {
            base.rgb = mix(float3(1.0, 0.15, 0.15), base.rgb, edge / 4.0);
        }
        // 左上角一个棋盘方块：它出现在屏幕上就说明覆盖窗确实盖住了内容
        if (px.x < 120.0 && px.y < 120.0) {
            float checker = fmod(floor(px.x / 20.0) + floor(px.y / 20.0), 2.0);
            base.rgb = mix(float3(0.0, 0.8, 1.0), float3(1.0, 1.0, 1.0), checker);
        }
        return float4(base.rgb, 1.0);
    }

    // ---- 顶部留白：保护菜单栏（在 shader 里做，不依赖 14.2+ 的 includeMenuBar）----
    if (u.topInsetPx > 0.0 && uv.y * u.viewportHeight < u.topInsetPx) {
        return float4(0.0);   // 全透明：该区域完全不动
    }

    // ---- 折叠几何 ----
    // d：0 = 铰链（清晰锚点），1 = 自由边（最模糊）
    const float d = (u.hingeOnRight != 0) ? (1.0 - uv.x) : uv.x;

    // sweep 模式下折痕随折叠量从自由边移向铰链；ramp/uniform 固定在自由边
    const float front = (u.spatialMode == 2) ? (1.0 - u.amount) : 0.0;
    const float t = (front >= 1.0)
                  ? 0.0
                  : clamp((d - front) / (1.0 - front), 0.0, 1.0);

    const float ramp = pow(smoothstep(0.0, u.rampKnee, t), u.rampExp);
    const float spatial = (u.spatialMode == 0) ? 1.0 : ramp;

    // blurFloor（Cinematic 的"常驻薄雾"）乘一个短包络：覆盖层在 amount ≤ 0.001 时
    // 完全不合成，floor 若不随 amount 收敛，第一帧可见时会从"绝对清晰"
    // 直接跳到整屏模糊。0.12 与 Swift 侧 FoldParameters.floorRampAmount 一致。
    const float floorEnvelope = smoothstep(0.0, 1.0, min(u.amount / 0.12, 1.0));
    const float floorTerm = u.blurFloor * floorEnvelope;
    const float sigma = u.maxRadiusPx * (floorTerm + (1.0 - floorTerm) * u.amount * spatial);

    // ---- 取色 ----
    float4 color;
    if (sigma < 0.75) {
        // 锐利短路：与真实屏幕逐像素一致（"清晰区绝对清晰"的保证）。
        // 测试图案模式下没有"真实屏幕"，取金字塔 level 0（只多了一次 0.7px 二项式，不可见）。
        color = (u.debugMode == 2)
              ? pyramid.sample(smp, uv, level(0.0))
              : sharp.sample(smp, captureUV);
    } else {
        // 一次采样，硬件三线性在相邻两级之间插值 → 模糊半径连续、无跳档
        const float lod = clamp(log2(sigma / max(u.sigmaPerLevel, 1e-4)),
                                0.0, float(u.levels - 1));
        color = pyramid.sample(smp, uv, level(lod));
    }

    // 高光的时间包络：折叠量为 0 时完全无高光，折起来才有
    const float bendSine = sin(u.amount * M_PI_F * 0.5);

    // ---- 变暗（Duo 的"光损失"）----
    //
    // **必须乘 u.amount**：dimCurve 只描述"面板内从铰链到自由边"的分布，与折叠量无关；
    // 不乘 amount 的话，只要越过死区（t 一达到 dimReach）自由边就直接被压成纯黑 ——
    // 实测表现就是"稍微一转头，屏幕一侧出现一条黑带"。Swift 镜像
    // `FoldParameters.dimFactor` 一直带这个因子，此处曾经漏掉，导致
    // 预览（偏亮）与真实渲染（偏黑）不一致。
    const float dimCurve = max(u.dimHingeFloor, smoothstep(0.0, u.dimReach, t));
    color.rgb *= pow(max(1.0 - u.dimAmount * dimCurve * u.amount, 0.0), 2.1);

    // ---- 掠过变暗：折得越深，自由边越暗 ----
    color.rgb *= 1.0 - u.grazingStrength * bendSine * pow(t, 1.5);

    // ---- 折痕线 ----
    //
    // **坐标系很重要**：折痕与镜面光在 d 空间（离铰链的距离 = 屏幕空间）表达，
    // 变暗与掠过则在 t 空间（面板内进度）。原因是这两种光本质上是**屏幕上的**
    // 光学特征，带宽应该是屏宽的固定比例。
    //
    // 若把带宽写在 t 空间会有一个隐蔽的后果：t 空间的宽度随折叠量缩放
    // （窗口宽度 = 1 - front = amount），于是低折叠量时带被拉得很宽、
    // 峰值被稀释到几乎看不见——实测就是这样，折痕完全看不出来。
    const float rimCenterD = front + 0.65 * (1.0 - front);
    color.rgb += float3(0.90, 0.93, 0.95) * u.hingeLineStrength * u.reflection * bendSine
               * exp(-pow((d - front) / 0.06, 2.0));
    color.rgb += float3(0.82, 0.85, 0.86) * u.rimStrength * u.reflection * bendSine
               * exp(-pow((d - rimCenterD) / 0.35, 2.0));

    // ---- 通道可视化（debugMode == 3）----
    // R = 面板进度 t，G = 变暗系数，B = 归一化模糊半径。
    // 用于在像素级核对着色器内部量，而不是靠反推。定量验证的利器。
    if (u.debugMode == 3) {
        float vis = u.maxRadiusPx > 0.0 ? clamp(sigma / u.maxRadiusPx, 0.0, 1.0) : 0.0;
        float dimVis = pow(max(1.0 - u.dimAmount * dimCurve * u.amount, 0.0), 2.1);
        return float4(t, dimVis, vis, 1.0);
    }

    // ---- 抖动：必须在 saturate 之前，否则暗部会被截断成不含抖动的平整带 ----
    const float2 noiseCoord = uv * float2(u.viewportWidth, u.viewportHeight);
    const float dither = (hash21(noiseCoord, 0.0) + hash21(noiseCoord, 17.0) - 1.0) / 255.0;
    color.rgb += dither;

    return float4(saturate(color.rgb), 1.0);
}
