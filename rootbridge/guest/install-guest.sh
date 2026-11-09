#!/usr/bin/env bash
# install-guest.sh - guest (proot-distro Ubuntu) part of termux-rootbridge.
# Normally started by ../install.sh; can also be run by hand as root in the guest.
#
#   install-guest.sh [--src DIR] [--root DIR] [--autonomous yes|no|ask] [--remote-name NAME]
#                    [--theme NAME] [--model NAME|none] [--apt-upgrade 6h|<N>h|daily|always|off]
#                    [--claude yes|no] [--codex yes|no] [--claude-update M] [--codex-update M] [--uninstall]
#
#   --claude yes|no   Claude Code is part of the installation (default yes). no = Codex only: no Claude Code
#                     settings, hooks, managed settings or claude() wrapper (an existing value in the config stays
#                     without the option)
#   --codex yes|no    Codex is part of the installation (default yes): rootbridge-codex (the Codex window), the
#                     update step and, together with Claude Code, the Codex pre-commit review hook in the managed
#                     settings (an existing value in the config stays without the option)
#   --codex-update M  CODEX_UPDATE in /etc/termux-rootbridge.conf: `codex update` and the Codex plugin update at the
#                     start of a session (rootbridge-update). Same values and rules as --claude-update.
#   --src DIR         directory that contains bin/ and claude/ (default: next to this script)
#   --root DIR        install below DIR instead of / (staging, tests)
#   --autonomous      yes (default): write skipDangerousModePermissionPrompt into ~/.claude/settings.json
#                     (no warning dialog for bypass mode) and, if settings.json has no default mode yet,
#                     permissions.defaultMode = bypassPermissions (Claude Code starts in bypass mode; every
#                     Android-root command still asks); no: leave both as they are (an earlier value
#                     stays); ask: ask on a terminal
#   --theme NAME      set the Claude Code theme in ~/.claude/settings.json (auto = match the terminal,
#                     dark, light, light-daltonized, dark-daltonized, light-ansi, dark-ansi, or custom:epaper =
#                     "Auto epaper": ~/.claude/themes/epaper.json, created with base light-ansi if missing,
#                     whose base `rootbridge theme` switches between light and dark); other keys stay
#   --model NAME      model in ~/.claude/settings.json. Default "opusplan" (Opus plans, Sonnet works), written
#                     only if settings.json has no model yet; with the option the value is always written;
#                     none leaves the model alone
#   --remote-name N   name shown in the Remote Control view (claude.ai/code): sets
#                     `--remote-control N` in CLAUDE_ARGS of /etc/termux-rootbridge.conf
#                     (other arguments stay; a new line also gets --continue) and, unless you set it
#                     yourself, remoteControlAtStartup=true in ~/.claude/settings.json
#   --apt-upgrade M   APT_UPGRADE in /etc/termux-rootbridge.conf: rootbridge-apt runs apt-get
#                     update + upgrade at the start of the Claude Code session (6h = at most once
#                     every 6 hours, <N>h = every N hours (1-999), daily = 24h, always, off).
#                     Without the option an existing value stays and a missing one becomes "6h".
#   --claude-update M CLAUDE_UPDATE in /etc/termux-rootbridge.conf: rootbridge-claude runs
#                     `claude update` at the start of the session (6h = at most once every 6 hours
#                     after a success, <N>h, daily = 24h, always, off). Same rules as --apt-upgrade.
#   --uninstall      remove everything this script installed
#
# Idempotent. Existing files are backed up as *.bak-<timestamp>.

