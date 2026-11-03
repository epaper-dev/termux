#!/usr/bin/env bash
# install-guest.sh - guest (proot-distro Ubuntu) part of termux-root-bridge.
# Normally started by ../install.sh; can also be run by hand as root in the guest.
#
#   install-guest.sh [--src DIR] [--root DIR] [--autonomous yes|no|ask] [--remote-name NAME]
#                    [--theme NAME] [--uninstall]
#
#   --src DIR         directory that contains bin/ and claude/ (default: next to this script)
#   --root DIR        install below DIR instead of / (staging, tests)
#   --autonomous      write skipDangerousModePermissionPrompt into ~/.claude/settings.json
#   --theme NAME      set the Claude Code theme in ~/.claude/settings.json (dark, light,
#                     light-daltonized, dark-daltonized, light-ansi, dark-ansi); other keys stay
#   --remote-name N   name shown in the Remote Control view (claude.ai/code): sets
#                     `--remote-control N` in CLAUDE_ARGS of /etc/termux-root-bridge.conf
#                     (other arguments stay; a new line also gets --continue)
#   --uninstall       remove everything this script installed
#
# Idempotent. Existing files are backed up as *.bak-<timestamp>.

set -eu

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT=""
AUTONOMOUS=ask
REMOTE_NAME=""; REMOTE_NAME_SET=0
THEME=""; THEME_SET=0
UNINSTALL=0
while [ $# -gt 0 ]; do
    case "$1" in
        --src) SRC="$2"; shift 2 ;;
        --root) ROOT="${2%/}"; shift 2 ;;
        --autonomous) AUTONOMOUS="$2"; shift 2 ;;
        --remote-name)
            [ $# -ge 2 ] || { echo "--remote-name braucht einen Namen" >&2; exit 2; }
            REMOTE_NAME="$2"; REMOTE_NAME_SET=1; shift 2 ;;
        --theme)
            [ $# -ge 2 ] || { echo "--theme braucht einen Namen" >&2; exit 2; }
            THEME="$2"; THEME_SET=1; shift 2 ;;
        --uninstall) UNINSTALL=1; shift ;;
        *) echo "unbekannte Option: $1" >&2; exit 2 ;;
    esac
done

if [ "$REMOTE_NAME_SET" = 1 ] && ! [[ "$REMOTE_NAME" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]]; then
    echo "--remote-name: ungültiger Name '$REMOTE_NAME' (erlaubt: Buchstaben, Ziffern, . _ -; max. 64 Zeichen; nicht mit - beginnen)" >&2
    exit 2
fi

if [ "$THEME_SET" = 1 ]; then
    case "$THEME" in
        dark|light|light-daltonized|dark-daltonized|light-ansi|dark-ansi) ;;
        *) echo "--theme: ungültiger Name '$THEME' (erlaubt: dark, light, light-daltonized, dark-daltonized, light-ansi, dark-ansi)" >&2
           exit 2 ;;
    esac
fi

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

# settings_set <key> <json-value>: set one key in the user's ~/.claude/settings.json.
# All other keys stay; nothing is written (and nothing backed up) if the value is already
# there; a file that is not valid JSON is left alone with a warning.
settings_set() {
    local s="$ROOT$HOME_DIR/.claude/settings.json" rc=0
    mkdir -p "$(dirname "$s")"
    python3 -I - "$s" "$s.new.$$" "$1" "$2" <<'PY' || rc=$?
import json, sys
path, out, key, raw = sys.argv[1:5]
value = json.loads(raw)
try:
    with open(path, encoding="utf-8") as fh:
        cur = json.load(fh)
except FileNotFoundError:
    cur = {}
except (OSError, ValueError):
    sys.exit(3)
if not isinstance(cur, dict):
    sys.exit(3)
if key in cur and cur[key] == value:
    sys.exit(4)
cur[key] = value
with open(out, "w", encoding="utf-8") as fh:
    json.dump(cur, fh, indent=2, ensure_ascii=False)
    fh.write("\n")
PY
    case "$rc" in
        0) commit_file "$s.new.$$" "$s"; say "  ~/.claude/settings.json: $1=$2" ;;
        4) say "  ~/.claude/settings.json: $1=$2 (schon gesetzt)" ;;
        3) say "  Hinweis: ~/.claude/settings.json ist kein gültiges JSON-Objekt - $1 nicht gesetzt." ;;
        *) rm -f "$s.new.$$"; echo "settings_set: Fehler ($rc)" >&2; return 1 ;;
    esac
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
# Remote Control name -> CLAUDE_ARGS (other arguments stay; a new line also gets --continue,
# because the name belongs to the session and --continue keeps that session)
if [ -n "$REMOTE_NAME" ]; then
    python3 -I - "$ROOT$CONF" "$ROOT$CONF.new.$$" "$REMOTE_NAME" <<'PY'
import sys
path, out, name = sys.argv[1:4]
lines = open(path, encoding="utf-8").read().split("\n")
last = max((i for i, l in enumerate(lines) if l.startswith("CLAUDE_ARGS=")), default=None)
if last is None:
    rest = ["--continue"]
else:
    val = lines[last].split("=", 1)[1].strip()
    if len(val) >= 2 and val[0] == val[-1] and val[0] in "\"'":
        val = val[1:-1]
    toks, rest, i = val.split(), [], 0
    while i < len(toks):
        t = toks[i]
        if t == "--remote-control":
            if i + 1 < len(toks) and not toks[i + 1].startswith("-"):
                i += 1                      # skip the old name too
        elif not t.startswith("--remote-control="):
            rest.append(t)
        i += 1
new = 'CLAUDE_ARGS="' + " ".join(["--remote-control", name] + rest) + '"'
res = []
for i, l in enumerate(lines):
    if l.startswith("CLAUDE_ARGS="):
        if i == last:
            res.append(new)
    else:
        res.append(l)
if last is None:
    while res and res[-1] == "":
        res.pop()
    res.append(new)
with open(out, "w", encoding="utf-8") as fh:
    fh.write("\n".join(res).rstrip("\n") + "\n")
PY
    commit_file "$ROOT$CONF.new.$$" "$ROOT$CONF"
    say "  Remote-Control-Name: $REMOTE_NAME (CLAUDE_ARGS)"
fi
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
    settings_set skipDangerousModePermissionPrompt true
fi

# Claude Code theme (only when asked for: install.sh passes --theme unless --no-colors)
if [ "$THEME_SET" = 1 ]; then
    settings_set theme "\"$THEME\""
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
