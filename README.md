# herdr-terminal-notifier

Customizable macOS notifications for [herdr](https://herdr.dev) agent state
changes — with a **custom herdr app icon**, templated messages, and click-to-jump.

When an agent in any workspace becomes **blocked** (waiting for your input) or
**done**, you get a native notification whose **left icon is the herdr logo**
(not the generic terminal icon), and clicking it jumps straight to that pane.

```
🐑  ⏳ claude needs input
    my-project · feature-x          [Show]
```

## Why the bundled notifier app

The left icon of a macOS notification is the icon of the **app that posts it**.
The usual tricks don't help on modern macOS:

- `terminal-notifier -appIcon` is ignored (you get terminal-notifier's terminal icon).
- `terminal-notifier -sender <bundleid>` (borrow another app's icon) **hangs** on macOS 26.
- `osascript -e 'display notification …'` always shows the **Script Editor** icon and
  supports no icon/sound/click customization at all.

So this plugin ships **`assets/HerdrNotify.app`** — a copy of `terminal-notifier`
rebranded with the herdr icon and its own bundle id (`codes.dot.herdr-notify`). The
plugin posts through it, so the notification is genuinely "from herdr" and shows
the herdr logo. No Homebrew `terminal-notifier` needed at runtime.

## Requirements

- macOS (tested on macOS 26).
- `jq` — the only runtime dependency. Declare it in your `homebrew.nix` / `Brewfile`:

  ```sh
  brew install jq
  ```

### Grant notification permission (required, once per machine)

**No toast appears until you allow notifications for the app.** macOS gates
notifications per app, and this can't be scripted. After installing:

1. Trigger one notification (e.g. let an agent go blocked), or run
   `assets/HerdrNotify.app/Contents/MacOS/terminal-notifier -title hi -message x`.
2. Open **System Settings → Notifications → herdr** and turn **Allow Notifications** on
   (set the style to Alerts/Banners as you like).

The grant is keyed to the bundle id (`codes.dot.herdr-notify`), so it persists across
plugin updates and even if the app moves on disk. If notifications silently stop,
re-check this setting and that Focus / Do Not Disturb is off.

> **Re-signing may reset the grant.** The app is ad-hoc signed, and every re-sign
> mints a fresh code signature (CDHash) that macOS can treat as a different app —
> silently dropping the notification grant. To avoid that, the plugin re-signs
> **only when the existing signature is invalid** (setup/install and the handler
> both verify first). If you deliberately re-sign — e.g. after swapping the icon
> (`scripts/setup-notifier.sh` with an invalid/absent signature) — and toasts stop,
> re-approve **herdr** under **System Settings → Notifications**.

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

Install registers `HerdrNotify.app` with Launch Services (`lsregister`, plus an
ad-hoc re-sign **only if the existing signature is invalid** — see the grant note
above). On `herdr plugin install` this happens via the manifest `[[build]]` step;
on `link` the handler also self-registers on first event.

An ad-hoc-signed helper can quietly lose that registration over time (reboots,
OS updates), and macOS then falls back to showing the **parent terminal's** icon
instead of the herdr logo. To recover without manual intervention, the handler
re-registers the bundle (verifying — and only if invalid, repairing — the
signature) whenever its registration is older than
`REGISTER_TTL_SECONDS` (default 6h) — so the icon self-heals within that window
the next time a notification fires. No cron, daemon, or `chezmoi apply` needed.
A failed repair is logged (look for `codesign FAILED` on stderr) and retried on
the same TTL cadence.

### Avoid double notifications

herdr has its own built-in desktop toast. Turn it off (or to in-terminal) so only
this plugin posts to the desktop — in `~/.config/herdr/config.toml`:

```toml
[ui.toast]
delivery = "terminal"   # was "system"; "terminal" shows an in-app toast instead
```

## Configuration

All settings are optional. Every key is overridable at each layer; resolution
order (later wins):

1. built-in defaults
2. environment variable (exported before `notify.sh` runs)
3. `$HERDR_PLUGIN_CONFIG_DIR/config.env` (herdr-managed, per machine)
4. **`$HERDR_TN_CONFIG`** — a file you point at, ideal for dotfiles

An env var exported to the empty string (e.g. `export NOTIFIER=`) counts as
unset and keeps the built-in default; set the key in a config file to force an
empty value.

Copy [`config/config.example.env`](config/config.example.env) into your dotfiles
and point at it from your shell profile:

```sh
export HERDR_TN_CONFIG="$HOME/.config/herdr-terminal-notifier/config.env"
```

Key settings:

| Key | Default | Meaning |
| --- | --- | --- |
| `TRIGGER_STATUSES` | `"blocked done"` | which new statuses notify |
| `SUPPRESS_FOCUSED` | `1` | mute only when the workspace is focused in herdr **and** the terminal is frontmost |
| `TERMINAL_APP_IDS` | common terminals | bundle ids that host herdr, for the frontmost check (empty/undetectable ⇒ notify) |
| `DEBOUNCE_SECONDS` | `2` | drop repeated `(pane,status)` within window |
| `ACTIVATE_ON_CLICK` | `1` | click notification → focus the agent |
| `CLICK_COMMAND` | `agent focus {pane}` | `herdr` subcommand run on click |
| `NOTIFIER` | _(bundled app)_ | absolute path to override the notifier binary |
| `REGISTER_TTL_SECONDS` | `21600` | refresh Launch Services registration when older (self-heals left icon) |
| `ICON_MODE` | `contentImage` | right-side image mode (`contentImage`/`appIcon`) |
| `GROUP` | `{pane}` | notification group key (template); `""` disables grouping |
| `TITLE_<STATUS>` / `BODY_<STATUS>` | see example | message templates |
| `ICON_<STATUS>` / `SOUND_<STATUS>` | see example | right-side image / macOS sound |

Template placeholders: `{agent}` `{workspace}` `{worktree}` `{tab}` `{pane}`
`{session}` `{old_status}` `{new_status}` `{cwd}`. `<STATUS>` is the upper-cased
status (`BLOCKED`, `DONE`, …); `*_DEFAULT` covers the rest.

The **left** icon is always the herdr logo (the notifier app). `ICON_*` controls
the optional **right-side** status image.

**Grouping** (`GROUP`, default `{pane}`) sets terminal-notifier's `-group` key,
which *replaces* any earlier notification sharing it. Per-pane grouping keeps one
live notification per pane, but a later `done` then hides an earlier still-unread
`blocked` from the same pane. Widen the key so states don't overwrite each other
— `GROUP="{pane}-{new_status}"` is the "don't let done hide blocked" recipe (each
status gets its own group). `GROUP=""` (set in a config file) disables grouping
entirely, so every notification stacks.

**Focus suppression** (`SUPPRESS_FOCUSED=1`) mutes an event only when its
workspace is the one focused *inside herdr* **and** a terminal listed in
`TERMINAL_APP_IDS` is the frontmost macOS app. That way, starting an agent and
switching to the browser still delivers its blocked/done notification — herdr
keeps the workspace "focused" even though you are no longer looking at it. If the
frontmost app can't be detected (no `lsappinfo`, or `TERMINAL_APP_IDS` empty),
the notification is delivered (fail open: a duplicate beats a missed alert). Add
your terminal's bundle id to `TERMINAL_APP_IDS` if it isn't in the default list
(`osascript -e 'id of app "Ghostty"'`).

## Customizing the herdr icon

The icon source lives in `assets/` (`herdr-logo.svg` → rounded `herdr-rounded.svg`
→ `herdr.icns`). To use your own:

```sh
# render any 1024×1024 PNG, then:
sips -s format icns your.png --out assets/HerdrNotify.app/Contents/Resources/Terminal.icns
bash scripts/setup-notifier.sh   # re-register; re-signs because the icon swap
                                 # invalidated the signature (may reset the grant)
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