set -eu

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT=""
AUTONOMOUS=yes
REMOTE_NAME=""; REMOTE_NAME_SET=0
THEME=""; THEME_SET=0
MODEL=opusplan; MODEL_SET=0
APT_MODE=""; APT_MODE_SET=0
CLAUDE_UPD_MODE=""; CLAUDE_UPD_SET=0
CODEX_UPD_MODE=""; CODEX_UPD_SET=0
CLAUDE_ON=""; CODEX_ON=""
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
        --model)
            [ $# -ge 2 ] || { echo "--model braucht einen Namen oder none" >&2; exit 2; }
            MODEL="$2"; MODEL_SET=1; shift 2 ;;
        --apt-upgrade)
            [ $# -ge 2 ] || { echo "--apt-upgrade braucht 6h (Stunden), daily, always oder off" >&2; exit 2; }
            APT_MODE="$2"; APT_MODE_SET=1; shift 2 ;;
        --claude-update)
            [ $# -ge 2 ] || { echo "--claude-update braucht 6h (Stunden), daily, always oder off" >&2; exit 2; }
            CLAUDE_UPD_MODE="$2"; CLAUDE_UPD_SET=1; shift 2 ;;
        --codex-update)
            [ $# -ge 2 ] || { echo "--codex-update braucht 6h (Stunden), daily, always oder off" >&2; exit 2; }
            CODEX_UPD_MODE="$2"; CODEX_UPD_SET=1; shift 2 ;;
        --claude)
            [ $# -ge 2 ] || { echo "--claude braucht yes oder no" >&2; exit 2; }
            CLAUDE_ON="$2"; shift 2 ;;
        --codex)
            [ $# -ge 2 ] || { echo "--codex braucht yes oder no" >&2; exit 2; }
            CODEX_ON="$2"; shift 2 ;;
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
        auto|dark|light|light-daltonized|dark-daltonized|light-ansi|dark-ansi|custom:epaper) ;;
        *) echo "--theme: ungültiger Name '$THEME' (erlaubt: auto, dark, light, light-daltonized, dark-daltonized, light-ansi, dark-ansi, custom:epaper)" >&2
           exit 2 ;;
    esac
fi

MODEL_RE='^(none|[A-Za-z0-9][]A-Za-z0-9._:[-]{0,63})$'
if [ "$MODEL_SET" = 1 ] && ! [[ "$MODEL" =~ $MODEL_RE ]]; then
    echo "--model: ungültiger Name '$MODEL' (erlaubt: Buchstaben, Ziffern, . _ : - [ ]; max. 64 Zeichen; oder none)" >&2
    exit 2
fi

if [ "$APT_MODE_SET" = 1 ]; then
    [[ "$APT_MODE" =~ ^(always|off|daily|[1-9][0-9]{0,2}h)$ ]] || {
        echo "--apt-upgrade: ungültiger Wert '$APT_MODE' (erlaubt: 6h (1-999 Stunden), daily, always, off)" >&2
        exit 2
    }
fi

if [ "$CLAUDE_UPD_SET" = 1 ]; then
    [[ "$CLAUDE_UPD_MODE" =~ ^(always|off|daily|[1-9][0-9]{0,2}h)$ ]] || {
        echo "--claude-update: ungültiger Wert '$CLAUDE_UPD_MODE' (erlaubt: 6h (1-999 Stunden), daily, always, off)" >&2
        exit 2
    }
fi

if [ "$CODEX_UPD_SET" = 1 ]; then
    [[ "$CODEX_UPD_MODE" =~ ^(always|off|daily|[1-9][0-9]{0,2}h)$ ]] || {
        echo "--codex-update: ungültiger Wert '$CODEX_UPD_MODE' (erlaubt: 6h (1-999 Stunden), daily, always, off)" >&2
        exit 2
    }
fi

case "$AUTONOMOUS" in
    yes|no|ask) ;;
    *) echo "--autonomous: ungültiger Wert '$AUTONOMOUS' (erlaubt: yes, no, ask)" >&2; exit 2 ;;
esac
for pair in "claude:$CLAUDE_ON" "codex:$CODEX_ON"; do
    case "${pair#*:}" in
        ""|yes|no) ;;
        *) echo "--${pair%%:*}: ungültiger Wert '${pair#*:}' (erlaubt: yes, no)" >&2; exit 2 ;;
    esac
done

