# Logins and MCP links

Signing in on a phone has three annoyances: the browser does not open, the link is huge, and copying it from the
terminal brings line breaks and spaces. This is what termux-root-bridge changes — and how to fix it when it does not.

## Why copying was so painful

* Claude Code's fullscreen interface (`"tui": "fullscreen"`) together with tmux `mouse on` captures the touch
  input. Selecting the link by hand copies the layout padding and the line breaks as well. The dialog even says
  "Hold … while selecting to use your terminal's native copy" — something a touch screen cannot do.
* Claude Code *has* a copy key (**`c`** in the login dialogs) that writes the link via the OSC 52 escape sequence.
  tmux, however, only forwards OSC 52 from programs when `set-clipboard on` is set — and inside the guest Claude
  Code cannot even see that it runs under tmux.
* In the Ubuntu guest there is no browser, so `BROWSER`/`xdg-open` lead nowhere.
* For claude.ai connectors the link comes back as the result of a tool (`mcp__<server>__authenticate`) and ends
  up as plain text in the chat, where there is no copy key at all.

## What the installer sets up

| Piece | Effect |
|---|---|
| `~/.tmux.conf` block (Termux): `set-clipboard on`, `allow-passthrough on` | The **`c`** key puts a clean, single-line link into the Android clipboard |
| `rootbridge-open` as `BROWSER` and `xdg-open` (guest) | `/login`, `/mcp`, `claude mcp login <server>` open the Android browser; the link also lands in the clipboard if the Termux:API app is installed |
| `auth-url-hook.py` (PostToolUse hook, managed settings) | Finds the link in `authenticate` results, opens/copies it, and tells Claude not to print it |
| `rootbridge login <server>` (Termux) | `claude mcp login <server>` outside a session, with the browser hand-off |

`rootbridge-open` accepts only plain `https://` URLs without spaces, control or quote characters (max. 8 KiB). The
browser is opened by the daemon (reliable) or, if the daemon does not run, directly via `termux-open-url`.

## Settings

Guest `/etc/termux-root-bridge.conf` (or environment variables of the same name):

| Key | Values | Meaning |
|---|---|---|
| `AUTH_OPEN` | `auto` (default), `copy`, `off` | `auto`: open + copy · `copy`: only copy · `off`: leave `authenticate` results alone |
| `AUTH_REPLACE_OUTPUT` | `0` (default), `1` | `1` replaces the tool result with a short note (`updatedToolOutput`). Off until verified on a real call; the hook then relies on `additionalContext` telling Claude not to print the link. |

## Troubleshooting

**The browser does not open.** In Termux run `rootbridge status` (daemon running?). Open Termux in the foreground —
Android only lets an app start another one from the foreground; if you work in another app, allow *Display over
other apps* for Termux. Check `~/.rootbridge/audit.log` for `OPEN` lines. Without the Termux:API app the link is
opened but not copied.

**The `c` key does nothing.** Check in Termux: `tmux show -g set-clipboard` must say `on`; restart the tmux session
(`rootbridge stop`, `rootbridge start`) after the installer added the block. Termux itself must accept OSC 52; if
yours does not, use the browser hand-off instead (or `rootbridge-open --copy-only <url>`).

**Browser says "connection refused" after login.** The login redirects to `http://localhost:<port>/callback`.
proot shares the phone's network, so this should work while Claude Code is waiting. If the page still fails, copy
the **full address from the browser's address bar** and paste it into the prompt that Claude Code shows
("paste the redirect URL"). Pasting into a prompt does not suffer from the wrapping problem.

**I only want my own sign-in flow.** Set `AUTH_OPEN=off`, remove the `PostToolUse` entry from
`/etc/claude-code/managed-settings.json`, or run `rootbridge guard-off` (switches *all* hooks off).

**Headless token instead of a browser login.** `claude setup-token` creates a long-lived token; export it as
`CLAUDE_CODE_OAUTH_TOKEN` to skip the browser on a fresh install.

## Verification status

Tested automatically: link extraction from 19 response shapes, URL rules, the three modes, daemon opening and
`--copy-only`. **Confirmed on a device** (Hisense A9, 2026-11-04): `/login` opens the Android browser from the guest,
the **`c`** key puts the link into the Android clipboard (OSC 52 through tmux), and `rootbridge-open --copy-only` copies a
214-character link through the daemon without a single changed character. **Not yet confirmed on a device:** the
`localhost` redirect after a completed login, the real `tool_response` shape of `authenticate` tools, and whether
`updatedToolOutput` is accepted for MCP tools. Please report results using the device-report issue template.
