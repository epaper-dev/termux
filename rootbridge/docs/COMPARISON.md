# Comparison with other Claude Code on Android projects

termux-root-bridge does **not** install Claude Code for you. It assumes Claude Code already runs (here: inside a
proot-distro Ubuntu guest) and adds what the projects below do not cover: **root confirmation inside Claude Code,
one-tap start with `claude update`, and comfortable logins.** Reviewed on 2026-11-01 from each project's README,
scripts and docs. All four projects are MIT licensed.

| Project | What it solves | Covers our goals? | What we took from it |
|---|---|---|---|
| [bd-loser/claude-code-termux](https://github.com/bd-loser/claude-code-termux) | Claude Code **natively in Termux** (no proot) through `glibc-runner`, plus a DNS shim for `getaddrinfo ENOTIMP` and an argv[0] shim | No root gating, no autostart, no login help. Not needed when Claude already runs in proot. | Pointer as the "native" alternative. Insight: natively `su` works directly, so there the hook alone would suffice (no daemon) — roadmap v2.1. |
| [ferrumclaudepilgrim/claude-code-android](https://github.com/ferrumclaudepilgrim/claude-code-android) | Three install paths (A native + auto-updating wrapper, B proot Ubuntu, C AVF VM), security model, add-ons (fingerprint gate hook, agent permission separation, SSRF guard), tests, ShellCheck CI, issue/device-report templates | Only partly: its fingerprint gate matches literal `git push` strings and, by its own documentation, fails open and is untested. No Android-root gating. Login: "copy the URL manually". | Repo hygiene (SECURITY.md, CHANGELOG, issue templates, ShellCheck CI, device reports), the "honest limits" documentation style, pointer for the "Checking connectivity" hang. A biometric second factor via `termux-fingerprint` is a candidate for v2.1. |
| [Crypt0Shmipt0/root-aicli](https://github.com/Crypt0Shmipt0/root-aicli) | Android app that installs AI CLIs into Termux on rooted devices: `su -mm`, SELinux MLS relabeling, boot persistence, Alpine dispatcher | No. Root is used to *install*; nothing is confirmed or restricted. Auth: browser OAuth, API key or `claude setup-token`. | `su -mm` (global mount namespace) as the daemon option `SU_ARGS`. The note that files written via `su` inside Termux folders need `chcon`. The lesson that a Claude self-update recreates `~/.local/bin/claude` — the autostart therefore calls the absolute path. |
| **termux-root-bridge** (this project) | Root confirmation inside the Claude Code session, headless daemon, one-tap start and Termux:Boot (`claude update` → Claude Code), login/MCP link hand-off | — | — |

## Why a separate project at all?

* Installing Claude Code on Android is largely solved by the projects above.
* *Asking before touching the phone's system* needs a hook in the Claude Code permission pipeline plus a daemon
  outside proot. None of them has either.
* The login link problem (very long, wrapped URL) is mentioned by none of them beyond "copy it manually".

## Can they be combined?

Yes. Install Claude Code with whichever project fits (for example ferrum's Path B for proot Ubuntu), then run
`install.sh` of this repository. The native variants (bd-loser, ferrum Path A) need a different layout — `su`
works there directly — and are not supported by v2.0.
