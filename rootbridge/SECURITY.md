# Security

## What this project protects — and what it does not

termux-rootbridge makes **unintended** Android-root actions by an AI agent much less likely. It is **not** a
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
* **Codex pre-commit review.** With Claude Code and Codex installed, a second hook (`codex-precommit-review.py`, managed
  settings, `onFailure: "block"`) lets Codex review every `git commit` of Claude Code, a strict loop that fails closed (no
  login, plugin or `node`, or a failing Codex blocks the commit). The approved diffs live in `~/.claude/codex-precommit`, a
  protected path like the other bridge files. Only you switch it off: `rootbridge codex-off`. The hook's log and state live in a
  private directory (0700, files 0600), commands are logged by their first word and length only, every `git` call is bounded in
  time and size (a hanging `git` blocks instead of letting Claude Code's cut-off pass the commit unreviewed), and what goes to
  Claude is cleaned of control characters, capped and marked as foreign text.

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
* **Codex is not covered by the guard.** The `android-root-guard` hook runs inside Claude Code. Codex starts with its own
  defaults (sandbox and approval questions, no bypass mode); `androidsu` still refuses it without a ticket, but the
  limits below about the shared Termux home apply to it just as well.
* **The pre-commit review sends your diff to OpenAI** (under the account you logged in to Codex with), and Codex's sandbox
  restricts writing, not reading: it can read more of the guest than the repository.
* **The review hook takes the command apart like a shell, nothing more.** It reviews a `git commit` that is run (also after
  `cd`, with `git -C`, behind `sudo` / `env` / `time`, in `bash -c '…'` and `$(…)`); text in quotes or heredocs does not count.
  Commands with an executable `git commit` and unquoted parentheses are blocked: the hook cannot reliably track
  directory changes across subshells. Run the commit separately instead. Quoted text and heredoc bodies do not count.
  It does not recognise git aliases (`git ci`), scripts or programs that commit for you, and `merge`, `rebase` or
  `cherry-pick`. A command it cannot take apart falls back to a text search, so a real commit is not missed. A `git` that fails blocks the commit (only "not a git repository" passes). Files that
  only a `git add` of the same command brings in are in no diff: they are listed to Codex and part of the approval hash.
  Codex blocks only for high severity (a bug that breaks something, a security hole, a secret, data loss, a swallowed
  error); smaller findings come as notes after `ALLOW`. The review sees the working tree as it is when the command
  starts: what the same command changes before the commit (`sed -i … && git commit -a`, a build script) is not covered. It also reads the
  approved-diff state from a file that a process in the guest could write; the guard asks before Claude Code does that with
  its tools, nothing more. It is a safety net against slips, not a sandbox.
* **Voice and the side key.** PulseAudio (installed with the voice part) listens on `127.0.0.1` only and lets a client in only with its cookie
  (`~/.config/pulse/cookie`, private to Termux). Anonymous access would let every app on the phone record the microphone through Termux'
  permission, because every app reaches `127.0.0.1`; the guest shares the Termux home and reads the cookie (`PULSE_COOKIE`), so any process in
  the guest can record while PulseAudio runs. The microphone
  permission for Termux is granted with a root command (`pm grant ... RECORD_AUDIO`, to Termux:API and for the shared user id to every Termux app) that `install.sh` runs **only on a terminal**, where the root manager asks you,
  and `rootbridge voice grant` runs on request; neither goes through the Claude Code hook. `--sidekey` keeps a root `cat` on `/dev/input/event2` alive
  (reads the side key and the volume key, writes nothing); `--no-sidekey` or `uninstall.sh` removes it.
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