STAMP="$(date +%Y%m%d%H%M%S)"
LIBDIR=/usr/local/lib/termux-rootbridge
BINDIR=/usr/local/bin
CONF=/etc/termux-rootbridge.conf
MANAGED_DIR=/etc/claude-code
MANAGED="$MANAGED_DIR/managed-settings.json"
BRIDGE_DIR=/data/data/com.termux/files/home/.rootbridge
HOME_DIR="${ROOTBRIDGE_GUEST_HOME:-/root}"
BEGIN='# >>> termux-rootbridge >>>'
END='# <<< termux-rootbridge <<<'

say() { printf '%s\n' "$*"; }

# Which tools are part of the installation: the option, else what an earlier install stored in the config
# (TOOL_CLAUDE / TOOL_CODEX = on|off), else yes.
tool_on() {   # tool_on <config key> <option value yes|no|empty>
    case "$2" in yes|no) printf '%s' "$2"; return ;; esac
    if [ "$(sed -n "s/^$1=//p" "$ROOT$CONF" 2>/dev/null | tail -n 1 | tr -d '\042\047')" = off ]; then printf no; else printf yes; fi
}
CLAUDE_ON="$(tool_on TOOL_CLAUDE "$CLAUDE_ON")"
CODEX_ON="$(tool_on TOOL_CODEX "$CODEX_ON")"

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

merge_managed() {   # merge_managed <current> <out> <python> <libdir> <template>...
    python3 -I - "$@" <<'PY'
import json, os, sys
target, out, python, libdir = sys.argv[1:5]
MARK = "termux-rootbridge"
new, asks = {}, []
for template_path in sys.argv[5:]:
    raw = open(template_path, encoding="utf-8").read()
    raw = raw.replace("@PYTHON@", python).replace("@LIBDIR@", libdir)
    tpl = json.loads(raw)
    for event, entries in tpl.get("hooks", {}).items():
        new.setdefault(event, []).extend(entries)
    for rule in tpl.get("permissions", {}).get("ask", []):
        if rule not in asks:
            asks.append(rule)
try:
    cur = json.load(open(target, encoding="utf-8"))
except (OSError, ValueError):
    cur = {}
# Every entry of ours is replaced by the ones of the templates (so an entry that is no longer in them,
# e.g. the Codex hook after --no-codex, goes); entries of anybody else stay.
hooks = cur.setdefault("hooks", {})
for event, entries in new.items():
    kept = [e for e in hooks.get(event, [])
            if not any(MARK in h.get("command", "") for h in e.get("hooks", []))]
    hooks[event] = kept + entries
perms = cur.setdefault("permissions", {})
ask = perms.setdefault("ask", [])
for rule in asks:
    if rule not in ask:
        ask.append(rule)
with open(out, "w", encoding="utf-8") as fh:
    json.dump(cur, fh, indent=2, ensure_ascii=False)
    fh.write("\n")
PY
}

