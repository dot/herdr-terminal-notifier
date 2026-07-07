#!/usr/bin/env bash
# Regression tests for the register/self-heal block in bin/notify.sh (issue #4).
#
# Uses a sandbox copy of bin/ + lib/ with a fake minimal app bundle, a fake
# `codesign` injected via PATH (driven by control files), and a stub lsregister
# injected via LSREGISTER — the checked-in bundle and the real LS database are
# never touched. notify.sh exits right after the register block because the
# event carries no status ("no status in event").
#
# Covered:
#   * valid signature        -> registered, but NO --force re-sign
#   * fresh sentinel         -> no codesign invocations at all
#   * invalid sig, sign OK   -> exactly one --force + "re-signed" hint log
#   * invalid sig, sign FAIL -> "codesign FAILED" logged, no "re-signed" claim,
#                               no per-event retry, retry after TTL expiry
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

pass=0 fail=0
ok()  { printf 'ok   - %s\n' "$1"; pass=$((pass + 1)); }
nok() { printf 'FAIL - %s\n' "$1"; fail=$((fail + 1)); }
assert() { # assert MSG CMD [ARGS...] — pass when CMD succeeds
  local msg="$1"; shift
  if "$@"; then ok "$msg"; else nok "$msg"; fi
}
not() { ! "$@"; }
err_has() { printf '%s' "$ERR" | grep -q "$1"; }

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq unavailable" >&2; exit 0; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# --- sandbox plugin tree (fake app so the real bundle is never signed) --------
SANDBOX="$TMP/plugin"
mkdir -p "$SANDBOX"
cp -R "$ROOT/bin" "$ROOT/lib" "$SANDBOX/"
mkdir -p "$SANDBOX/assets/HerdrNotify.app/Contents/MacOS"
printf '#!/usr/bin/env bash\nexit 0\n' >"$SANDBOX/assets/HerdrNotify.app/Contents/MacOS/terminal-notifier"
chmod +x "$SANDBOX/assets/HerdrNotify.app/Contents/MacOS/terminal-notifier"

# --- fakes ---------------------------------------------------------------------
CTRL="$TMP/ctrl"
FAKEBIN="$TMP/fakebin"
mkdir -p "$CTRL" "$FAKEBIN"

cat >"$FAKEBIN/codesign" <<'FAKE'
#!/usr/bin/env bash
echo "$*" >>"$CODESIGN_CTRL/calls"
case "$1" in
  --verify) exit "$(cat "$CODESIGN_CTRL/verify_rc")" ;;
  --force)  rc="$(cat "$CODESIGN_CTRL/sign_rc")"
            # a successful signing repairs the signature
            [ "$rc" -eq 0 ] && echo 0 >"$CODESIGN_CTRL/verify_rc"
            exit "$rc" ;;
esac
exit 0
FAKE
cat >"$FAKEBIN/lsregister" <<'FAKE'
#!/usr/bin/env bash
echo "$*" >>"$CODESIGN_CTRL/ls_calls"
exit 0
FAKE
chmod +x "$FAKEBIN/codesign" "$FAKEBIN/lsregister"

STATE="$TMP/state"
TTL0_CONF="$TMP/ttl0.env"
echo 'REGISTER_TTL_SECONDS=0' >"$TTL0_CONF"

reset_state() { rm -rf "$STATE"; : >"$CTRL/calls"; : >"$CTRL/ls_calls"; }

run_notify() { # run_notify [extra VAR=val ...] -> stderr captured in $ERR
  local rc=0
  ERR="$(env -i PATH="$FAKEBIN:/usr/bin:/bin:/usr/sbin:/sbin:$(dirname "$(command -v jq)")" \
    HOME="$TMP" CODESIGN_CTRL="$CTRL" LSREGISTER="$FAKEBIN/lsregister" \
    HERDR_PLUGIN_STATE_DIR="$STATE" HERDR_BIN_PATH=/usr/bin/false \
    HERDR_PLUGIN_EVENT_JSON='{}' HERDR_PLUGIN_CONTEXT_JSON='{}' \
    "$@" bash "$SANDBOX/bin/notify.sh" 2>&1 >/dev/null)" || rc=$?
  return "$rc"
}

force_count() { grep -c -- '--force' "$CTRL/calls" || true; }
codesign_calls() { wc -l <"$CTRL/calls" | tr -d ' '; }
sentinel="$STATE/.notifier-registered"

# --- Case A: valid signature -> register without re-signing -------------------
reset_state
echo 0 >"$CTRL/verify_rc"; echo 0 >"$CTRL/sign_rc"
run_notify || nok "case A: notify.sh exited non-zero: $ERR"
assert "A: valid sig -> no --force re-sign" test "$(force_count)" -eq 0
assert "A: signature was verified" grep -q -- '--verify' "$CTRL/calls"
assert "A: lsregister invoked" test -s "$CTRL/ls_calls"
assert "A: sentinel created" test -f "$sentinel"

# --- Case B: fresh sentinel -> no codesign activity at all --------------------
: >"$CTRL/calls"
run_notify || nok "case B: notify.sh exited non-zero: $ERR"
assert "B: fresh sentinel -> zero codesign calls" test "$(codesign_calls)" -eq 0

# --- Case C: invalid signature, signing succeeds ------------------------------
reset_state
echo 1 >"$CTRL/verify_rc"; echo 0 >"$CTRL/sign_rc"
run_notify || nok "case C: notify.sh exited non-zero: $ERR"
assert "C: invalid sig -> exactly one --force" test "$(force_count)" -eq 1
assert "C: re-sign is logged" err_has 're-signed'
assert "C: hint names \"herdr\" (CFBundleName)" err_has '"herdr"'

# --- Case D: invalid signature, signing FAILS ----------------------------------
reset_state
echo 1 >"$CTRL/verify_rc"; echo 1 >"$CTRL/sign_rc"
run_notify || nok "case D: notify.sh exited non-zero: $ERR"
assert "D: failure logged distinctly (codesign FAILED)" err_has 'codesign FAILED'
assert "D: does not claim a re-sign" not err_has 're-signed'
assert "D: sentinel still written (bounded retry, no per-event loop)" test -f "$sentinel"

# D2: immediate rerun (sentinel fresh, default TTL) -> no per-event retry
: >"$CTRL/calls"
run_notify || nok "case D2: notify.sh exited non-zero: $ERR"
assert "D2: no retry while sentinel is fresh" test "$(codesign_calls)" -eq 0

# D3: TTL expired (REGISTER_TTL_SECONDS=0 via HERDR_TN_CONFIG) -> retry happens
: >"$CTRL/calls"
run_notify HERDR_TN_CONFIG="$TTL0_CONF" || nok "case D3: notify.sh exited non-zero: $ERR"
assert "D3: failed sign retried after TTL expiry" test "$(force_count)" -ge 1
assert "D3: retry failure logged again" err_has 'codesign FAILED'

echo "----"
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
