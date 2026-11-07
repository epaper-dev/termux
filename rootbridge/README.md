# termux-root-bridge

**Run Claude Code on Android (Termux + proot-distro) with every real-root action confirmed inside Claude Code — and with logins that just work.**

[Deutsch](README.de.md) · [Español](README.es.md) · [Comparison with other projects](docs/COMPARISON.md) · [Login & MCP details](docs/LOGIN.md) · [Security](SECURITY.md)

> **Status: v2.0.0-dev.** Unit and integration tests pass (guard hook, login hook, daemon, installers).
> Confirmed on a device (Hisense A9): the root prompt also in bypass mode, a complete `/login` including the automatic
> `localhost` redirect, opening the browser from the guest and copying links into the Android clipboard (through the
> daemon and with the `c` key through tmux). Still to check: the exact `tool_response` format of MCP login tools.
> See [what is verified](#what-is-verified).

## What problem does it solve?

If you run Claude Code inside an Ubuntu guest (proot-distro) in Termux, three things get in the way:

1. **Real Android root is out of reach.** `su` inside proot collides with Magisk. This project runs a small
   daemon *outside* proot that executes `su -c` for the guest — but only for commands you confirmed.
2. **You want Claude to work autonomously** (no question for every `ls`) **but never touch the phone's system
   unasked.** A hook turns every root-capable command (`androidsu`, `adb`, `fastboot`, `su`, `magisk`, ...)
   into an ordinary permission prompt *inside Claude Code* — also in bypass-permissions mode.
3. **Logins are painful on a phone.** The OAuth/MCP link is hundreds of characters long, wraps over many lines
   and picks up spaces when you copy it. The login link is now opened in the Android browser for you, or copied
   cleanly with one key.

There is no second terminal window and no popup any more (v1 needed one).

## How it works

```
Claude Code (Ubuntu guest, root)                  Termux (outside proot)
────────────────────────────────                  ──────────────────────
Bash: androidsu 'id'
 └─ PreToolUse hook (android-root-guard.py)
     • literal command?  → single-use ticket bound to sha256("id")
     • asks: "⚠ ANDROID-ROOT: id"   ← you answer Yes / No in Claude Code
androidsu ── request + ticket ─────────────────▶  rootbridge-daemon (headless)
                                                  valid ticket? → su -c 'id'
                         ◀──────── result ─────  no ticket?    → refused (exit 99)
```

* **No ticket, no root.** A denied prompt means the command never runs. There is no popup fallback.
* **Autonomy elsewhere.** Anything that is not root-related (including `/sdcard`) runs without questions.
* **Login links.** `/login`, `/mcp`, `claude mcp login <server>` open the browser through `BROWSER`/`xdg-open`;
  `mcp__*__authenticate` results are intercepted so the long link is opened and copied instead of printed.

## Requirements

* Android with Termux (F-Droid/GitHub build), `proot-distro` with an Ubuntu guest, Claude Code installed in the guest
  (`curl -fsSL https://claude.ai/install.sh | bash`); `install.sh` sets up what is missing of this and of the packages below
* A working `su` (Magisk, KernelSU, ...) — without it, only the login features work
* Termux packages: `tmux proot-distro python coreutils util-linux`; optional `termux-api` (+ the Termux:API app)
  for the clipboard
* Guest packages: `python3` (hooks), coreutils with `sha256sum`, `od`, `timeout`
* Claude Code ≥ 2.1.295 (`onFailure: "block"` for hooks)

## Install

In a **Termux** shell (not inside proot):

```bash
pkg install -y git
git clone --depth 1 https://github.com/epaper-dev/termux
cd termux/rootbridge
bash install.sh
```

The installer sets up what is missing, by itself and without asking: the Termux packages (`pkg install`), the Ubuntu guest
(`proot-distro install`, a download of a few hundred MB), `python3`, `curl` and the certificates in the guest, and Claude Code
with the official installer. On a device that has it all, only the normal installation runs. Run it again after a failure.
Still manual: the root grant for Termux (your root manager asks on the first request), opening Termux:Boot once, putting the
**Claude** widget on the home screen, and the Claude login (`/login`; the browser opens by itself). `--no-setup` changes
none of this and only tells you what is missing (`--no-deps-check` skips the package part, `--no-guest` the guest part).
`--setup`, the option of earlier versions, is still accepted and does nothing extra.

**Autonomous mode is on by default** (`--autonomous yes`): the installer sets `skipDangerousModePermissionPrompt` in the guest's
`~/.claude/settings.json`, so Claude Code shows no warning dialog for bypass mode, and `permissions.defaultMode` to
`bypassPermissions` (only if you have not set a default mode yet), so Claude Code **starts in bypass mode**. Bypass mode runs
inside the proot guest, and every Android-root command still asks for confirmation (also in bypass mode). `--autonomous no`
leaves both settings alone (a value set earlier stays), `--autonomous ask` asks on a terminal.

The installer also sets the **model** to `opusplan` (Opus plans, Sonnet works), again only if `settings.json` has no model
yet. `--model NAME` always writes the given model, `--model none` leaves it alone. And it creates the **working directory
`/root/work`** in the guest, where Claude Code starts (`WORKDIR` in `/etc/termux-root-bridge.conf`; a value you set there
stays). Before, the folder was never created, so a fresh installation started Claude Code in `/root`. An old default
`WORKDIR=/root/workspace` is moved to `/root/work` if the folder `/root/workspace` does not exist.

Then start Claude Code with the **Claude** widget, or type `ubuntu` (alias for `rootbridge attach`) in a Termux
shell. The first start creates the session: it starts the daemon, updates the guest's packages (`apt-get update` +
`upgrade`, at most once every 6 hours, see below), runs `claude update` (likewise) and starts Claude Code; later
starts just attach to it.
**Ordinary Termux windows stay plain shells** (with the colours loaded), nothing starts by itself. With Termux:Boot the
session is created in the background after a reboot (`rootbridge start --no-attach`). Claude **starts in bypass
mode** (with `--autonomous no`: in the mode of your `settings.json`); press **Shift+Tab** to switch modes (on a phone use the **S-TAB** key
the installer adds to the Termux extra keys row, see below).

