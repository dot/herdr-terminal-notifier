#!/usr/bin/env bash
# Tests for the verify-gated ad-hoc signing decision in scripts/setup-notifier.sh.
#
# Rationale (issue #4): ad-hoc re-signing mints a fresh CDHash each time, which
# changes the app identity macOS keys the notification (TCC) grant to. We must
# re-sign ONLY when the existing signature is invalid, so a valid signature (and
# its grant) survives repeated `plugin install` runs.
#
# Operates on a throwaway copy of the bundle — never the checked-in one.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC_APP="$ROOT/assets/HerdrNotify.app"

# shellcheck source=../scripts/setup-notifier.sh
. "$ROOT/scripts/setup-notifier.sh"

pass=0 fail=0
ok()   { printf 'ok   - %s\n' "$1"; pass=$((pass + 1)); }
nok()  { printf 'FAIL - %s\n' "$1"; fail=$((fail + 1)); }

if ! command -v codesign >/dev/null 2>&1; then
  echo "SKIP: codesign unavailable (not macOS?)" >&2
  exit 0
fi
[ -d "$SRC_APP" ] || { echo "SKIP: bundled app missing: $SRC_APP" >&2; exit 0; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
APP="$TMP/HerdrNotify.app"
cp -R "$SRC_APP" "$APP"

cdhash() { # print the app's ad-hoc CDHash, or empty if unsigned/invalid
  codesign -dvvv "$1" 2>&1 | sed -n 's/^CDHash=//p'
}

# --- Case 1: valid signature -> ensure_adhoc_signed is a no-op ----------------
codesign --force --deep -s - "$APP" >/dev/null 2>&1
before="$(cdhash "$APP")"
[ -n "$before" ] || { echo "setup failed: could not sign temp copy" >&2; exit 1; }

if ensure_adhoc_signed "$APP"; then
  nok "valid signature: expected skip (return 1) but it re-signed"
else
  ok "valid signature: returns non-zero (no re-sign)"
fi
after="$(cdhash "$APP")"
if [ "$before" = "$after" ]; then
  ok "valid signature: CDHash unchanged ($before)"
else
  nok "valid signature: CDHash changed $before -> $after"
fi

# --- Case 2: broken/absent signature -> ensure_adhoc_signed re-signs ----------
# Remove the signature so --verify fails.
codesign --remove-signature "$APP" >/dev/null 2>&1 || true
if codesign --verify --deep "$APP" >/dev/null 2>&1; then
  echo "SKIP case 2: signature could not be invalidated on this platform" >&2
else
  if ensure_adhoc_signed "$APP"; then
    ok "invalid signature: returns zero (re-signed)"
  else
    nok "invalid signature: expected re-sign (return 0) but it skipped"
  fi
  if codesign --verify --deep "$APP" >/dev/null 2>&1; then
    ok "invalid signature: app is valid again after re-sign"
  else
    nok "invalid signature: app still invalid after re-sign"
  fi
fi

echo "----"
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
