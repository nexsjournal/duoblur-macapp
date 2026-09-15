# DuoBlur — 构建 / 打包 / 签名 / 分发
#
#   --- 开发期 ---
#   make app        编译 + 组装 .app + 签名 → build/DuoBlur.app（本机自签名，TCC 授权稳定）
#   make run        构建并启动（必须经 LaunchServices 启动，否则 TCC 弹窗不会出现）
#   make icon       生成应用图标（Resources/Assets/AppIcon.icns）
#   make test       单元测试
#   make tcc        查看 TCC 授权状态
#   make reset-tcc  重置本应用的 TCC 授权，便于重跑首次启动引导
#
#   --- 分发给别人 ---
#   make release    通用二进制（Intel + Apple Silicon）+ hardened runtime 签名
#   make dmg        打分发用 DMG（内含安装说明 + Applications 链接）
#   make verify-release  校验产物：架构 / 签名 / 强化运行时 / 公证状态
#   make notary-setup    一次性：把 App Store Connect 凭据存进钥匙串
#   make notarize   提交公证 + stapler 装订（需要 Developer ID 证书与凭据）
#
#   make clean

APP_NAME    := DuoBlur
BUNDLE_ID   := com.duoblur.app
BUILD_DIR   := build
BUNDLE      := $(BUILD_DIR)/$(APP_NAME).app
CONFIG      := release

# 版本号：默认取 Info.plist，可用 `make release VERSION=1.0.0` 覆盖（只改包内副本，不动仓库文件）
VERSION_STR := $(shell /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist 2>/dev/null)
ifneq ($(strip $(VERSION)),)
VERSION_STR := $(VERSION)
endif
DMG         := $(BUILD_DIR)/$(APP_NAME)-$(VERSION_STR).dmg

# 通用二进制：SwiftPM 会把产物放到 .build/apple/Products/Release/
UNIVERSAL   ?= 0
ifeq ($(UNIVERSAL),1)
  SWIFT_BIN   := .build/apple/Products/Release/$(APP_NAME)
  BUILD_FLAGS := -c $(CONFIG) --arch arm64 --arch x86_64
else
  SWIFT_BIN   := .build/$(CONFIG)/$(APP_NAME)
  BUILD_FLAGS := -c $(CONFIG)
endif

# 开发期签名身份：一次性创建自签名证书后，TCC 授权就不会再随每次重建失效。
# 创建方式见 docs/03 §8.2。找不到证书时自动退回 adhoc 并给出警告。
SIGN_ID     ?= DuoBlur Dev

# 分发签名身份：Developer ID Application（可分发给任何人、可公证）。
# 没有时退回本机自签名证书 —— 对方要手动放行，但 TCC 授权仍能跨版本保持。
DEV_ID          := $(shell security find-identity -p codesigning 2>/dev/null \
                     | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)
NOTARY_PROFILE  ?= duoblur-notary

# 本地覆盖（不纳入版本管理）：例如 SIGN_ID = "Apple Development: me@example.com"
-include Makefile.local

