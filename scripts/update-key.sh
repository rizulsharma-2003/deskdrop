#!/usr/bin/env bash
# The key that signs DeskDrop updates. Every copy of DeskDrop built after
# `create` trusts updates signed with it, and only those.
#
#   scripts/update-key.sh create   Make the key (once). Stores the private key in your
#                                  login keychain and writes Config/UpdateKey.xcconfig
#                                  (the public key, safe to share and commit).
#   scripts/update-key.sh show     Print the public key.
#   scripts/update-key.sh export   Print the private key, to back it up somewhere safe
#                                  (a password manager). Lose it and installed copies
#                                  can't be updated in-app any more.
#   scripts/update-key.sh import   Read a backed-up private key from stdin (e.g. on a
#                                  new Mac) and store it in the keychain.
#   scripts/update-key.sh sync     Rewrite Config/UpdateKey.xcconfig from the keychain
#                                  (the release script does this).

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SERVICE="DeskDrop update signing key"
ACCOUNT="deskdrop"
XCCONFIG="$ROOT/Config/UpdateKey.xcconfig"
TOOL="$ROOT/build/tools/update-tool"

build_tool() {
  mkdir -p "$(dirname "$TOOL")"
  if [[ ! -x "$TOOL" || "$ROOT/scripts/update-tool.swift" -nt "$TOOL" || "$ROOT/Shared/UpdatePackage.swift" -nt "$TOOL" ]]; then
    xcrun swiftc -O -parse-as-library "$ROOT/scripts/update-tool.swift" "$ROOT/Shared/UpdatePackage.swift" \
      "$ROOT/Shared/UpdaterXPC.swift" -o "$TOOL"
  fi
}

private_key() {
  security find-generic-password -a "$ACCOUNT" -s "$SERVICE" -w 2>/dev/null
}

store_key() {
  # Through `security -i` on stdin, so the key never appears on a command line.
  printf 'add-generic-password -U -a %s -s "%s" -T /usr/bin/security -w %s\n' "$ACCOUNT" "$SERVICE" "$1" | security -i >/dev/null
}

write_xcconfig() {
  local public
  public="$(private_key | "$TOOL" public-key)"
  cat > "$XCCONFIG" <<CONFIG
// The public half of the DeskDrop update-signing key. Written by scripts/update-key.sh.
// Copies of DeskDrop built with it install only updates signed with the matching private key.
DESKDROP_UPDATE_PUBLIC_KEY = $public
CONFIG
  echo "$public"
}

build_tool
case "${1:-}" in
  create)
    if private_key >/dev/null; then
      echo "A DeskDrop update key already exists in your keychain. Public key:"
      write_xcconfig
      exit 0
    fi
    store_key "$("$TOOL" keygen)"
    echo "Created the DeskDrop update key and stored it in your login keychain."
    echo "Public key (also in Config/UpdateKey.xcconfig):"
    write_xcconfig
    echo
    echo "Back up the private key now: scripts/update-key.sh export"
    ;;
  show)
    private_key | "$TOOL" public-key
    ;;
  sync)
    private_key >/dev/null || { echo "No DeskDrop update key in your keychain." >&2; exit 1; }
    write_xcconfig >/dev/null
    ;;
  export)
    private_key || { echo "No DeskDrop update key in your keychain." >&2; exit 1; }
    ;;
  import)
    key="$(cat | tr -d '[:space:]')"
    printf '%s' "$key" | "$TOOL" public-key >/dev/null
    store_key "$key"
    write_xcconfig
    ;;
  *)
    sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'
    exit 1
    ;;
esac
