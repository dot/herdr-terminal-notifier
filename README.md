# herdr-terminal-notifier

Customizable macOS notifications for [herdr](https://herdr.dev) agent state
changes — with a **custom herdr app icon**, templated messages, and click-to-jump.

When an agent in any workspace becomes **blocked** (waiting for your input) or
**done**, you get a native notification whose **left icon is the herdr logo**
(not the generic terminal icon), and clicking it jumps straight to that pane.

```
🐑  ⏳ claude が入力待ち
    my-project · feature-x          [表示]
```

## Why the bundled notifier app

The left icon of a macOS notification is the icon of the **app that posts it**.
The usual tricks don't help on modern macOS:

- `terminal-notifier -appIcon` is ignored (you get terminal-notifier's terminal icon).
- `terminal-notifier -sender <bundleid>` (borrow another app's icon) **hangs** on macOS 26.
- `osascript -e 'display notification …'` always shows the **Script Editor** icon and
  supports no icon/sound/click customization at all.

So this plugin ships **`assets/HerdrNotify.app`** — a copy of `terminal-notifier`
rebranded with the herdr icon and its own bundle id (`com.dot.herdr-notify`). The
plugin posts through it, so the notification is genuinely "from herdr" and shows
the herdr logo. No Homebrew `terminal-notifier` needed at runtime.

## Requirements

- macOS (tested on macOS 26).
- `jq` — the only runtime dependency. Declare it in your `homebrew.nix` / `Brewfile`:

  ```sh
  brew install jq
  ```

First notification: macOS asks once to allow notifications for **herdr** (System
Settings → Notifications). This per-machine grant can't be scripted.

## Install

```sh
herdr plugin install dot/herdr-terminal-notifier      # GitHub
# or, for local dev:
herdr plugin link /path/to/herdr-terminal-notifier
```

Or the idempotent helper (safe to re-run):

```sh
scripts/install.sh            # install from GitHub
scripts/install.sh --link     # link this checkout + register the notifier app
```

Install registers `HerdrNotify.app` with Launch Services (re-sign + `lsregister`).
On `herdr plugin install` this happens via the manifest `[[build]]` step; on
`link` the handler also self-registers on first event.

### Avoid double notifications

herdr has its own built-in desktop toast. Turn it off (or to in-terminal) so only
this plugin posts to the desktop — in `~/.config/herdr/config.toml`:

```toml
[ui.toast]
delivery = "terminal"   # was "system"; "terminal" shows an in-app toast instead
```

## Configuration

All settings are optional. Resolution order (later wins):

1. built-in defaults
2. `$HERDR_PLUGIN_CONFIG_DIR/config.env` (herdr-managed, per machine)
3. **`$HERDR_TN_CONFIG`** — a file you point at, ideal for dotfiles

Copy [`config/config.example.env`](config/config.example.env) into your dotfiles
and point at it from your shell profile:

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
| `NOTIFIER` | _(bundled app)_ | absolute path to override the notifier binary |
| `ICON_MODE` | `contentImage` | right-side image mode (`contentImage`/`appIcon`) |
| `TITLE_<STATUS>` / `BODY_<STATUS>` | see example | message templates |
| `ICON_<STATUS>` / `SOUND_<STATUS>` | see example | right-side image / macOS sound |

Template placeholders: `{agent}` `{workspace}` `{worktree}` `{tab}` `{pane}`
`{session}` `{old_status}` `{new_status}` `{cwd}`. `<STATUS>` is the upper-cased
status (`BLOCKED`, `DONE`, …); `*_DEFAULT` covers the rest.

The **left** icon is always the herdr logo (the notifier app). `ICON_*` controls
the optional **right-side** status image.

## Customizing the herdr icon

The icon source lives in `assets/` (`herdr-logo.svg` → rounded `herdr-rounded.svg`
→ `herdr.icns`). To use your own:

```sh
# render any 1024×1024 PNG, then:
sips -s format icns your.png --out assets/HerdrNotify.app/Contents/Resources/Terminal.icns
bash scripts/setup-notifier.sh        # re-sign + re-register
```

## Cross-machine / declarative management (nix · chezmoi)

- **Self-contained**: the notifier app is bundled, so the only external dep is `jq`.
- **Config source of truth in dotfiles** via `HERDR_TN_CONFIG` (never hand-edit
  herdr's per-machine config dir, which an apply would revert).
- **Install convergence**: call `scripts/install.sh` from a chezmoi `run_onchange_*`
  script or a nix-darwin `activationScript`; it installs/links only when absent and
  registers the notifier app.

## Notes & caveats

- `SOUND_*` uses **macOS system sound names** (`Glass`, `Hero`, `Ping`, …).
- Set `DEBUG=1` to dump the raw event/context JSON to
  `$HERDR_PLUGIN_STATE_DIR/last-event.json` (handy after a herdr upgrade).
- The bundled notifier is a copy of [`terminal-notifier`](https://github.com/julienXX/terminal-notifier)
  (MIT, see `assets/HerdrNotify.app.LICENSE.md`).

## Ideas / roadmap (not yet implemented)

- **Inline reply** — answer a blocked agent from the notification
  (`terminal-notifier -reply` → `herdr agent send`).
- **Per-status app icons** (separate notifier apps) for a colored left icon.
- **Allow/deny filters** by workspace or agent name; quiet hours / DND.

## License

MIT
