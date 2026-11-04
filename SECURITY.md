# Security

## What this project protects — and what it does not

termux-root-bridge makes **unintended** Android-root actions by an AI agent much less likely. It is **not** a
sandbox against a hostile agent or a compromised guest. Read the limits before relying on it.

### Protections

* **Confirmation inside Claude Code.** A PreToolUse hook (`android-root-guard.py`, delivered through *managed
  settings*, the highest settings level) turns `androidsu`, `adb` (except harmless subcommands), `fastboot`, `su`,
  `magisk`, `resetprop`, `setprop` and similar into a permission prompt. Claude Code keeps asking for hook
  decisions of this kind in bypass-permissions mode. Managed settings cannot be overridden by user settings,
  `--settings` or `disableAllHooks`.
* **Tickets.** For a literal `androidsu '<cmd>'` the hook creates a single-use ticket bound to `sha256(<cmd>)` with a
  30 minute lifetime. The daemon runs `su` only for a request with a matching, unexpired, unused ticket. A denied
  prompt leaves nobody who knows the ticket id.
* **Fail closed.** A crashing or timing-out hook blocks the call (`onFailure: "block"`); unparsable input asks.
* **No popup fallback.** Without a ticket there is no way to get root.
* **Tamper protection.** Writes to the hook, the settings, the bridge directory or the scripts ask for confirmation
  (hook decision plus static ask rules). Reading them is free.
* **Indirect calls.** `bash -c`, `xargs`, `find -exec`, interpreters and scripts that mention root tools ask too
  (without a ticket, so the daemon refuses unless you re-issue the command directly).
* **Daemon hardening.** Its configuration is parsed as data against a whitelist and never executed. Only plain
  `https://` URLs are opened (no whitespace, quotes, control characters; ≤ 8 KiB; ≤ 10 per minute).
* **Audit log.** Every decision is appended to `~/.rootbridge/audit.log`.

### Known limits

* **Root in the guest shares the Termux home with the daemon.** proot maps your files into the guest, so a
  deliberately malicious process there can write a ticket itself. The hook asks before Claude does that with
  its tools, but a script file, an interpreter or a program that writes the files indirectly is only caught
  on a best-effort basis (text scan of scripts, interpreter arguments).
* **Text analysis is not a security boundary.** Shell is too flexible; the tokenizer covers quoting,
  substitutions, pipelines and wrappers, but obfuscation (encoded commands, scripts generated at runtime) can
  hide a call. Prefer `permissions.deny` rules for things that must never run.
* **`adb` has its own root** (`adb root`). It is covered by the hook only, not by tickets.
* **The terminal confirmation of `androidsu`** (outside Claude Code) trusts the terminal; a process with a
  pseudo-terminal can answer it. Disable with `TTY_CONFIRM=0` if that matters.
* **Auto-opening of login links** follows links that MCP servers return. Only `https` URLs are opened; set
  `AUTH_OPEN=copy` or `off` if you do not trust a server.
* **Bypass mode is bypass mode.** Everything not covered above runs unattended by design. Use it with projects
  and MCP servers you trust.
* Hardening idea for later: run the guest with `proot-distro --isolated` and bind only `~/.rootbridge`.

### Emergency switch

If the hooks block everything (for example `python3` is broken), run in Termux: `rootbridge guard-off`
(`guard-on` to restore). It renames the managed settings file inside the guest and logs the action.

## Reporting a vulnerability

Please do **not** open a public issue. Use GitHub's private vulnerability reporting for this repository
(Security → Report a vulnerability). Include the Claude Code version, Android version, the exact command and
what you expected. This is a one-person project: expect an answer within about a week.
