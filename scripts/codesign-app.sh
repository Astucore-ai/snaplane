#!/bin/zsh
# Sign $1 (a .app). Prefers Developer ID Application (stable TCC + notarization).
# Falls back to the gitignored local identity so `./scripts/build.sh` still works
# on a machine with no paid Apple Developer membership.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:?app path}"
IDENTIFIER="com.astucore.snaplane"
ENTITLEMENTS="$ROOT/Resources/App.entitlements"
NOTARY_PROFILE="${NOTARY_PROFILE:-astucore}"
NOTARIZE="${NOTARIZE:-0}"
LOCAL_CN="Snaplane"
LOCAL_PASS="snaplane-local-sign"

pick_developer_id() {
  security find-identity -v -p codesigning 2>/dev/null \
    | sed -n 's/.*"\(Developer ID Application: .*\)"/\1/p' \
    | head -1
}

sign_with() {
  local name="$1" keychain="${2:-}"
  local args=(
    --force --sign "$name"
    --identifier "$IDENTIFIER"
    --entitlements "$ENTITLEMENTS"
  )
  if [[ -n "$keychain" ]]; then
    args+=(--keychain "$keychain")
  else
    args+=(--options runtime --timestamp)
  fi
  codesign "${args[@]}" "$APP"
  echo "signed $APP as $name"
}

DEV_ID="$(pick_developer_id)"
if [[ -n "$DEV_ID" ]]; then
  sign_with "$DEV_ID"
  if [[ "$NOTARIZE" == "1" ]]; then
    if xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
      ZIP="${TMPDIR:-/tmp}/$(basename "$APP" .app)-notarize.zip"
      rm -f "$ZIP"
      ditto -c -k --keepParent "$APP" "$ZIP"
      echo "submitting $(basename "$APP") to Apple notary…"
      xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
      xcrun stapler staple "$APP"
      rm -f "$ZIP"
      echo "notarized and stapled $APP"
    else
      echo "Developer ID used, but notarytool profile '$NOTARY_PROFILE' is missing." >&2
      echo "Store it with: xcrun notarytool store-credentials $NOTARY_PROFILE --apple-id <id> --team-id <team> --password <app-specific-password>" >&2
    fi
  fi
  exit 0
fi

chmod +x "$ROOT/scripts/ensure-identity.sh"
KEYCHAIN="$("$ROOT/scripts/ensure-identity.sh")"
security unlock-keychain -p "$LOCAL_PASS" "$KEYCHAIN"
OLD_KEYCHAINS=("${(@f)$(security list-keychains -d user | sed 's/^ *"//; s/"$//')}")
security list-keychains -d user -s "$KEYCHAIN" "${OLD_KEYCHAINS[@]}"
cleanup_keychains() {
  security list-keychains -d user -s "${OLD_KEYCHAINS[@]}" >/dev/null || true
}
trap cleanup_keychains EXIT
sign_with "$LOCAL_CN" "$KEYCHAIN"
echo "signed with local identity (not notarized; Gatekeeper will warn on other Macs)"