# settings_queue <key> <json-value> [missing]: remember one key for ~/.claude/settings.json.
# settings_apply writes everything remembered in ONE go (one write, at most one backup; a fresh
# installation does not leave intermediate versions behind).
#   <key>   may be a dotted path (permissions.defaultMode)
#   missing an existing value stays (a default, not a decision); without it the value is always written
# All other keys stay; nothing is written (and nothing backed up) if everything is already there;
# a file that is not valid JSON is left alone with a warning.
SETTINGS_Q=()
settings_queue() { SETTINGS_Q+=("$1" "$2" "${3:-}"); }
settings_apply() {
    [ "${#SETTINGS_Q[@]}" -gt 0 ] || return 0
    local s="$ROOT$HOME_DIR/.claude/settings.json" rc=0 kind key raw mode i keys=""
    local msgs="$s.msgs.$$"
    mkdir -p "$(dirname "$s")"
    python3 -I - "$s" "$s.new.$$" "${SETTINGS_Q[@]}" > "$msgs" <<'PY' || rc=$?
import json, sys
path, out = sys.argv[1:3]
rest = sys.argv[3:]
entries = [rest[i:i + 3] for i in range(0, len(rest), 3)]
try:
    with open(path, encoding="utf-8") as fh:
        cur = json.load(fh)
except FileNotFoundError:
    cur = {}
except (OSError, ValueError):
    sys.exit(3)
if not isinstance(cur, dict):
    sys.exit(3)
changed = False
for key, raw, mode in entries:
    value = json.loads(raw)
    node = cur
    parts = key.split(".")
    ok = True
    for part in parts[:-1]:
        node = node.setdefault(part, {})
        if not isinstance(node, dict):
            ok = False
            break
    if not ok:
        print("BAD\t%s\t%s\t%s" % (key, raw, mode))
        continue
    last = parts[-1]
    if last in node and (mode == "missing" or node[last] == value):
        print("KEEP\t%s\t%s\t%s" % (key, raw, mode))
        continue
    node[last] = value
    changed = True
    print("SET\t%s\t%s\t%s" % (key, raw, mode))
if not changed:
    sys.exit(4)
with open(out, "w", encoding="utf-8") as fh:
    json.dump(cur, fh, indent=2, ensure_ascii=False)
    fh.write("\n")
PY
    for ((i = 0; i < ${#SETTINGS_Q[@]}; i += 3)); do keys="$keys ${SETTINGS_Q[i]}"; done
    SETTINGS_Q=()
    case "$rc" in
        0) commit_file "$s.new.$$" "$s" ;;
        4) ;;
        3) rm -f "$msgs"
           say "  Hinweis: ~/.claude/settings.json ist kein gültiges JSON-Objekt - nicht gesetzt:$keys"
           return 0 ;;
        *) rm -f "$s.new.$$" "$msgs"; echo "settings_apply: Fehler ($rc)" >&2; return 1 ;;
    esac
    while IFS=$'\t' read -r kind key raw mode; do
        case "$kind" in
            SET)  say "  ~/.claude/settings.json: $key=$raw" ;;
            KEEP) if [ "$mode" = missing ]; then
                      say "  ~/.claude/settings.json: $key ist bereits belegt - bleibt unverändert"
                  else
                      say "  ~/.claude/settings.json: $key=$raw (schon gesetzt)"
                  fi ;;
            BAD)  say "  Hinweis: ~/.claude/settings.json: $key nicht gesetzt (ein übergeordneter Eintrag ist kein Objekt)." ;;
        esac
    done < "$msgs"
    rm -f "$msgs"
}

