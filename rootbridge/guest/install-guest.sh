#!/usr/bin/env bash
# install-guest.sh - guest (proot-distro Ubuntu) part of termux-rootbridge.
# Normally started by ../install.sh; can also be run by hand as root in the guest.
#
#   install-guest.sh [--src DIR] [--root DIR] [--autonomous yes|no|ask] [--remote-name NAME]
#                    [--theme NAME] [--model NAME|none] [--apt-upgrade 6h|<N>h|daily|always|off]
#                    [--claude yes|no] [--codex yes|no] [--codex-bypass yes|no] [--guidelines yes|no] [--voice yes|no]
#                    [--claude-update M] [--codex-update M] [--uninstall]
#
#   --claude yes|no   Claude Code is part of the installation (default yes). no = Codex only: no Claude Code
#                     settings, hooks, managed settings or claude() wrapper (an existing value in the config stays
#                     without the option)
#   --codex yes|no    Codex is part of the installation (default yes): rootbridge-codex (the Codex window), the
#                     update step and, together with Claude Code, the Codex pre-commit review hook in the managed
#                     settings (an existing value in the config stays without the option)
#   --codex-bypass yes|no  Codex without its own sandbox (default yes; only with Codex): under proot the bubblewrap
#                     sandbox fails on every command ("unsupported host mount"), so Codex gets
#                     CODEX_ARGS="--dangerously-bypass-approvals-and-sandbox" in /etc/termux-rootbridge.conf (your other
#                     arguments stay). no removes the flag again. Stored as CODEX_BYPASS. What keeps Android root closed is
#                     the Termux daemon, which asks you itself for every root request.
#   --guidelines yes|no  code quality guidelines for the agents (default yes): a marked block (<!-- >>> termux-rootbridge >>> -->)
#                     in ~/.claude/CLAUDE.md (with Claude Code) and ~/.codex/AGENTS.md (with Codex), text from templates/. Your
#                     own text in those files stays; no removes the blocks again. Stored as GUIDELINES.
#   --codex-update M  CODEX_UPDATE in /etc/termux-rootbridge.conf: `codex update` at the
#                     start of a session (rootbridge-update). Same values and rules as --claude-update.
#   --src DIR         directory that contains bin/, lib/ and claude/ (default: next to this script)
#   --root DIR        install below DIR instead of / (staging, tests)
#   --voice yes|no    voice dictation for Claude Code (default yes; needs Claude Code): ~/.claude/keybindings.json gets
#                     meta+k = voice:pushToTalk (Chat context; an existing binding for that action stays), and
#                     ~/.claude/settings.json "voice": {"enabled": true, "mode": "tap"} where you have not set it yet;
#                     speech output: rootbridge-speak and three hooks in the managed settings (Stop reads Claude's answer
#                     aloud with Piper or Articulino, PreToolUse its notes between tool calls, UserPromptSubmit ends it), and a
#                     text in our block of ~/.claude/CLAUDE.md (templates/speech.claude.md: summary first, questions last, for
#                     the short version read aloud). no removes the command, the hooks and that text again.
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
CLAUDE_ON=""; CODEX_ON=""; VOICE_ON=yes; BYPASS_ON=""; GUIDE_ON=""
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
        --codex-bypass)
            [ $# -ge 2 ] || { echo "--codex-bypass braucht yes oder no" >&2; exit 2; }
            BYPASS_ON="$2"; shift 2 ;;
        --guidelines)
            [ $# -ge 2 ] || { echo "--guidelines braucht yes oder no" >&2; exit 2; }
            GUIDE_ON="$2"; shift 2 ;;
        --voice)
            [ $# -ge 2 ] || { echo "--voice braucht yes oder no" >&2; exit 2; }
            VOICE_ON="$2"; shift 2 ;;
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

# check_mode <option> <value> <set 0|1>: exit 2 unless the value is 6h (1-999 hours), daily, always or off
check_mode() {
    [ "$3" = 1 ] || return 0
    [[ "$2" =~ ^(always|off|daily|[1-9][0-9]{0,2}h)$ ]] || {
        echo "--$1: ungültiger Wert '$2' (erlaubt: 6h (1-999 Stunden), daily, always, off)" >&2
        exit 2
    }
}
check_mode apt-upgrade "$APT_MODE" "$APT_MODE_SET"
check_mode claude-update "$CLAUDE_UPD_MODE" "$CLAUDE_UPD_SET"
check_mode codex-update "$CODEX_UPD_MODE" "$CODEX_UPD_SET"

case "$AUTONOMOUS" in
    yes|no|ask) ;;
    *) echo "--autonomous: ungültiger Wert '$AUTONOMOUS' (erlaubt: yes, no, ask)" >&2; exit 2 ;;
