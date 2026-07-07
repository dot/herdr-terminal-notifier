#!/usr/bin/env bash
# herdr event handler: turn a pane.agent_status_changed event into a
# customizable macOS notification via terminal-notifier.
#
# herdr runs this with the plugin directory as cwd and injects:
#   HERDR_PLUGIN_EVENT, HERDR_PLUGIN_EVENT_JSON, HERDR_PLUGIN_CONTEXT_JSON,
#   HERDR_BIN_PATH, HERDR_PLUGIN_CONFIG_DIR, HERDR_PLUGIN_STATE_DIR, ...
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/config.sh
. "$ROOT/lib/config.sh"
# shellcheck source=lib/herdr.sh
. "$ROOT/lib/herdr.sh"

STATE_DIR="${HERDR_PLUGIN_STATE_DIR:-${TMPDIR:-/tmp}/herdr-tn}"
mkdir -p "$STATE_DIR"

log() { printf '[terminal-notifier] %s\n' "$*" >&2; }

# --- 0. resolve the notifier binary -----------------------------------------
# Prefer the bundled HerdrNotify.app (custom herdr icon + own bundle id), then
# an explicit override, then a system terminal-notifier. The bundled app is
# what makes the notification's LEFT icon the herdr logo instead of a terminal.
BUNDLED_APP="$ROOT/assets/HerdrNotify.app"
BUNDLED_BIN="$BUNDLED_APP/Contents/MacOS/terminal-notifier"
if [ -n "${NOTIFIER:-}" ] && [ -x "$NOTIFIER" ]; then
  NOTIFIER_BIN="$NOTIFIER"
elif [ -x "$BUNDLED_BIN" ]; then
  NOTIFIER_BIN="$BUNDLED_BIN"
  # Keep the bundle registered with Launch Services so macOS attributes the
  # notification (and its LEFT icon) to HerdrNotify.app instead of falling back
  # to the parent terminal's icon (ghostty, Terminal, ...).
  #
  # An ad-hoc-signed, non-notarized helper can silently lose its LS registration
  # over time (reboots, OS updates). When that happens the icon reverts to the
  # terminal's. A plain "register once per app revision" sentinel never recovers
  # from that — once stale, it stays stale — so we self-heal on a TTL:
  #   * no sentinel / bundle newer than sentinel -> new build: verify the
  #     signature and re-sign (ad-hoc) ONLY if it is invalid, then register
  #   * sentinel older than REGISTER_TTL_SECONDS  -> register only (cheap refresh)
  # Re-signing is verify-gated because an ad-hoc signature gets a fresh CDHash
  # each time, which changes the identity macOS keys the notification (TCC) grant
  # to — a needless re-sign can drop the grant. lsregister-only on the periodic
  # path likewise avoids re-signing.
  # Termination: the sentinel is refreshed (: >sentinel) at the end of the branch
  # regardless of whether we signed, so its mtime lands newer than the bundle's;
  # the next event therefore takes the cheap TTL path, never re-entering the
  # "bundle newer" branch on every event.
  sentinel="$STATE_DIR/.notifier-registered"
  lsregister="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
  register_ttl="${REGISTER_TTL_SECONDS:-21600}" # 6h; bounds how long a stale reg can linger
  needs_register=0 needs_codesign=0
  if [ ! -f "$sentinel" ] || [ "$BUNDLED_BIN" -nt "$sentinel" ]; then
    needs_register=1 needs_codesign=1
  else
    sentinel_age=$(( $(date +%s) - $(stat -f %m "$sentinel" 2>/dev/null || echo 0) ))
    [ "$sentinel_age" -ge "$register_ttl" ] && needs_register=1
  fi
  if [ "$needs_register" = 1 ]; then
    if [ "$needs_codesign" = 1 ] && ! codesign --verify --deep "$BUNDLED_APP" >/dev/null 2>&1; then
      codesign --force --deep -s - "$BUNDLED_APP" >/dev/null 2>&1 || true
      log "re-signed HerdrNotify.app (ad-hoc); if desktop notifications stop, re-approve HerdrNotify in System Settings -> Notifications"
    fi
    "$lsregister" -f "$BUNDLED_APP" >/dev/null 2>&1 || true
    : >"$sentinel"
  fi
