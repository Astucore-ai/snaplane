#!/bin/zsh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/.build"
APP="$BUILD/Snaplane.app"
DEST="/Applications/Snaplane.app"
ICON_SRC="${1:-}"

mkdir -p "$BUILD/icon.iconset" "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "Compiling Snaplane…"
swiftc -swift-version 5 -O \
  -target arm64-apple-macos13.0 \
  -sdk "$(xcrun --show-sdk-path)" \
  -framework AppKit \
  -framework Carbon \
  -framework ApplicationServices \
  -o "$APP/Contents/MacOS/Snaplane" \
  "$ROOT"/Sources/*.swift

cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
echo -n "APPL????" > "$APP/Contents/PkgInfo"

if [[ -n "$ICON_SRC" && -f "$ICON_SRC" ]]; then
  echo "Building icns from $ICON_SRC"
  MASTER="$BUILD/icon-master.png"
  sips -s format png "$ICON_SRC" --out "$MASTER" >/dev/null
  for size in 16 32 64 128 256 512 1024; do
    sips -z $size $size "$MASTER" --out "$BUILD/icon.iconset/icon_${size}x${size}.png" >/dev/null
  done
  sips -z 32 32 "$MASTER" --out "$BUILD/icon.iconset/icon_16x16@2x.png" >/dev/null
  sips -z 64 64 "$MASTER" --out "$BUILD/icon.iconset/icon_32x32@2x.png" >/dev/null
  sips -z 256 256 "$MASTER" --out "$BUILD/icon.iconset/icon_128x128@2x.png" >/dev/null
  sips -z 512 512 "$MASTER" --out "$BUILD/icon.iconset/icon_256x256@2x.png" >/dev/null
  sips -z 1024 1024 "$MASTER" --out "$BUILD/icon.iconset/icon_512x512@2x.png" >/dev/null
  iconutil -c icns "$BUILD/icon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"
  cp "$APP/Contents/Resources/AppIcon.icns" "$ROOT/Resources/AppIcon.icns"
fi

if [[ -f "$ROOT/Resources/AppIcon.icns" ]]; then
  cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi

chmod +x "$ROOT/scripts/ensure-identity.sh"
KEYCHAIN="$("$ROOT/scripts/ensure-identity.sh")"
security unlock-keychain -p "snaplane-local-sign" "$KEYCHAIN"

# codesign only searches default keychains unless we add ours for this command
OLD_KEYCHAINS=("${(@f)$(security list-keychains -d user | sed 's/^ *"//; s/"$//')}")
security list-keychains -d user -s "$KEYCHAIN" "${OLD_KEYCHAINS[@]}"
cleanup_keychains() {
  security list-keychains -d user -s "${OLD_KEYCHAINS[@]}" >/dev/null || true
}
trap cleanup_keychains EXIT

sign_app() {
  codesign --force --sign "Snaplane" --keychain "$KEYCHAIN" \
    --identifier com.astucore.snaplane \
    "$1"
}

sign_app "$APP"

# Replace the installed app without leaving a half-written bundle
if pgrep -x Snaplane >/dev/null; then
  killall Snaplane 2>/dev/null || true
  sleep 0.3
fi
rm -rf "$DEST"
cp -R "$APP" "$DEST"
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true
sign_app "$DEST"

/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST" >/dev/null 2>&1 || true

echo "Installed $DEST"
ls -la "$DEST/Contents/MacOS/Snaplane"
