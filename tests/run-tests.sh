#!/usr/bin/env bash
# Plain-bash test harness for bin/notify.sh (no bats dependency).
#
# Each test runs notify.sh in an isolated temp state dir with stubbed
# collaborators so we can assert on the observable side effects:
#   * the log lines it writes to stderr (drop reasons, notifier errors)
#   * the argv it hands to terminal-notifier (recorded by the stub)
#   * the DEBUG dump it writes to the state dir
#
# Stubs:
#   * terminal-notifier -> a script that records its argv (and can be told to
#     fail with a chosen stderr message). Most tests inject NOTIFIER= via a
#     HERDR_TN_CONFIG file; #5 also injects it (and other keys) via the env, now
#     that config.sh honors env overrides instead of clobbering them.
#   * herdr             -> a script answering pane/workspace queries, pointed
#     at via HERDR_BIN_PATH.
#
# This harness is intentionally reusable: issues #2/#3 extend the fixtures.
# run_notify forwards extra "VAR=value" env assignments via "$@" so #2/#3 can
# inject config without editing the harness; today's tests pass none.
# shellcheck disable=SC2119,SC2120
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NOTIFY="$ROOT/bin/notify.sh"

PASS=0 FAIL=0
FAILED_NAMES=()

fail() { FAIL=$((FAIL + 1)); FAILED_NAMES+=("$CURRENT_TEST: $1"); printf 'FAIL %s: %s\n' "$CURRENT_TEST" "$1"; }
pass() { PASS=$((PASS + 1)); printf 'ok   %s\n' "$CURRENT_TEST"; }

assert_contains() { # haystack needle msg
  case "$1" in
    *"$2"*) return 0 ;;
    *) fail "$3 (missing '$2')"; return 1 ;;
  esac
}
assert_not_contains() { # haystack needle msg
  case "$1" in
    *"$2"*) fail "$3 (unexpected '$2')"; return 1 ;;
    *) return 0 ;;
  esac
}
assert_eq() { # actual expected msg
  [ "$1" = "$2" ] && return 0
  fail "$3 (got '$1' want '$2')"; return 1
}

# --- fixture builders --------------------------------------------------------

# make_notifier <dir> [exit_code] [stderr_msg]
# Writes an executable stub that records argv to <dir>/notifier-args and exits
# with the given code, emitting stderr_msg on failure.
make_notifier() {
  local dir="$1" code="${2:-0}" msg="${3:-}"
  local f="$dir/terminal-notifier"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'printf "%%s\\n" "$@" >"%s/notifier-args"\n' "$dir"
    [ -n "$msg" ] && printf 'printf "%%s\\n" %q >&2\n' "$msg"
    printf 'exit %s\n' "$code"
  } >"$f"
  chmod +x "$f"
  printf '%s' "$f"
}

# make_herdr <dir> [focused_ws]
# Fake herdr: answers `workspace list` with one focused workspace (focused_ws),
# and pane/workspace get with empty results (context fixtures carry the data).
make_herdr() {
  local dir="$1" focused="${2:-}"
  local f="$dir/herdr"
  {
    printf '#!/usr/bin/env bash\n'
    # shellcheck disable=SC2016  # writing literal shell into the stub, not expanding here
    printf 'printf "%%s\\n" "$*" >>"%s/herdr-calls"\n' "$dir"
    # shellcheck disable=SC2016  # writing literal shell into the stub, not expanding here
    printf 'case "$1 $2" in\n'
    printf '  "workspace list") printf %q ;;\n' "{\"result\":{\"workspaces\":[{\"workspace_id\":\"$focused\",\"focused\":true}]}}"
    printf '  "pane get") printf %q ;;\n' '{"result":{"pane":{}}}'
    printf '  "workspace get") printf %q ;;\n' '{"result":{"workspace":{}}}'
    printf '  *) printf "{}" ;;\n'
    printf 'esac\n'
  } >"$f"
  chmod +x "$f"
  printf '%s' "$f"
}

# make_config <path> [extra lines...]
make_config() {
  local path="$1"; shift
  : >"$path"
  local line
  for line in "$@"; do printf '%s\n' "$line" >>"$path"; done
}

# make_min_path <dir>
# A PATH dir with the coreutils notify.sh needs BUT NO jq, to exercise the
# fail-loud-on-missing-jq path.
make_min_path() {
  local dir="$1" tool src
  mkdir -p "$dir"
  for tool in bash sh mkdir dirname basename pwd cat tr date stat sed env printf expr rm chmod; do
    src="$(command -v "$tool" 2>/dev/null || true)"
    [ -n "$src" ] && ln -sf "$src" "$dir/$tool"
  done
  printf '%s' "$dir"
}

# make_lsappinfo <dir> <bundleid | --garbage | --empty>
# Writes a fake `lsappinfo` (found via PATH) that answers `front` with a dummy
# ASN and `info -only bundleid <asn>` with a chosen frontmost bundle id.
#   <bundleid> -> a normal "CFBundleIdentifier"="<id>" line
#   --garbage  -> a line with no parseable quoted value (unparsable output)
#   --empty    -> the key present but no value ("CFBundleIdentifier"=)
make_lsappinfo() {
  local dir="$1" mode="$2" line
  local f="$dir/lsappinfo"
  case "$mode" in
    --garbage) line='total garbage no quoted value here' ;;
    --empty)   line='"CFBundleIdentifier"=' ;;
    *)         line="\"CFBundleIdentifier\"=\"$mode\"" ;;
  esac
  {
    printf '#!/usr/bin/env bash\n'
    # shellcheck disable=SC2016  # writing literal shell into the stub, not expanding here
    printf 'if [ "$1" = front ]; then printf "%%s\\n" "ASN:0x0-0x12345:"; exit 0; fi\n'
    # shellcheck disable=SC2016  # writing literal shell into the stub, not expanding here
    printf 'if [ "$1" = info ]; then printf "%%s\\n" %q; exit 0; fi\n' "$line"
    printf 'exit 0\n'
  } >"$f"
  chmod +x "$f"
  printf '%s' "$f"
}

# make_path_with_jq <dir>
# Like make_min_path but ALSO includes jq (and cut), for exercising notify.sh's
# full path on a restricted PATH that deliberately omits a tool (e.g. lsappinfo).
make_path_with_jq() {
  local dir="$1" src
  make_min_path "$dir" >/dev/null
  for src in jq cut; do
    local p; p="$(command -v "$src" 2>/dev/null || true)"
    [ -n "$p" ] && ln -sf "$p" "$dir/$src"
  done
  printf '%s' "$dir"
}

