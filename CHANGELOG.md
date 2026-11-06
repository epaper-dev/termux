# Changelog

## 2.0.0-dev (unreleased)

Rewrite. The tmux popup and the second Termux window are gone; confirmation happens inside Claude Code.

### Changed
* The apt upgrade and `claude update` at the session start now run at most once every **6 hours** (before: once per
  24 h). `APT_UPGRADE` and `CLAUDE_UPDATE` take `6h` (new default), any `<N>h` (1-999 hours), `daily` (= 24 h, as before),
  `always` or `off`; `install.sh --apt-upgrade` and `--claude-update` accept the same values. A value already in
  `/etc/termux-root-bridge.conf` stays, so switch an older `daily` once: `bash install.sh --apt-upgrade 6h --claude-update 6h`.
  npm is not part of this: `apt-get upgrade` covers everything installed with `apt` (`nodejs`/`npm` too, if added), global
  `npm -g` packages are not updated, and Claude Code is a native binary that `claude update` replaces.
* The Remote Control name defaults to `android`: a plain `install.sh` (no `--remote-name`) now writes
  `CLAUDE_ARGS="--remote-control android --continue"` into the guest config, so Remote Control is on at
  every start and the session is named. The guest installer also sets `remoteControlAtStartup: true` in
  `~/.claude/settings.json` (only if not set yet). `--remote-name NAME` still picks another name and is remembered.
  There is deliberately no `--name`: the Remote Control session is reused across restarts and `/clear` and keeps its
  title (also one set with `/rename`), while `--name` would show the name in the frame of the input field as well.
* `--autonomous yes` (the default) now also makes bypass mode the **start mode**: the installer sets
  `permissions.defaultMode` to `bypassPermissions` in the guest's `settings.json`, but only if no default mode is set yet
  (before, a fresh installation started in the normal mode and bypass was only selectable with Shift+Tab). Every
  Android-root command still asks. `--autonomous no` leaves it alone.
* New default model `opusplan` in the guest's `settings.json`, only if no model is set yet. New option
  `--model NAME|none`: writes the given model, `none` leaves the model alone.
* The guest installer **creates the working directory**: `WORKDIR` (default now `/root/work`, before `/root/workspace`).
  It was never created, so `rootbridge-claude` fell back to `/root` on a fresh installation. A `WORKDIR` already in
  `/etc/termux-root-bridge.conf` stays and is created; an unsafe one (`..`) falls back to `/root/work`.
  The old default `WORKDIR=/root/workspace` (guest conf and Termux config) is moved to `/root/work` when the folder
  `/root/workspace` does not exist (it never was created, so nobody uses it); an existing folder keeps its setting.
* All `settings.json` changes of one installer run are written in **one** go (`settings_queue` / `settings_apply` instead of
  one write per key): one backup at most, no intermediate versions, one warning for a broken file.
  `tests/test_autonomous.sh` (58 checks) covers the start mode, model, working directory and the pass-through in `install.sh`.
* `--autonomous` now defaults to `yes` (before: `ask`, which meant `no` without a terminal): the installer sets
  `skipDangerousModePermissionPrompt`, so Claude Code shows no warning dialog when you switch to bypass mode. Every
  Android-root command still asks. `no` leaves the setting alone, `ask` asks on a terminal; other values are rejected.
  `tests/test_autonomous.sh`.

### Added
* Automatic setup in `install.sh`: what is missing gets installed first, without a question and without an option: the
  Termux packages (`pkg install -y`, only the missing ones), the Ubuntu guest (`proot-distro install`), and, through the new
  `guest/setup-guest.sh`, `python3` / `curl` / certificates in the guest (`apt-get`) and Claude Code (official installer).
  The guest is looked at from outside first, so a complete guest is not even entered for it. Idempotent, stops with a hint on every
  failure (run `bash install.sh` again). `--no-setup` only checks and tells you what is missing (the old behaviour;
  `--no-deps-check` skips the package part, `--no-guest` the guest part); `--setup` of the first draft is still
  accepted. The guest `~/.bashrc` block now puts `~/.local/bin` on the PATH. `tests/test_setup.sh` (87 checks, stubbed
  pkg / proot-distro / apt-get / curl on a PATH made of symlinks, so the result does not depend on the machine; mutation
  probes fail as expected); the install tests that run the guest part pass `--no-setup`.
* Termux extra keys row: `install.sh` sets it in `~/.termux/termux.properties` (marked block, backup first, reload only
  on a change, mode 600; `termux/extra-keys.snippet`). Two rows of six: `ESC` `CTRL` `S-TAB` `BKSP` `↑` `ENTER` and `KEYBOARD`
  `/` `TAB` `←` `↓` `→`. S-TAB sends Shift+Tab (a phone keyboard has none, Claude Code switches its permission mode with
  it), TAB completes slash commands and `@` files; KEYBOARD shows/hides the soft keyboard (ENTER and the arrows keep working without it); swipe up
  on `←` for HOME and on `→` for END. An `extra-keys` line of the user's own is never replaced (single or
  multi line). `--no-extra-keys`, removed by `uninstall.sh`. `backup()` no longer keeps empty files.
  `tests/test_extra_keys.sh` (90 checks, own parser for the layout, mutation probes fail as expected);
  the other install tests pass `--no-extra-keys` so they never count or trigger a reload.