unmerge_managed() {
    [ -f "$ROOT$MANAGED" ] || return 0
    python3 -I - "$ROOT$MANAGED" <<'PY'
import json, sys
path = sys.argv[1]
cur = json.load(open(path, encoding="utf-8"))
MARK = "termux-rootbridge"
for event in list(cur.get("hooks", {})):
    cur["hooks"][event] = [e for e in cur["hooks"][event]
        if not any(MARK in h.get("command", "") for h in e.get("hooks", []))]
    if not cur["hooks"][event]:
        del cur["hooks"][event]
cur["hooks"] = cur.get("hooks") or {}
if not cur["hooks"]:
    cur.pop("hooks")
ask = [r for r in cur.get("permissions", {}).get("ask", [])
       if "androidsu" not in r and "termux-rootbridge" not in r
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
    for f in androidsu rootbridge-open rootbridge-claude rootbridge-codex rootbridge-update rootbridge-apt; do rm -f "$ROOT$BINDIR/$f"; done
    [ -L "$ROOT$BINDIR/xdg-open" ] && rm -f "$ROOT$BINDIR/xdg-open"
    rm -rf "$ROOT$LIBDIR" "$ROOT/var/lib/termux-rootbridge"
    rm -f "$ROOT$CONF"
    strip_block "$ROOT$HOME_DIR/.bashrc"
    say "Fertig. ($ROOT$HOME_DIR/.claude/settings.json bleibt unverändert.)"
    exit 0
fi

# ------------------------------------------------------------------ install
say "== Gast: Installation (Quelle: $SRC)"
if [ "$CLAUDE_ON" = no ] && [ "$CODEX_ON" = no ]; then
    echo "Mindestens eines von Claude Code und Codex muss installiert werden (--claude yes / --codex yes)." >&2
    exit 2
fi
for need in python3 bash sha256sum od timeout; do
    command -v "$need" >/dev/null 2>&1 || { echo "FEHLT: $need (apt install python3 coreutils)" >&2; exit 1; }
done
if [ "$CLAUDE_ON" = yes ]; then
    command -v claude >/dev/null 2>&1 || [ -x "$ROOT$HOME_DIR/.local/bin/claude" ] \
        || say "  Hinweis: claude nicht gefunden (curl -fsSL https://claude.ai/install.sh | bash)"
fi
if [ "$CODEX_ON" = yes ]; then
    command -v codex >/dev/null 2>&1 || [ -x "$ROOT$HOME_DIR/.local/bin/codex" ] || [ -L "$ROOT$HOME_DIR/.local/bin/codex" ] \
        || say "  Hinweis: codex nicht gefunden (curl -fsSL https://chatgpt.com/codex/install.sh | sh)"
fi
say "  Programme: Claude Code $CLAUDE_ON, Codex $CODEX_ON"

PYTHON="$(command -v python3)"

put "$SRC/bin/androidsu"         "$BINDIR/androidsu"
put "$SRC/bin/rootbridge-open"   "$BINDIR/rootbridge-open"
put "$SRC/bin/rootbridge-apt"    "$BINDIR/rootbridge-apt"
put "$SRC/bin/rootbridge-update" "$BINDIR/rootbridge-update"
# what belongs to a tool that is switched off is removed again (a reinstall with --claude no / --codex no)
if [ "$CLAUDE_ON" = yes ]; then
    put "$SRC/bin/rootbridge-claude" "$BINDIR/rootbridge-claude"
    put "$SRC/claude/android-root-guard.py" "$LIBDIR/android-root-guard.py"
    put "$SRC/claude/auth-url-hook.py"      "$LIBDIR/auth-url-hook.py"
else
    rm -f "$ROOT$BINDIR/rootbridge-claude" "$ROOT$LIBDIR/android-root-guard.py" "$ROOT$LIBDIR/auth-url-hook.py"
fi
if [ "$CODEX_ON" = yes ]; then
    put "$SRC/bin/rootbridge-codex" "$BINDIR/rootbridge-codex"
else
    rm -f "$ROOT$BINDIR/rootbridge-codex"
fi
# the Codex pre-commit review hook runs inside Claude Code: it needs both
if [ "$CLAUDE_ON" = yes ] && [ "$CODEX_ON" = yes ]; then
    put "$SRC/claude/codex-precommit-review.py" "$LIBDIR/codex-precommit-review.py"
else
    rm -f "$ROOT$LIBDIR/codex-precommit-review.py"
fi

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
for kv in "BRIDGE_DIR=$BRIDGE_DIR" "TICKET_TTL=1800" "WORKDIR=/root/work" \
          "AUTH_OPEN=auto" "AUTH_REPLACE_OUTPUT=0" "TTY_CONFIRM=1" \
          "APT_UPGRADE=6h" "APT_TIMEOUT=1800" "CLAUDE_UPDATE=6h" "CODEX_UPDATE=6h" "NOFILE_LIMIT=2048" \
          "APT_HOLD=rust-coreutils gnu-coreutils coreutils-from-uutils coreutils" \
          "TOOL_CLAUDE=$([ "$CLAUDE_ON" = yes ] && echo on || echo off)" \
          "TOOL_CODEX=$([ "$CODEX_ON" = yes ] && echo on || echo off)"; do
    key="${kv%%=*}"
    grep -q "^$key=" "$ROOT$CONF" || printf '%s\n' "$kv" >> "$ROOT$CONF"
done
# Raise the previous 10-minute default for slow first upgrades under proot.
# Other timeout values remain as configured.
if grep -qx 'APT_TIMEOUT=600' "$ROOT$CONF"; then
    tmp="$ROOT$CONF.new.$$"
    sed 's/^APT_TIMEOUT=600$/APT_TIMEOUT=1800/' "$ROOT$CONF" > "$tmp"
    commit_file "$tmp" "$ROOT$CONF"
    say "  APT_TIMEOUT: 600 -> 1800 Sekunden"
fi
# APT_UPGRADE from --apt-upgrade: replace the line (an existing value stays without the option)
if [ "$APT_MODE_SET" = 1 ]; then
    tmp="$ROOT$CONF.new.$$"
    cp "$ROOT$CONF" "$tmp"
    sed -i "s|^APT_UPGRADE=.*|APT_UPGRADE=$APT_MODE|" "$tmp"
    commit_file "$tmp" "$ROOT$CONF"
    say "  APT_UPGRADE=$APT_MODE"
fi
# CLAUDE_UPDATE from --claude-update: same (an existing value stays without the option)
if [ "$CLAUDE_UPD_SET" = 1 ]; then
    tmp="$ROOT$CONF.new.$$"
    cp "$ROOT$CONF" "$tmp"
    sed -i "s|^CLAUDE_UPDATE=.*|CLAUDE_UPDATE=$CLAUDE_UPD_MODE|" "$tmp"
    commit_file "$tmp" "$ROOT$CONF"
    say "  CLAUDE_UPDATE=$CLAUDE_UPD_MODE"
fi
# CODEX_UPDATE from --codex-update: same (an existing value stays without the option)
if [ "$CODEX_UPD_SET" = 1 ]; then
    tmp="$ROOT$CONF.new.$$"
    cp "$ROOT$CONF" "$tmp"
    sed -i "s|^CODEX_UPDATE=.*|CODEX_UPDATE=$CODEX_UPD_MODE|" "$tmp"
    commit_file "$tmp" "$ROOT$CONF"
    say "  CODEX_UPDATE=$CODEX_UPD_MODE"
fi
# TOOL_CLAUDE / TOOL_CODEX (which tools this installation has; read by rootbridge-update and later installs) were
# added above if missing; a changed choice (--claude no, --codex yes, ...) replaces the stored value
for kv in "TOOL_CLAUDE=$([ "$CLAUDE_ON" = yes ] && echo on || echo off)" "TOOL_CODEX=$([ "$CODEX_ON" = yes ] && echo on || echo off)"; do
    key="${kv%%=*}"
    if [ "$(sed -n "s/^$key=//p" "$ROOT$CONF" | tail -n 1)" != "${kv#*=}" ]; then
        tmp="$ROOT$CONF.new.$$"
        cp "$ROOT$CONF" "$tmp"
        sed -i "s|^$key=.*|$kv|" "$tmp"
        commit_file "$tmp" "$ROOT$CONF"
        say "  $kv"
    fi
done
# Remote Control name -> CLAUDE_ARGS (other arguments stay; a new line also gets --continue,
# because the name belongs to the session and --continue keeps that session).
# --remote-control NAME turns Remote Control on and titles a new bridge session. The bridge session is reused
# across restarts and /clear and keeps its title (also one set with /rename). Deliberately no --name: it would
# also show the name in the frame of the input field.
if [ -n "$REMOTE_NAME" ] && [ "$CLAUDE_ON" = yes ]; then
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
# The old default WORKDIR=/root/workspace was never created. If the folder is not there nobody uses it:
# move to the new default /root/work (an existing /root/workspace and any other value stay).
if grep -qx 'WORKDIR=/root/workspace' "$ROOT$CONF" && [ ! -e "$ROOT/root/workspace" ]; then
    cp "$ROOT$CONF" "$ROOT$CONF.new.$$"
    sed -i 's|^WORKDIR=/root/workspace$|WORKDIR=/root/work|' "$ROOT$CONF.new.$$"
    commit_file "$ROOT$CONF.new.$$" "$ROOT$CONF"
    say "  WORKDIR: /root/workspace -> /root/work (der alte Standardordner wurde nie angelegt)"
fi
chmod 644 "$ROOT$CONF"
say "  Konfiguration: $CONF"

# working directory of the Claude Code session: rootbridge-claude starts in it and falls back to /root
# if it is missing, so it has to exist (WORKDIR from the config, a value you set earlier stays)
wd="$(sed -n 's/^WORKDIR=//p' "$ROOT$CONF" | tail -n 1 | tr -d '\042\047')"
case "$wd" in
    *..*|"") wd=/root/work ;;
    /[A-Za-z0-9._/-]*) ;;
    *) wd=/root/work ;;
