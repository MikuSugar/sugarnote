#!/bin/bash
#
# 把 SwiftPM 产物组装成一个可用的 sugarnote.app。
#
# 为什么不用 Xcode 工程：这个项目全程用命令行构建和测试，SwiftPM 就够了。
# 唯一需要手工做的是「组装 .app 目录结构 + 写 Info.plist + 签名」这三步，
# 都放在这个脚本里，比维护一个 .xcodeproj 透明得多。
#
# 用法：
#   scripts/build-app.sh                    # ad-hoc 签名（本地开发）
#   SIGN_IDENTITY="Developer ID Application: ..." scripts/build-app.sh
#
# 注意 TCC：ad-hoc 签名的 App，辅助功能授权是按 cdhash 记的，重新构建就会失效，
# 需要在系统设置里重新授权。要避免反复授权就传一个稳定的 SIGN_IDENTITY。

set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
CONFIG="${CONFIG:-release}"
APP_NAME="sugarnote"
BUILD_DIR="$ROOT/build"
APP="$BUILD_DIR/$APP_NAME.app"
# 签名身份。优先用 scripts/setup-dev-signing.sh 建的稳定开发身份——
# ad-hoc 签名每次重建都会换 cdhash，而辅助功能授权按 cdhash 记，等于每重建一次就要
# 重新授权一次。稳定身份签出来的要求锚定证书哈希，重建后授权依然有效。
DEV_KEYCHAIN="$HOME/Library/Keychains/sugarnote-dev.keychain"
DEV_CERT_NAME="sugarnote Dev Signing"
if [ -z "${SIGN_IDENTITY:-}" ]; then
  # 只靠 find-certificate 判断：新版本 macOS 的 keychain 文件名带 -db 后缀，
# 用 [ -f path ] 判断会落空
if security find-certificate -c "$DEV_CERT_NAME" "$DEV_KEYCHAIN" >/dev/null 2>&1; then
    SIGN_IDENTITY="$DEV_CERT_NAME"
    SIGN_KEYCHAIN="$DEV_KEYCHAIN"
    security unlock-keychain -p "sugarnote-dev" "$DEV_KEYCHAIN" 2>/dev/null || true
  else
    SIGN_IDENTITY="-"
    echo "提示：没有稳定的开发签名身份，这次用 ad-hoc 签名。"
    echo "      这意味着重新构建后辅助功能授权会失效，需要重新授权。"
    echo "      跑一次 scripts/setup-dev-signing.sh 可以根治。"
  fi
fi
SIGN_KEYCHAIN="${SIGN_KEYCHAIN:-}"

echo "==> 构建（${CONFIG}）"
swift build -c "$CONFIG" --product "$APP_NAME"

BIN="$(swift build -c "$CONFIG" --product "$APP_NAME" --show-bin-path)/$APP_NAME"
[ -x "$BIN" ] || { echo "找不到可执行文件：${BIN}" >&2; exit 1; }

echo "==> 组装 ${APP}"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# SwiftPM 生成的资源 bundle（menu-aliases.json 在里面），
# Bundle.module 会在 main bundle 的 Resources 下找它
BIN_DIR="$(dirname "$BIN")"
for bundle in "$BIN_DIR"/*.bundle; do
  [ -e "$bundle" ] || continue
  echo "    资源：$(basename "$bundle")"
  cp -R "$bundle" "$APP/Contents/Resources/"
done

# 应用图标：由 Tools/make-icon.swift 从 Resources/AppIcon-source.png 生成。
# 源图变了或还没生成过就重新生成一次——设计稿通常是内容占满画布的，直接打包会比
# Dock 里别的图标大一圈，中间那步「缩到 macOS 规范的 824/1024 网格」不能省。
SOURCE_ICON="$ROOT/Resources/AppIcon-source.png"
ICNS="$ROOT/Resources/AppIcon.icns"
if [ -f "$SOURCE_ICON" ]; then
  if [ ! -f "$ICNS" ] || [ "$SOURCE_ICON" -nt "$ICNS" ]; then
    echo "==> 生成应用图标"
    (cd "$ROOT" && swift Tools/make-icon.swift)
  fi
  cp "$ICNS" "$APP/Contents/Resources/"
  echo "    图标：AppIcon.icns"
fi

echo "==> 签名（identity: ${SIGN_IDENTITY}）"
# 先签内嵌的资源 bundle，再签 App 本体
find "$APP/Contents/Resources" -name "*.bundle" -maxdepth 1 -print0 2>/dev/null \
  | while IFS= read -r -d '' bundle; do
      codesign --force --sign "$SIGN_IDENTITY" --timestamp=none "$bundle" 2>/dev/null || true
    done
if [ -n "$SIGN_KEYCHAIN" ]; then
  codesign --force --sign "$SIGN_IDENTITY" --keychain "$SIGN_KEYCHAIN" \
    --options runtime --identifier com.mikusugar.sugarnote "$APP"
else
  codesign --force --sign "$SIGN_IDENTITY" \
    --options runtime --identifier com.mikusugar.sugarnote "$APP"
fi

echo "==> 校验"
codesign --verify --deep --strict "$APP" && echo "    签名校验通过"
# 把签名要求打出来：辅助功能授权认的就是这一串，稳定身份签出来的应该是
# 「锚定证书哈希」而不是 cdhash
codesign -d -r- "$APP" 2>&1 | grep "designated" | sed 's/^/    /' || true
/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$APP/Contents/Info.plist" | sed 's/^/    bundle id: /'

cat <<EOF

完成：$APP

下一步：
  1. open "$APP"
  2. 到「系统设置 > 隐私与安全性 > 辅助功能」把 sugarnote 打开
  3. 打开备忘录，在正文里敲 **粗体** 试试
EOF
