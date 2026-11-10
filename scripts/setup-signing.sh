#!/bin/zsh
# One-time signing setup for releases. Run it yourself (it asks for an app-specific password):
#   ! scripts/setup-signing.sh
set -euo pipefail
cd "$(dirname "$0")/.."
[[ -f signing.env ]] || { cp signing.env.example signing.env; echo "created signing.env, fill in DEVELOPER_ID and TEAM_ID, then rerun"; exit 1; }
source signing.env

echo "Code-signing identities in your keychain:"
security find-identity -p codesigning -v | sed 's/^/  /'
if [[ -z "${DEVELOPER_ID:-}" ]] || ! security find-identity -p codesigning -v | grep -qF "$DEVELOPER_ID"; then
  cat <<'MSG'

No valid "Developer ID Application" identity configured.
  1. Join the Apple Developer Program (paid) at developer.apple.com.
  2. Xcode → Settings → Accounts → (your team) → Manage Certificates → + → Developer ID Application.
  3. Copy its exact name from the list above into DEVELOPER_ID in signing.env, and your team ID into TEAM_ID.
MSG
  exit 1
fi

echo
echo "Storing notarization credentials as keychain profile '$NOTARY_PROFILE'."
echo "Use an app-specific password from appleid.apple.com → Sign-In and Security → App-Specific Passwords."
read "APPLE_ID?Apple ID email: "
xcrun notarytool store-credentials "$NOTARY_PROFILE" --apple-id "$APPLE_ID" --team-id "$TEAM_ID"
echo "Done. ./release.sh will now sign, notarize and staple."
