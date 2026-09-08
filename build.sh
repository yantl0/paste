#!/bin/zsh
# 编译并打包成 Paste.app（放在 ./build/ 下）
set -e
cd "$(dirname "$0")"

swift build -c release 2>&1 | grep -v '^\[' || true

APP=build/Paste.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Paste "$APP/Contents/MacOS/Paste"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# 优先用本机已有的开发者证书签名，这样重新编译后不用重新授权辅助功能；没有就临时签名
IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | grep -m1 -oE '"[^"]+"' | tr -d '"' || true)
if [[ -n "$IDENTITY" ]]; then
  codesign --force --sign "$IDENTITY" --identifier com.yan.paste "$APP" >/dev/null 2>&1 && echo "已用证书签名: $IDENTITY" || codesign --force --sign - "$APP"
else
  codesign --force --sign - "$APP"
  echo "已使用临时签名（每次重新编译后需要重新授权辅助功能）"
fi

echo "构建完成: $PWD/$APP"
echo "运行:  open $APP"