Options: `--no-setup`, `--no-guest`, `--no-boot`, `--no-migrate`, `--no-colors`, `--no-widgets`, `--no-extra-keys`, `--autonomous yes|no|ask`, `--model NAME|none`, `--remote-name NAME`,
`--apt-upgrade 6h|<N>h|daily|always|off`, `--no-apt-upgrade`, `--claude-update 6h|<N>h|daily|always|off`, `--no-claude-update`. The installer is idempotent, backs up what it changes, and
migrates the old v1 popup bridge if it finds one.

**Widgets.** With the Termux:Widget app you get two shortcuts: **Claude** (attach to the Claude Code session) and
**Ubuntu** (a plain Ubuntu shell). The installer puts them into `~/.shortcuts` together with the widget icon
(`termux/shortcuts/icons/widget.png`, copied to `~/.shortcuts/icons/<name>.png`, the same one for both). The neutral `>_`
icons of earlier versions (`termux/shortcuts/icons/legacy`) are replaced by it, any other icon that already exists is never
replaced, so you can drop your own PNG there; with earlier names ("Claude Code" / "Ubuntu Shell", "Claude >_" / "Ubuntu >_") an existing icon
is carried over to the new name and the old scripts are removed. Backups of widget and boot scripts go to
`~/.rootbridge/backups` (Termux:Widget lists every file in `~/.shortcuts`, Termux:Boot runs every file in
`~/.termux/boot`). `--no-widgets` skips all of it.

**Extra keys.** A phone keyboard has no Shift+Tab, and Claude Code switches its permission mode (plan, auto, bypass) with it.
The installer therefore sets the Termux extra keys row in `~/.termux/termux.properties` (inside a marked block, the file is
backed up first, Termux reloads its settings afterwards): two rows of six keys,
`ESC` `CTRL` `S-TAB` `BKSP` `↑` `ENTER` and `KEYBOARD` `/` `TAB` `←` `↓` `→`. **S-TAB** sends Shift+Tab, **TAB** completes
slash commands and `@` files. **KEYBOARD** shows or hides the soft keyboard (a hidden keyboard does not reappear by itself;
`ENTER`, the arrows, `ESC` and `S-TAB` still answer prompts and menus). Swipe up on `←` for `HOME`, on `→` for `END`. A row of your own (an `extra-keys` line outside our block) is never replaced, the installer
only tells you which key to add by hand (template: `termux/extra-keys.snippet`). `--no-extra-keys` skips all of this,
`uninstall.sh` removes the block. The colours of the bar are fixed by Termux and cannot be changed from here.

**End of the session.** `/exit` (or Ctrl+C) in Claude Code ends everything: the tmux window and session close, `rootbridge attach`
returns, and the Termux window opened by the **Claude** widget closes with it. You do not land in the Ubuntu shell. Only if Claude Code
ends with an error code does the guest shell stay open, with a note, so the message stays readable (also when `claude` is not installed).

