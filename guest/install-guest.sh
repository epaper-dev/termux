#!/usr/bin/env bash
# install-guest.sh - guest (proot-distro Ubuntu) part of termux-root-bridge.
# Normally started by ../install.sh; can also be run by hand as root in the guest.
#
#   install-guest.sh [--src DIR] [--root DIR] [--autonomous yes|no|ask] [--uninstall]
#
#   --src DIR         directory that contains bin/ and claude/ (default: next to this script)
#   --root DIR        install below DIR instead of / (staging, tests)
#   --autonomous      write skipDangerousModePermissionPrompt into ~/.claude/settings.json
#   --uninstall       remove everything this script installed
#
# Idempotent. Existing files are backed up as *.bak-<timestamp>.

set -eu

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT=""
AUTONOMOUS=ask
UNINSTALL=0
while [ $# -gt 0 ]; do
    case "$1" in
        --src) SRC="$2"; shift 2 ;;
        --root) ROOT="${2%/}"; shift 2 ;;
        --autonomous) AUTONOMOUS="$2"; shift 2 ;;
        --uninstall) UNINSTALL=1; shift ;;
        *) echo "unbekannte Option: $1" >&2; exit 2 ;;
    esac
done

STAMP="$(date +%Y%m%d%H%M%S)"
LIBDIR=/usr/local/lib/termux-root-bridge
BINDIR=/usr/local/bin
CONF=/etc/termux-root-bridge.conf
MANAGED_DIR=/etc/claude-code
MANAGED="$MANAGED_DIR/managed-settings.json"
BRIDGE_DIR=/data/data/com.termux/files/home/.rootbridge
HOME_DIR="${ROOTBRIDGE_GUEST_HOME:-/root}"
BEGIN='# >>> termux-root-bridge >>>'
END='# <<< termux-root-bridge <<<'

say() { printf '%s\n' "$*"; }
backup() { [ -e "$1" ] && cp -p "$1" "$1.bak-$STAMP" && say "  Sicherung: $1.bak-$STAMP" || true; }

# put <src> <dest> [mode] - copy with guest shebang, back up differing files
put() {
    local src="$1" dest="$ROOT$2" mode="${3:-755}"
    mkdir -p "$(dirname "$dest")"
    local tmp="$dest.new.$$"
    sed '1s|^#!/usr/bin/env bash|#!/bin/bash|; 1s|^#!/usr/bin/env python3|#!/usr/bin/python3|' "$src" > "$tmp"
    if [ -e "$dest" ] && ! cmp -s "$tmp" "$dest"; then backup "$dest"; fi
    chmod "$mode" "$tmp" && mv -f "$tmp" "$dest"
    say "  installiert: $2"
}

# commit_file <tmp> <dest>: install tmp as dest; back up dest only if it differs
commit_file() {
    if [ -e "$2" ] && cmp -s "$1" "$2"; then rm -f "$1"; return 0; fi
    [ -e "$2" ] && backup "$2"
    mkdir -p "$(dirname "$2")"
    mv -f "$1" "$2"
}

# strip_block <file>: remove our marked block
strip_block() {
    [ -f "$1" ] || return 0
    python3 -I - "$1" "$BEGIN" "$END" <<'PY'
import sys
path, begin, end = sys.argv[1:4]
lines = open(path, encoding="utf-8").read().split("\n")
out, skip = [], False
for line in lines:
    if line.strip() == begin:
        skip = True
        continue
    if skip:
        if line.strip() == end:
            skip = False
        continue
    out.append(line)
open(path, "w", encoding="utf-8").write("\n".join(out).rstrip("\n") + "\n")
PY
}

merge_managed() {   # merge_managed <template> <current> <out> <python> <libdir>
    python3 -I - "$1" "$2" "$3" "$4" "$5" <<'PY'
import json, os, sys
template_path, target, out, python, libdir = sys.argv[1:6]
raw = open(template_path, encoding="utf-8").read()
raw = raw.replace("@PYTHON@", python).replace("@LIBDIR@", libdir)
tpl = json.loads(raw)
try:
    cur = json.load(open(target, encoding="utf-8"))
except (OSError, ValueError):
    cur = {}
MARK = "termux-root-bridge"
hooks = cur.setdefault("hooks", {})
for event, entries in tpl["hooks"].items():
    kept = [e for e in hooks.get(event, [])
            if not any(MARK in h.get("command", "") for h in e.get("hooks", []))]
    hooks[event] = kept + entries
perms = cur.setdefault("permissions", {})
ask = perms.setdefault("ask", [])
for rule in tpl["permissions"]["ask"]:
    if rule not in ask:
        ask.append(rule)
with open(out, "w", encoding="utf-8") as fh:
    json.dump(cur, fh, indent=2, ensure_ascii=False)
    fh.write("\n")
PY
}

