#!/usr/bin/env python3
"""生成 DuoBlur 的应用图标（可复现）。

图形语义 = 应用在做的事：一块屏幕被"折页"分成两半 ——
左半边是锐利的细网格，右半边是同一网格的模糊 + 轻微变暗版本，
中间一条青色折痕线。小尺寸下"一半利一半糊"仍可辨认。

用法：
    python3 Resources/Assets/make_icon.py
    # 产出 Resources/Assets/AppIcon.iconset/ 与 AppIcon.icns

依赖：Pillow（`python3 -m pip install pillow`）。刻意不引入其它依赖 ——
图标是构建产物，脚本入库保证它可复现、可改（改配色/构图重跑即可）。
"""

import os
import sys

try:
    from PIL import Image, ImageDraw, ImageFilter
except ImportError:  # pragma: no cover
    print("需要 Pillow：python3 -m pip install pillow", file=sys.stderr)
    sys.exit(1)

HERE = os.path.dirname(os.path.abspath(__file__))

# --- 画布与 macOS 图标规范 ---------------------------------------------------
CANVAS = 1024
INSET = 100                     # 四周留白（macOS 图标惯例）
SIDE = CANVAS - INSET * 2       # 内容边长
RADIUS = int(SIDE * 0.2237)     # 连续圆角半径（Big Sur 起的比例）

# --- 配色 -------------------------------------------------------------------
TOP = (46, 58, 84)              # 深板岩蓝（上）
BOTTOM = (24, 30, 46)           # 更深（下）
GRID = (226, 236, 248)          # 网格线
CREASE = (110, 220, 235)        # 折痕青
BLUR_MAX = 34                   # 模糊侧的最大高斯半径（px）
DIM = 0.55                      # 模糊侧的最低亮度系数

FOLD_X = 0.47                   # 折痕位置（内容宽度的比例）


def vertical_gradient(size, top, bottom):
    img = Image.new("RGB", (1, size), top)
    px = img.load()
    for y in range(size):
        t = y / max(size - 1, 1)
        px[0, y] = tuple(int(top[i] + (bottom[i] - top[i]) * t) for i in range(3))
    return img.resize((size, size), Image.BILINEAR)


def build_master():
    canvas = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))

    # 1) 圆角底板 + 垂直渐变
    tile = vertical_gradient(SIDE, TOP, BOTTOM).convert("RGBA")
    mask = Image.new("L", (SIDE, SIDE), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, SIDE - 1, SIDE - 1], RADIUS, fill=255)

    # 2) 锐利内容层：细网格 + 几条"文字行"
    sharp = Image.new("RGBA", (SIDE, SIDE), (0, 0, 0, 0))
    d = ImageDraw.Draw(sharp)
    cell = 34
    for x in range(0, SIDE, cell):
        d.line([(x, 0), (x, SIDE)], fill=GRID + (150,), width=2)
    for y in range(0, SIDE, cell):
        d.line([(0, y), (SIDE, y)], fill=GRID + (150,), width=2)
    for i, (y, w) in enumerate([(SIDE * 0.20, 0.52), (SIDE * 0.28, 0.40),
                                (SIDE * 0.36, 0.58), (SIDE * 0.44, 0.33),
                                (SIDE * 0.62, 0.50), (SIDE * 0.70, 0.44)]):
        d.rounded_rectangle([SIDE * 0.08, y, SIDE * (0.08 + w), y + 18],
                            radius=9, fill=GRID + (185,))

    # 3) 折痕两侧：左 = 原样；右 = 模糊 + 变暗，且随距离渐进
    fold = int(SIDE * FOLD_X)
    sharp_left = sharp.crop((0, 0, fold, SIDE))
    base_left = tile.crop((0, 0, fold, SIDE)).convert("RGBA")
    base_left.alpha_composite(sharp_left)
    canvas.paste(base_left, (INSET, INSET), base_left)

    blurred = sharp.filter(ImageFilter.GaussianBlur(BLUR_MAX))
    right = Image.new("RGBA", (SIDE - fold, SIDE), (0, 0, 0, 0))
    ramp = Image.new("L", (SIDE - fold, 1))
    rp = ramp.load()
    for x in range(SIDE - fold):
        rp[x, 0] = int(255 * (x / max(SIDE - fold - 1, 1)) ** 0.7)
    ramp = ramp.resize((SIDE - fold, SIDE))

    layer = tile.crop((fold, 0, SIDE, SIDE)).convert("RGBA")
    sampled = sharp.crop((fold, 0, SIDE, SIDE))
    mixed = Image.composite(blurred.crop((fold, 0, SIDE, SIDE)), sampled, ramp)
    layer.alpha_composite(mixed)

    # 变暗（与效果里的"光损失"同向）
    dark = Image.new("RGBA", layer.size, (0, 0, 0, 0))
    dp = dark.load()
    for x in range(layer.size[0]):
        a = int(255 * (1 - DIM) * (x / max(layer.size[0] - 1, 1)) ** 0.7)
        for y in range(layer.size[1]):
            dp[x, y] = (0, 0, 0, a)
    layer.alpha_composite(dark)
    canvas.paste(layer, (INSET + fold, INSET), layer)

    # 4) 折痕亮线
    d2 = ImageDraw.Draw(canvas)
    for offset, alpha in ((0, 210), (-4, 70), (4, 70)):
        d2.line([(INSET + fold + offset, INSET + 6),
                 (INSET + fold + offset, INSET + SIDE - 6)],
                fill=CREASE + (alpha,), width=5)

    # 5) 裁圆角（整幅尺寸的蒙版，圆角矩形贴在 INSET 位置）
    out = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    full_mask = Image.new("L", (CANVAS, CANVAS), 0)
    full_mask.paste(mask, (INSET, INSET))
    out.paste(canvas, (0, 0), full_mask)
    return out


def main():
    master = build_master()
    iconset = os.path.join(HERE, "AppIcon.iconset")
    os.makedirs(iconset, exist_ok=True)

    specs = [
        ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
        ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
        ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
        ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
        ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
    ]
    for name, size in specs:
        master.resize((size, size), Image.LANCZOS).save(os.path.join(iconset, name))
    print(f"已写出 {iconset}")


if __name__ == "__main__":
    main()
