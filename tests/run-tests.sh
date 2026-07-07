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
#     fail with a chosen stderr message). Injected via NOTIFIER= inside a
#     HERDR_TN_CONFIG file, because config.sh clobbers the NOTIFIER env var.
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
  TN_CONFIG="$T/config.env"
  make_config "$TN_CONFIG" "NOTIFIER=$n" 'TRIGGER_STATUSES="blocked done"' 'SUPPRESS_FOCUSED=1'
  EVENT_JSON='{"data":{"pane_id":"p1","agent_status":"done","agent":"claude","workspace_id":"w1"}}'
  CONTEXT_JSON='{}'
  DEBUG_FLAG=1   # focused drops are high-volume: logged only under DEBUG
  run_notify
  assert_eq "$REPLY_RC" 0 "exit 0 on focused suppression"
  assert_contains "$REPLY_ERR" "drop reason=focused" "logs focused drop reason"
  assert_contains "$REPLY_ERR" "w1" "focused drop names workspace"
  [ ! -f "$T/bin/notifier-args" ] || fail "notifier must not fire when focused"
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

# --- run ---------------------------------------------------------------------
for t in \
  test_trigger_drop \
  test_focused_drop \
  test_debounce_drop \
  test_nostatus_drop \
  test_jq_missing \
  test_notifier_stderr_captured \
  test_happy_path \
  test_debug_dump; do
  PRE_FAIL="$FAIL"
  "$t"
done

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
  printf 'Failures:\n'; printf '  - %s\n' "${FAILED_NAMES[@]}"
  exit 1
fi