# run_notify — runs notify.sh, capturing stderr into REPLY_ERR and exit in REPLY_RC.
# Args are extra "VAR=value" env assignments. Uses globals set by the caller:
#   T (temp dir), EVENT_JSON, CONTEXT_JSON, HERDR_BIN, TN_CONFIG, [DEBUG], [PATH_OVERRIDE]
run_notify() {
  local errf="$T/stderr"
  local path="${PATH_OVERRIDE:-$PATH}"
  env -i \
    PATH="$path" \
    HOME="$HOME" \
    HERDR_PLUGIN_STATE_DIR="$T/state" \
    HERDR_PLUGIN_EVENT_JSON="$EVENT_JSON" \
    HERDR_PLUGIN_CONTEXT_JSON="$CONTEXT_JSON" \
    HERDR_BIN_PATH="$HERDR_BIN" \
    HERDR_TN_CONFIG="$TN_CONFIG" \
    DEBUG="${DEBUG_FLAG:-0}" \
    "$@" \
    bash "$NOTIFY" 2>"$errf"
  REPLY_RC=$?
  REPLY_ERR="$(cat "$errf" 2>/dev/null || true)"
}

# new_temp — fresh isolated temp dir for a test, sets T and resets globals.
new_temp() {
  T="$(mktemp -d "${TMPDIR:-/tmp}/tn-test.XXXXXX")"
  TEMPS+=("$T")
  mkdir -p "$T/state" "$T/bin"
  DEBUG_FLAG=0
  PATH_OVERRIDE=""
}

TEMPS=()
cleanup() { local d; for d in "${TEMPS[@]:-}"; do [ -n "$d" ] && rm -rf "$d"; done; }
trap cleanup EXIT

# --- tests -------------------------------------------------------------------

test_trigger_drop() {
  CURRENT_TEST="trigger_drop"
  new_temp
  local n; n="$(make_notifier "$T/bin")"
  HERDR_BIN="$(make_herdr "$T/bin")"
  TN_CONFIG="$T/config.env"
  make_config "$TN_CONFIG" "NOTIFIER=$n" 'TRIGGER_STATUSES="blocked done"' 'SUPPRESS_FOCUSED=0'
  EVENT_JSON='{"event":"pane.agent_status_changed","data":{"pane_id":"p1","agent_status":"working","agent":"claude","workspace_id":"w1"}}'
  CONTEXT_JSON='{}'
  DEBUG_FLAG=1   # trigger drops are high-volume: logged only under DEBUG
  run_notify
  assert_eq "$REPLY_RC" 0 "exit 0 on non-trigger status"
  assert_contains "$REPLY_ERR" "drop reason=trigger" "logs trigger drop reason"
  assert_contains "$REPLY_ERR" "working" "trigger drop names the status"
  [ ! -f "$T/bin/notifier-args" ] || fail "notifier must not fire on non-trigger status"
  [ "$FAIL" -eq "$PRE_FAIL" ] && pass
}

test_focused_drop() {
  CURRENT_TEST="focused_drop"
  new_temp
  local n; n="$(make_notifier "$T/bin")"
  HERDR_BIN="$(make_herdr "$T/bin" "w1")"   # w1 is focused
  make_lsappinfo "$T/bin" "com.test.term" >/dev/null   # terminal IS frontmost
  PATH_OVERRIDE="$T/bin:$PATH"                          # find the lsappinfo stub
  TN_CONFIG="$T/config.env"
  make_config "$TN_CONFIG" "NOTIFIER=$n" 'TRIGGER_STATUSES="blocked done"' \
    'SUPPRESS_FOCUSED=1' 'TERMINAL_APP_IDS="com.test.term"'
  EVENT_JSON='{"data":{"pane_id":"p1","agent_status":"done","agent":"claude","workspace_id":"w1"}}'
  CONTEXT_JSON='{}'
  DEBUG_FLAG=1   # focused drops are high-volume: logged only under DEBUG
  run_notify
  assert_eq "$REPLY_RC" 0 "exit 0 on focused suppression"
  assert_contains "$REPLY_ERR" "drop reason=focused" "logs focused drop reason"
  assert_contains "$REPLY_ERR" "w1" "focused drop names workspace"
  assert_contains "$REPLY_ERR" "frontmost=com.test.term" "focused drop names the frontmost terminal"
  [ ! -f "$T/bin/notifier-args" ] || fail "notifier must not fire when focused AND terminal frontmost"
  [ "$FAIL" -eq "$PRE_FAIL" ] && pass
}

test_debounce_drop() {
  CURRENT_TEST="debounce_drop"
  new_temp
  local n; n="$(make_notifier "$T/bin")"
  HERDR_BIN="$(make_herdr "$T/bin")"
  TN_CONFIG="$T/config.env"
  make_config "$TN_CONFIG" "NOTIFIER=$n" 'TRIGGER_STATUSES="blocked done"' 'SUPPRESS_FOCUSED=0' 'DEBOUNCE_SECONDS=60'
  EVENT_JSON='{"data":{"pane_id":"p1","agent_status":"done","agent":"claude","workspace_id":"w1"}}'
  CONTEXT_JSON='{}'
  DEBUG_FLAG=1   # debounce drops are high-volume: logged only under DEBUG
  run_notify   # first fires
  rm -f "$T/bin/notifier-args"
  run_notify   # second within window -> debounced
  assert_eq "$REPLY_RC" 0 "exit 0 on debounce"
  assert_contains "$REPLY_ERR" "drop reason=debounce" "logs debounce drop reason"
  [ ! -f "$T/bin/notifier-args" ] || fail "notifier must not fire when debounced"
  [ "$FAIL" -eq "$PRE_FAIL" ] && pass
}

test_nostatus_drop() {
  CURRENT_TEST="nostatus_drop"
  new_temp
  local n; n="$(make_notifier "$T/bin")"
  HERDR_BIN="$(make_herdr "$T/bin")"
  TN_CONFIG="$T/config.env"
  make_config "$TN_CONFIG" "NOTIFIER=$n"
  EVENT_JSON='{"data":{"pane_id":"p1"}}'
  CONTEXT_JSON='{}'
  # DEBUG stays off: nostatus is an anomaly (--loud) and must log unconditionally.
  run_notify
  assert_eq "$REPLY_RC" 0 "exit 0 when no status"
  assert_contains "$REPLY_ERR" "drop reason=nostatus" "logs nostatus drop reason unconditionally"
  [ "$FAIL" -eq "$PRE_FAIL" ] && pass
}

