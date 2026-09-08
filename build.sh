#!/bin/zsh
# 编译并打包成 Paste.app（放在 ./build/ 下）
#
#   ./build.sh          发布构建：ad-hoc 签名，永不过期，分发给他人用这个
#   ./build.sh --dev    开发构建：用本机开发者证书签名，重新编译后不用重新授权辅助功能
set -e
cd "$(dirname "$0")"

MODE="release"
[[ "$1" == "--dev" ]] && MODE="dev"

swift build -c release 2>&1 | grep -v '^\[' || true

APP=build/Paste.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Paste "$APP/Contents/MacOS/Paste"
cp Resources/Info.plist "$APP/Contents/Info.plist"

if [[ "$MODE" == "dev" ]]; then
  IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | grep -m1 -oE '"[^"]+"' | tr -d '"' || true)
  if [[ -n "$IDENTITY" ]] && codesign --force --sign "$IDENTITY" --identifier com.yan.paste "$APP" >/dev/null 2>&1; then
    echo "开发构建，已用证书签名: $IDENTITY"
  else
    codesign --force --sign - --identifier com.yan.paste "$APP"
    echo "未找到可用证书，已改用 ad-hoc 签名"
  fi
else
  codesign --force --sign - --identifier com.yan.paste "$APP"
  echo "发布构建，已使用 ad-hoc 签名（无证书、永不过期）"
fi

echo "构建完成: $PWD/$APP"
echo "运行:  open $APP"
