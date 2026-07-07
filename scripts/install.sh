#!/usr/bin/env bash
# Idempotent install/link for the dot.terminal-notifier herdr plugin.
#
# Designed to be called from a declarative apply step, e.g.
#   - chezmoi:     run_onchange_install-herdr-tn.sh
#   - nix-darwin:  a system.activationScripts entry
# Re-running is a no-op once the plugin is registered. To apply a version bump
# from a declarative hook, key a run_onchange on the plugin version and call
# `install.sh --force`: it skips the already-registered short-circuit and re-runs
# `herdr plugin install`, which herdr treats as an update.
#
# Usage:
#   scripts/install.sh                 # install from GitHub (dot/herdr-terminal-notifier)
#   scripts/install.sh --force         # reinstall/update even if already registered
#   scripts/install.sh --link [PATH]   # link a local checkout (default: this repo)
set -euo pipefail

PLUGIN_ID="dot.terminal-notifier"
GITHUB_SLUG="dot/herdr-terminal-notifier"
HERDR="${HERDR_BIN_PATH:-herdr}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

mode="--install"
force=0
link_path="$ROOT"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --force)   force=1 ;;
    --install) mode="--install" ;;
    --link)
      mode="--link"
      # Optional non-flag PATH argument (default: this repo).
      if [ "$#" -gt 1 ] && [ "${2#-}" = "$2" ]; then
        link_path="$2"
        shift
      fi
      ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

if ! command -v "$HERDR" >/dev/null 2>&1; then
  echo "herdr not found on PATH; skipping plugin install" >&2
  exit 0
fi

# `herdr plugin list` prints one line per plugin: "- <id> (<desc>) <state> [...]".
# Match the id field exactly with a fixed string (leading "- ", trailing space);
# grep -F avoids the '.' in the id being treated as a regex wildcard. --force
# skips this short-circuit so a declarative bump can reinstall/update.
if [ "$force" -eq 0 ] && "$HERDR" plugin list 2>/dev/null | grep -qF -- "- $PLUGIN_ID "; then
  echo "$PLUGIN_ID already installed; nothing to do (pass --force to reinstall/update)"
  exit 0
fi

case "$mode" in
  --link)
    # Normalize to an absolute path so the link and the setup call below both
    # refer to the linked checkout (herdr plugin link takes the path as-is).
    path="$(cd "$link_path" && pwd)"
    echo "linking $PLUGIN_ID from $path"
    "$HERDR" plugin link "$path"
    # link skips [[build]], so register the linked checkout's notifier ourselves
    bash "$path/scripts/setup-notifier.sh" || true
    ;;
  --install)
    echo "installing $PLUGIN_ID from $GITHUB_SLUG"
    # --yes: required when stdin is non-interactive (CI / chezmoi / activation)
    "$HERDR" plugin install "$GITHUB_SLUG" --yes
    ;;
esac

# jq is the only runtime dep (terminal-notifier is bundled as HerdrNotify.app).
command -v jq >/dev/null 2>&1 || echo "warning: 'jq' missing — add it to your Brewfile/homebrew.nix" >&2
