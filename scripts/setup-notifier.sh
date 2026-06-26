#!/usr/bin/env bash
# Ad-hoc re-sign and register the bundled HerdrNotify.app with Launch Services
# so macOS attributes notifications (and the herdr icon) to it.
#
# Runs as a herdr plugin [[build]] step on `herdr plugin install`, and is also
# safe to run by hand or from scripts/install.sh. Idempotent.
#
# Note: the one-time "Allow notifications" grant (System Settings -> Notifications
# -> herdr) cannot be scripted; the first notification will request it.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/assets/HerdrNotify.app"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

[ -d "$APP" ] || { echo "bundled notifier missing: $APP" >&2; exit 0; }

codesign --force --deep -s - "$APP" >/dev/null 2>&1 || true
[ -x "$LSREGISTER" ] && "$LSREGISTER" -f "$APP" >/dev/null 2>&1 || true
echo "registered notifier: $APP"