esac
for pair in "claude:$CLAUDE_ON" "codex:$CODEX_ON" "codex-bypass:$BYPASS_ON" "guidelines:$GUIDE_ON" "voice:$VOICE_ON"; do
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
# Codex without its sandbox (the option, else the stored CODEX_BYPASS, else yes) - only with Codex
GUIDE_SET=0; [ -z "$GUIDE_ON" ] || GUIDE_SET=1
GUIDE_ON="$(tool_on GUIDELINES "$GUIDE_ON")"
BYPASS_SET=0; [ -z "$BYPASS_ON" ] || BYPASS_SET=1
BYPASS_CHOICE="$(tool_on CODEX_BYPASS "$BYPASS_ON")"   # the choice that is stored (also while Codex is off)
BYPASS_ON="$BYPASS_CHOICE"
if [ "$CODEX_ON" = no ]; then BYPASS_ON=no; fi

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

# conf_set <KEY> <VALUE> [message]: set KEY=VALUE in the guest config (the line is replaced; a backup only on a change)
conf_set() {
    local tmp="$ROOT$CONF.new.$$"
    cp "$ROOT$CONF" "$tmp"
    sed -i "s|^$1=.*|$1=$2|" "$tmp"
    commit_file "$tmp" "$ROOT$CONF"
    [ -z "${3:-}" ] || say "  $3"
}

# onoff <yes|no>: the config spelling of a choice
onoff() { if [ "$1" = yes ]; then echo on; else echo off; fi; }

# strip_block <file>: remove our marked block
strip_block() {
    [ -f "$1" ] || return 0
    python3 -I "$SRC/lib/rbfile.py" drop "$1" "$BEGIN" "$END"
}