test_jq_missing() {
  CURRENT_TEST="jq_missing"
  new_temp
  local n; n="$(make_notifier "$T/bin")"
  HERDR_BIN="$(make_herdr "$T/bin")"
  TN_CONFIG="$T/config.env"
  make_config "$TN_CONFIG" "NOTIFIER=$n"
  EVENT_JSON='{"data":{"pane_id":"p1","agent_status":"done"}}'
  CONTEXT_JSON='{}'
  PATH_OVERRIDE="$(make_min_path "$T/nojq"):$T/bin"   # no jq on PATH
  run_notify
  assert_contains "$REPLY_ERR" "jq" "fails loudly naming jq when jq is missing"
  [ "$REPLY_RC" -ne 0 ] || fail "must exit non-zero when jq is missing"
  # The preflight must run before any side effect: no herdr query, no notifier.
  [ ! -f "$T/bin/herdr-calls" ] || fail "must not query herdr before the jq preflight"
  [ ! -f "$T/bin/notifier-args" ] || fail "must not invoke the notifier before the jq preflight"
  [ "$FAIL" -eq "$PRE_FAIL" ] && pass
}

test_notifier_stderr_captured() {
  CURRENT_TEST="notifier_stderr_captured"
  new_temp
  local n; n="$(make_notifier "$T/bin" 3 "boom-from-notifier")"
  HERDR_BIN="$(make_herdr "$T/bin")"
  TN_CONFIG="$T/config.env"
  make_config "$TN_CONFIG" "NOTIFIER=$n" 'TRIGGER_STATUSES="blocked done"' 'SUPPRESS_FOCUSED=0'
  EVENT_JSON='{"data":{"pane_id":"p1","agent_status":"done","agent":"claude","workspace_id":"w1"}}'
  CONTEXT_JSON='{}'
  run_notify
  assert_contains "$REPLY_ERR" "notifier failed" "logs notifier failure"
  assert_contains "$REPLY_ERR" "boom-from-notifier" "captures notifier stderr in the log line"
  [ "$FAIL" -eq "$PRE_FAIL" ] && pass
}

test_happy_path() {
  CURRENT_TEST="happy_path"
  new_temp
  local n; n="$(make_notifier "$T/bin")"
  HERDR_BIN="$(make_herdr "$T/bin")"
  TN_CONFIG="$T/config.env"
  make_config "$TN_CONFIG" "NOTIFIER=$n" 'TRIGGER_STATUSES="blocked done"' 'SUPPRESS_FOCUSED=0' 'ACTIVATE_ON_CLICK=0'
  EVENT_JSON='{"data":{"pane_id":"p1","agent_status":"done","agent":"claude","workspace_id":"w1"}}'
  CONTEXT_JSON='{"workspace_label":"My WS"}'
  run_notify
  assert_eq "$REPLY_RC" 0 "exit 0 on happy path"
  if [ -f "$T/bin/notifier-args" ]; then
    local args; args="$(cat "$T/bin/notifier-args")"
    assert_contains "$args" "-title" "notifier gets a title"
    assert_contains "$args" "done" "title reflects done status"
  else
    fail "notifier must fire on a triggering, unfocused, un-debounced event"
  fi
  [ "$FAIL" -eq "$PRE_FAIL" ] && pass
}

test_debug_dump() {
  CURRENT_TEST="debug_dump"
  new_temp
  local n; n="$(make_notifier "$T/bin")"
  HERDR_BIN="$(make_herdr "$T/bin")"
  TN_CONFIG="$T/config.env"
  make_config "$TN_CONFIG" "NOTIFIER=$n" 'TRIGGER_STATUSES="blocked done"' 'SUPPRESS_FOCUSED=0'
  EVENT_JSON='{"data":{"pane_id":"p1","agent_status":"done","agent":"claude","workspace_id":"w1"}}'
  CONTEXT_JSON='{"workspace_label":"My WS"}'
  DEBUG_FLAG=1
  run_notify
  local dump="$T/state/last-event.json"
  if [ -f "$dump" ]; then
    local d; d="$(cat "$dump")"
    assert_contains "$d" "pane_id" "dump includes resolved pane_id"
    assert_contains "$d" "new_status" "dump includes resolved new_status"
    assert_contains "$d" "p1" "dump shows the actual pane id value"
    assert_contains "$d" "decision" "dump records the decision taken"
  else
    fail "DEBUG=1 must write last-event.json"
  fi
  [ "$FAIL" -eq "$PRE_FAIL" ] && pass
}

# --- #2: event fields must not fall back to focused-pane context -------------
# A fake herdr whose `pane get` returns a caller-supplied pane object, so a test
# can exercise pane_field enrichment keyed by the REAL pane id (vs guessing the
# focused pane). Appended here (not folded into make_herdr) to keep the diff off
# the shared fixture builders.
make_herdr_pane() { # <dir> <pane_json> [focused_ws]
  local dir="$1" pane_json="$2" focused="${3:-}"
  local f="$dir/herdr"
  {
    printf '#!/usr/bin/env bash\n'
    # shellcheck disable=SC2016
    printf 'printf "%%s\\n" "$*" >>"%s/herdr-calls"\n' "$dir"
    # shellcheck disable=SC2016
    printf 'case "$1 $2" in\n'
    printf '  "workspace list") printf %q ;;\n' "{\"result\":{\"workspaces\":[{\"workspace_id\":\"$focused\",\"focused\":true}]}}"
    printf '  "pane get") printf %q ;;\n' "{\"result\":{\"pane\":$pane_json}}"
    printf '  "workspace get") printf %q ;;\n' '{"result":{"workspace":{}}}'
    printf '  *) printf "{}" ;;\n'
    printf 'esac\n'
  } >"$f"
  chmod +x "$f"
  printf '%s' "$f"
}

test_missing_pane_id_loud_drop() {
  CURRENT_TEST="missing_pane_id_loud_drop"
  new_temp
  local n; n="$(make_notifier "$T/bin")"
  HERDR_BIN="$(make_herdr "$T/bin" "w1")"   # w1 focused (must not matter)
  TN_CONFIG="$T/config.env"
  make_config "$TN_CONFIG" "NOTIFIER=$n" 'TRIGGER_STATUSES="blocked done"' 'SUPPRESS_FOCUSED=1'
  # Event about SOME pane but the pane_id field is absent (schema drift). The old
  # code guessed ctx.focused_pane_id; now this must loudly drop, never guess.
  EVENT_JSON='{"event":"pane.agent_status_changed","data":{"agent_status":"done","agent":"claude","workspace_id":"w1"}}'
  CONTEXT_JSON='{"focused_pane_id":"pFOCUSED","workspace_id":"w1"}'
  # DEBUG off: nopane is an anomaly (--loud) and must log unconditionally.
  run_notify
  assert_eq "$REPLY_RC" 0 "exit 0 on missing pane_id"
  assert_contains "$REPLY_ERR" "drop reason=nopane" "logs nopane drop reason unconditionally"
  assert_not_contains "$REPLY_ERR" "pFOCUSED" "must not fall back to focused pane id"
  [ ! -f "$T/bin/notifier-args" ] || fail "notifier must not fire when pane_id is missing"
  [ "$FAIL" -eq "$PRE_FAIL" ] && pass
}

