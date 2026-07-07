#!/usr/bin/env bash
# Config loading for the terminal-notifier herdr plugin.
#
# Resolution order (later wins), so the source of truth can live in
# dotfiles (nix/chezmoi) instead of herdr's per-machine config dir:
#   1. built-in default (the literal in this file)
#   2. environment variable                    (exported before notify.sh runs)
#   3. $HERDR_PLUGIN_CONFIG_DIR/config.env      (herdr-managed, per machine; optional)
#   4. $HERDR_TN_CONFIG                          (a dotfiles-managed file you point at)
#
# Each key gets its built-in default only when it is unset OR empty in the
# environment, so an exported env var wins over the default; the two config
# files are sourced AFTER these assignments and therefore still override the
# environment. This is `${VAR:-default}` semantics, applied via the _tn_default
# helper — a literal `${VAR:-…}` mis-parses defaults that hold more than one
# `{…}` placeholder pair (bash brace-matching), which several templates below do.
#
# Caveat of `:-` semantics: an env var exported to the EMPTY string (e.g.
# `export NOTIFIER=`) counts as unset, so the built-in default applies. To force
# "empty means empty" set the key in a config file instead. We keep `:-` (not
# `-`) semantics for uniform, predictable behavior across all keys.
#
# Values below are consumed by bin/notify.sh via indirect expansion (${!var}),
# so shellcheck cannot see the uses.
# shellcheck disable=SC2034

# _tn_default VAR "default": set VAR to the default only when it is unset/empty.
_tn_default() { [ -n "${!1:-}" ] || printf -v "$1" '%s' "$2"; }

# --- built-in defaults -------------------------------------------------------

# Which NEW agent statuses trigger a notification (space separated).
# Valid herdr statuses: working blocked idle done unknown
_tn_default TRIGGER_STATUSES "blocked done"

# Suppress notifications for the workspace you are currently looking at.
# This fires only when BOTH the event's workspace is the focused herdr workspace
# AND a herdr-hosting terminal (TERMINAL_APP_IDS) is the frontmost macOS app — so
# switching away to the browser while an agent runs still lets its blocked/done
# notification through (the workspace stays "focused" inside herdr, but you are
# not looking at the terminal).
_tn_default SUPPRESS_FOCUSED "1"

# Bundle ids (space separated) of terminal apps that can host herdr, used by the
# frontmost check above. If frontmost detection fails (lsappinfo missing/garbage)
# or this is empty, suppression is skipped and the notification is delivered
# (fail open: a duplicate beats a silently missed alert). Find an app's id with:
#   osascript -e 'id of app "Ghostty"'
_tn_default TERMINAL_APP_IDS "com.mitchellh.ghostty com.apple.Terminal com.googlecode.iterm2 net.kovidgoyal.kitty com.github.wez.wezterm org.alacritty"

# Ignore a repeated (pane,status) within this many seconds (flap guard).
_tn_default DEBOUNCE_SECONDS "2"

# Clicking the notification focuses the agent that changed.
_tn_default ACTIVATE_ON_CLICK "1"
# How to focus on click. {pane}/{workspace}/{agent} are substituted.
# `agent focus <pane>` lands on the exact agent; `workspace focus <workspace>`
# is a coarser fallback if your herdr build dislikes pane targets.
# The template's literal words are shell-word-split into command arguments, but
# each substituted VALUE is shell-quoted, so it becomes exactly one literal
# argument and can't inject shell syntax into the click handler. Do NOT quote
# placeholders yourself ("{pane}") — values arrive pre-quoted and would end up
# double-escaped.
_tn_default CLICK_COMMAND "agent focus {pane}"

# Notifier binary. Empty = use the bundled assets/HerdrNotify.app (herdr icon),
# falling back to a system `terminal-notifier`. Set to an absolute path to use
# a different notifier build. (Because of `:-` semantics, exporting NOTIFIER=
# empty counts as unset and keeps this default; point a config file at a path,
# or export NOTIFIER=/abs/path, to override.)
_tn_default NOTIFIER ""

# How often (seconds) to refresh the bundled app's Launch Services registration.
# Ad-hoc-signed helpers can lose their registration over time (reboots, OS
# updates), which makes macOS show the parent terminal's icon instead of the
# herdr logo. notify.sh re-registers when the sentinel is older than this, so
# the icon self-heals within REGISTER_TTL_SECONDS of going stale. Default 6h.
_tn_default REGISTER_TTL_SECONDS "21600"

# contentImage is reliable on modern macOS; appIcon is often ignored. See README.
# This is the RIGHT-side image; the LEFT app icon comes from the notifier app
# (the bundled HerdrNotify.app shows the herdr logo).
_tn_default ICON_MODE "contentImage" # contentImage | appIcon

# Per-status presentation. Placeholders:
#   {agent} {workspace} {worktree} {tab} {pane} {session} {old_status} {new_status} {cwd}
_tn_default TITLE_BLOCKED "⏳ {agent} needs input"
_tn_default BODY_BLOCKED "{workspace} · {worktree}"
_tn_default ICON_BLOCKED "assets/icons/blocked.png"
_tn_default SOUND_BLOCKED "Glass"

_tn_default TITLE_DONE "✅ {agent} done"
_tn_default BODY_DONE "{workspace} · {worktree}"
_tn_default ICON_DONE "assets/icons/done.png"
_tn_default SOUND_DONE "Hero"

_tn_default TITLE_WORKING "🔧 {agent} working"
_tn_default BODY_WORKING "{workspace} · {worktree}"
_tn_default ICON_WORKING "assets/icons/working.png"
_tn_default SOUND_WORKING "none"

# Fallback for any other status not given an explicit template above.
_tn_default TITLE_DEFAULT "{agent}: {new_status}"
_tn_default BODY_DEFAULT "{workspace} · {worktree}"
_tn_default ICON_DEFAULT "assets/icons/working.png"
_tn_default SOUND_DEFAULT "none"

# Set DEBUG=1 to dump the raw event/context JSON to the state dir.
_tn_default DEBUG "0"

# --- overrides ---------------------------------------------------------------

_tn_load() {
  local f="$1"
  [ -n "$f" ] && [ -f "$f" ] || return 0
  # shellcheck disable=SC1090
  . "$f"
}

_tn_load "${HERDR_PLUGIN_CONFIG_DIR:-}/config.env"
_tn_load "${HERDR_TN_CONFIG:-}"
