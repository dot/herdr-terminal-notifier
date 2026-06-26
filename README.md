# herdr-terminal-notifier

Customizable macOS notifications for [herdr](https://herdr.dev) agent state
changes, delivered through
[`terminal-notifier`](https://github.com/julienXX/terminal-notifier).

When an agent in any workspace becomes **blocked** (waiting for your input) or
**done**, you get a native notification with a custom icon and message — and
clicking it jumps straight to that agent's pane.

```
⏳ claude が入力待ち
my-project · feature-x
```

## Features

- **Custom icons** per status (`-contentImage`, ships amber/green/blue samples).
- **Custom message templates** with placeholders: `{agent}` `{workspace}`
  `{worktree}` `{tab}` `{pane}` `{session}` `{old_status}` `{new_status}` `{cwd}`.
- **Click to jump** to the agent that changed (`herdr agent focus`).
- **Per-status sounds** (macOS system sound names, e.g. `Glass`, `Hero`).
- **Focus suppression** — stay quiet for the workspace you are already looking at.
- **Debounce + group replacement** — flap guard, and one rolling notification per pane.

## Requirements

Declare these in your `homebrew.nix` / `Brewfile` (the plugin never installs them):

```sh
brew install terminal-notifier jq
```

Grant `terminal-notifier` permission to post notifications on first run
(System Settings → Notifications).

## Install

From GitHub:

```sh
herdr plugin install dot/herdr-terminal-notifier
```

Local development:

```sh
herdr plugin link /path/to/herdr-terminal-notifier
```

Or use the idempotent helper (safe to re-run; no-op once registered):

```sh
scripts/install.sh            # install from GitHub
scripts/install.sh --link     # link this checkout
```

## Configuration

All settings are optional. Resolution order (later wins):

1. built-in defaults
2. `$HERDR_PLUGIN_CONFIG_DIR/config.env` (herdr-managed, per machine)
3. **`$HERDR_TN_CONFIG`** — a file you point at, ideal for dotfiles

Copy [`config/config.example.env`](config/config.example.env) somewhere your
dotfiles own and point at it from your shell profile:

```sh
export HERDR_TN_CONFIG="$HOME/.config/herdr-terminal-notifier/config.env"
```

Key settings:

| Key | Default | Meaning |
| --- | --- | --- |
| `TRIGGER_STATUSES` | `"blocked done"` | which new statuses notify |
| `SUPPRESS_FOCUSED` | `1` | mute the workspace you are viewing |
| `DEBOUNCE_SECONDS` | `2` | drop repeated `(pane,status)` within window |
| `ACTIVATE_ON_CLICK` | `1` | click notification → focus the agent |
| `CLICK_COMMAND` | `agent focus {pane}` | `herdr` subcommand run on click |
| `ICON_MODE` | `contentImage` | `contentImage` or `appIcon` |
| `TITLE_<STATUS>` / `BODY_<STATUS>` | see example | message templates |
| `ICON_<STATUS>` / `SOUND_<STATUS>` | see example | icon path / macOS sound |

`<STATUS>` is the upper-cased status (`BLOCKED`, `DONE`, …); `*_DEFAULT` covers
the rest.

## Cross-machine / declarative management (nix · chezmoi)

- **Config source of truth in dotfiles** via `HERDR_TN_CONFIG`, so you never
  hand-edit herdr's per-machine config dir (which an apply would revert).
- **Deps declared** in `homebrew.nix` / `Brewfile`.
- **Install convergence**: call `scripts/install.sh` from a chezmoi
  `run_onchange_*` script or a nix-darwin `activationScript`. It checks
  `herdr plugin list` and installs/links only when absent.

## Notes & caveats

- On recent macOS the notification's **app icon is locked to terminal-notifier**,
  so `-appIcon` is often ignored. `ICON_MODE=contentImage` (the default) shows
  your image reliably on the right side of the notification.
- `SOUND_*` uses **macOS system sound names** (`Glass`, `Hero`, `Ping`, …),
  which are unrelated to herdr's own `none`/`done`/`request` sounds.
- Set `DEBUG=1` to dump the raw event/context JSON to
  `$HERDR_PLUGIN_STATE_DIR/last-event.json` (handy after a herdr upgrade).

## Ideas / roadmap (not yet implemented)

- **Inline reply** — answer a blocked agent straight from the notification
  (`terminal-notifier -reply` → `herdr agent send`).
- **Allow/deny filters** by workspace or agent name.
- **Quiet hours / Do Not Disturb** and a "working too long" watchdog.

## License

MIT
