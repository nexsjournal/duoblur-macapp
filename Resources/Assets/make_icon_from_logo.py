#!/usr/bin/env python3
"""把一张方形的 logo 图做成 macOS 应用图标。

为什么要经过这一步而不是直接改名：macOS 的应用图标不是"一张方图"，而是
**内容缩到 ~80% 并套连续圆角矩形**（Big Sur 起的规范）。直接把满幅方图塞进去，
在 Dock/访达里会比系统图标大一圈、方角也格格不入。

用法：
    python3 Resources/Assets/make_icon_from_logo.py <源图路径>
    # 产出 Resources/Assets/AppIcon.iconset/ 与 AppIcon.icns

没有现成 logo 时，用程序生成的图标即可：`make icon`（不带 LOGO= 参数）。

依赖：Pillow。
"""

import os
import sys

try:
    from PIL import Image, ImageDraw
except ImportError:  # pragma: no cover
    print("需要 Pillow：python3 -m pip install pillow", file=sys.stderr)
    sys.exit(1)

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))

CANVAS = 1024
INSET = 100                      # 四周留白（macOS 图标规范 ~10%）
SIDE = CANVAS - INSET * 2
RADIUS = int(SIDE * 0.2237)


def main():
    if len(sys.argv) < 2:
        print("用法：make_icon_from_logo.py <源图路径>", file=sys.stderr)
        print("（或用 `make icon` 直接生成程序化图标）", file=sys.stderr)
        sys.exit(2)

    source = sys.argv[1]
    if not os.path.exists(source):
        print(f"找不到源图：{source}", file=sys.stderr)
        sys.exit(1)

    logo = Image.open(source).convert("RGBA")
    # 源图若是满幅方图，先等比缩到内容区（裁成正方形，避免拉伸变形）
    w, h = logo.size
    edge = min(w, h)
    logo = logo.crop(((w - edge) // 2, (h - edge) // 2, (w - edge) // 2 + edge, (h - edge) // 2 + edge))
    logo = logo.resize((SIDE, SIDE), Image.LANCZOS)

    mask = Image.new("L", (SIDE, SIDE), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, SIDE - 1, SIDE - 1], RADIUS, fill=255)

    master = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    master.paste(logo, (INSET, INSET), mask)

    iconset = os.path.join(HERE, "AppIcon.iconset")
    os.makedirs(iconset, exist_ok=True)
    for name, size in [
        ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
        ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
        ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
        ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
        ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
    ]:
        master.resize((size, size), Image.LANCZOS).save(os.path.join(iconset, name))
    print(f"已写出 {iconset}（源：{os.path.relpath(source, REPO)}）")


if __name__ == "__main__":
    main()
