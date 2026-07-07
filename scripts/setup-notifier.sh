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

# signature_valid APP — true if APP carries a valid (deep) code signature.
signature_valid() {
  codesign --verify --deep "$1" >/dev/null 2>&1
}

# adhoc_sign APP — ad-hoc re-sign APP; propagates codesign's exit status so a
# failed signing is never mistaken for a successful one.
adhoc_sign() {
  codesign --force --deep -s - "$1" >/dev/null 2>&1
}

main() {
  local root app lsregister
  root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  app="$root/assets/HerdrNotify.app"
  # Overridable so tests can inject a stub.
  lsregister="${LSREGISTER:-/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister}"

  [ -d "$app" ] || { echo "bundled notifier missing: $app" >&2; exit 0; }

  if ! signature_valid "$app"; then
    if adhoc_sign "$app"; then
      echo "re-signed notifier (ad-hoc): $app"
      echo "  note: a re-sign can reset the Notifications grant — if desktop toasts" >&2
      echo "  stop, re-approve \"herdr\" in System Settings -> Notifications." >&2
    else
      # Registration is still attempted; the plugin self-heals on a TTL at
      # notify time, so this build step stays best-effort (exit 0).
      echo "codesign FAILED for $app — signature is still invalid" >&2
    fi
  fi
  [ -x "$lsregister" ] && "$lsregister" -f "$app" >/dev/null 2>&1 || true
  echo "registered notifier: $app"
}

# Run the flow only when executed directly, not when sourced by tests.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
fi