METAL_SOURCES := $(wildcard Sources/DuoBlurRender/Shaders/*.metal)
METALLIB      := $(BUILD_DIR)/default.metallib

.PHONY: all app compile metallib icon run test tcc reset-tcc clean help \
        release dmg ship verify-release notary-setup notary-setup-key notarize signing-status

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
	swift build $(BUILD_FLAGS)

# 组装 .app（不含签名）。`make app` 与 `make release` 共用，避免两份组装逻辑漂移。
assemble: | $(BUILD_DIR)
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
	@if [ "$(VERSION_STR)" != "" ]; then \
		/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $(VERSION_STR)" $(BUNDLE)/Contents/Info.plist >/dev/null; \
	fi

app: compile metallib assemble
	@$(MAKE) --no-print-directory sign

sign:
	@echo "==> 签名（开发期）"
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

# ============================================================================
#  分发
# ============================================================================

# 分发用构建：通用二进制 + 强化运行时（公证的硬性要求）+ 可用的最好身份。
release: clean
	@$(MAKE) --no-print-directory UNIVERSAL=1 compile
	@$(MAKE) --no-print-directory UNIVERSAL=1 metallib
	@$(MAKE) --no-print-directory UNIVERSAL=1 assemble
	@$(MAKE) --no-print-directory sign-release

sign-release:
	@echo "==> 签名（分发）"
	@if [ -n "$(DEV_ID)" ]; then \
		echo "    身份：$(DEV_ID)  （Developer ID：可分发给任何人，可公证）"; \
		codesign --force --options runtime --timestamp \
			--sign "$(DEV_ID)" \
			--entitlements Resources/$(APP_NAME).entitlements \
			$(BUNDLE) || exit 1; \
		echo "    ✅ 已用 Developer ID 签名（带 hardened runtime 与安全时间戳）"; \
	elif security find-identity -p codesigning 2>/dev/null | grep -q "$(SIGN_ID)"; then \
		echo "    ⚠  未找到 Developer ID Application 证书，改用本机自签名证书 \"$(SIGN_ID)\""; \
		echo "       后果：对方首次打开需要手动放行；无法通过公证（notarize 会失败）。"; \
		echo "       想彻底解决：加入 Apple Developer Program → 创建 Developer ID Application 证书"; \
		echo "         Xcode → Settings → Accounts → Manage Certificates → + → Developer ID Application"; \
		echo "       （--timestamp 需要 Apple 时间戳服务，自签名签名时省略）"; \
		codesign --force --options runtime \
			--sign "$(SIGN_ID)" \
			--entitlements Resources/$(APP_NAME).entitlements \
			$(BUNDLE) || exit 1; \
	else \
		echo "    ⚠  既没有 Developer ID 也没有自签名证书，退回 adhoc"; \
		codesign --force --options runtime --sign - $(BUNDLE) || exit 1; \
	fi

# 打 DMG：应用 + Applications 软链 + 安装说明
dmg: release
	@echo "==> 打包 DMG（$(VERSION_STR)）"
	@rm -rf $(BUILD_DIR)/dmg-root
	@mkdir -p $(BUILD_DIR)/dmg-root
	@cp -R $(BUNDLE) $(BUILD_DIR)/dmg-root/
	@ln -s /Applications $(BUILD_DIR)/dmg-root/Applications
	@if [ -f "Resources/Release/安装说明.txt" ]; then cp "Resources/Release/安装说明.txt" $(BUILD_DIR)/dmg-root/; fi
	@rm -f $(DMG)
	@hdiutil create -volname "$(APP_NAME) $(VERSION_STR)" \
		-srcfolder $(BUILD_DIR)/dmg-root -ov -format UDZO $(DMG) >/dev/null
	@rm -rf $(BUILD_DIR)/dmg-root
	@if [ -n "$(DEV_ID)" ]; then \
		codesign --force --sign "$(DEV_ID)" $(DMG) && echo "    DMG 已用 Developer ID 签名"; \
	fi
	@echo "    → $(DMG)"
	@du -h $(DMG) | cut -f1 | sed 's/^/      体积 /'

# 分发签名体检：一眼看出"能不能做出双击即开的包"，以及缺什么。
# 这是给"我要一个别人下载就能用的 DMG"这个目标准备的检查表。
signing-status:
	@echo "=== 分发签名体检 ==="
	@echo ""
	@echo "[1] 本机代码签名身份"
	@security find-identity -p codesigning 2>/dev/null | sed -n 's/^ *[0-9]*) /    /p' | sed 's/ (CSSMERR.*//' | sort -u || true
	@echo ""
	@echo "[2] Developer ID Application 证书（双击即开的前提）"
	@if [ -n "$(DEV_ID)" ]; then \
		echo "    OK  $(DEV_ID)"; \
	else \
		echo "    缺失：收件人首次打开需要右键 →「打开」放行一次"; \
		echo "    创建（约 2 分钟）：Xcode → Settings → Accounts → 登录付费团队的 Apple ID"; \
		echo "      → Manage Certificates → 左下角 + → Developer ID Application → Done"; \
		echo "    只有**付费**的 Apple Developer Program 团队才能签发 Developer ID。"; \
	fi
	@echo ""
	@echo "    这台机器上出现过的团队（来自 Apple Distribution 证书）："
	@security find-identity -p codesigning 2>/dev/null | sed -n 's/.*(\([A-Z0-9]\{10\}\))".*/      Team ID: \1/p' | sort -u || true
	@echo ""
	@echo "[3] 公证凭据（notarytool profile: $(NOTARY_PROFILE)）"
	@if xcrun notarytool history --keychain-profile "$(NOTARY_PROFILE)" >/dev/null 2>&1; then \
		echo "    OK  已保存且可用 —— 可以直接 make notarize"; \
	else \
		echo "    尚未保存。一次性配置："; \
		echo "      make notary-setup APPLE_ID=你的邮箱 TEAM_ID=团队ID"; \
		echo "      （密码用 appleid.apple.com 生成的 App 专用密码，不是登录密码）"; \
	fi
	@echo ""
	@echo "[4] 下一步"
	@if [ -n "$(DEV_ID)" ]; then \
		echo "    make dmg && make notarize"; \
	else \
		echo "    先补 [2] 的证书，然后： make notary-setup … → make dmg && make notarize"; \
		echo "    现在也可以直接 make dmg（产出的包需要对方手动放行一次）"; \
	fi

# 校验产物：架构、签名、强化运行时、Gatekeeper 评估
verify-release:
	@echo "=== 架构 ==="
	@lipo -info $(BUNDLE)/Contents/MacOS/$(APP_NAME)
	@echo "=== 签名 ==="
	@codesign -dvvv $(BUNDLE) 2>&1 | grep -E "Identifier|Authority|TeamIdentifier|flags|Timestamp" || true
	@echo "=== 强化运行时 ==="
	@codesign -dvvv $(BUNDLE) 2>&1 | grep -q "flags=.*runtime" \
		&& echo "  ✅ 已启用 hardened runtime" \
		|| echo "  ⚠  未启用 hardened runtime（公证要求）"
	@echo "=== 公证 / Gatekeeper ==="
	@xcrun stapler validate $(BUNDLE) 2>&1 | tail -1 || true
	@spctl -a -vvv $(BUNDLE) 2>&1 | tail -2 || true
	@echo "=== 结构 ==="
	@codesign --verify --deep --strict --verbose=1 $(BUNDLE) 2>&1 | tail -2
	@echo "=== 包内资源 ==="
	@ls -1 $(BUNDLE)/Contents/Resources/

# 一次性：把 App Store Connect 的凭据存进钥匙串（之后 notarize 不再需要密码）
#   make notary-setup APPLE_ID=you@example.com TEAM_ID=ABCDE12345
# 其中密码要在 appleid.apple.com 生成"App 专用密码"（不是登录密码）。
notary-setup:
	@test -n "$(APPLE_ID)" || { echo "用法：make notary-setup APPLE_ID=you@example.com TEAM_ID=ABCDE12345"; exit 1; }
	@test -n "$(TEAM_ID)" || { echo "缺少 TEAM_ID（Developer 账号的 Team ID）"; exit 1; }
	xcrun notarytool store-credentials "$(NOTARY_PROFILE)" \
		--apple-id "$(APPLE_ID)" --team-id "$(TEAM_ID)"

# 备用（更稳）：用 App Store Connect API Key 而不是 App 专用密码。
#   1) appstoreconnect.apple.com → 用户和访问 → 集成 → App Store Connect API
#      → 生成密钥（角色 Developer 即可）→ 下载 AuthKey_XXXXXX.p8（**只能下载一次**）
#      页面上同时能看到 Key ID 与 Issuer ID
#   2) make notary-setup-key KEY=~/Downloads/AuthKey_ABC123.p8 KEY_ID=ABC123 ISSUER=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
# 这条路的优点：不受"App 专用密码/双重认证状态"影响，团队里 Admin 也能用。
notary-setup-key:
	@test -n "$(KEY)" -a -n "$(KEY_ID)" -a -n "$(ISSUER)" || { \
		echo "用法：make notary-setup-key KEY=AuthKey_XXX.p8 KEY_ID=XXX ISSUER=xxx-xxx"; exit 1; }
	xcrun notarytool store-credentials "$(NOTARY_PROFILE)" \
		--key "$(KEY)" --key-id "$(KEY_ID)" --issuer "$(ISSUER)"

# 公证：提交 DMG → 等待结果 → 把公证票据装订进 DMG 与 .app
notarize: dmg
	@if [ -z "$(DEV_ID)" ]; then \
		echo "✗ 没有 Developer ID Application 证书，公证无法通过。先看 make release 的提示。"; \
		exit 1; \
	fi
	@echo "==> 提交公证（profile：$(NOTARY_PROFILE)）"
	xcrun notarytool submit $(DMG) --keychain-profile "$(NOTARY_PROFILE)" --wait
	@echo "==> 装订公证票据"
	xcrun stapler staple $(DMG)
	xcrun stapler validate $(DMG)
	@echo "✅ 完成：$(DMG) 已可公证分发（对方双击即可，无任何提示）"

# 一条命令发版：通用二进制 → Developer ID 签名 → DMG → 公证 → 装订 → 校验。
# 与那些"看起来很省事"的项目等价（例如 dsh-desktop 的 `yarn dist:mac`）——
# 它们同样是 Developer ID + 苹果公证，只是把这条链藏在一个脚本里、凭据预先放好。
ship:
	@$(MAKE) --no-print-directory notarize
	@$(MAKE) --no-print-directory verify-release
	@echo ""
	@echo "===================================================================="
	@echo "  可分发产物：$(DMG)"
	@echo "  收件人：打开 DMG → 拖进「应用程序」→ 双击即可，无任何拦截"
	@echo ""
	@echo "  sha256: $$(shasum -a 256 $(DMG) | cut -d' ' -f1)"
	@echo "===================================================================="

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