esac
mkdir -p "$ROOT$wd"
say "  Arbeitsordner: $wd"

# bridge directory must exist as a real node inside the guest (proot bind quirk)
mkdir -p "$ROOT$BRIDGE_DIR" 2>/dev/null || say "  Hinweis: $BRIDGE_DIR nicht anlegbar (Termux-Home nicht gebunden?)"

# managed settings (hooks + ask rules). Only with Claude Code; the Codex pre-commit review hook only with both.
if [ "$CLAUDE_ON" = yes ]; then
    templates=("$SRC/claude/managed-settings.template.json")
    [ "$CODEX_ON" = yes ] && templates+=("$SRC/claude/managed-settings.codex.template.json")
    mkdir -p "$ROOT$MANAGED_DIR"
    merge_managed "$ROOT$MANAGED" "$ROOT$MANAGED.new.$$" "$PYTHON" "$LIBDIR" "${templates[@]}"
    commit_file "$ROOT$MANAGED.new.$$" "$ROOT$MANAGED"
    say "  Managed Settings: $MANAGED"
    [ "$CODEX_ON" = yes ] && say "  Codex-Review vor dem Commit: Hook in den Managed Settings (Notausgang: rootbridge codex-off)"
else
    unmerge_managed
    say "  Managed Settings: ohne Claude Code nichts zu tun (Einträge dieser Installation entfernt)"