test_missing_status_enriched_via_pane_field() {
  CURRENT_TEST="missing_status_enriched_via_pane_field"
  new_temp
  local n; n="$(make_notifier "$T/bin")"
  # Event lacks agent_status; live pane get (keyed by the real pane id) carries it.
  HERDR_BIN="$(make_herdr_pane "$T/bin" '{"agent_status":"done","workspace_id":"w1","agent":"claude"}')"
  TN_CONFIG="$T/config.env"
  make_config "$TN_CONFIG" "NOTIFIER=$n" 'TRIGGER_STATUSES="blocked done"' 'SUPPRESS_FOCUSED=0'
  EVENT_JSON='{"event":"pane.agent_status_changed","data":{"pane_id":"p1"}}'
  CONTEXT_JSON='{"focused_pane_status":"working"}'   # would misattribute if used
  run_notify
  assert_eq "$REPLY_RC" 0 "exit 0 on enriched status"
  assert_not_contains "$REPLY_ERR" "drop reason=nostatus" "must not drop: status enriched from pane_field"
  assert_contains "$(cat "$T/bin/herdr-calls" 2>/dev/null || true)" "pane get p1" "enriches via the REAL pane id, not the focused pane"
  if [ -f "$T/bin/notifier-args" ]; then
    assert_contains "$(cat "$T/bin/notifier-args")" "done" "title reflects the enriched (not focused) status"
  else
    fail "notifier must fire once status is enriched to a triggering value"
  fi
  [ "$FAIL" -eq "$PRE_FAIL" ] && pass
}

test_workspace_id_via_pane_field_not_ctx() {
  CURRENT_TEST="workspace_id_via_pane_field_not_ctx"
  new_temp
  local n; n="$(make_notifier "$T/bin")"
  # Focused workspace is wFOCUSED. The event is about a background pane whose real
  # workspace (from pane get) is wREAL. Old code fell back to ctx.workspace_id
  # (== the focused ws) and SUPPRESS_FOCUSED silenced EVERY event. It must not.
  HERDR_BIN="$(make_herdr_pane "$T/bin" '{"workspace_id":"wREAL","agent":"claude"}' "wFOCUSED")"
  TN_CONFIG="$T/config.env"
  make_config "$TN_CONFIG" "NOTIFIER=$n" 'TRIGGER_STATUSES="blocked done"' 'SUPPRESS_FOCUSED=1'
  EVENT_JSON='{"event":"pane.agent_status_changed","data":{"pane_id":"p1","agent_status":"done"}}'
  CONTEXT_JSON='{"workspace_id":"wFOCUSED"}'   # the focused ws; must NOT be used
  run_notify
  assert_eq "$REPLY_RC" 0 "exit 0"
  assert_not_contains "$REPLY_ERR" "drop reason=focused" "background pane must not be suppressed as focused"
  [ -f "$T/bin/notifier-args" ] || fail "notifier must fire: real ws (wREAL) != focused (wFOCUSED)"
  [ "$FAIL" -eq "$PRE_FAIL" ] && pass
}

# --- issue #3: frontmost-aware focus suppression -----------------------------
# SUPPRESS_FOCUSED must mute only when BOTH the event workspace is the focused
# herdr workspace AND a herdr-hosting terminal is the frontmost macOS app.
# (Appended at the END to minimize merge conflicts with parallel work on #2.)

# Shared setup: focused workspace w1, triggering event on w1. Callers add an
# lsappinfo stub + TERMINAL_APP_IDS to control the frontmost-app half.
_setup_focus_case() { # <lsappinfo-mode|SKIP> [extra config lines...]
  local mode="$1"; shift
  new_temp
  _FOCUS_N="$(make_notifier "$T/bin")"
  HERDR_BIN="$(make_herdr "$T/bin" "w1")"   # w1 is focused inside herdr
  if [ "$mode" != "SKIP" ]; then
    make_lsappinfo "$T/bin" "$mode" >/dev/null
  fi
  PATH_OVERRIDE="$T/bin:$PATH"
  TN_CONFIG="$T/config.env"
  make_config "$TN_CONFIG" "NOTIFIER=$_FOCUS_N" 'TRIGGER_STATUSES="blocked done"' "$@"
  EVENT_JSON='{"data":{"pane_id":"p1","agent_status":"done","agent":"claude","workspace_id":"w1"}}'
  CONTEXT_JSON='{}'
  DEBUG_FLAG=1
}

# Terminal frontmost -> both conditions met -> suppress.
test_focus_terminal_frontmost_drop() {
  CURRENT_TEST="focus_terminal_frontmost_drop"
  _setup_focus_case "com.mitchellh.ghostty" \
    'SUPPRESS_FOCUSED=1' 'TERMINAL_APP_IDS="com.mitchellh.ghostty com.apple.Terminal"'
  run_notify
  assert_eq "$REPLY_RC" 0 "exit 0 when suppressed"
  assert_contains "$REPLY_ERR" "drop reason=focused" "suppresses when terminal is frontmost"
  assert_contains "$REPLY_ERR" "frontmost=com.mitchellh.ghostty" "names the frontmost terminal"
  [ ! -f "$T/bin/notifier-args" ] || fail "notifier must not fire when suppressed"
  [ "$FAIL" -eq "$PRE_FAIL" ] && pass
}

# Another app frontmost (user switched to the browser) -> notify anyway.
test_focus_other_app_notify() {
  CURRENT_TEST="focus_other_app_notify"
  _setup_focus_case "com.google.Chrome" \
    'SUPPRESS_FOCUSED=1' 'TERMINAL_APP_IDS="com.mitchellh.ghostty com.apple.Terminal"'
  run_notify
  assert_eq "$REPLY_RC" 0 "exit 0"
  assert_not_contains "$REPLY_ERR" "drop reason=focused" "must NOT suppress when terminal is not frontmost"
  [ -f "$T/bin/notifier-args" ] || fail "notifier must fire when the terminal is not frontmost"
  [ "$FAIL" -eq "$PRE_FAIL" ] && pass
}

# lsappinfo missing entirely -> fail open -> notify.
test_focus_lsappinfo_missing_notify() {
  CURRENT_TEST="focus_lsappinfo_missing_notify"
  _setup_focus_case "SKIP" \
    'SUPPRESS_FOCUSED=1' 'TERMINAL_APP_IDS="com.mitchellh.ghostty"'
  # Restricted PATH with jq but NO lsappinfo (and no $T/bin, so no stub either).
  PATH_OVERRIDE="$(make_path_with_jq "$T/nols")"
  run_notify
  assert_eq "$REPLY_RC" 0 "exit 0 (fail open)"
  assert_not_contains "$REPLY_ERR" "drop reason=focused" "fail open when lsappinfo missing"
  [ -f "$T/bin/notifier-args" ] || fail "notifier must fire when frontmost detection is unavailable"
  [ "$FAIL" -eq "$PRE_FAIL" ] && pass
}