**Package updates in the guest.** On by default: when the Claude Code session starts, `rootbridge-apt` runs
`apt-get update` and `apt-get -y upgrade` — at most once per 6 h after a success (`APT_UPGRADE=6h`; `12h` and so on set another distance, `daily` = 24 h), never blocking
the start (no network, an error or a timeout just print a note and Claude Code starts; the next start tries again). Two
safeguards matter on proot-distro with Ubuntu 26.04: dpkg gets `-o DPkg::Path` including `/usr/local/bin`, because the
uutils coreutils need the GNU-named symlinks there (otherwise maintainer scripts abort with "Security violation"), and
the coreutils packages (`APT_HOLD`) are held back, because upgrading the multicall binary itself breaks the guest. Log:
`/var/log/termux-root-bridge-apt.log` in the guest — every run ends with a `Ende: ok` (or the reason) line, a run
without it was interrupted; held packages: `apt-mark showhold`. Turn it off with
`bash install.sh --no-apt-upgrade` (stored in the Termux config as `APT_UPGRADE`, so later installs keep it, also with a
fresh guest), or run it at every start with `--apt-upgrade always`. Run it by hand: `rootbridge-apt` in the guest. Everything installed with `apt` is covered, `nodejs` and `npm` included
if you add them; global packages from `npm -g` are not. Claude Code itself is a native binary that `claude update`
replaces, no npm involved. A value already in `/etc/termux-root-bridge.conf` stays when you run the installer without
the option; switch an older `daily` once with `bash install.sh --apt-upgrade 6h --claude-update 6h`.

**`claude update`.** Same rules as the package updates (`CLAUDE_UPDATE=6h|<N>h|daily|always|off`, default `6h`): the session
start runs `claude update` at most once per 6 h after a success (stamp
`/var/lib/termux-root-bridge/claude-update-last-success` in the guest). A failed or aborted update leaves no stamp, prints a
note and Claude Code starts anyway; the next start tries again. With the default Claude Code can be up to 6 hours behind the
newest version. `bash install.sh --no-claude-update` turns it off, `--claude-update always` runs it at every start (stored in
the Termux config as `CLAUDE_UPDATE`, so later installs keep it, also with a fresh guest). A `claude update` you run by
hand does not set the stamp.

**Colours and theme.** The installer writes no colour file. The E-Paper Termux build (`epaper-dev/termux`) has a light and a
dark scheme built in and follows the phone's light/dark mode, so the terminal is light in light mode and dark in dark mode
without any file; `~/.termux/colors-light.properties`, `colors-dark.properties` and `colors.properties` only override that.
Colour files that earlier versions installed (`colors.properties` with the light palette, `colors-light.properties`) are
removed when they are still exactly as installed, because they would override the built-in scheme; a file you changed
stays. `--no-colors` leaves colour files and the Claude Code theme alone. The installer sets `"theme": "auto"` in the
guest's `~/.claude/settings.json` (other keys stay): Claude Code asks the terminal for its background colour and picks its
light or dark theme, so it follows the phone as well; switch any time with `/theme`. Every new interactive Termux shell
runs `termux-reload-settings`, and so do the Termux:Widget shortcuts before they attach. Other Termux builds have no
built-in light scheme; copy a scheme to `~/.termux/colors.properties` there.

**Fixed name in the Remote Control view** (claude.ai/code): the default is `android`, so a plain `bash install.sh`
sets it. Another name: `bash install.sh --remote-name NAME`. That name is stored in the Termux config (`REMOTE_NAME`), so
every later install reuses it without the option — also with a fresh guest or after `uninstall.sh` — and the guest
installer writes
`CLAUDE_ARGS="--remote-control android --continue"`. `--remote-control NAME` turns Remote Control on and titles the
session in the Remote Control view. That Remote Control session is reused across restarts and `/clear` and keeps its
name, also one you set with `/rename`. For another name a single `/rename NAME` is enough. There is deliberately no
`--name`: it would also show the name in the frame of the input field in the Claude Code window.

## Daily use

| Command (Termux) | What it does |
|---|---|
| `rootbridge start` | daemon + session; `--no-attach` creates it in the background (Termux:Boot runs that after a reboot) |
| `rootbridge attach` / alias `ubuntu` | attach to the Claude Code session |
| `rootbridge shell` | plain Ubuntu shell in this terminal (starts the daemon for `androidsu`, but no Claude Code and no tmux session; widget "Ubuntu") |
| `rootbridge status` | daemon, session, guest install, last audit lines |
| `rootbridge login <server>` | `claude mcp login <server>` with browser hand-off |
| `rootbridge stop` | stop session and daemon |
| `rootbridge guard-off` / `guard-on` | emergency switch for the hooks |

