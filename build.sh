#!/bin/zsh
# Builds Rim.app into ./build.
#   ./build.sh                 local build, signed with DEV_IDENTITY (or ad-hoc)
#   ./build.sh --install       … and copy to /Applications
#   ./build.sh --run           … and launch it
#   ./build.sh --release       universal binary, hardened runtime, signed with DEVELOPER_ID (used by release.sh)
# Settings come from signing.env (see signing.env.example); environment variables override them.
set -euo pipefail
cd "$(dirname "$0")"

# Load signing.env, but never override a variable already set in the environment.
if [[ -f signing.env ]]; then
  while IFS='=' read -r k v; do
    [[ -n "${(P)k-}" ]] && continue
    eval "$k=$v"
  done < <(grep -E '^[A-Z_]+=' signing.env)
fi

APP_NAME=${APP_NAME:-Rim}
BUNDLE_ID=${BUNDLE_ID:-com.getrim.Rim}
VERSION=${VERSION:-1.0.0}
BUILD=${BUILD:-1}
DEV_IDENTITY=${DEV_IDENTITY:-Rim Dev}
RELEASE=0; [[ " $* " == *" --release "* ]] && RELEASE=1
APP=build/$APP_NAME.app

# ---- Compile ----
if [[ $RELEASE == 1 && "${ARCHS:-universal}" == universal ]]; then
  swift build -c release --arch arm64 --arch x86_64
  BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/Rim"
else
  swift build -c release
  BIN="$(swift build -c release --show-bin-path)/Rim"
fi

# ---- Bundle ----
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"
[[ -f Resources/AppIcon.icns && -f Resources/MenuIcon.pdf ]] || scripts/make-icon.sh
cp Resources/AppIcon.icns Resources/MenuIcon.pdf "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleExecutable</key><string>$APP_NAME</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>© $(date +%Y) $APP_NAME</string>
  <key>CFBundleURLTypes</key>
  <array><dict>
    <key>CFBundleURLName</key><string>$BUNDLE_ID</string>
    <key>CFBundleURLSchemes</key><array><string>rim</string></array>
  </dict></array>
</dict>
</plist>
PLIST
plutil -lint -s "$APP/Contents/Info.plist"

# ---- Sign ----
if [[ $RELEASE == 1 ]]; then
  [[ -n "${DEVELOPER_ID:-}" ]] || { echo "error: DEVELOPER_ID is empty (set it in signing.env)"; exit 1; }
  # Hardened runtime + secure timestamp: both required for notarization.
  TS=(--timestamp); [[ -n "${NO_TIMESTAMP:-}" ]] && TS=()
  codesign --force --options runtime $TS --entitlements Rim.entitlements --sign "$DEVELOPER_ID" "$APP"
elif security find-certificate -c "$DEV_IDENTITY" >/dev/null 2>&1; then
  # Same flags as release (minus the timestamp) so hardened-runtime problems show up in daily builds.
  codesign --force --options runtime --entitlements Rim.entitlements --sign "$DEV_IDENTITY" "$APP"
else
  echo "note: '$DEV_IDENTITY' not found (run ./make-cert.sh); ad-hoc signing, Accessibility must be re-granted after each build"
  codesign --force --options runtime --entitlements Rim.entitlements --sign - "$APP"
fi
codesign --verify --strict "$APP"

# ---- Install / run ----
if [[ " $* " == *" --install "* ]]; then
  pkill -x "$APP_NAME" 2>/dev/null || true
  rm -rf "/Applications/$APP_NAME.app"
  cp -R "$APP" /Applications/
  APP="/Applications/$APP_NAME.app"
  echo "installed to $APP"
fi
if [[ " $* " == *" --run "* ]]; then
  pkill -x "$APP_NAME" 2>/dev/null || true
  open "$APP"
fi
