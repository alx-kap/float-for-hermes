#!/bin/bash
# Install Float for Hermes from the latest GitHub release.
#   curl -fsSL https://alx-kap.github.io/float-for-hermes/install.sh | bash
# Everything is inside main so a half-downloaded script never runs.
set -euo pipefail

main() {
  local ver major tmp app=~/Applications/Float.app
  ver=$(sw_vers -productVersion)
  major=${ver%%.*}
  if [ "$major" -lt 26 ]; then
    echo "Float needs macOS 26 (Tahoe) or later. This Mac is on $ver." >&2
    exit 1
  fi

  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT
  echo "Downloading Float…"
  curl -fsSL -o "$tmp/Float.zip" https://github.com/alx-kap/float-for-hermes/releases/latest/download/Float.zip

  pkill -x Float 2>/dev/null || true
  mkdir -p ~/Applications
  rm -rf "$app"
  ditto -x -k "$tmp/Float.zip" ~/Applications
  # Float is ad-hoc signed, not notarized. Clearing quarantine skips the Gatekeeper prompt.
  xattr -dr com.apple.quarantine "$app" 2>/dev/null || true
  open "$app"

  echo "Float is installed in ~/Applications. Look for it in your menu bar, then press ⌥Space."
}

main "$@"