unmerge_managed() {
    [ -f "$ROOT$MANAGED" ] || return 0
    python3 -I - "$ROOT$MANAGED" <<'PY'
import json, sys
path = sys.argv[1]
cur = json.load(open(path, encoding="utf-8"))
MARK = "termux-root-bridge"
for event in list(cur.get("hooks", {})):
    cur["hooks"][event] = [e for e in cur["hooks"][event]
        if not any(MARK in h.get("command", "") for h in e.get("hooks", []))]
    if not cur["hooks"][event]:
        del cur["hooks"][event]
cur["hooks"] = cur.get("hooks") or {}
if not cur["hooks"]:
    cur.pop("hooks")
ask = [r for r in cur.get("permissions", {}).get("ask", [])
       if "androidsu" not in r and "termux-root-bridge" not in r
       and "/etc/claude-code" not in r and "rootbridge" not in r
       and "/usr/local/bin/xdg-open" not in r]
if "permissions" in cur:
    cur["permissions"]["ask"] = ask
    if not ask:
        del cur["permissions"]["ask"]
    if not cur["permissions"]:
        del cur["permissions"]
if cur:
    json.dump(cur, open(path, "w", encoding="utf-8"), indent=2, ensure_ascii=False)
else:
    import os; os.remove(path)
PY
}

# ---------------------------------------------------------------- uninstall
if [ "$UNINSTALL" = 1 ]; then
    say "== Gast: Deinstallation"
    unmerge_managed
    for f in androidsu rootbridge-open rootbridge-claude; do rm -f "$ROOT$BINDIR/$f"; done
    [ -L "$ROOT$BINDIR/xdg-open" ] && rm -f "$ROOT$BINDIR/xdg-open"
    rm -rf "$ROOT$LIBDIR"
    rm -f "$ROOT$CONF"
    strip_block "$ROOT$HOME_DIR/.bashrc"
    say "Fertig. ($ROOT$HOME_DIR/.claude/settings.json bleibt unverändert.)"
    exit 0
fi

# ------------------------------------------------------------------ install
say "== Gast: Installation (Quelle: $SRC)"
for need in python3 bash sha256sum od timeout; do
    command -v "$need" >/dev/null 2>&1 || { echo "FEHLT: $need (apt install python3 coreutils)" >&2; exit 1; }
done
command -v claude >/dev/null 2>&1 || [ -x "$ROOT$HOME_DIR/.local/bin/claude" ] \
    || say "  Hinweis: claude nicht gefunden (curl -fsSL https://claude.ai/install.sh | bash)"

PYTHON="$(command -v python3)"

put "$SRC/bin/androidsu"         "$BINDIR/androidsu"
put "$SRC/bin/rootbridge-open"   "$BINDIR/rootbridge-open"
put "$SRC/bin/rootbridge-claude" "$BINDIR/rootbridge-claude"
put "$SRC/claude/android-root-guard.py" "$LIBDIR/android-root-guard.py"
put "$SRC/claude/auth-url-hook.py"      "$LIBDIR/auth-url-hook.py"

# xdg-open shim: only if no real xdg-open would be hidden by it
if [ ! -e "$ROOT$BINDIR/xdg-open" ] || [ -L "$ROOT$BINDIR/xdg-open" ]; then
    ln -sf rootbridge-open "$ROOT$BINDIR/xdg-open"
    say "  Link: $BINDIR/xdg-open -> rootbridge-open"
else
    say "  Hinweis: $BINDIR/xdg-open existiert bereits und bleibt unverändert."
fi