merge_managed() {   # merge_managed <current> <out> <python> <libdir> <template>...
    python3 -I - "$@" <<'PY'
import json, os, sys
target, out, python, libdir = sys.argv[1:5]
MARK = "termux-rootbridge"
new, asks = {}, []
plugins = {"enabledPlugins": {}, "extraKnownMarketplaces": {}}
for template_path in sys.argv[5:]:
    raw = open(template_path, encoding="utf-8").read()
    raw = raw.replace("@PYTHON@", python).replace("@LIBDIR@", libdir)
    tpl = json.loads(raw)
    for key in plugins:
        plugins[key].update(tpl.get(key, {}))
    for event, entries in tpl.get("hooks", {}).items():
        new.setdefault(event, []).extend(entries)
    for rule in tpl.get("permissions", {}).get("ask", []):
        if rule not in asks:
            asks.append(rule)
try:
    cur = json.load(open(target, encoding="utf-8"))
except (OSError, ValueError):
    cur = {}
# Every entry of ours, in every event, is replaced by the ones of the templates (so an entry that is no longer in
# them goes: the Codex hook after --no-codex, the guard of an earlier version); entries of anybody else stay.
hooks = cur.setdefault("hooks", {})
for event in list(hooks):
    hooks[event] = [e for e in hooks[event]
                    if not any(MARK in h.get("command", "") for h in e.get("hooks", []))]
for event, entries in new.items():
    hooks[event] = hooks.get(event, []) + entries
for event in [e for e, entries in hooks.items() if not entries]:
    del hooks[event]
# These two declarations belong to the Codex review hook. Claude Code fetches the plugin at startup.
# Removing the Codex template must also remove the declarations, while keeping other plugins/marketplaces.
for key, owned in (("enabledPlugins", "codex@openai-codex"), ("extraKnownMarketplaces", "openai-codex")):
    values = cur.get(key, {})
    values.pop(owned, None)
    values.update(plugins[key])
    if values:
        cur[key] = values
    else:
        cur.pop(key, None)
perms = cur.setdefault("permissions", {})
# the rules of earlier versions (the guard asked in Claude Code; the Termux daemon asks now) go
ask = [r for r in perms.get("ask", [])
       if "androidsu" not in r and "/etc/claude-code" not in r and "rootbridge" not in r
       and "/usr/local/bin/xdg-open" not in r]
for rule in asks:
    if rule not in ask:
        ask.append(rule)
if ask:
    perms["ask"] = ask
else:
    perms.pop("ask", None)
if not perms:
    cur.pop("permissions")
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
for key, owned in (("enabledPlugins", "codex@openai-codex"), ("extraKnownMarketplaces", "openai-codex")):
    if key in cur:
        cur[key].pop(owned, None)
        if not cur[key]:
            del cur[key]
ask = [r for r in cur.get("permissions", {}).get("ask", [])
       if "androidsu" not in r and "/etc/claude-code" not in r and "rootbridge" not in r
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
    for f in androidsu rootbridge-open rootbridge-claude rootbridge-codex rootbridge-update rootbridge-apt rootbridge-speak; do rm -f "$ROOT$BINDIR/$f"; done
    [ -L "$ROOT$BINDIR/xdg-open" ] && rm -f "$ROOT$BINDIR/xdg-open"
    rm -rf "$ROOT$LIBDIR" "$ROOT/var/lib/termux-rootbridge"
    # the managed Codex hook: only our block (a requirements.toml of your own stays)
    REQ=/etc/codex/requirements.toml
    if [ -f "$ROOT$REQ" ] && grep -qxF "$BEGIN" "$ROOT$REQ"; then
        python3 -I "$SRC/lib/rbfile.py" drop "$ROOT$REQ" "$BEGIN" "$END"
        if ! grep -q '[^[:space:]]' "$ROOT$REQ"; then rm -f "$ROOT$REQ"; rmdir "$ROOT$(dirname "$REQ")" 2>/dev/null || true; fi
    fi
    for gf in .claude/CLAUDE.md .codex/AGENTS.md; do
        if [ -f "$ROOT$HOME_DIR/$gf" ] && grep -qxF '<!-- >>> termux-rootbridge >>> -->' "$ROOT$HOME_DIR/$gf"; then
            python3 -I "$SRC/lib/rbfile.py" drop "$ROOT$HOME_DIR/$gf" '<!-- >>> termux-rootbridge >>> -->' '<!-- <<< termux-rootbridge <<< -->'
            grep -q '[^[:space:]]' "$ROOT$HOME_DIR/$gf" || rm -f "$ROOT$HOME_DIR/$gf"
        fi
    done
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

# the python3 of the guest itself where there is one: the agents' hooks run in isolated sessions (no Termux inside)
PYTHON=/usr/bin/python3
[ -x "$ROOT$PYTHON" ] || PYTHON="$(command -v python3)"

put "$SRC/lib/rootbridge-guest-lib.sh" "$LIBDIR/rootbridge-guest-lib.sh" 644   # sourced by the scripts below
put "$SRC/bin/androidsu"         "$BINDIR/androidsu"
put "$SRC/bin/rootbridge-open"   "$BINDIR/rootbridge-open"
put "$SRC/bin/rootbridge-apt"    "$BINDIR/rootbridge-apt"
put "$SRC/bin/rootbridge-update" "$BINDIR/rootbridge-update"
# what belongs to a tool that is switched off is removed again (a reinstall with --claude no / --codex no)
if [ "$CLAUDE_ON" = yes ]; then
    put "$SRC/bin/rootbridge-claude" "$BINDIR/rootbridge-claude"
    put "$SRC/claude/auth-url-hook.py"      "$LIBDIR/auth-url-hook.py"
    put "$SRC/claude/claude-conversation.py" "$LIBDIR/claude-conversation.py"
else
    rm -f "$ROOT$BINDIR/rootbridge-claude" "$ROOT$LIBDIR/auth-url-hook.py" "$ROOT$LIBDIR/claude-conversation.py"
fi
if [ "$CODEX_ON" = yes ]; then
    put "$SRC/bin/rootbridge-codex" "$BINDIR/rootbridge-codex"
else
    rm -f "$ROOT$BINDIR/rootbridge-codex"
fi
# speech output (part of voice, Claude Code only): reads Claude's answers aloud (Piper or Articulino with speak-server.py,
# both installed by setup-guest.sh)
if [ "$VOICE_ON" = yes ] && [ "$CLAUDE_ON" = yes ]; then
    put "$SRC/claude/speak.py"       "$LIBDIR/speak.py"
    put "$SRC/claude/speak-english.txt" "$LIBDIR/speak-english.txt"
    put "$SRC/claude/speak-server.py" "$LIBDIR/speak-server.py"
    put "$SRC/bin/rootbridge-speak"  "$BINDIR/rootbridge-speak"
else
    rm -f "$ROOT$LIBDIR/speak.py" "$ROOT$LIBDIR/speak-english.txt" "$ROOT$LIBDIR/speak-server.py" "$ROOT$BINDIR/rootbridge-speak"
fi
# rootbridge-hook.py hands the refusals of the Termux daemon to the agent that asked (Claude Code and Codex)
put "$SRC/claude/rootbridge-hook.py" "$LIBDIR/rootbridge-hook.py"
# the guards of the earlier versions (the daemon asks now, tickets are gone)
rm -f "$ROOT$LIBDIR/android-root-guard.py" "$ROOT$LIBDIR/codex-root-guard.py"
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

# uutils: rust-coreutils is one 10 MB multicall program, hard-linked under about 115 names. Unpacked under proot
# every name became a copy of its own (1.2 GB). A name that GNU coreutils has as well (gnu-coreutils, which
# coreutils-from-uutils depends on) becomes a link to the GNU program; uutils itself refuses links to its
# multicall program ("Security violation"). Only single copies (one link) are touched. The package is on
# hold (APT_HOLD); `apt-get install --reinstall rust-coreutils` brings the copies back.
UU_DIR=/usr/lib/cargo/bin/coreutils
if [ -d "$ROOT$UU_DIR" ]; then
    n=0
    while IFS= read -r -d '' f; do
        gnu="/usr/bin/gnu${f##*/}"
        [ -x "$ROOT$gnu" ] && ln -s "$gnu" "$f.rb-link.$$" && mv -f "$f.rb-link.$$" "$f" && n=$((n + 1))
    done < <(find "$ROOT$UU_DIR" -maxdepth 1 -type f -links 1 -print0)
    [ "$n" = 0 ] || say "  uutils: $n Kopien durch Links auf GNU coreutils ersetzt (je etwa 10 MB frei)"
fi

# configuration (keep user edits, add missing keys)
mkdir -p "$ROOT$(dirname "$CONF")"
touch "$ROOT$CONF"
for kv in "BRIDGE_DIR=$BRIDGE_DIR" "WORKDIR=/root/work" \
          "AUTH_OPEN=auto" "AUTH_REPLACE_OUTPUT=0" \
          "APT_UPGRADE=6h" "APT_TIMEOUT=600" "CLAUDE_UPDATE=6h" "CODEX_UPDATE=6h" "NOFILE_LIMIT=2048" \
          "APT_HOLD=rust-coreutils gnu-coreutils coreutils-from-uutils coreutils" \
          "TOOL_CLAUDE=$(onoff "$CLAUDE_ON")" \
          "TOOL_CODEX=$(onoff "$CODEX_ON")"; do
    key="${kv%%=*}"
    grep -q "^$key=" "$ROOT$CONF" || printf '%s\n' "$kv" >> "$ROOT$CONF"
done
# Lower the former default 1800 back to 600: a longer limit did not help when dpkg hangs under proot.
# Other timeout values remain as configured.
if grep -qx 'APT_TIMEOUT=1800' "$ROOT$CONF"; then
    conf_set APT_TIMEOUT 600 "APT_TIMEOUT: 1800 -> 600 Sekunden"
fi
# APT_UPGRADE / CLAUDE_UPDATE / CODEX_UPDATE from the options: replace the line (an existing value stays without the option)
if [ "$APT_MODE_SET" = 1 ]; then conf_set APT_UPGRADE "$APT_MODE" "APT_UPGRADE=$APT_MODE"; fi
if [ "$CLAUDE_UPD_SET" = 1 ]; then conf_set CLAUDE_UPDATE "$CLAUDE_UPD_MODE" "CLAUDE_UPDATE=$CLAUDE_UPD_MODE"; fi
if [ "$CODEX_UPD_SET" = 1 ]; then conf_set CODEX_UPDATE "$CODEX_UPD_MODE" "CODEX_UPDATE=$CODEX_UPD_MODE"; fi
# TOOL_CLAUDE / TOOL_CODEX (which tools this installation has; read by rootbridge-update and later installs) were
# added above if missing; a changed choice (--claude no, --codex yes, ...) replaces the stored value
for kv in "TOOL_CLAUDE=$(onoff "$CLAUDE_ON")" "TOOL_CODEX=$(onoff "$CODEX_ON")"; do
    key="${kv%%=*}"
    if [ "$(sed -n "s/^$key=//p" "$ROOT$CONF" | tail -n 1)" != "${kv#*=}" ]; then conf_set "$key" "${kv#*=}" "$kv"; fi
done
# Codex without its sandbox (--codex-bypass). The choice is stored as CODEX_BYPASS (on|off) when it was given.
if [ "$BYPASS_SET" = 1 ]; then
    grep -q '^CODEX_BYPASS=' "$ROOT$CONF" || printf 'CODEX_BYPASS=%s\n' "$(onoff "$BYPASS_CHOICE")" >> "$ROOT$CONF"
    if [ "$(sed -n 's/^CODEX_BYPASS=//p' "$ROOT$CONF" | tail -n 1)" != "$(onoff "$BYPASS_CHOICE")" ]; then
        conf_set CODEX_BYPASS "$(onoff "$BYPASS_CHOICE")" "CODEX_BYPASS=$(onoff "$BYPASS_CHOICE")"
    fi
fi
if [ "$GUIDE_SET" = 1 ]; then
    grep -q '^GUIDELINES=' "$ROOT$CONF" || printf 'GUIDELINES=%s\n' "$(onoff "$GUIDE_ON")" >> "$ROOT$CONF"
    if [ "$(sed -n 's/^GUIDELINES=//p' "$ROOT$CONF" | tail -n 1)" != "$(onoff "$GUIDE_ON")" ]; then
        conf_set GUIDELINES "$(onoff "$GUIDE_ON")" "GUIDELINES=$(onoff "$GUIDE_ON")"
    fi
fi
BYPASS_FLAG="--dangerously-bypass-approvals-and-sandbox"
REQ_DIR=/etc/codex
REQ="$REQ_DIR/requirements.toml"

# codex_args <add|remove>: put the bypass flag into CODEX_ARGS (other arguments stay) or take it out (an empty line goes)
codex_args() {
    local tmp="$ROOT$CONF.new.$$"
    python3 -I - "$ROOT$CONF" "$tmp" "$1" "$BYPASS_FLAG" <<'PY'
import sys
path, out, mode, flag = sys.argv[1:5]
lines = open(path, encoding="utf-8").read().split("\n")
idx = [i for i, l in enumerate(lines) if l.startswith("CODEX_ARGS=")]
val = ""
if idx:
    val = lines[idx[-1]].split("=", 1)[1].strip()
    if len(val) >= 2 and val[0] == val[-1] and val[0] in "\"'":
        val = val[1:-1]
toks = [t for t in val.split() if t != flag]
if mode == "add":
    toks.append(flag)
new = 'CODEX_ARGS="' + " ".join(toks) + '"' if toks else None
res = []
for i, l in enumerate(lines):
    if l.startswith("CODEX_ARGS="):
        if i == idx[-1] and new:
            res.append(new)
    else:
        res.append(l)
if not idx and new:
    while res and res[-1] == "":
        res.pop()
    res.append(new)
    res.append("")
with open(out, "w", encoding="utf-8") as fh:
    fh.write("\n".join(res))
PY
    if cmp -s "$tmp" "$ROOT$CONF"; then rm -f "$tmp"; return 0; fi
    commit_file "$tmp" "$ROOT$CONF"
    if [ "$1" = add ]; then say "  CODEX_ARGS: $BYPASS_FLAG (Codex ohne eigene Sandbox)"; else say "  CODEX_ARGS: $BYPASS_FLAG entfernt"; fi
}

# the managed hook of Codex (requirements.toml is read as the managed layer, its hooks need no review in /hooks):
# it hands the refusals of the Termux daemon to Codex. A requirements.toml of your own stays untouched.
if [ "$CODEX_ON" = yes ]; then
    if [ -s "$ROOT$REQ" ] && python3 -I "$SRC/lib/rbfile.py" other "$ROOT$REQ" "$BEGIN" "$END" '[ \t]*[^ \t#]'; then
        say "  Hinweis: $REQ enthält eigene Einstellungen und bleibt unverändert. Der Melde-Hook für Codex fehlt dann:"
        say "           Codex erfährt nicht von abgelehnten Root-Anfragen (den Block von Hand ergänzen, siehe README)."
    else
        content="$ROOT$REQ.content.$$"
        mkdir -p "$ROOT$REQ_DIR"
        req_src="$ROOT$REQ"; [ -e "$req_src" ] || req_src=/dev/null
        cat > "$content" <<EOF
# Hands the refusals of the Termux daemon (Android root) to Codex: install.sh of termux-rootbridge.
[hooks]
managed_dir = "$LIBDIR"

[[hooks.PostToolUse]]
matcher = "Bash"

[[hooks.PostToolUse.hooks]]
type = "command"
command = "$PYTHON -I $LIBDIR/rootbridge-hook.py"
timeout = 15

[[hooks.UserPromptSubmit]]

[[hooks.UserPromptSubmit.hooks]]
type = "command"
command = "$PYTHON -I $LIBDIR/rootbridge-hook.py"
timeout = 15
EOF
        python3 -I "$SRC/lib/rbfile.py" set "$req_src" "$ROOT$REQ.new.$$" "$BEGIN" "$END" "$content"
        rm -f "$content"
        commit_file "$ROOT$REQ.new.$$" "$ROOT$REQ"
        chmod 644 "$ROOT$REQ"
        say "  Codex-Hook: $REQ (Managed Hook $LIBDIR/rootbridge-hook.py)"
    fi
elif [ -f "$ROOT$REQ" ] && grep -qxF "$BEGIN" "$ROOT$REQ"; then
    python3 -I "$SRC/lib/rbfile.py" drop "$ROOT$REQ" "$BEGIN" "$END"
    if ! grep -q '[^[:space:]]' "$ROOT$REQ"; then rm -f "$ROOT$REQ"; rmdir "$ROOT$REQ_DIR" 2>/dev/null || true; fi
    say "  Codex-Hook: Block aus $REQ entfernt"
fi
# Codex without its sandbox
if [ "$BYPASS_ON" = yes ]; then
    codex_args add
elif [ "$BYPASS_SET" = 1 ] || [ "$CODEX_ON" = no ]; then
    codex_args remove
fi

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
    conf_set WORKDIR /root/work "WORKDIR: /root/workspace -> /root/work (der alte Standardordner wurde nie angelegt)"
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

# managed settings (hooks + ask rules + plugin declaration). Only with Claude Code; Codex review only with both.
if [ "$CLAUDE_ON" = yes ]; then
    templates=("$SRC/claude/managed-settings.template.json")
    [ "$CODEX_ON" = yes ] && templates+=("$SRC/claude/managed-settings.codex.template.json")
    [ "$VOICE_ON" = yes ] && templates+=("$SRC/claude/managed-settings.voice.template.json")
    mkdir -p "$ROOT$MANAGED_DIR"
    merge_managed "$ROOT$MANAGED" "$ROOT$MANAGED.new.$$" "$PYTHON" "$LIBDIR" "${templates[@]}"
    commit_file "$ROOT$MANAGED.new.$$" "$ROOT$MANAGED"
    say "  Managed Settings: $MANAGED"
    if [ "$CODEX_ON" = yes ]; then
        say "  Codex-Review vor dem Commit: Hook in den Managed Settings (Notausgang: rootbridge codex-off)"
        say "  Codex-Plugin: Claude Code lädt codex@openai-codex beim Start automatisch (Netz nötig)."
    fi
    if [ "$VOICE_ON" = yes ]; then
        say "  Vorlesen: Hook in den Managed Settings (an/aus in Termux: rootbridge voice speak on|off)"
    fi
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

# voice dictation (/voice): on, in "tap" mode: one press starts, the next stops and sends. It fits both triggers: the side key
# (press = start, release = send) and the long press on Home (Android gives no release: once to start, once more to send). In
# "hold" the side key broke off (ptt's repeats start 1.2 s late). A value you set yourself stays.
if [ "$VOICE_ON" = yes ] && [ "$CLAUDE_ON" = yes ]; then
    settings_queue voice.enabled true missing
    settings_queue voice.mode '"tap"' missing
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

# ~/.claude/keybindings.json: meta+k starts and stops the recording (Chat context). The file is created if it is missing; in an
# existing one the binding is added only if nothing is bound to voice:pushToTalk yet and meta+k is free. A file that is not
# valid JSON, or has an unexpected shape, stays as it is.
if [ "$VOICE_ON" = yes ] && [ "$CLAUDE_ON" = yes ]; then
    KB="$ROOT$HOME_DIR/.claude/keybindings.json"
    mkdir -p "$(dirname "$KB")"
    rc=0
    python3 -I - "$KB" "$KB.new.$$" <<'PY' || rc=$?
import json, os, sys
path, out = sys.argv[1:3]
ACTION, KEY = "voice:pushToTalk", "meta+k"
if os.path.exists(path):
    try:
        data = json.load(open(path, encoding="utf-8"))
    except ValueError:
        sys.exit(10)
else:
    data = {"$schema": "https://www.schemastore.org/claude-code-keybindings.json", "bindings": []}
if not isinstance(data, dict) or not isinstance(data.get("bindings"), list):
    sys.exit(10)
chat = None
for block in data["bindings"]:
    if not isinstance(block, dict) or not isinstance(block.get("bindings"), dict):
        sys.exit(10)
    if block.get("context") == "Chat" and block["bindings"].get(KEY) == ACTION:
        sys.exit(13)                      # our binding from an earlier install
    if ACTION in block["bindings"].values():
        sys.exit(11)                      # already bound to something: the user's choice
    if block.get("context") == "Chat":
        chat = block
if chat is None:
    chat = {"context": "Chat", "bindings": {}}
    data["bindings"].append(chat)
if KEY in chat["bindings"]:
    sys.exit(12)                          # meta+k is used for something else
chat["bindings"][KEY] = ACTION
with open(out, "w", encoding="utf-8") as fh:
    json.dump(data, fh, indent=2, ensure_ascii=False)
    fh.write("\n")
PY
    case "$rc" in
        0)  backup "$KB"; mv -f "$KB.new.$$" "$KB"; say "  ~/.claude/keybindings.json: $([ -s "$KB.bak-$STAMP" ] && echo ergänzt || echo angelegt) (meta+k = voice:pushToTalk)" ;;
        13) say "  ~/.claude/keybindings.json: meta+k = voice:pushToTalk ist schon gesetzt" ;;
        11) say "  ~/.claude/keybindings.json: voice:pushToTalk ist schon belegt - bleibt unverändert (ptt drückt PTT_KEY, Standard M-k)" ;;
        12) say "  Hinweis: ~/.claude/keybindings.json: meta+k ist anders belegt - nicht gesetzt (PTT_KEY in der Termux-Konfig anpassen)" ;;
        *)  say "  Hinweis: ~/.claude/keybindings.json ist kein erwartetes JSON - nicht geändert" ;;
    esac
    rm -f "$KB.new.$$"
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
if [ "$VOICE_ON" = yes ] && [ "$CLAUDE_ON" = yes ]; then
# Voice: PulseAudio in Termux lets a client in only with its cookie (private to Termux; the guest shares the Termux home)
cat >> "$B.new.$$" <<'EOF'
[ -r /data/data/com.termux/files/home/.config/pulse/cookie ] && export PULSE_COOKIE=/data/data/com.termux/files/home/.config/pulse/cookie
EOF
fi
cat >> "$B.new.$$" <<EOF
$END
EOF
commit_file "$B.new.$$" "$B"
say "  ~/.bashrc: Block (PATH$([ "$CLAUDE_ON" = yes ] && echo ', claude()')$([ "$CODEX_ON" = yes ] && echo ', codex()'))"

