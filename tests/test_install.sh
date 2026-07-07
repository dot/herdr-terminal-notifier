#!/usr/bin/env bash
# Tests for scripts/install.sh — the declarative install/update entry point.
#
# Rationale (issue #12): the old already-installed guard used `grep -q "$PLUGIN_ID"`,
# where the '.' in "dot.terminal-notifier" is a regex wildcard, and its early exit
# gave declarative re-runs no way to apply a version bump. We assert:
#   (a) already-installed + no flag  -> NO `plugin install` call (idempotent no-op)
#   (b) already-installed + --force  -> `plugin install` IS called (update path)
#   (c) not installed                -> `plugin install` IS called
#
# A fake `herdr` (pointed at via HERDR_BIN_PATH) records its argv and answers
# `plugin list` from a fixture, so we assert on the observable side effect: did
# install.sh reach `herdr plugin install`?
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL="$ROOT/scripts/install.sh"
PLUGIN_ID="dot.terminal-notifier"

PASS=0 FAIL=0
FAILED_NAMES=()
fail() { FAIL=$((FAIL + 1)); FAILED_NAMES+=("$CURRENT: $1"); printf 'FAIL %s: %s\n' "$CURRENT" "$1"; }
pass() { PASS=$((PASS + 1)); printf 'ok   %s\n' "$CURRENT"; }

# make_herdr <dir> <installed|absent>
# Writes a fake herdr that logs argv to <dir>/herdr-calls and answers
# `plugin list` either with the real installed-line format or an empty list.
make_herdr() {
  local dir="$1" state="$2"
  local f="$dir/herdr" listing
  if [ "$state" = installed ]; then
    listing="1 plugin installed:
- $PLUGIN_ID (terminal-notifier notifications) enabled [github:dot/herdr-terminal-notifier@abc1234]"
  else
    listing="0 plugins installed."
  fi
  {
    printf '#!/usr/bin/env bash\n'
    # shellcheck disable=SC2016  # writing literal shell into the stub, not expanding here
    printf 'printf "%%s\\n" "$*" >>%q\n' "$dir/herdr-calls"
    # shellcheck disable=SC2016
    printf 'if [ "$1 $2" = "plugin list" ]; then printf "%%s\\n" %q; exit 0; fi\n' "$listing"
    printf 'exit 0\n'
  } >"$f"
  chmod +x "$f"
  printf '%s' "$f"
}

# run_install <herdr_state> [install.sh args...] -> sets OUT/RC, herdr-calls in $T
run_install() {
  local state="$1"; shift
  T="$(mktemp -d "${TMPDIR:-/tmp}/tn-install.XXXXXX")"
  TEMPS+=("$T")
  local herdr; herdr="$(make_herdr "$T" "$state")"
  OUT="$(HERDR_BIN_PATH="$herdr" bash "$INSTALL" "$@" 2>&1)"; RC=$?
  CALLS="$(cat "$T/herdr-calls" 2>/dev/null || true)"
}

installed_install_call() { case "$CALLS" in *"plugin install"*) return 0 ;; *) return 1 ;; esac; }

TEMPS=()
cleanup() { local d; for d in "${TEMPS[@]:-}"; do [ -n "$d" ] && rm -rf "$d"; done; }
trap cleanup EXIT

# (a) already installed, no flag -> no-op, no install call ----------------------
CURRENT="installed_no_flag_is_noop"
run_install installed
if [ "$RC" -ne 0 ]; then fail "expected exit 0, got $RC"
elif installed_install_call; then fail "must NOT call 'plugin install' when already installed"
else pass; fi

# (b) already installed, --force -> install call happens ------------------------
CURRENT="installed_force_reinstalls"
run_install installed --force
if [ "$RC" -ne 0 ]; then fail "expected exit 0, got $RC: $OUT"
elif installed_install_call; then pass
else fail "--force must re-run 'plugin install' even when already installed"; fi

# (c) not installed -> install call happens -------------------------------------
CURRENT="not_installed_installs"
run_install absent
if [ "$RC" -ne 0 ]; then fail "expected exit 0, got $RC: $OUT"
elif installed_install_call; then pass
else fail "must call 'plugin install' when not installed"; fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then printf 'Failures:\n'; printf '  - %s\n' "${FAILED_NAMES[@]}"; exit 1; fi
