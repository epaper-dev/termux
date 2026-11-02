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
* `rootbridge` control program, autostart in Termux (`claude update` → Claude Code), Termux:Widget shortcuts,
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

### Fixed
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