# guidelines: a marked block in the guidance file of each agent (Markdown: the markers are HTML comments)
GL_BEGIN='<!-- >>> termux-rootbridge >>> -->'
GL_END='<!-- <<< termux-rootbridge <<< -->'
# guidelines <file in the guest home> [template...]: our block in the file, the texts of the templates one after the other;
# without a template the block goes (an empty file goes). One block, so the file is written once per run.
guidelines() {
    local file="$ROOT$HOME_DIR/$1" src t
    shift
    if [ "$#" -gt 0 ]; then
        mkdir -p "$(dirname "$file")"
        for t in "$@"; do cat "$SRC/templates/$t"; echo; done > "$file.text.$$"
        src="$file"; [ -e "$src" ] || src=/dev/null
        python3 -I "$SRC/lib/rbfile.py" set "$src" "$file.new.$$" "$GL_BEGIN" "$GL_END" "$file.text.$$"
        rm -f "$file.text.$$"
        commit_file "$file.new.$$" "$file"
        say "  ~/${file#"$ROOT$HOME_DIR/"}: Richtlinien-Block ($*)"
    elif [ -f "$file" ] && grep -qxF "$GL_BEGIN" "$file"; then
        python3 -I "$SRC/lib/rbfile.py" drop "$file" "$GL_BEGIN" "$GL_END"
        grep -q '[^[:space:]]' "$file" || rm -f "$file"
        say "  ~/${file#"$ROOT$HOME_DIR/"}: Richtlinien-Block entfernt"
    fi
}
# Claude Code: code quality (--guidelines) and, with voice, the summary first and the question last, so the short version
# read aloud (speak-first) carries the answer; in German when Claude Code answers in German (its setting "language"), so
# English rules do not pull the answers into English. Codex: code quality.
claude_texts=(); codex_texts=()
if [ "$CLAUDE_ON" = yes ]; then
    lang="$(python3 -I -c 'import json, sys; print(str(json.load(open(sys.argv[1], encoding="utf-8")).get("language", "")).lower())' \
        "$ROOT$HOME_DIR/.claude/settings.json" 2>/dev/null)" || lang=""
    de=""; case "$lang" in german|deutsch|de|de[-_]*) de=.de ;; esac
    [ "$GUIDE_ON" = yes ] && claude_texts+=("code-quality$de.claude.md")
    [ "$VOICE_ON" = yes ] && claude_texts+=("speech$de.claude.md")
fi
[ "$GUIDE_ON" = yes ] && [ "$CODEX_ON" = yes ] && codex_texts+=(code-quality.codex.md)
guidelines .claude/CLAUDE.md "${claude_texts[@]}"
guidelines .codex/AGENTS.md "${codex_texts[@]}"

say "Fertig. Gast-Teil installiert."
