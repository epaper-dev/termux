# Changelog

## 2.0.0-dev (unreleased)

Rewrite. The tmux popup and the second Termux window are gone; confirmation happens inside Claude Code.

### Added
* `android-root-guard.py` — PreToolUse hook: confirmation for every Android-root execution, tickets bound to
  `sha256(<cmd>)`, tamper protection, fail-closed. 43 tests.
* `rootbridge-daemon` — headless, ticket-only, long commands (`ack` + unlimited wait for the result), URL opener.
  49 checks incl. an end-to-end run hook → `androidsu` → daemon.
* `auth-url-hook.py` — PostToolUse hook that opens/copies login links of `mcp__*__authenticate` results.
  19 tests.
* `rootbridge-open` as `BROWSER` / `xdg-open` in the guest; tmux clipboard settings for Claude Code's `c` key.
* `rootbridge` control program, session start via alias `ubuntu`, `rootbridge attach` or the widgets (`claude update` → Claude Code), Termux:Widget shortcuts,
  optional Termux:Boot script.
* Idempotent installers/uninstaller with change-only backups and a staging root; migration of the v1 bridge.
* `tests/headless-proof.sh` — run yourself to prove that the hook's `ask` holds in bypass-permissions mode.
* Guest `CLAUDE_ARGS` (`/etc/termux-root-bridge.conf`): the `claude()` function takes a `--remote-control <name>` from
  it, so manual starts show up under the same name as the autostart. `tests/test_claude_wrapper.sh` (22 checks, stubbed
  `claude`, staging root).

* `install.sh --remote-name NAME` (and `install-guest.sh --remote-name`): the Remote Control name is stored in the Termux
  config (`REMOTE_NAME`), reused by every later install (fresh guest, after `uninstall.sh`) and written to the guest
  `CLAUDE_ARGS` (`--remote-control NAME`, other arguments stay, a new line also gets `--continue`).
  `tests/test_remote_name.sh` (51 checks, stubbed `proot-distro`, fake HOME/PREFIX).

* Light colour scheme: `install.sh` writes `~/.termux/colors.properties` (`termux/colors.properties`; the previous file
  is kept as `*.bak-<timestamp>`, a changed file triggers `termux-reload-settings` at once). The `~/.bashrc` block runs
  `termux-reload-settings` in every new interactive Termux shell (not inside tmux), and the Termux:Widget shortcuts run
  it before they attach, so the colours are loaded before `claude update`. `install.sh --no-colors` skips the colours
  and the theme.
* Ordinary Termux windows are plain shells: the `~/.bashrc` block no longer runs `rootbridge start` (it started or
  attached to the Claude Code session in every window, and once the session ran there was no countdown to escape).
  Claude Code starts via the widget "Claude Code", alias `ubuntu`, `rootbridge attach` or, after a reboot, Termux:Boot
  (`rootbridge start --no-attach`). Re-running `install.sh` removes the old autostart from `~/.bashrc`;
  `ROOTBRIDGE_NO_AUTOSTART` is gone. `tests/test_colors_theme.sh` covers the block (reload only, nothing in tmux,
  migration of the old block).
* `rootbridge shell` (widget "Ubuntu Shell") is a plain guest shell: it only starts the daemon (for `androidsu`) and runs
  `proot-distro login` in the current terminal. It used to call `session_create`, which started the Claude Code window
  (`rootbridge-claude`: apt, `claude update`, Claude Code) in the background and put the shell in front of it, so leaving the
  shell with `exit` dropped you into Claude Code. `tests/test_rootbridge_shell.sh` (19 checks, stub daemon/`tmux`/
  `proot-distro`): no tmux call, no `rootbridge-claude`, `attach` still creates the session.
* Claude Code theme: `install.sh` passes `--theme light-ansi` to `install-guest.sh`, which sets `"theme": "light-ansi"` in
  `~/.claude/settings.json` (the ANSI variant uses the 16 colours of `colors.properties`; the RGB theme `light` was hard to
  read in Termux) (new `settings_set` helper: other keys stay, nothing is written or backed up when the value
  is already there, a file that is not valid JSON is left alone). `install-guest.sh --theme NAME` accepts `dark`, `light`,
  `light-daltonized`, `dark-daltonized`, `light-ansi`, `dark-ansi`. `tests/test_colors_theme.sh` (92 checks, stubbed
  `proot-distro`, `termux-reload-settings` and `rootbridge`).