elif command -v terminal-notifier >/dev/null 2>&1; then
  NOTIFIER_BIN="terminal-notifier"
else
  log "no notifier found (bundled HerdrNotify.app missing and no terminal-notifier on PATH)"
  exit 0
fi

EVENT_JSON="${HERDR_PLUGIN_EVENT_JSON:-}"; [ -n "$EVENT_JSON" ] || EVENT_JSON='{}'
CONTEXT_JSON="${HERDR_PLUGIN_CONTEXT_JSON:-}"; [ -n "$CONTEXT_JSON" ] || CONTEXT_JSON='{}'

# --- 1. optional debug dump (used to confirm field names on a new build) -----
if [ "${DEBUG:-0}" = "1" ]; then
  {
    printf 'event=%s\n' "${HERDR_PLUGIN_EVENT:-}"
    printf 'EVENT_JSON=%s\n' "$EVENT_JSON"
    printf 'CONTEXT_JSON=%s\n' "$CONTEXT_JSON"
  } >"$STATE_DIR/last-event.json"
  log "debug dump written to $STATE_DIR/last-event.json"
fi

# --- 2. pull the essentials (event payload lives under .data; context is flat)
# Event shape:  {"event":...,"data":{"pane_id","workspace_id","agent_status","agent"}}
# Both the event and the (richer) context are tried before falling back to a
# live `herdr pane get`, with `// empty` chains so a missing key is just blank.
ev()  { printf '%s' "$EVENT_JSON"   | jq -r "$1 // empty" 2>/dev/null || true; }
ctx() { printf '%s' "$CONTEXT_JSON" | jq -r "$1 // empty" 2>/dev/null || true; }

pane_id="$(ev '.data.pane_id')";          [ -n "$pane_id" ]      || pane_id="$(ctx '.focused_pane_id')"
new_status="$(ev '.data.agent_status')";  [ -n "$new_status" ]   || new_status="$(ctx '.focused_pane_status')"
agent="$(ev '.data.agent')";              [ -n "$agent" ]        || agent="$(ctx '.focused_pane_agent')"
workspace_id="$(ev '.data.workspace_id')";[ -n "$workspace_id" ] || workspace_id="$(ctx '.workspace_id')"
workspace="$(ctx '.workspace_label')"
tab_id="$(ctx '.tab_id')"
cwd="$(ctx '.workspace_cwd')";            [ -n "$cwd" ]          || cwd="$(ctx '.focused_pane_cwd')"

# --- 3. enrich from live herdr state for anything still missing --------------
# session id is only available live; the rest are fallbacks if context was thin.
session="$(pane_field "$pane_id" '.agent_session.value')"
[ -n "$new_status" ]   || new_status="$(pane_field "$pane_id" '.agent_status')"
[ -n "$agent" ]        || agent="$(pane_field "$pane_id" '.agent')"
[ -n "$workspace_id" ] || workspace_id="$(pane_field "$pane_id" '.workspace_id')"
[ -n "$tab_id" ]       || tab_id="$(pane_field "$pane_id" '.tab_id')"
[ -n "$cwd" ]          || cwd="$(pane_field "$pane_id" '.cwd')"
[ -n "$workspace" ]    || workspace="$(workspace_label "$workspace_id")"

[ -n "$workspace" ] || workspace="$workspace_id"
[ -n "$agent" ]     || agent="agent"
worktree="$([ -n "$cwd" ] && basename "$cwd" || printf '%s' "$workspace")"

if [ -z "$new_status" ]; then
  log "no status in event; nothing to do"
  exit 0
fi

