#!/usr/bin/env bash
# Config loading for the terminal-notifier herdr plugin.
#
# Resolution order (later wins), so the source of truth can live in
# dotfiles (nix/chezmoi) instead of herdr's per-machine config dir:
#   1. built-in defaults (this file)
#   2. $HERDR_PLUGIN_CONFIG_DIR/config.env   (herdr-managed, per machine; optional)
#   3. $HERDR_TN_CONFIG                       (a dotfiles-managed file you point at)
#
# Values below are consumed by bin/notify.sh via indirect expansion (${!var}),
# so shellcheck cannot see the uses.
# shellcheck disable=SC2034

# --- built-in defaults -------------------------------------------------------

# Which NEW agent statuses trigger a notification (space separated).
# Valid herdr statuses: working blocked idle done unknown
TRIGGER_STATUSES="blocked done"

# Suppress notifications for the workspace you are currently looking at.
SUPPRESS_FOCUSED=1

# Ignore a repeated (pane,status) within this many seconds (flap guard).
DEBOUNCE_SECONDS=2

# Clicking the notification focuses the agent that changed.
ACTIVATE_ON_CLICK=1
# How to focus on click. {pane}/{workspace}/{agent} are substituted.
# `agent focus <pane>` lands on the exact agent; `workspace focus <workspace>`
# is a coarser fallback if your herdr build dislikes pane targets.
CLICK_COMMAND="agent focus {pane}"

# contentImage is reliable on modern macOS; appIcon is often ignored. See README.
ICON_MODE="contentImage" # contentImage | appIcon

# Per-status presentation. Placeholders:
#   {agent} {workspace} {worktree} {tab} {pane} {session} {old_status} {new_status} {cwd}
TITLE_BLOCKED="⏳ {agent} が入力待ち"
BODY_BLOCKED="{workspace} · {worktree}"
ICON_BLOCKED="assets/icons/blocked.png"
SOUND_BLOCKED="Glass"

TITLE_DONE="✅ {agent} 完了"
BODY_DONE="{workspace} · {worktree}"
ICON_DONE="assets/icons/done.png"
SOUND_DONE="Hero"

TITLE_WORKING="🔧 {agent} 作業中"
BODY_WORKING="{workspace} · {worktree}"
ICON_WORKING="assets/icons/working.png"
SOUND_WORKING="none"

# Fallback for any other status not given an explicit template above.
TITLE_DEFAULT="{agent}: {new_status}"
BODY_DEFAULT="{workspace} · {worktree}"
ICON_DEFAULT="assets/icons/working.png"
SOUND_DEFAULT="none"

# Set DEBUG=1 to dump the raw event/context JSON to the state dir.
DEBUG="${DEBUG:-0}"

# --- overrides ---------------------------------------------------------------

_tn_load() {
  local f="$1"
  [ -n "$f" ] && [ -f "$f" ] || return 0
  # shellcheck disable=SC1090
  . "$f"
}

_tn_load "${HERDR_PLUGIN_CONFIG_DIR:-}/config.env"
_tn_load "${HERDR_TN_CONFIG:-}"