* Package updates in the guest: new `guest/bin/rootbridge-apt` (installed to `/usr/local/bin`), called by
  `rootbridge-claude` before `claude update`. It runs `apt-get update` + `apt-get -y upgrade` at the start of the session,
  **at most once per 24 h after a success** (`APT_UPGRADE=daily`, the default; `always` = every start, `off` = never).
  Safeguards for proot-distro/Ubuntu 26.04: `-o DPkg::Path` includes `/usr/local/bin` (the uutils coreutils need the
  GNU-named symlinks there, apt's default path lacks it), non-interactive with `--force-confold`/`--force-confdef`, short
  network timeouts, 120 s for the update and `APT_TIMEOUT` (default 600 s) for the upgrade, the coreutils packages
  (`APT_HOLD`, default `rust-coreutils gnu-coreutils coreutils-from-uutils coreutils`) are held back because upgrading the
  multicall binary breaks the guest, a failure, a timeout or a missing network never stops the start and leaves no
  success stamp (so the next start tries again), `dpkg --audit` is checked afterwards. Log:
  `/var/log/termux-root-bridge-apt.log` (cut at 256 KiB): the apt output plus the result lines (`apt: fertig.`, held
  packages, errors) and a closing line `=== <time> Ende: ok|update-fehlgeschlagen|upgrade-fehlgeschlagen|dpkg-audit-warnung`
  per run — a run that has a header but no `Ende:` line was interrupted (killed, reboot). On by default; `install.sh --no-apt-upgrade` (or
  `--apt-upgrade daily|always|off`) turns it off or changes it, the choice is stored in the Termux config
  (`APT_UPGRADE`) and reused by every later install, like `REMOTE_NAME`. `install-guest.sh --apt-upgrade MODE` sets
  `APT_UPGRADE` in `/etc/termux-root-bridge.conf` (an existing value stays without the option).
  `tests/test_apt_upgrade.sh` (143 checks; stub `apt-get`/`apt-mark`/`dpkg`/`dpkg-query`/`timeout`/`proot-distro`, real
  apt is never started).

### Fixed
* Leaked daemons: every `install.sh` run deleted the lock (`~/.rootbridge/.lock`) of the RUNNING daemon (the cleanup was meant
  for v1 leftovers), so the next `rootbridge start` spawned a second daemon while the old one kept polling — five were
  running on a device. Two daemons can race for one request (the ticket is single-use, but the second one may write a
  "refused" result for a command the first one executed). Now `install.sh` removes the lock only if it has no pid or the
  pid is dead; the daemon removes the lock only while it is its own (a leftover used to delete its successor's lock), checks
  in every poll that the lock still names it, takes a vanished lock again, and stops itself when another daemon owns it.
  `tests/test_daemon_lock.sh` (22 checks, real daemon loop in a temp dir, `pkill`/`pgrep`/`tmux` stubs). Daemons that are
  already running keep the old code: stop leftovers once with `kill -9 <pid>` (not `kill`: the old cleanup would delete the
  live daemon's lock), the one named in `~/.rootbridge/.lock/pid` stays.
* `install-guest.sh --root DIR` failed when the guest home did not exist below `DIR`.
* README listed `CLAUDE_ARGS` in the Termux config, but only the guest config is used for it.

### Removed
* `root-bridge-watch.sh`, `root-bridge-confirm.sh` (tmux popup), `ubuntu-toggle.sh`, `ubuntu-switch.sh`, v1 widgets.
  They stay available in the tag `v1.0.0`.

### Not yet verified on a device
OSC 52 clipboard into Android, opening the browser from the guest, the `tool_response` shape of MCP login tools,
`updatedToolOutput` for MCP tools, and the bypass-mode proof above.

## 1.0.0

Popup based bridge (`androidsu` → watcher → tmux popup with `y` + Enter → `su -c`).
