#!/usr/bin/env bash
# Idempotent install/link for the dot.terminal-notifier herdr plugin.
#
# Designed to be called from a declarative apply step, e.g.
#   - chezmoi:     run_onchange_install-herdr-tn.sh
#   - nix-darwin:  a system.activationScripts entry
# Re-running is a no-op once the plugin is registered.
#
# Usage:
#   scripts/install.sh                 # install from GitHub (dot/herdr-terminal-notifier)
#   scripts/install.sh --link [PATH]   # link a local checkout (default: this repo)
set -euo pipefail

PLUGIN_ID="dot.terminal-notifier"
GITHUB_SLUG="dot/herdr-terminal-notifier"
HERDR="${HERDR_BIN_PATH:-herdr}"

if ! command -v "$HERDR" >/dev/null 2>&1; then
  echo "herdr not found on PATH; skipping plugin install" >&2
  exit 0
fi

if "$HERDR" plugin list 2>/dev/null | grep -q "$PLUGIN_ID"; then
  echo "$PLUGIN_ID already installed; nothing to do"
  exit 0
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

mode="${1:---install}"
case "$mode" in
  --link)
    path="${2:-$ROOT}"
    echo "linking $PLUGIN_ID from $path"
    "$HERDR" plugin link "$path"
    # link skips [[build]], so register the bundled notifier ourselves
    bash "$ROOT/scripts/setup-notifier.sh" || true
    ;;
  --install|*)
    echo "installing $PLUGIN_ID from $GITHUB_SLUG"
    "$HERDR" plugin install "$GITHUB_SLUG"
    ;;
esac

# jq is the only runtime dep (terminal-notifier is bundled as HerdrNotify.app).
command -v jq >/dev/null 2>&1 || echo "warning: 'jq' missing — add it to your Brewfile/homebrew.nix" >&2
