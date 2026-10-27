#!/usr/bin/env bash
# Publishes DeskDrop as a GitHub release. Every copy of DeskDrop checks the
# repository's latest release and updates itself from it.
#
# Usage:
#   scripts/publish-release.sh
#
# It builds with scripts/build-release.sh (which signs the in-app update with your
# key), then tags the current commit v<version> and creates the GitHub release with:
#   - DeskDrop-<version>.dmg            for installing DeskDrop the first time
#   - DeskDrop-<version>.deskdropupdate the signed update DeskDrop downloads itself
# and this version's CHANGELOG.md section as the release notes.
#
# Needs: the update key (scripts/update-key.sh create), the GitHub CLI signed in
# (gh auth login), a new version number, and your changes committed and pushed.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPO="$(sed -n 's/^DESKDROP_UPDATE_REPOSITORY *= *//p' "$ROOT/Config/DeskDrop.xcconfig" | tr -d '[:space:]')"
if [[ -z "$REPO" ]]; then
  echo "error: set DESKDROP_UPDATE_REPOSITORY in Config/DeskDrop.xcconfig" >&2
  exit 1
fi
if [[ -n "$(git -C "$ROOT" status --porcelain)" ]]; then
  echo "error: commit your changes first, so the release matches what's on GitHub" >&2
  exit 1
fi
git -C "$ROOT" fetch --quiet origin
if [[ "$(git -C "$ROOT" rev-parse HEAD)" != "$(git -C "$ROOT" rev-parse '@{upstream}' 2>/dev/null || true)" ]]; then
  echo "error: push your commits first (git push)" >&2
  exit 1
fi

"$ROOT/scripts/build-release.sh"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/dist/DeskDrop.app/Contents/Info.plist")"
DMG="$ROOT/dist/DeskDrop-$VERSION.dmg"
UPDATE="$ROOT/dist/DeskDrop-$VERSION.deskdropupdate"
if [[ ! -f "$UPDATE" ]]; then
  echo "error: no signed update was made. Run scripts/update-key.sh create, then try again." >&2
  exit 1
fi
if gh release view "v$VERSION" --repo "$REPO" >/dev/null 2>&1; then
  echo "error: release v$VERSION already exists on $REPO. Raise MARKETING_VERSION first." >&2
  exit 1
fi

NOTES="$(mktemp)"
awk -v v="$VERSION" 'index($0, "## " v " ") == 1 || $0 == "## " v { found = 1; next } /^## / { if (found) exit } found' \
  "$ROOT/CHANGELOG.md" > "$NOTES"
cat >> "$NOTES" <<'TEXT'

---
**Already using DeskDrop?** It updates itself from this release. **New here?** Download the `.dmg`, drag DeskDrop to Applications, and open it (see README › Installing on colleagues' Macs).
TEXT

printf '\n==> Publishing v%s on %s\n' "$VERSION" "$REPO"
gh release create "v$VERSION" "$DMG" "$UPDATE" --repo "$REPO" --title "DeskDrop $VERSION" \
  --notes-file "$NOTES" --target "$(git -C "$ROOT" rev-parse HEAD)"
rm -f "$NOTES"
echo "Done: https://github.com/$REPO/releases/tag/v$VERSION"