# lsappinfo present but emits unparsable output -> fail open -> notify.
test_focus_lsappinfo_garbage_notify() {
  CURRENT_TEST="focus_lsappinfo_garbage_notify"
  _setup_focus_case "--garbage" \
    'SUPPRESS_FOCUSED=1' 'TERMINAL_APP_IDS="com.mitchellh.ghostty"'
  run_notify
  assert_eq "$REPLY_RC" 0 "exit 0 (fail open)"
  assert_not_contains "$REPLY_ERR" "drop reason=focused" "fail open on unparsable lsappinfo output"
  [ -f "$T/bin/notifier-args" ] || fail "notifier must fire on unparsable frontmost output"
  [ "$FAIL" -eq "$PRE_FAIL" ] && pass
}

# SUPPRESS_FOCUSED=0 -> never suppress, even with terminal frontmost + focused ws.
test_focus_suppress_disabled_notify() {
  CURRENT_TEST="focus_suppress_disabled_notify"
  _setup_focus_case "com.mitchellh.ghostty" \
    'SUPPRESS_FOCUSED=0' 'TERMINAL_APP_IDS="com.mitchellh.ghostty"'
  run_notify
  assert_eq "$REPLY_RC" 0 "exit 0"
  assert_not_contains "$REPLY_ERR" "drop reason=focused" "SUPPRESS_FOCUSED=0 never suppresses"
  [ -f "$T/bin/notifier-args" ] || fail "notifier must fire when SUPPRESS_FOCUSED=0"
  [ "$FAIL" -eq "$PRE_FAIL" ] && pass
}

# --- issue #6: enrichment must run AFTER the trigger gate --------------------
# A non-triggering event must short-circuit with ZERO herdr CLI calls; a
# triggering event must still see live-enriched fields ({session} etc.).
# (Appended at the END to minimize merge conflicts with parallel work.)

# Non-triggering `working` event with a FULL event payload -> drop AND not a
# single herdr socket round-trip (the enrichment block never runs pre-gate).
test_nontrigger_zero_cli() {
  CURRENT_TEST="nontrigger_zero_cli"
  new_temp
  local n; n="$(make_notifier "$T/bin")"
  HERDR_BIN="$(make_herdr "$T/bin")"
  TN_CONFIG="$T/config.env"
  make_config "$TN_CONFIG" "NOTIFIER=$n" 'TRIGGER_STATUSES="blocked done"' 'SUPPRESS_FOCUSED=0'
  # Full payload: pane_id + agent_status present, so new_status needs no CLI.
  EVENT_JSON='{"event":"pane.agent_status_changed","data":{"pane_id":"p1","agent_status":"working","agent":"claude","workspace_id":"w1"}}'
  CONTEXT_JSON='{}'
  DEBUG_FLAG=1   # trigger drops are high-volume: logged only under DEBUG
  run_notify
  assert_eq "$REPLY_RC" 0 "exit 0 on non-trigger status"
  assert_contains "$REPLY_ERR" "drop reason=trigger" "logs trigger drop reason"
  # The whole point of #6: no herdr CLI call before the gate short-circuits.
  local calls; calls="$(cat "$T/bin/herdr-calls" 2>/dev/null || true)"
  assert_eq "$calls" "" "non-triggering event makes ZERO herdr CLI calls"
  [ ! -f "$T/bin/notifier-args" ] || fail "notifier must not fire on non-trigger status"
  [ "$FAIL" -eq "$PRE_FAIL" ] && pass
}

# Triggering event -> live enrichment still runs AFTER the gate: {session}, only
# resolvable from a live `herdr pane get`, must reach the notifier's argv.
test_trigger_enriches_session() {
  CURRENT_TEST="trigger_enriches_session"
  new_temp
  local n; n="$(make_notifier "$T/bin")"
  # session id lives only in live pane state; make pane get carry it.
  HERDR_BIN="$(make_herdr_pane "$T/bin" '{"agent_session":{"value":"sess-XYZ"},"workspace_id":"w1","agent":"claude"}')"
  TN_CONFIG="$T/config.env"
  make_config "$TN_CONFIG" "NOTIFIER=$n" 'TRIGGER_STATUSES="blocked done"' 'SUPPRESS_FOCUSED=0' \
    'BODY_DONE="session={session}"'
  EVENT_JSON='{"event":"pane.agent_status_changed","data":{"pane_id":"p1","agent_status":"done","agent":"claude","workspace_id":"w1"}}'
  CONTEXT_JSON='{}'
  run_notify
  assert_eq "$REPLY_RC" 0 "exit 0 on triggering event"
  assert_contains "$(cat "$T/bin/herdr-calls" 2>/dev/null || true)" "pane get p1" "enriches via a live pane get after the gate"
  if [ -f "$T/bin/notifier-args" ]; then
    assert_contains "$(cat "$T/bin/notifier-args")" "sess-XYZ" "notifier body carries the live-enriched session id"
  else
    fail "notifier must fire on a triggering, enriched event"
  fi
  [ "$FAIL" -eq "$PRE_FAIL" ] && pass
}

# old_status must be recorded BEFORE the trigger gate: a non-triggering `working`
# event (zero herdr CLI) still writes laststatus, so the next triggering `done`
# event expands {old_status}->{new_status} to working->done.
test_old_status_tracked_across_nontrigger() {
  CURRENT_TEST="old_status_tracked_across_nontrigger"
  new_temp
  local n; n="$(make_notifier "$T/bin")"
  HERDR_BIN="$(make_herdr "$T/bin")"
  TN_CONFIG="$T/config.env"
  make_config "$TN_CONFIG" "NOTIFIER=$n" 'TRIGGER_STATUSES="blocked done"' 'SUPPRESS_FOCUSED=0' \
    'BODY_DONE="{old_status}->{new_status}"'
  # 1) non-triggering working event: drops, but records laststatus and hits no CLI.
  EVENT_JSON='{"event":"pane.agent_status_changed","data":{"pane_id":"p1","agent_status":"working","agent":"claude","workspace_id":"w1"}}'
  CONTEXT_JSON='{}'
  DEBUG_FLAG=1
  run_notify
  assert_eq "$(cat "$T/bin/herdr-calls" 2>/dev/null || true)" "" "working event records old_status with ZERO herdr calls"
  [ ! -f "$T/bin/notifier-args" ] || fail "working event must not fire the notifier"
  # 2) triggering done event: expands old_status recorded by the working event.
  EVENT_JSON='{"event":"pane.agent_status_changed","data":{"pane_id":"p1","agent_status":"done","agent":"claude","workspace_id":"w1"}}'
  DEBUG_FLAG=0
  run_notify
  if [ -f "$T/bin/notifier-args" ]; then
    assert_contains "$(cat "$T/bin/notifier-args")" "working->done" "old_status transition survives the non-triggering event"
  else
    fail "notifier must fire on the triggering done event"
  fi
  [ "$FAIL" -eq "$PRE_FAIL" ] && pass
}

