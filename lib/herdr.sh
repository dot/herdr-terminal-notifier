#!/usr/bin/env bash
# Helpers that talk back to herdr through $HERDR_BIN_PATH and parse the
# JSON-over-socket responses with jq. All helpers are best-effort: a failure
# (server down, unknown id) yields empty output, never a non-zero exit.

HERDR_BIN="${HERDR_BIN_PATH:-herdr}"

# pane_field <pane_id> <jq_path_under_.result.pane>
# e.g. pane_field wC:p1 '.agent'  -> claude
pane_field() {
  local pane_id="$1" path="$2"
  [ -n "$pane_id" ] || return 0
  "$HERDR_BIN" pane get "$pane_id" 2>/dev/null \
    | jq -r "(.result.pane${path}) // empty" 2>/dev/null || true
}

# workspace_label <workspace_id> -> human label (falls back to the id)
workspace_label() {
  local ws="$1" label
  [ -n "$ws" ] || return 0
  label="$("$HERDR_BIN" workspace get "$ws" 2>/dev/null \
    | jq -r '(.result.workspace.label) // empty' 2>/dev/null || true)"
  [ -n "$label" ] && printf '%s' "$label" || printf '%s' "$ws"
}

# tab_label <tab_id> -> human label (falls back to the id). Mirrors
# workspace_label; used for the {tab_label} template placeholder so a
# notification can show a renamed tab (e.g. a synced agent session name)
# instead of the structural tab id.
tab_label() {
  local t="$1" label
  [ -n "$t" ] || return 0
  label="$("$HERDR_BIN" tab get "$t" 2>/dev/null \
    | jq -r '(.result.tab.label) // empty' 2>/dev/null || true)"
  [ -n "$label" ] && printf '%s' "$label" || printf '%s' "$t"
}

# focused_workspace_id -> the workspace the user is currently looking at
focused_workspace_id() {
  "$HERDR_BIN" workspace list 2>/dev/null \
    | jq -r 'first(.result.workspaces[] | select(.focused == true) | .workspace_id) // empty' 2>/dev/null \
    || true
}
