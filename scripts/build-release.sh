#!/usr/bin/env bash
# Builds a universal (Apple silicon + Intel) Release DeskDrop.app and packages it
# as a ZIP that colleagues can install without Xcode.
#
# Usage:
#   scripts/build-release.sh
#
# Optional environment:
#   DESKDROP_SIGN_IDENTITY   Code-signing identity, e.g.
#                            "Developer ID Application: Your Name (TEAMID)".
#                            Default "-" (ad-hoc: runs on this Mac; other Macs need
#                            the Gatekeeper override described in README.md).
#   DESKDROP_NOTARY_PROFILE  A `xcrun notarytool store-credentials` profile name.
#                            With a Developer ID identity, the ZIP is notarized and
#                            the ticket stapled so it opens normally everywhere.
#
# In-app updates: if your login keychain holds the update-signing key (made once
# with `scripts/update-key.sh create`), the build trusts that key and the script
# also writes dist/DeskDrop-<version>.deskdropupdate, signed with it. Publish that
# file from DeskDrop › Settings › About › Publish Update… to push it to colleagues.
#   GIPHY_API_KEY            A GIPHY API key to build in, so GIF and sticker search
#                            works without each person pasting a key in Settings.
#
# Output: dist/DeskDrop.app, dist/DeskDrop-<version>.zip and dist/DeskDrop-<version>.dmg

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DERIVED="$ROOT/build/release/DerivedData"
DIST="$ROOT/dist"
IDENTITY="${DESKDROP_SIGN_IDENTITY:--}"
NOTARY_PROFILE="${DESKDROP_NOTARY_PROFILE:-}"
ENTITLEMENTS="$ROOT/DeskDrop/DeskDrop.entitlements"

step() { printf '\n==> %s\n' "$*"; }

step "Checking the update-signing key"
UPDATE_KEY="$(security find-generic-password -a deskdrop -s "DeskDrop update signing key" -w 2>/dev/null || true)"
UPDATE_TOOL="$ROOT/build/tools/update-tool"
if [[ -n "$UPDATE_KEY" ]]; then
  "$ROOT/scripts/update-key.sh" sync
  echo "This build trusts updates signed with your key ($(printf '%s' "$UPDATE_KEY" | "$UPDATE_TOOL" public-key | cut -c1-16)…)."
else
  echo "No update-signing key in your keychain, so this build can't install in-app updates."
  echo "Run scripts/update-key.sh create once, then build again."
fi

step "Building Release (arm64 + x86_64)"
xcodebuild \
  -project "$ROOT/DeskDrop.xcodeproj" \
  -scheme DeskDrop \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -derivedDataPath "$DERIVED" \
  ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
  GIPHY_API_KEY="${GIPHY_API_KEY:-}" \
  build | grep -E "error:|warning:|BUILD (SUCCEEDED|FAILED)" || true

BUILT_APP="$DERIVED/Build/Products/Release/DeskDrop.app"
if [[ ! -d "$BUILT_APP" ]]; then
  echo "error: build did not produce $BUILT_APP" >&2
  exit 1
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$BUILT_APP/Contents/Info.plist")"
BUILD_NUMBER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$BUILT_APP/Contents/Info.plist")"

step "Copying DeskDrop $VERSION ($BUILD_NUMBER) to dist/"
rm -rf "$DIST"
mkdir -p "$DIST"
ditto "$BUILT_APP" "$DIST/DeskDrop.app"
APP="$DIST/DeskDrop.app"

step "Signing with identity: $IDENTITY"
# The installer helper first (nested code is signed inside out). It runs outside
# the sandbox, so it has no entitlements.
HELPER_ARGS=(--force --options runtime --sign "$IDENTITY")
SIGN_ARGS=(--force --options runtime --entitlements "$ENTITLEMENTS" --sign "$IDENTITY")
if [[ "$IDENTITY" != "-" ]]; then
  HELPER_ARGS+=(--timestamp)
  SIGN_ARGS+=(--timestamp)
fi
codesign "${HELPER_ARGS[@]}" "$APP/Contents/XPCServices/DeskDropUpdater.xpc"
codesign "${SIGN_ARGS[@]}" "$APP"
codesign --verify --strict --verbose=2 "$APP"
if codesign -d --entitlements - "$APP" 2>/dev/null | grep -q "get-task-allow"; then
  echo "error: the distribution build still carries the get-task-allow debugging entitlement" >&2
  exit 1
fi

ZIP="$DIST/DeskDrop-$VERSION.zip"
step "Packaging $ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

if [[ -n "$NOTARY_PROFILE" ]]; then
  if [[ "$IDENTITY" == "-" ]]; then
    echo "error: notarization needs a Developer ID Application identity (set DESKDROP_SIGN_IDENTITY)" >&2
    exit 1
  fi
  step "Notarizing (this can take a few minutes)"
  xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP"
  rm -f "$ZIP"
  ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
fi

UPDATE="$DIST/DeskDrop-$VERSION.deskdropupdate"
if [[ -n "$UPDATE_KEY" ]]; then
  step "Signing the in-app update $UPDATE"
  NOTES="$(mktemp)"
  # What's new: this version's section of CHANGELOG.md.
  awk -v v="$VERSION" 'index($0, "## " v " ") == 1 || $0 == "## " v { found = 1; next } /^## / { if (found) exit } found' \
    "$ROOT/CHANGELOG.md" > "$NOTES"
  printf '%s' "$UPDATE_KEY" | "$UPDATE_TOOL" package --app "$APP" --out "$UPDATE" --notes "$NOTES"
  rm -f "$NOTES"
fi

DMG="$DIST/DeskDrop-$VERSION.dmg"
step "Creating $DMG"
DMG_STAGE="$ROOT/build/release/dmg-stage"
rm -rf "$DMG_STAGE"
mkdir -p "$DMG_STAGE"
ditto "$APP" "$DMG_STAGE/DeskDrop.app"
ln -s /Applications "$DMG_STAGE/Applications"
cp "$ROOT/scripts/dmg/Install DeskDrop.txt" "$DMG_STAGE/"
hdiutil create -volname "DeskDrop" -srcfolder "$DMG_STAGE" -fs HFS+ \
  -format UDZO -imagekey zlib-level=9 -ov "$DMG" >/dev/null
rm -rf "$DMG_STAGE"
if [[ "$IDENTITY" != "-" ]]; then
  codesign --force --timestamp --sign "$IDENTITY" "$DMG"
fi
if [[ -n "$NOTARY_PROFILE" ]]; then
  step "Notarizing the disk image"
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
fi
hdiutil verify "$DMG" >/dev/null

step "Gatekeeper assessment"
if spctl --assess --type execute --verbose=2 "$APP" 2>&1; then
  echo "Gatekeeper accepts this build."
else
  echo "Gatekeeper rejects this build on other Macs (expected unless it is Developer ID signed and notarized)."
  echo "See README.md › Installing on colleagues' Macs."
fi

step "Done"
echo "App: $APP"
echo "ZIP: $ZIP ($(du -h "$ZIP" | cut -f1))"
echo "DMG: $DMG ($(du -h "$DMG" | cut -f1))"
if [[ -f "$UPDATE" ]]; then
  echo "Update: $UPDATE ($(du -h "$UPDATE" | cut -f1)) — publish it from DeskDrop › Settings › About › Publish Update…"
fi