fi

# autonomous mode: skip the one-time warning dialog of bypass mode (Claude Code only)
if [ "$CLAUDE_ON" = no ]; then
    AUTONOMOUS=no
elif [ "$AUTONOMOUS" = ask ]; then
    if [ -t 0 ]; then
        printf 'Bypass-Modus ohne Warndialog freischalten (skipDangerousModePermissionPrompt)? [J/n] '
        read -r ans || ans=n
        case "$ans" in n|N) AUTONOMOUS=no ;; *) AUTONOMOUS=yes ;; esac
    else
        AUTONOMOUS=no
    fi
fi
if [ "$AUTONOMOUS" = yes ]; then
    settings_queue skipDangerousModePermissionPrompt true
    # start in bypass mode (a default mode you chose yourself stays)
    settings_queue permissions.defaultMode '"bypassPermissions"' missing
fi

# Remote Control on at every session start (user scope; a value you set yourself stays). The
# `--remote-control NAME` flag in CLAUDE_ARGS does the same for sessions started by rootbridge-claude.
if [ -n "$REMOTE_NAME" ] && [ "$CLAUDE_ON" = yes ]; then
    settings_queue remoteControlAtStartup true missing
fi

# model: "opusplan" (Opus plans, Sonnet works) unless you already have one; --model always writes
if [ "$MODEL" != none ] && [ "$CLAUDE_ON" = yes ]; then
    if [ "$MODEL_SET" = 1 ]; then
        settings_queue model "\"$MODEL\""
    else
        settings_queue model "\"$MODEL\"" missing
    fi
fi

# Claude Code theme (only when asked for: install.sh passes --theme unless --no-colors)
if [ "$THEME_SET" = 1 ] && [ "$CLAUDE_ON" = yes ]; then
    settings_queue theme "\"$THEME\""
    # "Auto epaper": created once with the ANSI base (the 16 colours of the Termux scheme). A file exactly as an
    # earlier version created it (daltonized base) moves to the ANSI base, light or dark stays; any other file
    # (your base, your overrides) stays as it is.
    T="$ROOT$HOME_DIR/.claude/themes/epaper.json"
    epaper_theme() { printf '%s\n' '{' '  "name": "Auto epaper",' "  \"base\": \"$1\"," '  "overrides": {}' '}'; }
    if [ "$THEME" = custom:epaper ]; then
        if [ ! -e "$T" ]; then
            mkdir -p "$(dirname "$T")"
            epaper_theme light-ansi > "$T"
        else
            for m in light dark; do
                if [ "$(cat "$T")" = "$(epaper_theme "$m-daltonized")" ]; then
                    epaper_theme "$m-ansi" > "$T.new.$$" && mv -f "$T.new.$$" "$T"
                    echo "Theme Auto epaper: Basis $m-daltonized -> $m-ansi"
                fi
            done
        fi
    fi
