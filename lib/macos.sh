#!/usr/bin/env bash
# Helpers that query the macOS window server / Launch Services (not herdr).
# All helpers are best-effort and FAIL OPEN: any failure (tool missing,
# unparsable output, empty result) yields empty output and never a non-zero
# exit, so a detection failure can only ever cause a *missed suppression*
# (a duplicate notification), never a crash or a silently swallowed event.

# frontmost_bundle_id -> the bundle id of the frontmost macOS app, or empty.
#
# Uses `lsappinfo`, which reads the current front application from the window
# server WITHOUT needing a TCC/Automation grant (unlike `osascript`, which
# would prompt for "control Terminal"). `lsappinfo front` prints an ASN token;
# `lsappinfo info -only bundleid <asn>` then prints one line shaped like:
#   "CFBundleIdentifier"="com.mitchellh.ghostty"
# We extract the value inside the *second* quoted field. Anything unexpected
# (no lsappinfo, empty ASN, a line with no quoted value) collapses to empty.
frontmost_bundle_id() {
  command -v lsappinfo >/dev/null 2>&1 || return 0
  local asn out
  asn="$(lsappinfo front 2>/dev/null || true)"
  [ -n "$asn" ] || return 0
  out="$(lsappinfo info -only bundleid "$asn" 2>/dev/null || true)"
  # Grab the value inside `="..."`; print nothing if the pattern is absent.
  printf '%s' "$out" | sed -n 's/.*=[[:space:]]*"\([^"]*\)".*/\1/p'
}