# --- issue #5: every config key is env-overridable ---------------------------
# config.sh assigns defaults as ${VAR:-default}, so an exported env var wins over
# the built-in default, while the config files (config.env, HERDR_TN_CONFIG) are
# sourced afterwards and still win over the env var.
# (Appended at the END to minimize merge conflicts with parallel work.)

# NOTIFIER supplied ONLY via the environment (not in any config file) must be
# honored. This is the headline of #5: config.sh used to hardcode NOTIFIER=""
# and clobber the env override, so the stub was never used.
test_env_notifier_override_honored() {
  CURRENT_TEST="env_notifier_override_honored"
  new_temp
  local n; n="$(make_notifier "$T/bin")"
  HERDR_BIN="$(make_herdr "$T/bin")"
  TN_CONFIG="$T/config.env"
  # Config file deliberately does NOT set NOTIFIER; it comes from the env below.
  make_config "$TN_CONFIG" 'TRIGGER_STATUSES="blocked done"' 'SUPPRESS_FOCUSED=0' 'ACTIVATE_ON_CLICK=0'
  EVENT_JSON='{"data":{"pane_id":"p1","agent_status":"done","agent":"claude","workspace_id":"w1"}}'
  CONTEXT_JSON='{"workspace_label":"My WS"}'
  run_notify "NOTIFIER=$n"
  assert_eq "$REPLY_RC" 0 "exit 0 with env-only NOTIFIER"
  if [ -f "$T/bin/notifier-args" ]; then
    assert_contains "$(cat "$T/bin/notifier-args")" "done" "env NOTIFIER stub is used (title reflects done)"
  else
    fail "env-only NOTIFIER override must be honored (stub must fire)"
  fi
  [ "$FAIL" -eq "$PRE_FAIL" ] && pass
}

# A config file must still beat an env var for the SAME key. Env sets
# DEBOUNCE_SECONDS=0 (would let a repeat through); the config file sets 3600
# (debounces). If the config file wins, the second repeat is debounced.
test_config_beats_env_for_same_key() {
  CURRENT_TEST="config_beats_env_for_same_key"
  new_temp
  local n; n="$(make_notifier "$T/bin")"
  HERDR_BIN="$(make_herdr "$T/bin")"
  TN_CONFIG="$T/config.env"
  make_config "$TN_CONFIG" "NOTIFIER=$n" 'TRIGGER_STATUSES="blocked done"' 'SUPPRESS_FOCUSED=0' 'DEBOUNCE_SECONDS=3600'
  EVENT_JSON='{"data":{"pane_id":"p1","agent_status":"done","agent":"claude","workspace_id":"w1"}}'
  CONTEXT_JSON='{}'
  DEBUG_FLAG=1   # debounce drops are high-volume: logged only under DEBUG
  run_notify "DEBOUNCE_SECONDS=0"   # env says 0; config file says 3600 and must win
  rm -f "$T/bin/notifier-args"
  run_notify "DEBOUNCE_SECONDS=0"   # second repeat: debounced iff config's 3600 won
  assert_eq "$REPLY_RC" 0 "exit 0 on debounce"
  assert_contains "$REPLY_ERR" "drop reason=debounce" "config file DEBOUNCE_SECONDS beats the env var"
  [ ! -f "$T/bin/notifier-args" ] || fail "config's DEBOUNCE_SECONDS=3600 must win over env's 0 (second repeat debounced)"
  [ "$FAIL" -eq "$PRE_FAIL" ] && pass
}

# An env-only override with NO config-file entry for the key must take effect and
# override the built-in default. Env DEBOUNCE_SECONDS=0 disables debounce, whereas
# the built-in default (2s) would drop the rapid second event: the second event
# firing proves the env value (not the default) is in effect.
test_env_only_override_beats_builtin_default() {
  CURRENT_TEST="env_only_override_beats_builtin_default"
  new_temp
  local n; n="$(make_notifier "$T/bin")"
  HERDR_BIN="$(make_herdr "$T/bin")"
  TN_CONFIG="$T/config.env"
  # No DEBOUNCE_SECONDS in the config file: the env value below is the only source.
  make_config "$TN_CONFIG" "NOTIFIER=$n" 'TRIGGER_STATUSES="blocked done"' 'SUPPRESS_FOCUSED=0'
  EVENT_JSON='{"data":{"pane_id":"p1","agent_status":"done","agent":"claude","workspace_id":"w1"}}'
  CONTEXT_JSON='{}'
  DEBUG_FLAG=1
  run_notify "DEBOUNCE_SECONDS=0"   # first fires
  [ -f "$T/bin/notifier-args" ] || fail "first event must fire"
  rm -f "$T/bin/notifier-args"
  run_notify "DEBOUNCE_SECONDS=0"   # second, immediate: NOT debounced because env set 0
  assert_eq "$REPLY_RC" 0 "exit 0"
  assert_not_contains "$REPLY_ERR" "drop reason=debounce" "env DEBOUNCE_SECONDS=0 overrides the built-in 2s default"
  [ -f "$T/bin/notifier-args" ] || fail "second rapid event must fire when env sets DEBOUNCE_SECONDS=0"
  [ "$FAIL" -eq "$PRE_FAIL" ] && pass
}

# --- issue #8: -execute click command must be built with shell quoting -------
# terminal-notifier re-parses the -execute string through a shell. The template
# words of CLICK_COMMAND stay unquoted (word-split into argv), but the bin path
# and every substituted value must be `printf %q`-escaped so metacharacters in a
# value (or a spaced binary path) can never inject into the click handler.
# (Appended at the END to minimize merge conflicts with parallel work.)

# _execute_arg <notifier-args-file> -> the argv word that follows "-execute".
# notifier-args is one argv word per line (the stub does printf '%s\n' "$@").
_execute_arg() { awk 'p=="-execute"{print; exit} {p=$0}' "$1"; }