fi
settings_apply

# guest ~/.bashrc: claude() wrapper with browser hand-off and bypass availability
B="$ROOT$HOME_DIR/.bashrc"
mkdir -p "$(dirname "$B")"
touch "$B"
cp "$B" "$B.new.$$"
strip_block "$B.new.$$"
sed -i '/# rootbridge_bin$/d' "$B.new.$$"
cat >> "$B.new.$$" <<EOF

$BEGIN
# The official installers of Claude Code and Codex put claude and codex into ~/.local/bin.
case ":\$PATH:" in *":\$HOME/.local/bin:"*) ;; *) export PATH="\$HOME/.local/bin:\$PATH" ;; esac
EOF
if [ "$CLAUDE_ON" = yes ]; then
cat >> "$B.new.$$" <<EOF
# Browser hand-off for logins (/login, /mcp) and bypass mode selectable with Shift+Tab.
# A Remote Control name set in CLAUDE_ARGS ($CONF) is applied here too (the name only, no other flags).
claude() {
    local conf="\${ROOTBRIDGE_CONF:-$CONF}" name="" rc=() nofile=""
    if [ -r "\$conf" ]; then
        name="\$(sed -n 's/^CLAUDE_ARGS=.*--remote-control[ =]\([A-Za-z0-9._][A-Za-z0-9._-]*\).*/\1/p' "\$conf" | tail -n 1)"
        nofile="\$(sed -n 's/^NOFILE_LIMIT=//p' "\$conf" | tail -n 1 | tr -d '\042\047')"
    fi
    [ -n "\$name" ] && rc=(--remote-control "\$name")
    case " \$* " in
        *" -p "*|*" --print "*|*" --remote-control"*|*" -v "*|*" --version "*|*" -h "*|*" --help "*) rc=() ;;
    esac
    # Claude Code closes every fd up to the limit after each fork; under proot that costs 2.5-4 s per
    # started process. Lowered in a subshell, never raised; NOFILE_LIMIT=0 in $CONF switches it off.
    (
        nofile="\${nofile:-2048}"
        case "\$nofile" in
            ''|0|*[!0-9]*) ;;
            *) if [ "\$(ulimit -Hn)" = unlimited ] || [ "\$(ulimit -Hn)" -gt "\$nofile" ] 2>/dev/null; then
                   ulimit -n "\$nofile" 2>/dev/null
               fi ;;
        esac
        case "\${1:-}" in
            ""|-*) IS_SANDBOX=1 BROWSER=$BINDIR/rootbridge-open command claude --allow-dangerously-skip-permissions "\${rc[@]}" "\$@" ;;
            *)     BROWSER=$BINDIR/rootbridge-open command claude "\$@" ;;
        esac
    )
}
EOF
fi
if [ "$CODEX_ON" = yes ]; then
cat >> "$B.new.$$" <<EOF
# Browser hand-off for \`codex login\`: the link opens in Android's browser (like for Claude Code).
codex() { BROWSER=$BINDIR/rootbridge-open command codex "\$@"; }
EOF
fi
cat >> "$B.new.$$" <<EOF
$END
EOF
commit_file "$B.new.$$" "$B"
say "  ~/.bashrc: Block (PATH$([ "$CLAUDE_ON" = yes ] && echo ', claude()')$([ "$CODEX_ON" = yes ] && echo ', codex()'))"

say "Fertig. Gast-Teil installiert."
