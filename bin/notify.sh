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

# Diagnostics: a single dump file (DEBUG=1) captures every gate's inputs and the
# decision taken, so a silent drop is traceable after the fact. dbg() appends;
# the raw-JSON block below truncates it first.
DEBUG_FILE="$STATE_DIR/last-event.json"
dbg() { [ "${DEBUG:-0}" = "1" ] && printf '%s\n' "$*" >>"$DEBUG_FILE"; return 0; }

# drop [--loud] <reason...>: record the decision in the debug dump and exit 0.
# The reason is written to stderr only under DEBUG=1 by default, because the
# trigger/focused/debounce gates fire on routine status churn and would spam
# herdr's log. Pass --loud for rare/anomalous drops that always warrant a line.
drop() {
  local loud=0
  [ "${1:-}" = "--loud" ] && { loud=1; shift; }
  { [ "$loud" = 1 ] || [ "${DEBUG:-0}" = "1" ]; } && log "drop $*"
  dbg "decision=drop $*"
  exit 0
}

# jq is the hard dependency for every field we read out of the event/context and
# out of live herdr state. Without it the helpers below would degrade to empty
# strings and the event would drop for a bogus "no status" reason. Fail loudly.
command -v jq >/dev/null 2>&1 \
  || { log "fatal: jq not found on PATH; cannot parse herdr events (install jq)"; exit 1; }

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
  #   * no sentinel / bundle newer than sentinel -> register (new build)
  #   * sentinel older than REGISTER_TTL_SECONDS  -> register (periodic refresh)
  # Every register pass also verifies the code signature and ad-hoc re-signs
  # ONLY if it is invalid. The verify gate matters because an ad-hoc signature
  # gets a fresh CDHash each time, which changes the identity macOS keys the
  # notification (TCC) grant to — a needless re-sign can drop the grant.
  # A FAILED re-sign is logged distinctly (never claimed as a re-sign) and, since
  # the sentinel is refreshed regardless, retried on the next TTL expiry — a
  # bounded cadence, not per-event and not never. Delivery stays best-effort:
  # signing/registration problems never abort the notification itself.
  # Termination: the sentinel is refreshed (: >sentinel) at the end of the branch
  # regardless of the verify/sign outcome, so its mtime lands newer than the
  # bundle's; the next event therefore takes the cheap TTL path, never
  # re-entering the "bundle newer" branch on every event.
  sentinel="$STATE_DIR/.notifier-registered"
  # LSREGISTER is overridable so tests can inject a stub.
  lsregister="${LSREGISTER:-/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister}"
  register_ttl="${REGISTER_TTL_SECONDS:-21600}" # 6h; bounds how long a stale reg can linger
  needs_register=0
  if [ ! -f "$sentinel" ] || [ "$BUNDLED_BIN" -nt "$sentinel" ]; then
    needs_register=1
  else
    sentinel_age=$(( $(date +%s) - $(stat -f %m "$sentinel" 2>/dev/null || echo 0) ))
    [ "$sentinel_age" -ge "$register_ttl" ] && needs_register=1
  fi
  if [ "$needs_register" = 1 ]; then
    if ! codesign --verify --deep "$BUNDLED_APP" >/dev/null 2>&1; then
      if codesign --force --deep -s - "$BUNDLED_APP" >/dev/null 2>&1; then
        log "re-signed HerdrNotify.app (ad-hoc); if desktop notifications stop, re-approve \"herdr\" in System Settings -> Notifications"
      else
        log "codesign FAILED for HerdrNotify.app; signature still invalid, will retry within REGISTER_TTL_SECONDS (${register_ttl}s)"
      fi
    fi
    if ! "$lsregister" -f "$BUNDLED_APP" >/dev/null 2>&1; then
      # A failed registration would otherwise hide for a full TTL.
      [ "${DEBUG:-0}" != "1" ] || log "lsregister failed for HerdrNotify.app; will retry within REGISTER_TTL_SECONDS (${register_ttl}s)"
    fi
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
# Raw inputs first (truncating the file); resolved variables and the final
# decision are appended by dbg()/drop() as we go, so the dump reflects both what
# came in and which gate acted on it.
if [ "${DEBUG:-0}" = "1" ]; then
  {
    printf 'event=%s\n' "${HERDR_PLUGIN_EVENT:-}"
    printf 'EVENT_JSON=%s\n' "$EVENT_JSON"
    printf 'CONTEXT_JSON=%s\n' "$CONTEXT_JSON"
  } >"$DEBUG_FILE"
  log "debug dump written to $DEBUG_FILE"
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

# Record the resolved view so a drop below can be traced to concrete values.
dbg "pane_id=$pane_id"
dbg "new_status=$new_status"
dbg "agent=$agent"
dbg "workspace_id=$workspace_id"
dbg "workspace=$workspace"
dbg "tab_id=$tab_id"
dbg "cwd=$cwd"

if [ -z "$new_status" ]; then
  # Anomalous: this handler is bound to pane.agent_status_changed, so an event
  # with no resolvable status usually means a schema/parse problem worth seeing.
  drop --loud "reason=nostatus (event/context/herdr carried no agent_status)"
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
dbg "old_status=$old_status"

# --- 4. should this transition notify? ---------------------------------------
case " $TRIGGER_STATUSES " in
  *" $new_status "*) : ;;
  *) drop "reason=trigger status=$new_status not in [$TRIGGER_STATUSES]" ;;
esac

# --- 5. suppress the workspace you are currently looking at ------------------
if [ "${SUPPRESS_FOCUSED:-0}" = "1" ] && [ -n "$workspace_id" ]; then
  if [ "$(focused_workspace_id)" = "$workspace_id" ]; then
    drop "reason=focused ws=$workspace_id"
  fi
fi

# --- 6. debounce repeated (pane,status) within DEBOUNCE_SECONDS --------------
if [ -n "$pane_id" ]; then
  stamp_file="$STATE_DIR/debounce-$pane_key"
  now="$(date +%s)"
  if [ -f "$stamp_file" ]; then
    read -r last_ts last_status <"$stamp_file" || true
    if [ "$last_status" = "$new_status" ] && [ $((now - ${last_ts:-0})) -lt "${DEBOUNCE_SECONDS:-0}" ]; then
      drop "reason=debounce pane=$pane_id status=$new_status within ${DEBOUNCE_SECONDS:-0}s"
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

dbg "decision=notify title=$title"
# Capture the notifier's stderr (dropping its stdout) so a failure surfaces the
# actual reason instead of a bare "notifier failed". The `|| rc=$?` keeps set -e
# from biting; the stderr is flattened to one line and length-bounded so a noisy
# failure can't inject newlines or a wall of text into the log.
notifier_err="$("$NOTIFIER_BIN" "${args[@]}" 2>&1 >/dev/null)" && notifier_rc=0 || notifier_rc=$?
if [ "$notifier_rc" -ne 0 ]; then
  notifier_err="$(printf '%s' "${notifier_err:-<no stderr>}" | tr '\n' ' ' | cut -c1-500)"
  log "notifier failed (exit $notifier_rc): $notifier_err"
fi
