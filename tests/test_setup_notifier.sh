#!/usr/bin/env bash
# Tests for the verify-gated ad-hoc signing in scripts/setup-notifier.sh.
#
# Rationale (issue #4): ad-hoc re-signing mints a fresh CDHash each time, which
# changes the app identity macOS keys the notification (TCC) grant to. We must
# re-sign ONLY when the existing signature is invalid, so a valid signature (and
# its grant) survives repeated `plugin install` runs. A FAILED signing must be
# reported as such, never as a successful re-sign.
#
# Operates on a throwaway copy of the bundle — never the checked-in one.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC_APP="$ROOT/assets/HerdrNotify.app"
SETUP="$ROOT/scripts/setup-notifier.sh"

# shellcheck source=scripts/setup-notifier.sh
. "$SETUP"

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

# --- Case 1: valid signature -> signature_valid true, no re-sign needed -------
codesign --force --deep -s - "$APP" >/dev/null 2>&1
before="$(cdhash "$APP")"
[ -n "$before" ] || { echo "setup failed: could not sign temp copy" >&2; exit 1; }

if signature_valid "$APP"; then
  ok "valid signature: signature_valid returns true"
else
  nok "valid signature: signature_valid unexpectedly false"
fi
after="$(cdhash "$APP")"
if [ "$before" = "$after" ]; then
  ok "valid signature: CDHash unchanged ($before)"
else
  nok "valid signature: CDHash changed $before -> $after"
fi

# --- Case 2: broken/absent signature -> adhoc_sign repairs it -----------------
codesign --remove-signature "$APP" >/dev/null 2>&1 || true
if signature_valid "$APP"; then
  echo "SKIP case 2: signature could not be invalidated on this platform" >&2
else
  ok "invalid signature: signature_valid returns false"
  if adhoc_sign "$APP"; then
    ok "invalid signature: adhoc_sign succeeds (returns 0)"
  else
    nok "invalid signature: adhoc_sign unexpectedly failed"
  fi
  if signature_valid "$APP"; then
    ok "invalid signature: app is valid again after re-sign"
  else
    nok "invalid signature: app still invalid after re-sign"
  fi
fi

# --- Case 3: codesign failure -> reported as FAILED, never as re-signed -------
# Run the script end-to-end with a fake codesign (verify fails, sign fails) and
# a stub lsregister injected via PATH/LSREGISTER.
FAKEBIN="$TMP/fakebin"
mkdir -p "$FAKEBIN"
cat >"$FAKEBIN/codesign" <<'FAKE'
#!/usr/bin/env bash
# verify fails (signature invalid), signing fails too
exit 1
FAKE
cat >"$FAKEBIN/lsregister" <<'FAKE'
#!/usr/bin/env bash
exit 0
FAKE
chmod +x "$FAKEBIN/codesign" "$FAKEBIN/lsregister"

rc=0
out="$(PATH="$FAKEBIN:$PATH" LSREGISTER="$FAKEBIN/lsregister" bash "$SETUP" 2>&1)" || rc=$?
if [ "$rc" -eq 0 ]; then
  ok "sign failure: script stays best-effort (exit 0)"
else
  nok "sign failure: script exited $rc"
fi
if printf '%s' "$out" | grep -q "codesign FAILED"; then
  ok "sign failure: failure is logged distinctly (codesign FAILED)"
else
  nok "sign failure: no 'codesign FAILED' in output: $out"
fi
if printf '%s' "$out" | grep -q "re-signed"; then
  nok "sign failure: output falsely claims 're-signed': $out"
else
  ok "sign failure: does not claim a successful re-sign"
fi

echo "----"
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