# configuration (keep user edits, add missing keys)
mkdir -p "$ROOT$(dirname "$CONF")"
touch "$ROOT$CONF"
for kv in "BRIDGE_DIR=$BRIDGE_DIR" "TICKET_TTL=1800" "WORKDIR=/root/workspace" \
          "AUTH_OPEN=auto" "AUTH_REPLACE_OUTPUT=0" "TTY_CONFIRM=1"; do
    key="${kv%%=*}"
    grep -q "^$key=" "$ROOT$CONF" || printf '%s\n' "$kv" >> "$ROOT$CONF"
done
chmod 644 "$ROOT$CONF"
say "  Konfiguration: $CONF"

# bridge directory must exist as a real node inside the guest (proot bind quirk)
mkdir -p "$ROOT$BRIDGE_DIR" 2>/dev/null || say "  Hinweis: $BRIDGE_DIR nicht anlegbar (Termux-Home nicht gebunden?)"

# managed settings (hooks + ask rules)
mkdir -p "$ROOT$MANAGED_DIR"
merge_managed "$SRC/claude/managed-settings.template.json" "$ROOT$MANAGED" \
    "$ROOT$MANAGED.new.$$" "$PYTHON" "$LIBDIR"
commit_file "$ROOT$MANAGED.new.$$" "$ROOT$MANAGED"
say "  Managed Settings: $MANAGED"

# autonomous mode: skip the one-time warning dialog of bypass mode
if [ "$AUTONOMOUS" = ask ]; then
    if [ -t 0 ]; then
        printf 'Bypass-Modus ohne Warndialog freischalten (skipDangerousModePermissionPrompt)? [J/n] '
        read -r ans || ans=n
        case "$ans" in n|N) AUTONOMOUS=no ;; *) AUTONOMOUS=yes ;; esac
    else
        AUTONOMOUS=no
    fi
fi
if [ "$AUTONOMOUS" = yes ]; then
    mkdir -p "$ROOT$HOME_DIR/.claude"
    S="$ROOT$HOME_DIR/.claude/settings.json"
    python3 -I - "$S" "$S.new.$$" <<'PY'
import json, sys
path, out = sys.argv[1:3]
try:
    cur = json.load(open(path, encoding="utf-8"))
except (OSError, ValueError):
    cur = {}
cur["skipDangerousModePermissionPrompt"] = True
with open(out, "w", encoding="utf-8") as fh:
    json.dump(cur, fh, indent=2, ensure_ascii=False)
    fh.write("\n")
PY
    commit_file "$S.new.$$" "$S"
    say "  ~/.claude/settings.json: skipDangerousModePermissionPrompt=true"
fi

# guest ~/.bashrc: claude() wrapper with browser hand-off and bypass availability
B="$ROOT$HOME_DIR/.bashrc"
mkdir -p "$(dirname "$B")"
touch "$B"
cp "$B" "$B.new.$$"
strip_block "$B.new.$$"
sed -i '/# rootbridge_bin$/d' "$B.new.$$"
cat >> "$B.new.$$" <<EOF

$BEGIN
# Browser hand-off for logins (/login, /mcp) and bypass mode selectable with Shift+Tab.
# A Remote Control name set in CLAUDE_ARGS ($CONF) is applied here too (the name only, no other flags).
claude() {
    local conf="\${ROOTBRIDGE_CONF:-$CONF}" name="" rc=()
    if [ -r "\$conf" ]; then
        name="\$(sed -n 's/^CLAUDE_ARGS=.*--remote-control[ =]\([A-Za-z0-9._][A-Za-z0-9._-]*\).*/\1/p' "\$conf" | tail -n 1)"
    fi
    [ -n "\$name" ] && rc=(--remote-control "\$name")
    case " \$* " in
        *" -p "*|*" --print "*|*" --remote-control"*|*" -v "*|*" --version "*|*" -h "*|*" --help "*) rc=() ;;
    esac
    case "\${1:-}" in
        ""|-*) IS_SANDBOX=1 BROWSER=$BINDIR/rootbridge-open command claude --allow-dangerously-skip-permissions "\${rc[@]}" "\$@" ;;
        *)     BROWSER=$BINDIR/rootbridge-open command claude "\$@" ;;
    esac
}
$END
EOF
commit_file "$B.new.$$" "$B"
say "  ~/.bashrc: claude()-Block"

say "Fertig. Gast-Teil installiert."
