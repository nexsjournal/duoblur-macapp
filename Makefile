# DuoBlur — 构建 / 打包 / 签名
#
#   make app     编译 + 组装 .app + 签名 → build/DuoBlur.app
#   make run    构建并启动（必须经 LaunchServices 启动，否则 TCC 弹窗不会出现）
#   make icon   生成应用图标（Resources/Assets/AppIcon.icns）
#   make test   单元测试
#   make tcc    查看 TCC 授权状态
#   make reset-tcc  重置本应用的 TCC 授权，便于重跑首次启动引导
#   make clean
APP_NAME    := DuoBlur
BUNDLE_ID   := com.duoblur.app
BUILD_DIR   := build
BUNDLE      := $(BUILD_DIR)/$(APP_NAME).app
CONFIG      := release
SWIFT_BIN   := .build/$(CONFIG)/$(APP_NAME)

# 一次性创建自签名证书后，TCC 授权就不会再随每次重建失效。
# 创建方式见 README「开发环境准备」。找不到证书时自动退回 adhoc 并给出警告。
SIGN_ID     ?= DuoBlur Dev

# 本地覆盖（不纳入版本管理）：例如 SIGN_ID = "Apple Development: me@example.com"
-include Makefile.local

METAL_SOURCES := $(wildcard Sources/DuoBlurRender/Shaders/*.metal)
METALLIB      := $(BUILD_DIR)/default.metallib

.PHONY: all app compile metallib icon run test tcc reset-tcc clean help

all: app

help:
	@grep -E '^#   make' -A0 Makefile | sed 's/^#   //'

# --- 应用图标 ---
# 默认用程序生成的图标；有设计稿时用 LOGO=<路径> 指定，会按 macOS 的圆角规范套壳。
#   make icon
#   make icon LOGO=~/Desktop/logo.png
# 需要 Pillow：python3 -m pip install pillow
icon:
	@echo "==> 生成 AppIcon.icns"
	@if [ -n "$(LOGO)" ]; then \
		python3 Resources/Assets/make_icon_from_logo.py "$(LOGO)"; \
	else \
		python3 Resources/Assets/make_icon.py; \
	fi
	@iconutil -c icns Resources/Assets/AppIcon.iconset -o Resources/Assets/AppIcon.icns
	@echo "    → Resources/Assets/AppIcon.icns"

$(BUILD_DIR):
	@mkdir -p $(BUILD_DIR)

# --- Metal 着色器：离线编译成 metallib，运行时用 device.makeLibrary(URL:) 显式加载 ---
# 离线编译的好处：着色器语法错误在构建期就暴露，不会拖到运行时。
metallib: | $(BUILD_DIR)
ifeq ($(strip $(METAL_SOURCES)),)
	@echo "==> 暂无 .metal 源文件，跳过 metallib"
else
	@echo "==> 编译 Metal 着色器"
	@set -e; for f in $(METAL_SOURCES); do \
		base=$$(basename $$f .metal); \
		xcrun -sdk macosx metal -O2 -c $$f -o $(BUILD_DIR)/$$base.air; \
	done
	xcrun -sdk macosx metallib $(BUILD_DIR)/*.air -o $(METALLIB)
	@rm -f $(BUILD_DIR)/*.air
endif

# 注意：这个目标不能叫 `build` —— $(BUILD_DIR) 就是 build/，同名会让 make
# 报 "overriding commands for target" 并丢掉依赖关系。
compile: | $(BUILD_DIR)
	swift build -c $(CONFIG)

app: compile metallib
	@echo "==> 组装 $(BUNDLE)"
	@rm -rf $(BUNDLE)
	@mkdir -p $(BUNDLE)/Contents/MacOS $(BUNDLE)/Contents/Resources
	@cp $(SWIFT_BIN) $(BUNDLE)/Contents/MacOS/$(APP_NAME)
	@cp Resources/Info.plist $(BUNDLE)/Contents/Info.plist
	@printf 'APPL????' > $(BUNDLE)/Contents/PkgInfo
	@if [ -f $(METALLIB) ]; then cp $(METALLIB) $(BUNDLE)/Contents/Resources/; fi
	@# 同时把着色器源码放进 bundle：MetalContext 找不到 metallib 时会退回运行时编译，
	@# 这条兜底路径保证"换一台没装 Metal 工具链的机器"时渲染链路仍然可用。
	@if [ -d Sources/DuoBlurRender/Shaders ]; then \
		cp Sources/DuoBlurRender/Shaders/*.metal $(BUNDLE)/Contents/Resources/ 2>/dev/null || true; \
	fi
	@if [ -f Resources/Assets/AppIcon.icns ]; then cp Resources/Assets/AppIcon.icns $(BUNDLE)/Contents/Resources/; fi
	@$(MAKE) --no-print-directory sign

sign:
	@echo "==> 签名"
	@# 注意：**不加 -v**。`-v` 只列"受信任"的身份，而本地自签名证书是未受信任状态
	@# （CSSMERR_TP_NOT_TRUSTED），加 -v 会把它过滤掉，导致明明有证书却回退到 adhoc。
	@# 未受信任不影响 codesign 使用它，也不影响 TCC 授权的稳定性。
	@if security find-identity -p codesigning 2>/dev/null | grep -q "$(SIGN_ID)"; then \
		codesign --force --sign "$(SIGN_ID)" \
			--entitlements Resources/$(APP_NAME).entitlements \
			$(BUNDLE) >/dev/null 2>&1 \
		&& echo "    已用 \"$(SIGN_ID)\" 签名 —— TCC 授权可跨重建保持" \
		|| { echo "    ✗ 用 \"$(SIGN_ID)\" 签名失败"; exit 1; }; \
	else \
		codesign --force --sign - $(BUNDLE) >/dev/null 2>&1 \
		&& echo "    ⚠  未找到证书 \"$(SIGN_ID)\"，已用 adhoc 签名" \
		&& echo "       adhoc 签名每次重建都会改变身份 → 屏幕录制/运动与健身授权每次都要重新给。" \
		&& echo "       一次性解决：钥匙串访问 → 证书助理 → 创建证书…" \
		&& echo "         名称 \"$(SIGN_ID)\" / 身份类型「自签名根证书」/ 证书类型「代码签名」/ 3650 天" \
		&& echo "       然后重跑 make app。"; \
	fi

run: app
	@echo "==> 启动（经 LaunchServices；直接跑裸二进制不会触发权限弹窗）"
	@open $(BUNDLE)

test:
	swift test

tcc:
	@echo "--- 本应用的 TCC 记录 ---"
	@sqlite3 "$(HOME)/Library/Application Support/com.apple.TCC/TCC.db" \
		"select service, client, auth_value from access where client like '%duoblur%';" 2>/dev/null \
		|| echo "(无法读取 TCC.db —— 这是正常的，需要给终端完全磁盘访问权限。"
	@echo ""
	@echo "请在「系统设置 → 隐私与安全性」中查看："
	@echo "  · 运动与健身      → DuoBlur"
	@echo "  · 屏幕录制        → DuoBlur"

reset-tcc:
	-tccutil reset Motion $(BUNDLE_ID)
	-tccutil reset ScreenCapture $(BUNDLE_ID)
	@echo "==> 已重置 TCC。下次启动会重新弹窗。"

clean:
	swift package clean
	rm -rf .build $(BUILD_DIR)