Inside Claude Code, nothing changes: ask for what you want. When Claude needs root it runs
`androidsu '<command>'` and you get a prompt showing exactly that command. Every decision lands in
`~/.rootbridge/audit.log`.

## Logins and MCP links

Short version (details and troubleshooting: [docs/LOGIN.md](docs/LOGIN.md)):

* In a login dialog press **`c`** — Claude Code copies the link to the Android clipboard (needs the tmux
  settings the installer adds).
* `/login`, `/mcp` and `claude mcp login` **open the browser by themselves**.
* For claude.ai connectors (`authenticate` tools) a hook opens the link and Claude prints a one-line note
  instead of the long URL. `AUTH_OPEN=copy` only copies, `AUTH_OPEN=off` disables it.

## Configuration

Termux: `~/.config/termux-root-bridge/config` (parsed as data, never executed): `DISTRO`, `WORKDIR`, `SESSION`,
`TICKET_TTL`, `SU_ARGS` (`-c` or `-mm -c`), `AUTOSTART_DELAY`, `REMOTE_NAME`, `APT_UPGRADE` and `CLAUDE_UPDATE` (all read by `install.sh`).
Guest: `/etc/termux-root-bridge.conf`: `BRIDGE_DIR`, `TICKET_TTL`, `WORKDIR`, `AUTH_OPEN`, `AUTH_REPLACE_OUTPUT`,
`TTY_CONFIRM`, `PROTECTED_PATHS`, `CLAUDE_ARGS`, `APT_UPGRADE` (`6h`, `<N>h`, `daily`, `always`, `off`), `APT_TIMEOUT` (seconds for the
upgrade, default 600), `APT_HOLD` (packages held back from the upgrade), `CLAUDE_UPDATE` (`6h`, `<N>h`, `daily`, `always`, `off`), `NOFILE_LIMIT` (see below).

`NOFILE_LIMIT` (default `2048`, `0` = leave the limit alone) is the file-descriptor limit Claude Code is started with.
Claude Code closes every descriptor up to that limit after each fork, and under proot every `close()` is a trapped
syscall, so Android's default of 32768 added 2.5-4 s to every started process: each hook and tool call took 4-9 s
instead of well under a second. `rootbridge-claude` and the `claude()` function lower it for Claude only (never raise
it); the shell around it keeps its own limit.

`CLAUDE_ARGS` in the guest file holds extra arguments for the session start (`rootbridge-claude`), e.g.
`CLAUDE_ARGS="--remote-control android --continue"` to show the session as "android" in the Remote
Control view and resume the last session (`install.sh` writes and updates this line, name `android` by default; other
arguments in it stay). The `claude()` shell function reads only the Remote Control name from it (never `--continue`) and leaves it
out for `-p`, `--version` and `--help`.

## What is verified

| Verified by automated tests | Still to check on a real device |
|---|---|
| Guard decisions (43 tests): ticket binding, indirect calls, tamper protection, fail-closed | `tool_response` shape of MCP login tools; `updatedToolOutput` |
| Daemon: ticket single-use/expiry/hash, long commands, URL validation (49 checks) | — |
| Login hook (19 tests: response shapes, URL rules, modes) | — |
| Installers: staging root, idempotence, v1 migration, uninstall | — |

Confirmed on a device (Hisense A9, 2026-11-04): installer, colours and theme, apt upgrade, `claude update`, the
file-descriptor limit, widgets, ending the session with `/exit`, the root prompt in bypass mode (the hook asked inside Claude Code and `androidsu` ran only
after the answer), a complete `/login` with the automatic `localhost` redirect (no code to paste), opening the browser from the guest and copying links into the Android clipboard (`--copy-only` through the daemon, and the `c` key through tmux).

Run the tests: `python3 -I -m unittest discover -s tests && bash tests/test_daemon.sh`.

## Limits

This protects against **unintended** actions, not against a hostile agent: root in the guest shares the Termux
home with the daemon. See [SECURITY.md](SECURITY.md) for the honest list.

## Uninstall

```bash
bash uninstall.sh      # keeps ~/.rootbridge (audit log, backups) and the config
```

## Related projects and credits

Other ways to get Claude Code onto Android — they solve *installation*, this project solves *root confirmation,
start-up and logins* on top of it: [bd-loser/claude-code-termux](https://github.com/bd-loser/claude-code-termux),
[ferrumclaudepilgrim/claude-code-android](https://github.com/ferrumclaudepilgrim/claude-code-android),
[Crypt0Shmipt0/root-aicli](https://github.com/Crypt0Shmipt0/root-aicli). Details in
[docs/COMPARISON.md](docs/COMPARISON.md). Not affiliated with Anthropic.

## License

[MIT](LICENSE).