# Happy path: a plain pane id yields exactly `<bin> agent focus <pane>`, proving
# the quoting is transparent for benign values (no regression).
test_click_execute_happy_path() {
  CURRENT_TEST="click_execute_happy_path"
  new_temp
  local n; n="$(make_notifier "$T/bin")"
  HERDR_BIN="$(make_herdr "$T/bin")"   # absolute stub path -> command -v returns it as-is
  TN_CONFIG="$T/config.env"
  make_config "$TN_CONFIG" "NOTIFIER=$n" 'TRIGGER_STATUSES="blocked done"' 'SUPPRESS_FOCUSED=0' \
    'ACTIVATE_ON_CLICK=1' 'CLICK_COMMAND="agent focus {pane}"'
  EVENT_JSON='{"data":{"pane_id":"p1","agent_status":"done","agent":"claude","workspace_id":"w1"}}'
  CONTEXT_JSON='{}'
  run_notify
  assert_eq "$REPLY_RC" 0 "exit 0 on happy path"
  if [ -f "$T/bin/notifier-args" ]; then
    local exec_str; exec_str="$(_execute_arg "$T/bin/notifier-args")"
    assert_eq "$exec_str" "$HERDR_BIN agent focus p1" "-execute is '<bin> agent focus <pane>' for a plain pane id"
  else
    fail "notifier must fire on a triggering click event"
  fi
  [ "$FAIL" -eq "$PRE_FAIL" ] && pass
}

# Hostile values: pane_id/agent carrying spaces, ';', '$(...)', quotes must land
# in the -execute string only in %q-escaped form. Proven two ways: (1) the raw
# ';' injection sequence is absent, and (2) an eval round-trip (`set -- $exec`)
# in a sandbox reproduces the EXACT argv words AND does not run the embedded
# `$(touch PWNED)` — i.e. no command substitution escapes the quoting.
test_click_execute_hostile_values() {
  CURRENT_TEST="click_execute_hostile_values"
  new_temp
  local n; n="$(make_notifier "$T/bin")"
  HERDR_BIN="$(make_herdr "$T/bin")"
  TN_CONFIG="$T/config.env"
  local pwn="$T/PWNED"
  local hostile_pane="p1; touch $pwn; \$(touch $pwn) 'q\""
  local hostile_agent="a\$(touch $pwn)b"
  make_config "$TN_CONFIG" "NOTIFIER=$n" 'TRIGGER_STATUSES="blocked done"' 'SUPPRESS_FOCUSED=0' \
    'ACTIVATE_ON_CLICK=1' 'CLICK_COMMAND="agent focus {pane} {agent}"'
  EVENT_JSON="$(jq -nc --arg p "$hostile_pane" --arg a "$hostile_agent" \
    '{data:{pane_id:$p,agent_status:"done",agent:$a,workspace_id:"w1"}}')"
  CONTEXT_JSON='{}'
  run_notify
  assert_eq "$REPLY_RC" 0 "exit 0 on hostile click values"
  local exec_str; exec_str="$(_execute_arg "$T/bin/notifier-args")"
  # No raw injection sequence: the ';' must have been escaped (\;), never bare.
  assert_not_contains "$exec_str" "; touch" "hostile ';' must be %q-escaped, not raw"
  # eval round-trip in a subshell: prove word-for-word argv and no side effects.
  local roundtrip
  roundtrip="$(bash -c 'set -- '"$exec_str"'; printf "%s\n" "$#" "$@"' 2>/dev/null)"
  # Expected argv: bin, agent, focus, <hostile_pane>, <hostile_agent> => 5 words.
  local want; want="$(printf '%s\n' 5 "$HERDR_BIN" agent focus "$hostile_pane" "$hostile_agent")"
  assert_eq "$roundtrip" "$want" "eval round-trip reproduces the exact argv words"
  [ ! -e "$pwn" ] || fail "embedded \$(touch) must NOT execute (quoting failed: PWNED created)"
  [ "$FAIL" -eq "$PRE_FAIL" ] && pass
}

# A herdr binary path containing a space must be handled: %q-escaping the bin
# keeps it a single argv word through the -execute shell re-parse.
test_click_execute_spaced_bin_path() {
  CURRENT_TEST="click_execute_spaced_bin_path"
  new_temp
  local n; n="$(make_notifier "$T/bin")"
  mkdir -p "$T/sp ace"
  HERDR_BIN="$(make_herdr "$T/sp ace")"   # path contains a space
  TN_CONFIG="$T/config.env"
  make_config "$TN_CONFIG" "NOTIFIER=$n" 'TRIGGER_STATUSES="blocked done"' 'SUPPRESS_FOCUSED=0' \
    'ACTIVATE_ON_CLICK=1' 'CLICK_COMMAND="agent focus {pane}"'
  EVENT_JSON='{"data":{"pane_id":"p1","agent_status":"done","agent":"claude","workspace_id":"w1"}}'
  CONTEXT_JSON='{}'
  run_notify
  assert_eq "$REPLY_RC" 0 "exit 0"
  local exec_str; exec_str="$(_execute_arg "$T/bin/notifier-args")"
  local roundtrip
  roundtrip="$(bash -c 'set -- '"$exec_str"'; printf "%s\n" "$#" "$1"')"
  assert_eq "$roundtrip" "$(printf '%s\n' 4 "$HERDR_BIN")" "spaced bin path stays a single argv word"
  [ "$FAIL" -eq "$PRE_FAIL" ] && pass
}

# --- issue #9: a corrupt debounce stamp must degrade to "no debounce" ---------
# A partially written or hand-edited stamp file can hold a non-numeric timestamp.
# The debounce gate compares last_status to new_status first, so a corrupt stamp
# whose status field matches reaches the arithmetic `$((now - last_ts))`; under
# `set -euo pipefail` a non-numeric last_ts aborts the whole handler before any
# notification (silent drop). The fix validates last_ts (falling back to 0), so a
# corrupt stamp degrades to "no debounce" -> the notification fires.
# (Appended at the END to minimize merge conflicts with parallel work.)
test_corrupt_debounce_stamp_still_notifies() {
  CURRENT_TEST="corrupt_debounce_stamp_still_notifies"
  new_temp
  local n; n="$(make_notifier "$T/bin")"
  HERDR_BIN="$(make_herdr "$T/bin")"
  TN_CONFIG="$T/config.env"
  make_config "$TN_CONFIG" "NOTIFIER=$n" 'TRIGGER_STATUSES="blocked done"' 'SUPPRESS_FOCUSED=0' 'DEBOUNCE_SECONDS=60'
  EVENT_JSON='{"data":{"pane_id":"p1","agent_status":"done","agent":"claude","workspace_id":"w1"}}'
  CONTEXT_JSON='{}'
  DEBUG_FLAG=1   # debounce drops are high-volume: logged only under DEBUG
  # Corrupt stamp: non-numeric ts, but the status field MATCHES new_status ("done")
  # so the gate does not short-circuit and the arithmetic is actually reached.
  printf 'garbage done\n' >"$T/state/debounce-p1"
  run_notify
  assert_eq "$REPLY_RC" 0 "exit 0 despite a corrupt debounce stamp (no set -e crash)"
  assert_not_contains "$REPLY_ERR" "drop reason=debounce" "corrupt stamp must not be treated as an active debounce"
  if [ -f "$T/bin/notifier-args" ]; then
    assert_contains "$(cat "$T/bin/notifier-args")" "done" "notification fires (no-debounce degradation) on a corrupt stamp"
  else
    fail "notifier must fire when the debounce stamp is corrupt (degrade to no debounce)"
  fi
  # Leading-zero ts is all-digits but fatal in bash arithmetic as octal ("08");
  # it too must degrade, not crash. (The handler just rewrote a fresh valid stamp
  # above, so overwrite it again with the octal-shaped corruption.)
  printf '08 done\n' >"$T/state/debounce-p1"
  rm -f "$T/bin/notifier-args"
  run_notify
  assert_eq "$REPLY_RC" 0 "exit 0 on a leading-zero (octal-shaped) stamp"
  [ -f "$T/bin/notifier-args" ] || fail "notifier must fire on a leading-zero stamp (no octal crash)"
  # And a genuine fresh stamp must still debounce: the run above wrote a valid
  # numeric stamp, so an immediate repeat within the window is dropped — proving
  # the guard did not disable debounce for well-formed stamps.
  rm -f "$T/bin/notifier-args"
  run_notify
  assert_contains "$REPLY_ERR" "drop reason=debounce" "a valid fresh stamp still debounces a rapid repeat"
  [ ! -f "$T/bin/notifier-args" ] || fail "rapid repeat after a valid stamp must be debounced"
  [ "$FAIL" -eq "$PRE_FAIL" ] && pass
}