* MIT `LICENSE`, linked from the READMEs (before: "not chosen yet").
* `README.es.md` rewritten for v2 (the version on GitHub still described the v1 popup); the three READMEs link to each other.
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
  Claude Code starts via the widget "Claude", alias `ubuntu`, `rootbridge attach` or, after a reboot, Termux:Boot
  (`rootbridge start --no-attach`). Re-running `install.sh` removes the old autostart from `~/.bashrc`;
  `ROOTBRIDGE_NO_AUTOSTART` is gone. `tests/test_colors_theme.sh` covers the block (reload only, nothing in tmux,
  migration of the old block).
* Widgets renamed to **"Claude"** and **"Ubuntu"** (before: "Claude Code" / "Ubuntu Shell"; briefly "Claude >_" / "Ubuntu >_",
  which the widget list cut off), now with icons.
  The repo files are `termux/shortcuts/claude` and `ubuntu` (a `>` in a file name breaks checkouts on Windows); `install.sh`
  installs them as `~/.shortcuts/Claude` / `Ubuntu`. Default icons `termux/shortcuts/icons/{claude,ubuntu}.png`:
  a neutral dark rounded square with a coloured `>_`, no logos, generated by `tools/make-shortcut-icons.py` (pure Python).
  An existing icon is never replaced; icons of ALL earlier names are carried over to the new ones, the old scripts (only if they
  contain `rootbridge`) are moved to `~/.rootbridge/backups`. The widgets are created even without a `~/.shortcuts` folder;
  `install.sh --no-widgets` skips them. Backups of files in `~/.shortcuts` and `~/.termux/boot` now go to
  `~/.rootbridge/backups` instead of `*.bak-*` next to the original — Termux:Widget lists EVERY file in `~/.shortcuts` (the
  backups showed up as widgets) and Termux:Boot runs EVERY file in `~/.termux/boot`. `uninstall.sh` removes our scripts under every
  name ("Claude" is generic: a script that does not call `rootbridge` stays) and only the default icons. `tests/test_widgets.sh` (62 checks; `rootbridge`/`tmux`/`pkill` stubs: `uninstall.sh` calls
  `rootbridge stop`).
* `rootbridge shell` (widget "Ubuntu") is a plain guest shell: it only starts the daemon (for `androidsu`) and runs
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

* `claude update` at the session start runs at most once a day, like the apt upgrade: guest key `CLAUDE_UPDATE`
  (`daily` default, `always`, `off`), stamp `/var/lib/termux-root-bridge/claude-update-last-success` written only after a
  successful update (a failed or aborted one leaves none, the start goes on and the next start tries again).
  `install.sh --claude-update MODE` / `--no-claude-update` are stored in the Termux config (`CLAUDE_UPDATE`) and reused by
  every later install, also with a fresh guest; the guest installer takes `--claude-update MODE`. A value already in the
  guest config is kept. `tests/test_claude_update.sh` (125 checks, stubbed `claude` / `proot-distro`, the real
  `rootbridge-claude` is never run).
* The session ends with Claude Code: after `/exit` (exit code 0) or Ctrl+C (130) `rootbridge-claude` exits instead of
  starting `exec bash -l`, so the tmux window and session close, `rootbridge attach` returns and the Termux window of the
  "Claude" widget closes. Any other exit code (crash, kill) still opens the guest shell with a note naming the code, and
  so does a missing `claude` binary. New `after_claude()`; `tests/test_session_exit.sh` (28 checks, stub `claude` and stub
  `bash`, mutation probes fail as expected).

### Fixed
* `tests/test_nofile_limit.sh` aborted in a session that runs with the lowered limit (a hard limit cannot be raised again).
  It now starts from `min(hard limit, 8192)`; lowering to 2048 is only observable above that (CI), everything else is.
* Every hook and tool call took 4-9 s: Claude Code closes every file descriptor up to `RLIMIT_NOFILE` after each fork,
  and under proot each `close()` is a trapped syscall (~80 us), so Android's limit of 32768 cost 2.5-4 s per started
  process (the guard itself needs 0.2 s; even an empty `true` hook took 4-8 s). `rootbridge-claude` and the `claude()`
  function now start Claude Code (and `claude update`) with `ulimit -n 2048` in a subshell: hook phase 12 s → 1.2 s, a
  whole test run 45 s → 10 s. Both limits have to go down (Bun raises the soft limit back to the hard one); the limit is
  never raised and the shell afterwards keeps its own. New guest key `NOFILE_LIMIT` (default 2048, `0` = off; an existing
  value is kept). `tests/test_nofile_limit.sh` (29 checks, stubbed `command`, staging root, the real `rootbridge-claude`
  is never run). Takes effect after `install.sh` and a restart of the Claude Code session.
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

### Verified on a device
Hisense A9, 2026-11-04: installer, colours and theme, apt upgrade, `claude update`, the file-descriptor limit, widgets,
ending the session with `/exit`, the root prompt in bypass mode (live session in `bypassPermissions`: the hook answered
`ask` for `androidsu 'id'` 0.5 s after the call, the result came 5.6 s later, i.e. after the answer in Claude Code),
a complete `/login` with the automatic `localhost` redirect (no code to paste; new token, `claude auth status` logged
in), opening the browser from the guest (`BROWSER` → `rootbridge-open` → daemon → `termux-open-url`), copying a
214-character link into the Android clipboard through the daemon (`--copy-only`, pasted back byte for byte identical)
and the `c` key in the login dialog (OSC 52 through tmux).

### Not yet verified on a device
The `tool_response` shape of MCP login tools and `updatedToolOutput` for MCP tools. `tests/headless-proof.sh` (the automated version of the bypass check, with a stub instead of `su`) has
not been run on the device yet.

## 1.0.0

Popup based bridge (`androidsu` → watcher → tmux popup with `y` + Enter → `su -c`).
