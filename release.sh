#!/bin/zsh
# Builds, signs, notarizes and packages Rim for download.
#
#   ./release.sh            full release: Developer ID signature → notarize app → staple → DMG → sign →
#                           notarize DMG → staple → Gatekeeper check. Needs DEVELOPER_ID + NOTARY_PROFILE.
#   ./release.sh --dry-run  same pipeline with the local "Rim Dev" identity and no notarization,
#                           to test packaging before you have a Developer ID.
#
# One-time setup: cp signing.env.example signing.env, fill it in, then scripts/setup-signing.sh.
set -euo pipefail
cd "$(dirname "$0")"
[[ -f signing.env ]] && source signing.env
APP_NAME=${APP_NAME:-Rim}
VERSION=${VERSION:-1.0.0}
BUILD=${BUILD:-1}
DRY=0; [[ " $* " == *" --dry-run "* ]] && DRY=1

APP=build/$APP_NAME.app
OUT=build/release
DMG=$OUT/$APP_NAME-$VERSION.dmg
step() { print -P "%F{cyan}==>%f $1"; }

if [[ $DRY == 1 ]]; then
  export DEVELOPER_ID="${DEV_IDENTITY:-Rim Dev}" NO_TIMESTAMP=1
  step "Dry run: signing with '$DEVELOPER_ID', skipping notarization"
else
  [[ -n "${DEVELOPER_ID:-}" ]] || { echo "error: set DEVELOPER_ID in signing.env (see signing.env.example)"; exit 1; }
  [[ -n "${NOTARY_PROFILE:-}" ]] || { echo "error: set NOTARY_PROFILE and run scripts/setup-signing.sh"; exit 1; }
  security find-identity -p codesigning -v | grep -qF "$DEVELOPER_ID" \
    || { echo "error: '$DEVELOPER_ID' is not a valid signing identity in your keychain"; exit 1; }
fi

step "Testing"
scripts/test.sh >/dev/null || { echo "error: tests failed, run scripts/test.sh"; exit 1; }

step "Building $APP_NAME $VERSION ($BUILD), universal, hardened runtime"
./build.sh --release
lipo -archs "$APP/Contents/MacOS/$APP_NAME"
codesign -dv --verbose=2 "$APP" 2>&1 | grep -E "Authority=|TeamIdentifier=|flags=|Timestamp=" || true

mkdir -p "$OUT"
notarize() {   # $1 = file to submit
  [[ $DRY == 1 ]] && { step "(dry run) would notarize $1"; return; }
  step "Notarizing $(basename "$1") (usually 1–5 min)"
  xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" --wait
}

# 1) Notarize and staple the app itself, so it also opens offline once copied out of the DMG.
ditto -c -k --keepParent "$APP" "$OUT/$APP_NAME.zip"
notarize "$OUT/$APP_NAME.zip"
[[ $DRY == 1 ]] || xcrun stapler staple "$APP"
rm -f "$OUT/$APP_NAME.zip"

# 2) Disk image with an Applications shortcut.
step "Packaging $DMG"
rm -rf "$OUT/dmg" "$DMG"
mkdir -p "$OUT/dmg"
cp -R "$APP" "$OUT/dmg/"
ln -s /Applications "$OUT/dmg/Applications"
hdiutil create -volname "$APP_NAME" -srcfolder "$OUT/dmg" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$OUT/dmg"
TS=(--timestamp); [[ $DRY == 1 ]] && TS=()
codesign --force $TS --sign "$DEVELOPER_ID" "$DMG"

# 3) Notarize and staple the DMG.
notarize "$DMG"
[[ $DRY == 1 ]] || xcrun stapler staple "$DMG"

# 4) Verify like a user's Mac would.
step "Verifying"
codesign --verify --deep --strict --verbose=1 "$APP"
if [[ $DRY == 1 ]]; then
  echo "(dry run) Gatekeeper would reject this build: it isn't Developer ID signed or notarized."
else
  spctl --assess --type execute --verbose "$APP"
  spctl --assess --type open --context context:primary-signature --verbose "$DMG"
  xcrun stapler validate "$DMG"
fi

shasum -a 256 "$DMG" | tee "$DMG.sha256"
step "Done → $DMG"