# Per-pane previous status: the event carries only the new status, so we track
# the last-seen value ourselves to give {old_status} meaning. Updated on every
# event (before the trigger filter) so transitions are recorded faithfully.
old_status=""
if [ -n "$pane_id" ]; then
  pane_key="$(printf '%s' "$pane_id" | tr -c 'A-Za-z0-9._-' '_')"
  laststatus_file="$STATE_DIR/laststatus-$pane_key"
  [ -f "$laststatus_file" ] && old_status="$(cat "$laststatus_file" 2>/dev/null || true)"
  printf '%s' "$new_status" >"$laststatus_file"
fi

# --- 4. should this transition notify? ---------------------------------------
case " $TRIGGER_STATUSES " in
  *" $new_status "*) : ;;
  *) exit 0 ;;
esac

# --- 5. suppress the workspace you are currently looking at ------------------
if [ "${SUPPRESS_FOCUSED:-0}" = "1" ] && [ -n "$workspace_id" ]; then
  if [ "$(focused_workspace_id)" = "$workspace_id" ]; then
    exit 0
  fi
fi

# --- 6. debounce repeated (pane,status) within DEBOUNCE_SECONDS --------------
if [ -n "$pane_id" ]; then
  stamp_file="$STATE_DIR/debounce-$pane_key"
  now="$(date +%s)"
  if [ -f "$stamp_file" ]; then
    read -r last_ts last_status <"$stamp_file" || true
    if [ "$last_status" = "$new_status" ] && [ $((now - ${last_ts:-0})) -lt "${DEBOUNCE_SECONDS:-0}" ]; then
      exit 0
    fi
  fi
  printf '%s %s\n' "$now" "$new_status" >"$stamp_file"
fi

# --- 7. pick the per-status template and expand placeholders -----------------
status_uc="$(printf '%s' "$new_status" | tr '[:lower:]' '[:upper:]')"
pick() { # pick VAR_PREFIX -> value of ${PREFIX_STATUS} or ${PREFIX_DEFAULT}
  local var="${1}_${status_uc}" def="${1}_DEFAULT"
  printf '%s' "${!var:-${!def:-}}"
}

expand() {
  local s="$1"
  s="${s//\{agent\}/$agent}"
  s="${s//\{workspace\}/$workspace}"
  s="${s//\{worktree\}/$worktree}"
  s="${s//\{tab\}/$tab_id}"
  s="${s//\{pane\}/$pane_id}"
  s="${s//\{session\}/$session}"
  s="${s//\{cwd\}/$cwd}"
  s="${s//\{old_status\}/$old_status}"
  s="${s//\{new_status\}/$new_status}"
  printf '%s' "$s"
}

title="$(expand "$(pick TITLE)")"
body="$(expand "$(pick BODY)")"
icon="$(pick ICON)"
sound="$(pick SOUND)"

# --- 8. fire terminal-notifier ----------------------------------------------
args=(-title "$title" -message "$body")
[ -n "$pane_id" ] && args+=(-group "$pane_id")
[ -n "$sound" ] && [ "$sound" != "none" ] && args+=(-sound "$sound")

if [ -n "$icon" ]; then
  case "$icon" in /*) : ;; *) icon="$ROOT/$icon" ;; esac
  if [ -f "$icon" ]; then
    case "${ICON_MODE:-contentImage}" in
      appIcon) args+=(-appIcon "$icon") ;;
      *)       args+=(-contentImage "$icon") ;;
    esac
  fi
fi

if [ "${ACTIVATE_ON_CLICK:-0}" = "1" ] && [ -n "$pane_id" ]; then
  bin="$(command -v "$HERDR_BIN" || printf '%s' "$HERDR_BIN")"
  click="${CLICK_COMMAND//\{pane\}/$pane_id}"
  click="${click//\{workspace\}/$workspace_id}"
  click="${click//\{agent\}/$agent}"
  args+=(-execute "$bin $click")
fi

"$NOTIFIER_BIN" "${args[@]}" >/dev/null 2>&1 || log "notifier failed"