# --- issue #10: pick() must survive statuses with non-variable-name chars -----
# A future herdr status can carry a character invalid in a shell variable name
# (e.g. `needs-input`, `waiting.user`). Section 7 builds a variable NAME from the
# status (TITLE_<STATUS> via indirect expansion); a raw hyphen there is a fatal
# bash "bad substitution" that, under set -e, crashes the handler instead of
# falling back to the *_DEFAULT template. Sanitizing the NAME (uppercase then map
# non-[A-Z0-9] to '_') must fix it WITHOUT touching the raw status used for
# TRIGGER matching, {new_status} expansion, or the debounce/laststatus stamps.
# (Appended at the END to minimize merge conflicts with parallel work.)

# A triggering status with a hyphen and NO explicit TITLE_NEEDS_INPUT must not
# crash: the handler exits 0, the notifier fires, and TITLE_DEFAULT is used with
# {new_status} expanded to the RAW `needs-input` (sanitizing is name-only).
test_dashed_status_falls_back_to_default() {
  CURRENT_TEST="dashed_status_falls_back_to_default"
  new_temp
  local n; n="$(make_notifier "$T/bin")"
  HERDR_BIN="$(make_herdr "$T/bin")"
  TN_CONFIG="$T/config.env"
  make_config "$TN_CONFIG" "NOTIFIER=$n" 'TRIGGER_STATUSES="needs-input"' 'SUPPRESS_FOCUSED=0' \
    'ACTIVATE_ON_CLICK=0' 'TITLE_DEFAULT="{agent}: {new_status}"'
  EVENT_JSON='{"event":"pane.agent_status_changed","data":{"pane_id":"p1","agent_status":"needs-input","agent":"claude","workspace_id":"w1"}}'
  CONTEXT_JSON='{}'
  run_notify
  assert_eq "$REPLY_RC" 0 "exit 0 on a hyphenated status (no bad-substitution crash)"
  if [ -f "$T/bin/notifier-args" ]; then
    local args; args="$(cat "$T/bin/notifier-args")"
    assert_contains "$args" "claude: needs-input" "TITLE_DEFAULT used with raw {new_status}=needs-input"
  else
    fail "notifier must fire on a triggering hyphenated status"
  fi
  [ "$FAIL" -eq "$PRE_FAIL" ] && pass
}

# A per-status template keyed by the SANITIZED name (TITLE_NEEDS_INPUT for status
# `needs-input`) must resolve and win over TITLE_DEFAULT.
test_dashed_status_uses_sanitized_template() {
  CURRENT_TEST="dashed_status_uses_sanitized_template"
  new_temp
  local n; n="$(make_notifier "$T/bin")"
  HERDR_BIN="$(make_herdr "$T/bin")"
  TN_CONFIG="$T/config.env"
  make_config "$TN_CONFIG" "NOTIFIER=$n" 'TRIGGER_STATUSES="needs-input"' 'SUPPRESS_FOCUSED=0' \
    'ACTIVATE_ON_CLICK=0' 'TITLE_NEEDS_INPUT="NEEDS {agent} ({new_status})"' 'TITLE_DEFAULT="{agent}: {new_status}"'
  EVENT_JSON='{"event":"pane.agent_status_changed","data":{"pane_id":"p1","agent_status":"needs-input","agent":"claude","workspace_id":"w1"}}'
  CONTEXT_JSON='{}'
  run_notify
  assert_eq "$REPLY_RC" 0 "exit 0 on a hyphenated status with a sanitized-name template"
  if [ -f "$T/bin/notifier-args" ]; then
    local args; args="$(cat "$T/bin/notifier-args")"
    assert_contains "$args" "NEEDS claude (needs-input)" "TITLE_NEEDS_INPUT resolved for status needs-input"
    assert_not_contains "$args" "claude: needs-input" "sanitized-name template wins over TITLE_DEFAULT"
  else
    fail "notifier must fire on a triggering hyphenated status"
  fi
  [ "$FAIL" -eq "$PRE_FAIL" ] && pass
}

# --- run ---------------------------------------------------------------------
for t in \
  test_trigger_drop \
  test_focused_drop \
  test_debounce_drop \
  test_nostatus_drop \
  test_jq_missing \
  test_notifier_stderr_captured \
  test_happy_path \
  test_debug_dump \
  test_missing_pane_id_loud_drop \
  test_missing_status_enriched_via_pane_field \
  test_workspace_id_via_pane_field_not_ctx \
  test_focus_terminal_frontmost_drop \
  test_focus_other_app_notify \
  test_focus_lsappinfo_missing_notify \
  test_focus_lsappinfo_garbage_notify \
  test_focus_suppress_disabled_notify \
  test_nontrigger_zero_cli \
  test_trigger_enriches_session \
  test_old_status_tracked_across_nontrigger \
  test_env_notifier_override_honored \
  test_config_beats_env_for_same_key \
  test_env_only_override_beats_builtin_default \
  test_click_execute_happy_path \
  test_click_execute_hostile_values \
  test_click_execute_spaced_bin_path \
  test_corrupt_debounce_stamp_still_notifies \
  test_dashed_status_falls_back_to_default \
  test_dashed_status_uses_sanitized_template; do
  PRE_FAIL="$FAIL"
  "$t"
done

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
  printf 'Failures:\n'; printf '  - %s\n' "${FAILED_NAMES[@]}"
  exit 1
fi
