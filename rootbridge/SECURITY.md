# Security

## What this project protects — and what it does not

termux-rootbridge makes **unintended** Android-root actions by an AI agent much less likely. It is **not** a
sandbox against a hostile agent or a compromised guest. Read the limits before relying on it.

### Protections

* **You confirm every root request, in Termux.** For each `androidsu` request the daemon shows an Android dialog
  (`termux-dialog`) with the command and the agent that asked (Claude Code, Codex or a shell, read from the process tree:
  a hint, not a decision). Your answer is the output of the dialog itself, never a file, so nothing in the guest can
  approve a request for you. Refused: no answer within `ASK_TIMEOUT` (120 s), a dialog that fails or is missing
  (`termux-api` and the Termux:API app), and a command longer than 4000 characters (what you see is all that runs).
  One dialog at a time. A dismissed dialog shows again and a Yes within one second of its appearing (a slip while typing) is asked
  again; with the Termux:API of this repository (`api/`) the dialog also counts down, closes itself at the deadline and only a tap on
  Yes or No answers it.
* **The guest cannot reach Termux.** Agent sessions and shells open with `proot-distro login --isolated` and get only
  `~/.rootbridge` (the requests and the refusals), the shared storage (`/sdcard`, `/storage/emulated/0`: your phone files,
  as before, nothing of Termux) and, with voice, the PulseAudio cookie. They see neither the Termux home
  nor `usr`: not the daemon, not the `su` wrapper of Termux, not the files Termux runs at its next start (`.bashrc`,
  `~/.termux/boot`, shortcuts). The installer logins are not isolated: there you act, not an agent.
  `GUEST_ISOLATE=off` in the Termux config switches the isolation off (see the limits).
* **Refusals reach the agent.** The daemon leaves a note for the agent that asked, and the hook `rootbridge-hook.py` hands it
  over as context (PostToolUse, UserPromptSubmit; managed settings of Claude Code, `/etc/codex/requirements.toml` for
  Codex): you said no, do not look for a workaround. This only informs; it does not decide anything.
* **Daemon hardening.** Its configuration is parsed as data against a whitelist and never executed (the dialog program comes
  from the environment, not from the config). Only plain `https://` URLs are opened (no whitespace, quotes, control
  characters; ≤ 8 KiB; ≤ 10 per minute). Control characters are stripped from what the dialog shows.
* **Audit log.** Every decision is appended to `~/.rootbridge/audit.log` (`ALLOW`, `DENY-USER`, `ASK-TIMEOUT`, `ASK-FAIL`,
  `STALE`, ...). The guest can write that file: it is a record for you, not evidence against a hostile guest.
* **Codex pre-commit review.** With Claude Code and Codex installed, a second hook (`codex-precommit-review.py`, managed
  settings, `onFailure: "block"`) lets Codex review every `git commit` of Claude Code, a strict loop that fails closed (no
  login, plugin or `node`, or a failing Codex blocks the commit). The approved diffs live in `~/.claude/codex-precommit`. Only you switch it off: `rootbridge codex-off`. The hook's log and state live in a
  private directory (0700, files 0600), commands are logged by their first word and length only, every `git` call is bounded in
  time and size (a hanging `git` blocks instead of letting Claude Code's cut-off pass the commit unreviewed), and what goes to
  Claude is cleaned of control characters, capped and marked as foreign text.


### Known limits

* **The dialog protects `androidsu`, the isolation protects the rest.** Without the isolation (`GUEST_ISOLATE=off`, or a
  session you opened by hand with plain `proot-distro login`) the guest runs as the Termux user and sees the Termux home and
  `usr`: an agent could overwrite the daemon, call the `su` wrapper of Termux directly, or plant files Termux runs later,
  and never meet a dialog. Keep the isolation on.
* **The isolated guest still runs as the Termux user, with `/dev`.** It has no `su` binary and no Termux files, but a
  process that talks to the root manager (Magisk) over its own socket would be outside this control. Revoke the root grant
  of Termux and use the dialog only if that matters to you; the project cannot close that gap.
* **The bridge directory stays writable for the guest** (it has to be: the requests are files). A hostile process can create
  requests (each one costs you a dialog, you say no), forge notes (this can mislead the agent, it gives it no rights), and
  edit the audit log. It cannot forge your answer.
* **You approve a command, not what it does.** The dialog shows `androidsu 'sh /root/x.sh'` as that text; the script is a
  file the guest wrote and can contain anything. Approve what you understand.
* **`adb` has its own root** (`adb root`). There is no `adb` in the isolated guest; without the isolation nothing watches it.
* **Auto-opening of login links** follows links that MCP servers return. Only `https` URLs are opened; set
  `AUTH_OPEN=copy` or `off` if you do not trust a server.
* **Codex runs without its own sandbox.** Under proot the bubblewrap sandbox of Codex fails on every command, so the
  installer starts Codex with `--dangerously-bypass-approvals-and-sandbox` (`--no-codex-bypass` turns that off). Codex can
  then read and write the whole guest as root without approval questions of its own. What it cannot do, with the
  isolation on, is reach Termux or Android root without your answer in the dialog.
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
  approved-diff state from a file that a process in the guest could write, and nothing stops it. It is a safety net against
  slips, not a sandbox.
* **Voice and the side key.** PulseAudio (installed with the voice part) listens on `127.0.0.1` only and lets a client in only with its cookie
  (`~/.config/pulse/cookie`, private to Termux). Anonymous access would let every app on the phone record the microphone through Termux'
  permission, because every app reaches `127.0.0.1`; the isolated guest gets the cookie bound in (`PULSE_COOKIE`), so any process in
  the guest can record while PulseAudio runs. The microphone
  permission for Termux is granted with a root command (`pm grant ... RECORD_AUDIO`, to Termux:API and for the shared user id to every Termux app) that `install.sh` runs **only on a terminal**, where the root manager asks you,
  and `rootbridge voice grant` runs on request; neither goes through the Claude Code hook. `--sidekey` keeps a root `cat` on `/dev/input/event2` alive
  (reads the side key and the volume key, writes nothing); `--no-sidekey` or `uninstall.sh` removes it.
* **Bypass mode is bypass mode.** Everything not covered above runs unattended by design. Use it with projects
  and MCP servers you trust.

### Emergency switch

If the hooks block everything (for example `python3` is broken), run in Termux: `rootbridge guard-off`
(`guard-on` to restore). It renames the managed settings file inside the guest and logs the action.

## Reporting a vulnerability

Please do **not** open a public issue. Use GitHub's private vulnerability reporting for this repository
(Security → Report a vulnerability). Include the Claude Code version, Android version, the exact command and
what you expected. This is a one-person project: expect an answer within about a week.
