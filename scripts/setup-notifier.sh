#!/usr/bin/env bash
# Register the bundled HerdrNotify.app with Launch Services so macOS attributes
# notifications (and the herdr icon) to it, re-signing ad-hoc only when needed.
#
# Runs as a herdr plugin [[build]] step on `herdr plugin install`, and is also
# safe to run by hand or from scripts/install.sh. Idempotent.
#
# Ad-hoc signatures get a fresh CDHash on every signing, which changes the app
# identity macOS keys the notification (TCC) grant to — a needless re-sign can
# drop the "Allow notifications" grant. So we re-sign only when the existing
# signature is missing/invalid; a valid signature is left untouched.
#
# Note: the one-time "Allow notifications" grant (System Settings -> Notifications
# -> herdr) cannot be scripted; the first notification will request it.
set -euo pipefail

# ensure_adhoc_signed APP
# Ad-hoc re-signs APP only if its current signature is absent or invalid.
# Returns 0 if it re-signed, 1 if the existing signature was already valid
# (no-op). Factored out so tests can exercise the decision in isolation.
ensure_adhoc_signed() {
  local app="$1"
  if codesign --verify --deep "$app" >/dev/null 2>&1; then
    return 1
  fi
  codesign --force --deep -s - "$app" >/dev/null 2>&1 || true
  return 0
}

main() {
  local root app lsregister
  root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  app="$root/assets/HerdrNotify.app"
  lsregister="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

  [ -d "$app" ] || { echo "bundled notifier missing: $app" >&2; exit 0; }

  if ensure_adhoc_signed "$app"; then
    echo "re-signed notifier (ad-hoc): $app"
    echo "  note: a re-sign can reset the Notifications grant — if desktop toasts" >&2
    echo "  stop, re-approve HerdrNotify in System Settings -> Notifications." >&2
  fi
  [ -x "$lsregister" ] && "$lsregister" -f "$app" >/dev/null 2>&1 || true
  echo "registered notifier: $app"
}

# Run the flow only when executed directly, not when sourced by tests.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
fi
