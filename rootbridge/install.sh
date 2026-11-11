#!/usr/bin/env bash
# install.sh - termux-rootbridge v2 installer. Run it in a TERMUX shell
# (not inside proot): the daemon needs real `su` outside proot.
#
#   bash install.sh [--no-guest] [--no-boot] [--no-migrate] [--no-colors] [--no-widgets]
#                   [--autonomous yes|no|ask] [--no-deps-check] [--remote-name NAME] [--no-extra-keys]
#                   [--apt-upgrade 6h|<N>h|daily|always|off | --no-apt-upgrade]
#                   [--claude-update 6h|<N>h|daily|always|off | --no-claude-update] [--no-setup]
#                   [--model NAME|none] [--claude | --no-claude] [--codex | --no-codex]
#                   [--codex-update 6h|<N>h|daily|always|off | --no-codex-update]
#                   [--voice | --no-voice] [--sidekey | --no-sidekey]
#
# Setup: an interactive Termux shell asks for the device name used in Claude Remote Control
# (Enter accepts the suggested name; --remote-name NAME skips the question).
# Missing components are installed automatically: the Termux packages
#   (pkg install), the Ubuntu guest (proot-distro install, a download of a few hundred MB),
#   python3/curl/certificates in the guest and Claude Code (official installer). A device that has it
#   all just gets the normal installation. --no-setup only checks and tells you what is missing
#   (--no-deps-check skips the package part, --no-guest the guest part). --setup is still accepted and
#   changes nothing. Still manual afterwards: the root grant, Termux:Boot once, the widget on the home
#   screen, the Claude login.
#
# --autonomous yes|no|ask: yes (default) sets skipDangerousModePermissionPrompt in the guest, so Claude
#   Code shows no warning dialog for bypass mode, and makes bypass mode the start mode
#   (permissions.defaultMode = bypassPermissions, only if settings.json has no default mode yet).
#   Every Android-root command still asks. no leaves both settings alone (an earlier value stays),
#   ask asks on a terminal.
#
# --model NAME|none: model in the guest's ~/.claude/settings.json. Default "opusplan" (Opus plans,
#   Sonnet works), written only if settings.json has no model yet; --model always writes it, none
#   leaves the model alone.
#
# --no-claude / --no-codex: leave one of the two tools out (Codex only, or Claude Code only; at least one stays).
#   Both are part of the installation by default: Claude Code (widget "Claude") and Codex (widget "Codex"), and each
#   one starts with the update of the other (rootbridge-update), because the two review each other: the Codex plugin
#   of Claude Code and a pre-commit review hook (Codex checks every `git commit` Claude Code makes; the strict loop,
#   fail-closed, emergency switch `rootbridge codex-off`). Without Claude Code there is no plugin and no hook.
#   Your choice is stored in the Termux config (TOOL_CLAUDE / TOOL_CODEX) and reused by every later install;
#   --claude / --codex turn a tool on again. --codex-update sets how often `codex update` runs at the start of a
#   session (6h default, like --claude-update; stored as CODEX_UPDATE). Still manual: the Codex login,
#   `rootbridge codex-login`.
#
# --voice / --no-voice: voice dictation for Claude Code's /voice, on by default (needs Claude Code). The installer sets up sox in
#   the guest (rec), PulseAudio in Termux (127.0.0.1 only, with the microphone source and 200 % gain, started with the session),
#   the guest's ~/.claude/keybindings.json (meta+k = voice:pushToTalk) and "voice": {"enabled": true, "mode": "hold"} in
#   ~/.claude/settings.json (both only where you have not decided yet), and `ptt` (start / stop). Android's microphone
#   permission for Termux needs root: on a terminal the installer asks for it (the root manager prompts), otherwise run
#   `rootbridge voice grant` once. The choice is stored in the Termux config (VOICE).
# --sidekey / --no-sidekey: the side key of the Hisense A9 as push to talk (hold = record, release = stop): installs sidekey-ptt,
#   which keeps a root `cat` on /dev/input/event2 running, and starts it with the session. Off by default, stored as SIDEKEY.
#   Set the long press of the E-Ink app to "Nothing". A bridge until the E-Ink app does it itself.
#
# Claude Code starts in /root/work in the guest (WORKDIR; the installer creates the folder).
#
# What it does (idempotent, with backups):
#   1. installs rootbridge + rootbridge-daemon + ptt (push to talk) into $PREFIX/bin
#   2. config ~/.config/termux-rootbridge/config (the Remote Control name is "android" unless
#      --remote-name NAME says otherwise; NAME is stored there as REMOTE_NAME and reused by every
#      later install), tmux clipboard settings
#   3. colours: no colour file is written (the E-Paper Termux build has the light and the dark scheme built in
#      and follows the phone; ~/.termux/colors-light.properties, colors-dark.properties and colors.properties
#      are optional overrides of yours). Only colour files that earlier versions installed, still exactly as
#      installed, are removed. --no-colors leaves those and the Claude Code theme alone. A ~/.bashrc block
#      (aliases `ubuntu` for the guest shell, `claude` / `codex` for the tool sessions; reloads the Termux settings
#      in every new shell; ordinary Termux windows stay plain shells, Claude Code starts
#      via the widgets, `claude`, `codex` or `rootbridge attach`), the Termux:Widget shortcuts
#      "Claude" and "Ubuntu" with the widget icon (an icon you chose stays; icons of the
#      earlier names "Claude Code" / "Ubuntu Shell" / "Claude >_" / "Ubuntu >_" are carried
#      over; --no-widgets skips all this), optional boot script, an extra keys row in
#      ~/.termux/termux.properties (S-TAB = Shift+Tab, KEYBOARD = soft keyboard on/off; an
#      extra-keys line of your own stays; --no-extra-keys skips it)
#   4. migrates the old popup based bridge (v1) away
#   5. installs the guest part (hooks, androidsu, managed settings, Claude Code
#      theme "Auto epaper" = custom:epaper, colour-blind friendly, follows light/dark) via proot-distro. The guest runs apt-get update + upgrade
#      at the start of the Claude Code session, at most once every 6 h (--apt-upgrade 12h
#      or daily = 24 h changes the distance, --no-apt-upgrade turns it off, --apt-upgrade
#      always runs it at every start; the choice is stored in the Termux config as
#      APT_UPGRADE and reused by every later install). A value already in
#      /etc/termux-rootbridge.conf stays when you run the installer without the option,
#      so switch an older "daily" once with --apt-upgrade 6h --claude-update 6h. `claude
#      update` follows the same rules: every 6 h by default (--claude-update 12h|daily|
#      always, --no-claude-update turns it off; stored as CLAUDE_UPDATE)

set -eu

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
BRIDGE_DIR="${BRIDGE_DIR:-$HOME/.rootbridge}"
STAMP="$(date +%Y%m%d%H%M%S)"
BEGIN='# >>> termux-rootbridge >>>'
END='# <<< termux-rootbridge <<<'

DO_SETUP=1; SETUP_DID=0; DO_GUEST=1; DO_BOOT=1; DO_MIGRATE=1; DO_COLORS=1; DO_WIDGETS=1; DO_EXTRAKEYS=1; DEPS=1; AUTONOMOUS=yes
CLAUDE_THEME=custom:epaper   # "Auto epaper": light-/dark-ansi, switched by the tmux hook (rootbridge theme)
REMOTE_NAME="android"; REMOTE_NAME_SET=0   # default name in the Remote Control view
APT_MODE=""; APT_MODE_SET=0
MODEL=""; MODEL_SET=0
CLAUDE_UPD_MODE=""; CLAUDE_UPD_SET=0
CODEX_UPD_MODE=""; CODEX_UPD_SET=0
USE_CLAUDE=yes; USE_CLAUDE_SET=0; USE_CODEX=yes; USE_CODEX_SET=0   # which tools: yes | no
USE_VOICE=yes; USE_VOICE_SET=0; USE_SIDEKEY=no; USE_SIDEKEY_SET=0   # voice dictation / side key as push to talk
NAME_RE='^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$'
APT_RE='^(always|off|daily|[1-9][0-9]{0,2}h)$'
while [ $# -gt 0 ]; do
    case "$1" in
        --setup) DO_SETUP=1 ;;   # the default, kept for older command lines
        --no-setup) DO_SETUP=0 ;;
        --no-guest) DO_GUEST=0 ;;
        --no-boot) DO_BOOT=0 ;;
        --no-migrate) DO_MIGRATE=0 ;;
        --no-colors) DO_COLORS=0 ;;
        --no-widgets) DO_WIDGETS=0 ;;
        --no-extra-keys) DO_EXTRAKEYS=0 ;;
        --no-deps-check) DEPS=0 ;;
        --autonomous) AUTONOMOUS="$2"; shift ;;
        --remote-name)
            [ $# -ge 2 ] || { echo "--remote-name braucht einen Namen" >&2; exit 2; }
            REMOTE_NAME="$2"; REMOTE_NAME_SET=1; shift ;;
        --apt-upgrade)
            [ $# -ge 2 ] || { echo "--apt-upgrade braucht 6h (Stunden), daily, always oder off" >&2; exit 2; }
            APT_MODE="$2"; APT_MODE_SET=1; shift ;;
        --no-apt-upgrade) APT_MODE=off; APT_MODE_SET=1 ;;
        --claude-update)
            [ $# -ge 2 ] || { echo "--claude-update braucht 6h (Stunden), daily, always oder off" >&2; exit 2; }
            CLAUDE_UPD_MODE="$2"; CLAUDE_UPD_SET=1; shift ;;
        --no-claude-update) CLAUDE_UPD_MODE=off; CLAUDE_UPD_SET=1 ;;
        --codex-update)
            [ $# -ge 2 ] || { echo "--codex-update braucht 6h (Stunden), daily, always oder off" >&2; exit 2; }
            CODEX_UPD_MODE="$2"; CODEX_UPD_SET=1; shift ;;
        --no-codex-update) CODEX_UPD_MODE=off; CODEX_UPD_SET=1 ;;
        --claude) USE_CLAUDE=yes; USE_CLAUDE_SET=1 ;;
        --no-claude) USE_CLAUDE=no; USE_CLAUDE_SET=1 ;;
        --codex) USE_CODEX=yes; USE_CODEX_SET=1 ;;
        --no-codex) USE_CODEX=no; USE_CODEX_SET=1 ;;
        --voice) USE_VOICE=yes; USE_VOICE_SET=1 ;;
        --no-voice) USE_VOICE=no; USE_VOICE_SET=1 ;;
        --sidekey) USE_SIDEKEY=yes; USE_SIDEKEY_SET=1 ;;
        --no-sidekey) USE_SIDEKEY=no; USE_SIDEKEY_SET=1 ;;
        --model)
            [ $# -ge 2 ] || { echo "--model braucht einen Namen oder none" >&2; exit 2; }
            MODEL="$2"; MODEL_SET=1; shift ;;
        -h|--help) sed -n '2,/^set -eu/{ /^set -eu/d; p; }' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unbekannte Option: $1" >&2; exit 2 ;;
    esac
    shift
done

case "$AUTONOMOUS" in
    yes|no|ask) ;;
    *) echo "--autonomous: ungültiger Wert '$AUTONOMOUS' (erlaubt: yes, no, ask)" >&2; exit 2 ;;
esac

MODEL_RE='^(none|[A-Za-z0-9][]A-Za-z0-9._:[-]{0,63})$'
if [ "$MODEL_SET" = 1 ] && ! [[ "$MODEL" =~ $MODEL_RE ]]; then
    echo "--model: ungültiger Name '$MODEL' (erlaubt: Buchstaben, Ziffern, . _ : - [ ]; max. 64 Zeichen; oder none)" >&2
    exit 2
fi

if [ "$REMOTE_NAME_SET" = 1 ] && ! [[ "$REMOTE_NAME" =~ $NAME_RE ]]; then
    echo "--remote-name: ungültiger Name '$REMOTE_NAME' (erlaubt: Buchstaben, Ziffern, . _ -; max. 64 Zeichen; nicht mit - beginnen)" >&2
    exit 2
fi

if [ "$APT_MODE_SET" = 1 ] && ! [[ "$APT_MODE" =~ $APT_RE ]]; then
    echo "--apt-upgrade: ungültiger Wert '$APT_MODE' (erlaubt: 6h (1-999 Stunden), daily, always, off)" >&2
    exit 2
fi

if [ "$CLAUDE_UPD_SET" = 1 ] && ! [[ "$CLAUDE_UPD_MODE" =~ $APT_RE ]]; then
    echo "--claude-update: ungültiger Wert '$CLAUDE_UPD_MODE' (erlaubt: 6h (1-999 Stunden), daily, always, off)" >&2
    exit 2
fi

if [ "$CODEX_UPD_SET" = 1 ] && ! [[ "$CODEX_UPD_MODE" =~ $APT_RE ]]; then
    echo "--codex-update: ungültiger Wert '$CODEX_UPD_MODE' (erlaubt: 6h (1-999 Stunden), daily, always, off)" >&2
    exit 2
fi

BOTH_OFF_MSG="Mindestens eines von Claude Code und Codex muss installiert werden (nicht --no-claude und --no-codex zusammen)."
if [ "$USE_CLAUDE" = no ] && [ "$USE_CODEX" = no ]; then echo "$BOTH_OFF_MSG" >&2; exit 2; fi
if [ "$USE_SIDEKEY" = yes ] && [ "$USE_VOICE" = no ] && [ "$USE_SIDEKEY_SET" = 1 ] && [ "$USE_VOICE_SET" = 1 ]; then
    echo "--sidekey braucht die Sprachsteuerung (nicht zusammen mit --no-voice)." >&2; exit 2
fi

say() { printf '%s\n' "$*"; }
die() { echo "install.sh: $*" >&2; exit 1; }

[ -d "$PREFIX/bin" ] || die "Das sieht nicht nach Termux aus (PREFIX=$PREFIX). Dieses Skript in einer Termux-Shell starten."
if [ -z "${ROOTBRIDGE_ALLOW_GUEST:-}" ] && [ "$(id -u)" -eq 0 ] \
        && [ -f /etc/os-release ] && grep -qi ubuntu /etc/os-release 2>/dev/null; then
    die "Du bist im Ubuntu-Gast. Bitte in einer normalen Termux-Shell ausführen (nicht in proot-distro)."
fi

# Setup, part 1: the Termux packages that are missing. pkg_for maps a command to its Termux package.
pkg_for() {
    case "$1" in
        python3) echo python ;;
        termux-open-url) echo termux-api ;;
        sha256sum|stat|timeout) echo coreutils ;;
        setsid) echo util-linux ;;
        *) echo "$1" ;;
    esac
}
if [ "$DO_SETUP" = 1 ] && [ "$DEPS" = 1 ] && command -v pkg >/dev/null 2>&1; then
    need_pkgs=""
    for c in tmux proot-distro python3 sha256sum stat timeout setsid termux-open-url; do
        command -v "$c" >/dev/null 2>&1 && continue
        p="$(pkg_for "$c")"
        case " $need_pkgs " in *" $p "*) ;; *) need_pkgs="$need_pkgs $p" ;; esac
    done
    if [ -n "$need_pkgs" ]; then
        say "== 0/5 Einrichtung: Termux-Pakete"
        say "  pkg install -y$need_pkgs"
        # shellcheck disable=SC2086   # $need_pkgs is a list of package names on purpose
        DEBIAN_FRONTEND=noninteractive pkg install -y -o Dpkg::Options::=--force-confold $need_pkgs \
            || die "pkg install$need_pkgs ist fehlgeschlagen (Netz? pkg update?). Erneut starten: bash install.sh"
        hash -r
        SETUP_DID=1
    fi
fi

if [ "$DEPS" = 1 ]; then
    missing=""
    for c in tmux proot-distro sha256sum stat timeout setsid; do
        command -v "$c" >/dev/null 2>&1 || missing="$missing $c"
    done
    if [ -n "$missing" ]; then
        say "Fehlende Pakete:$missing"
        say "Installieren mit: pkg install tmux proot-distro coreutils util-linux"
        exit 1
    fi
    command -v su >/dev/null 2>&1 || say "Hinweis: kein 'su' gefunden - Root-Befehle werden mit Code 127 beantwortet."
    command -v termux-open-url >/dev/null 2>&1 || say "Hinweis: pkg install termux-api (für Browser-Öffnen und Zwischenablage)."
fi

backup() {
    # nothing to keep of a missing or empty file (set_block creates an empty one first)
    [ -s "$1" ] || return 0
    local dest="$1.bak-$STAMP"
    # Termux:Widget lists EVERY file in ~/.shortcuts and Termux:Boot runs EVERY file in
    # ~/.termux/boot: backups of those must not sit next to the originals
    case "$1" in
        "$HOME/.shortcuts/"*|"$HOME/.termux/boot/"*)
            mkdir -p "$BRIDGE_DIR/backups"
            dest="$BRIDGE_DIR/backups/${1##*/}.bak-$STAMP" ;;
    esac
    cp -p "$1" "$dest" && say "  Sicherung: $dest" || true
}

# inst <src> <dest>: copy with Termux shebang; back up only on change
inst() {
    local tmp="$2.new.$$"
    mkdir -p "$(dirname "$2")"
    sed "1s|^#!.*|#!$PREFIX/bin/bash|" "$1" > "$tmp"
    chmod 755 "$tmp"
    if [ -e "$2" ] && cmp -s "$tmp" "$2"; then rm -f "$tmp"; return 0; fi
    backup "$2"
    mv -f "$tmp" "$2"
    say "  installiert: $2"
}

# put_data <src> <dest> <mode>: copy a data file as it is (no shebang rewrite); back up only on
# change. Returns 0 if the file was written, 1 if it was already identical.
put_data() {
    local tmp="$2.new.$$"
    mkdir -p "$(dirname "$2")"
    cp "$1" "$tmp"
    chmod "$3" "$tmp"
    if [ -e "$2" ] && cmp -s "$tmp" "$2"; then rm -f "$tmp"; return 1; fi
    backup "$2"
    mv -f "$tmp" "$2"
    say "  installiert: $2"
}

# set_block <file> <content-file>: replace our marked block, keep the rest
set_block() {
    local file="$1" content="$2" tmp
    touch "$file"
    tmp="$file.new.$$"
    python3 -I - "$file" "$tmp" "$BEGIN" "$END" "$content" <<'PYEOF'
import sys
src, out, begin, end, content = sys.argv[1:6]
lines = open(src, encoding="utf-8").read().split("\n")
res, skip = [], False
for line in lines:
    if line.strip() == begin:
        skip = True
        continue
    if skip:
        if line.strip() == end:
            skip = False
        continue
    res.append(line)
body = "\n".join(res).rstrip("\n")
block = open(content, encoding="utf-8").read().rstrip("\n")
open(out, "w", encoding="utf-8").write(
    (body + "\n\n" if body else "") + begin + "\n" + block + "\n" + end + "\n")
PYEOF
    if cmp -s "$tmp" "$file"; then rm -f "$tmp"; else backup "$file"; mv -f "$tmp" "$file"; say "  aktualisiert: $file"; fi
}

drop_block() {
    [ -f "$1" ] || return 0
    local tmp="$1.new.$$"
    python3 -I - "$1" "$tmp" "$BEGIN" "$END" <<'PYEOF'
import sys
src, out, begin, end = sys.argv[1:5]
res, skip = [], False
for line in open(src, encoding="utf-8").read().split("\n"):
    if line.strip() == begin:
        skip = True
        continue
    if skip:
        if line.strip() == end:
            skip = False
        continue
    res.append(line)
open(out, "w", encoding="utf-8").write("\n".join(res).rstrip("\n") + "\n")
PYEOF
    mv -f "$tmp" "$1"
}

# own_extra_keys <file>: succeeds if the file sets `extra-keys` OUTSIDE our block, i.e. a row of the user's
# own. Our block is appended at the end and a later duplicate key wins, so it would silently replace it.
own_extra_keys() {
    [ -f "$1" ] || return 1
    python3 -I - "$1" "$BEGIN" "$END" <<'PYEOF'
import re, sys
path, begin, end = sys.argv[1:4]
skip = False
for line in open(path, encoding="utf-8").read().split("\n"):
    if line.strip() == begin:
        skip = True
        continue
    if skip:
        if line.strip() == end:
            skip = False
        continue
    if re.match(r"\s*extra-keys\s*[=:]", line):
        sys.exit(0)
sys.exit(1)
PYEOF
}

command -v python3 >/dev/null 2>&1 || die "python3 fehlt (pkg install python)"

say "== 1/5 Programme"
inst "$REPO/termux/bin/rootbridge"        "$PREFIX/bin/rootbridge"
inst "$REPO/termux/bin/rootbridge-daemon" "$PREFIX/bin/rootbridge-daemon"
inst "$REPO/termux/bin/ptt"               "$PREFIX/bin/ptt"
inst "$REPO/termux/lib/rootbridge-lib.sh" "$PREFIX/lib/termux-rootbridge/rootbridge-lib.sh"
chmod 644 "$PREFIX/lib/termux-rootbridge/rootbridge-lib.sh"

say "== 2/5 Konfiguration"
CFG="$HOME/.config/termux-rootbridge/config"
mkdir -p "$(dirname "$CFG")" "$BRIDGE_DIR"
chmod 700 "$BRIDGE_DIR"
if [ ! -e "$CFG" ]; then
    cat > "$CFG" <<'EOF'
# termux-rootbridge - read as data (no shell code is executed)
DISTRO=ubuntu
WORKDIR=/root/work
SESSION=ubuntu
TICKET_TTL=1800
# SU_ARGS=-mm -c      # global mount namespace (Magisk), if paths look empty
AUTOSTART_DELAY=3
# REMOTE_NAME=android   # name in the Remote Control view (claude.ai/code); default android, change with install.sh --remote-name
# APT_UPGRADE=6h        # apt-get update + upgrade in the guest at session start: 6h (<N>h = every N hours) | daily (= 24h) | always | off; set with install.sh --apt-upgrade / --no-apt-upgrade
# CLAUDE_UPDATE=6h      # claude update in the guest at session start: 6h (<N>h = every N hours) | daily (= 24h) | always | off; set with install.sh --claude-update / --no-claude-update
# CODEX_UPDATE=6h       # codex update at session start: same values; set with install.sh --codex-update / --no-codex-update
# TOOL_CLAUDE=on        # on | off: Claude Code is part of this installation; set with install.sh --claude / --no-claude
# TOOL_CODEX=on         # on | off: Codex is part of this installation; set with install.sh --codex / --no-codex
# VOICE=on              # on | off: voice dictation for Claude Code (PulseAudio, microphone); set with install.sh --voice / --no-voice
# SIDEKEY=off           # on | off: side key of the Hisense A9 as push to talk; set with install.sh --sidekey / --no-sidekey
# PTT_TARGET=ubuntu:claude   # `ptt`: tmux window it presses its key in (default <SESSION>:claude)
# PTT_KEY=M-k           # `ptt`: tmux key name (Claude Code: voice:pushToTalk is bound to meta+k)
# PTT_MODE=hold         # `ptt`: hold (repeat the key until stop) | tap (one press each); PTT_INTERVAL=50 (ms), PTT_MAX=120 (s)
EOF
    say "  neu: $CFG"
fi
# The old default WORKDIR=/root/workspace was never created. If the folder is not in the guest nobody uses it:
# move to the new default /root/work (an existing /root/workspace and any other value stay).
if grep -qx 'WORKDIR=/root/workspace' "$CFG"; then
    d="$(sed -n 's/^DISTRO=//p' "$CFG" | tail -n 1)"; d="${d:-ubuntu}"
    if [ ! -e "$PREFIX/var/lib/proot-distro/containers/$d/rootfs/root/workspace" ] \
       && [ ! -e "$PREFIX/var/lib/proot-distro/installed-rootfs/$d/root/workspace" ]; then
        tmp="$CFG.new.$$"
        sed 's|^WORKDIR=/root/workspace$|WORKDIR=/root/work|' "$CFG" > "$tmp"
        backup "$CFG"; mv -f "$tmp" "$CFG"
        say "  WORKDIR: /root/workspace -> /root/work (der alte Standardordner wurde nie angelegt)"
    fi
fi
if [ "$APT_MODE_SET" = 1 ]; then
    # same idea as REMOTE_NAME: the choice survives a reinstall of the guest
    tmp="$CFG.new.$$"
    cp "$CFG" "$tmp"
    [ -z "$(tail -c1 "$tmp")" ] || echo >> "$tmp"
    if grep -q '^APT_UPGRADE=' "$tmp"; then
        sed -i "s|^APT_UPGRADE=.*|APT_UPGRADE=$APT_MODE|" "$tmp"
    else
        printf 'APT_UPGRADE=%s\n' "$APT_MODE" >> "$tmp"
    fi
    if cmp -s "$tmp" "$CFG"; then rm -f "$tmp"; else backup "$CFG"; mv -f "$tmp" "$CFG"; say "  apt-Modus gespeichert: $APT_MODE"; fi
else
    v="$(sed -n 's/^APT_UPGRADE=//p' "$CFG" | tail -n 1)"
    v="${v%\"}"; v="${v#\"}"; v="${v%\'}"; v="${v#\'}"
    if [[ "$v" =~ $APT_RE ]]; then APT_MODE="$v"; say "  apt-Modus aus der Konfig: $APT_MODE"; fi
fi
if [ "$CLAUDE_UPD_SET" = 1 ]; then
    # same idea as APT_UPGRADE: the choice survives a reinstall of the guest
    tmp="$CFG.new.$$"
    cp "$CFG" "$tmp"
    [ -z "$(tail -c1 "$tmp")" ] || echo >> "$tmp"
    if grep -q '^CLAUDE_UPDATE=' "$tmp"; then
        sed -i "s|^CLAUDE_UPDATE=.*|CLAUDE_UPDATE=$CLAUDE_UPD_MODE|" "$tmp"
    else
        printf 'CLAUDE_UPDATE=%s\n' "$CLAUDE_UPD_MODE" >> "$tmp"
    fi
    if cmp -s "$tmp" "$CFG"; then rm -f "$tmp"; else backup "$CFG"; mv -f "$tmp" "$CFG"; say "  claude-update-Modus gespeichert: $CLAUDE_UPD_MODE"; fi
else
    v="$(sed -n 's/^CLAUDE_UPDATE=//p' "$CFG" | tail -n 1)"
    v="${v%\"}"; v="${v#\"}"; v="${v%\'}"; v="${v#\'}"
    if [[ "$v" =~ $APT_RE ]]; then CLAUDE_UPD_MODE="$v"; say "  claude-update-Modus aus der Konfig: $CLAUDE_UPD_MODE"; fi
fi
# cfg_get KEY: the value stored in the Termux config (quotes stripped; empty if there is none)
cfg_get() {
    local v
    v="$(sed -n "s/^$1=//p" "$CFG" | tail -n 1)"
    v="${v%\"}"; v="${v#\"}"; v="${v%\'}"; v="${v#\'}"
    printf '%s' "$v"
}
# cfg_set KEY VALUE MESSAGE: store KEY=VALUE (replace the line or add it; a backup only on a change)
cfg_set() {
    local tmp="$CFG.new.$$"
    cp "$CFG" "$tmp"
    [ -z "$(tail -c1 "$tmp")" ] || echo >> "$tmp"
    if grep -q "^$1=" "$tmp"; then sed -i "s|^$1=.*|$1=$2|" "$tmp"; else printf '%s=%s\n' "$1" "$2" >> "$tmp"; fi
    if cmp -s "$tmp" "$CFG"; then rm -f "$tmp"; else backup "$CFG"; mv -f "$tmp" "$CFG"; say "  $3"; fi
}
# the tools: an option wins (and is stored, so a reinstall keeps the choice), without one the stored value counts.
# Both choices are settled and checked BEFORE either is stored: a refused combination leaves the config as it was.
if [ "$USE_CLAUDE_SET" != 1 ] && [ "$(cfg_get TOOL_CLAUDE)" = off ]; then
    USE_CLAUDE=no; say "  Claude Code: abgewählt (aus der Konfig; wieder an mit --claude)"
fi
if [ "$USE_CODEX_SET" != 1 ] && [ "$(cfg_get TOOL_CODEX)" = off ]; then
    USE_CODEX=no; say "  Codex: abgewählt (aus der Konfig; wieder an mit --codex)"
fi
if [ "$USE_CLAUDE" = no ] && [ "$USE_CODEX" = no ]; then die "$BOTH_OFF_MSG (die Konfig hat eines abgewählt: --claude oder --codex)"; fi
if [ "$USE_CLAUDE_SET" = 1 ]; then
    cfg_set TOOL_CLAUDE "$([ "$USE_CLAUDE" = yes ] && echo on || echo off)" "Claude Code: $USE_CLAUDE"
fi
if [ "$USE_CODEX_SET" = 1 ]; then
    cfg_set TOOL_CODEX "$([ "$USE_CODEX" = yes ] && echo on || echo off)" "Codex: $USE_CODEX"
fi
# voice and side key: same idea (an option wins and is stored; without one the stored value counts)
if [ "$USE_VOICE_SET" != 1 ] && [ "$(cfg_get VOICE)" = off ]; then
    USE_VOICE=no; say "  Sprache: abgewählt (aus der Konfig; wieder an mit --voice)"
fi
if [ "$USE_SIDEKEY_SET" != 1 ] && [ "$(cfg_get SIDEKEY)" = on ]; then
    USE_SIDEKEY=yes; say "  Seitentaste: an (aus der Konfig; aus mit --no-sidekey)"
fi
if [ "$USE_VOICE_SET" = 1 ]; then
    cfg_set VOICE "$([ "$USE_VOICE" = yes ] && echo on || echo off)" "Sprache: $USE_VOICE"
fi
if [ "$USE_SIDEKEY_SET" = 1 ]; then
    cfg_set SIDEKEY "$([ "$USE_SIDEKEY" = yes ] && echo on || echo off)" "Seitentaste: $USE_SIDEKEY"
fi
# Resolve the device name after the enabled tools, so Codex-only installs ask no Claude question.
if [ "$REMOTE_NAME_SET" != 1 ]; then
    v="$(cfg_get REMOTE_NAME)"
    if [[ "$v" =~ $NAME_RE ]]; then REMOTE_NAME="$v"; fi
    if [ "$USE_CLAUDE" = yes ] && [ -t 0 ]; then
        say "Wie soll dieses Gerät in Claude Remote Control heißen?"
        say "  Erlaubt: Buchstaben, Ziffern, Punkt, _ und -; maximal 64 Zeichen (z. B. boox-max-lumi)."
        while true; do
            printf 'Gerätename [%s]: ' "$REMOTE_NAME"
            IFS= read -r answer || die "Namensabfrage abgebrochen; für einen Aufruf ohne Nachfrage --remote-name NAME verwenden."
            answer="${answer:-$REMOTE_NAME}"
            if [[ "$answer" =~ $NAME_RE ]]; then
                REMOTE_NAME="$answer"; REMOTE_NAME_SET=1; break
            fi
            say "Ungültiger Gerätename. Bitte ohne Leerzeichen oder Sonderzeichen eingeben."
        done
    else
        say "  Remote-Control-Name: $REMOTE_NAME (ohne Nachfrage; ändern mit --remote-name NAME)"
    fi
fi
if [ "$REMOTE_NAME_SET" = 1 ]; then
    # store the name in the Termux config: it survives a reinstall of the guest
    tmp="$CFG.new.$$"
    cp "$CFG" "$tmp"
    [ -z "$(tail -c1 "$tmp")" ] || echo >> "$tmp"
    if grep -q '^REMOTE_NAME=' "$tmp"; then
        sed -i "s|^REMOTE_NAME=.*|REMOTE_NAME=$REMOTE_NAME|" "$tmp"
    else
        printf 'REMOTE_NAME=%s\n' "$REMOTE_NAME" >> "$tmp"
    fi
    if cmp -s "$tmp" "$CFG"; then rm -f "$tmp"; else backup "$CFG"; mv -f "$tmp" "$CFG"; say "  Remote-Control-Name gespeichert: $REMOTE_NAME"; fi
fi
if [ "$CODEX_UPD_SET" = 1 ]; then
    cfg_set CODEX_UPDATE "$CODEX_UPD_MODE" "codex-update-Modus gespeichert: $CODEX_UPD_MODE"
else
    v="$(cfg_get CODEX_UPDATE)"
    if [[ "$v" =~ $APT_RE ]]; then CODEX_UPD_MODE="$v"; say "  codex-update-Modus aus der Konfig: $CODEX_UPD_MODE"; fi
fi
TMP_SNIP="$(mktemp)"; cp "$REPO/termux/tmux.conf.snippet" "$TMP_SNIP"
set_block "$HOME/.tmux.conf" "$TMP_SNIP"; rm -f "$TMP_SNIP"

say "== 3/5 Farben, Shell-Block, Widgets"
if [ "$DO_COLORS" = 1 ]; then
    # This installer writes no colour file any more: the E-Paper Termux build brings the light and the dark scheme with it
    # and follows the phone. The files below are what earlier versions installed (SHA-256 of the content). One that is still
    # exactly like that goes, because it would override the built-in scheme and keep the terminal light in dark mode (or
    # stay behind a later change of the built-in scheme). A file you changed stays, with a note. Nothing is overwritten.
    colors_changed=0
    FORMER_COLOR_FILES="colors.properties:3eaffea743c0ad78e60a98f5a2ccf57dfd31b3c8b6b71ae5a3dcef66b91bb54e
colors-light.properties:ddf723e84243925a9e09b468fb87bbcbca9b13a2aef1467835b46f6dba7bc53a"
    for entry in $FORMER_COLOR_FILES; do
        f="$HOME/.termux/${entry%%:*}"
        [ -f "$f" ] || continue
        if [ "$(sha256sum "$f" 2>/dev/null | cut -d' ' -f1)" = "${entry#*:}" ]; then
            rm -f "$f"
            say "  entfernt: $f (von einer früheren Version installiert, die App bringt das Schema jetzt selbst mit)"
            colors_changed=1
        elif [ -s "$f" ]; then
            say "  $f bleibt (von dir geändert) und überschreibt das eingebaute Schema."
        fi
    done
    if [ "$colors_changed" = 1 ]; then
        command -v termux-reload-settings >/dev/null 2>&1 && termux-reload-settings || true
    fi
else
    say "  Farben und Theme übersprungen (--no-colors)"
fi
if [ "$DO_EXTRAKEYS" = 1 ]; then
    # S-TAB (a phone keyboard has no Shift+Tab, Claude Code switches its permission mode with it) and
    # KEYBOARD (show/hide the soft keyboard) in the Termux extra keys row
    TP="$HOME/.termux/termux.properties"
    mkdir -p "$HOME/.termux"
    if own_extra_keys "$TP"; then
        say "  Zusatztasten: $TP enthält eine eigene extra-keys-Zeile, sie bleibt unverändert."
        say "    Für Shift+Tab die Taste {macro: \"SHIFT TAB\", display: \"S-TAB\"} selbst ergänzen,"
        say "    oder die Zeile löschen und install.sh erneut starten (Vorlage: termux/extra-keys.snippet)."
    else
        before="$(cksum < "$TP" 2>/dev/null || true)"
        set_block "$TP" "$REPO/termux/extra-keys.snippet"
        chmod 600 "$TP"
        if [ "$before" != "$(cksum < "$TP")" ]; then
            command -v termux-reload-settings >/dev/null 2>&1 && termux-reload-settings || true
        fi
    fi
else
    say "  Zusatztasten übersprungen (--no-extra-keys)"
fi
TMP_RC="$(mktemp)"
cat > "$TMP_RC" <<'EOF'
alias ubuntu='rootbridge shell'
alias claude='rootbridge attach claude'
alias codex='rootbridge attach codex'
if [[ $- == *i* ]] && [ -z "${TMUX:-}" ]; then
    # reload the Termux settings in every new Termux shell (Claude Code is NOT started here:
    # use the widgets, `claude`, `codex` or `rootbridge attach`)
    if command -v termux-reload-settings >/dev/null 2>&1; then termux-reload-settings; fi
fi
EOF
set_block "$HOME/.bashrc" "$TMP_RC"; rm -f "$TMP_RC"
if [ "$DO_WIDGETS" = 1 ]; then
    SC="$HOME/.shortcuts"
    mkdir -p "$SC/icons" "$BRIDGE_DIR/backups"
    # Earlier versions called the widgets "Claude Code" / "Ubuntu Shell", then "Claude >_" / "Ubuntu >_":
    # carry the user's icon over to the new name (before a default icon is installed), and move our old
    # scripts and their *.bak-* files out of the widget list.
    for pair in "Claude >_:Claude" "Claude Code:Claude" "Ubuntu >_:Ubuntu" "Ubuntu Shell:Ubuntu"; do
        old="${pair%%:*}"; new="${pair#*:}"
        if [ -e "$SC/icons/$old.png" ] && [ ! -e "$SC/icons/$new.png" ]; then
            mv "$SC/icons/$old.png" "$SC/icons/$new.png"
            say "  Icon übernommen: $old.png -> $new.png"
        fi
        if [ -f "$SC/$old" ] && grep -q 'rootbridge' "$SC/$old" 2>/dev/null; then
            mv "$SC/$old" "$BRIDGE_DIR/backups/$old.old-$STAMP"
            say "  altes Widget entfernt: $old (Kopie in $BRIDGE_DIR/backups)"
        fi
        for f in "$SC/$old".bak-*; do
            if [ -e "$f" ]; then mv "$f" "$BRIDGE_DIR/backups/"; say "  Sicherung aus der Widget-Liste verschoben: ${f##*/}"; fi
        done
    done
    # a tool that is switched off gets no widget (and our widget of an earlier install goes, with a copy in backups)
    for pair in "claude:Claude:$USE_CLAUDE" "claude-new:Claude Neu:$USE_CLAUDE" "codex:Codex:$USE_CODEX"; do
        if [ "${pair##*:}" = no ]; then
            w="${pair#*:}"; w="${w%%:*}"
            if [ -f "$SC/$w" ] && grep -q 'rootbridge' "$SC/$w" 2>/dev/null; then
                mv "$SC/$w" "$BRIDGE_DIR/backups/$w.old-$STAMP"
                say "  Widget entfernt: $w (abgewählt; Kopie in $BRIDGE_DIR/backups)"
            fi
        fi
    done
    WIDGET_LIST=("ubuntu:Ubuntu")
    [ "$USE_CODEX" = yes ] && WIDGET_LIST+=("codex:Codex")
    [ "$USE_CLAUDE" = yes ] && WIDGET_LIST+=("claude:Claude" "claude-new:Claude Neu")
    for pair in "${WIDGET_LIST[@]}"; do
        src="${pair%%:*}"; name="${pair#*:}"
        inst "$REPO/termux/shortcuts/$src" "$SC/$name"
        # One default icon for both widgets: installed if there is none, and in place of an icon that is exactly a default
        # icon of an earlier version (termux/shortcuts/icons/legacy). An icon the user chose stays.
        icon="$SC/icons/$name.png"
        replace=0
        if [ ! -e "$icon" ]; then
            replace=1
        else
            for old in "$REPO"/termux/shortcuts/icons/legacy/*.png; do
                cmp -s "$old" "$icon" 2>/dev/null && replace=1
            done
        fi
        if [ "$replace" = 1 ] && ! cmp -s "$REPO/termux/shortcuts/icons/widget.png" "$icon" 2>/dev/null; then
            cp "$REPO/termux/shortcuts/icons/widget.png" "$icon"
            say "  Icon: $icon"
        fi
    done
else
    say "  Widgets übersprungen (--no-widgets)"
fi
if [ "$DO_BOOT" = 1 ] && [ -d "$HOME/.termux/boot" ]; then
    inst "$REPO/termux/boot/10-rootbridge.sh" "$HOME/.termux/boot/10-rootbridge.sh"
fi

# inst_py <src> <dest>: like inst, for a Python program (the shebang points at Termux' python3)
inst_py() {
    local tmp="$2.new.$$"
    mkdir -p "$(dirname "$2")"
    sed "1s|^#!.*|#!$PREFIX/bin/python3|" "$1" > "$tmp"
    chmod 755 "$tmp"
    if [ -e "$2" ] && cmp -s "$tmp" "$2"; then rm -f "$tmp"; return 0; fi
    backup "$2"
    mv -f "$tmp" "$2"
    say "  installiert: $2"
}

# Voice dictation (/voice of Claude Code) works only with Claude Code: without it there is nothing to talk to.
VOICE_ON=no
if [ "$USE_VOICE" = yes ] && [ "$USE_CLAUDE" = yes ]; then VOICE_ON=yes; fi
say "== Sprache (/voice) und Seitentaste"
if [ "$VOICE_ON" = yes ]; then
    # PulseAudio in Termux: the guest records from it (sox in the guest, PULSE_SERVER=127.0.0.1)
    if [ ! -x "$PREFIX/bin/pulseaudio" ]; then
        if [ "$DO_SETUP" = 1 ] && [ "$DEPS" = 1 ] && command -v pkg >/dev/null 2>&1; then
            say "  pkg install -y pulseaudio"
            if DEBIAN_FRONTEND=noninteractive pkg install -y -o Dpkg::Options::=--force-confold pulseaudio; then
                hash -r; SETUP_DID=1
            else
                say "  Hinweis: pkg install pulseaudio ist fehlgeschlagen - ohne PulseAudio kein Mikrofon. Erneut starten: bash install.sh"
            fi
        else
            say "  Hinweis: pulseaudio fehlt (pkg install pulseaudio) - ohne PulseAudio kein Mikrofon."
        fi
    fi
    # PulseAudio configuration: Termux' own default.pa plus the microphone and the local socket. A default.pa of your own stays.
    PA_FILE="$HOME/.config/pulse/default.pa"
    if [ -e "$PA_FILE" ] && ! grep -q 'termux-rootbridge voice' "$PA_FILE" 2>/dev/null; then
        say "  $PA_FILE ist deine eigene Datei und bleibt unverändert (ohne die Zeilen aus termux/pulse/default.pa kein Mikrofon)"
    else
        TMP_PA="$(mktemp)"
        sed "s|@PREFIX@|$PREFIX|g" "$REPO/termux/pulse/default.pa" > "$TMP_PA"
        put_data "$TMP_PA" "$PA_FILE" 644 || true
        rm -f "$TMP_PA"
    fi
    # Android's microphone permission for Termux (root). Only on a terminal, where the root manager can ask you; a pipe or a
    # script run never starts a root command by itself.
    if [ "$DO_SETUP" = 1 ] && { [ -t 0 ] || [ "${ROOTBRIDGE_FORCE_INTERACTIVE:-}" = 1 ]; }; then
        "$PREFIX/bin/rootbridge" voice start >/dev/null 2>&1 || true
        if "$PREFIX/bin/rootbridge" voice status 2>/dev/null | grep -q 'Mikrofon:  *ok'; then
            say "  Mikrofon: ok (die Berechtigung für Termux ist da)"
        else
            say "  Mikrofon-Berechtigung für Termux erteilen (Root; der Root-Manager fragt):"
            "$PREFIX/bin/rootbridge" voice grant \
                || say "  Hinweis: ohne Berechtigung kein Mikrofon. Später:  rootbridge voice grant"
        fi
    else
        say "  Mikrofon-Berechtigung: einmal von Hand   rootbridge voice grant   (braucht Root; PulseAudio startet mit der Sitzung)"
    fi
else
    say "  übersprungen ($([ "$USE_CLAUDE" = yes ] && echo '--no-voice' || echo 'ohne Claude Code gibt es kein /voice'))"
fi
# the side key reader (Hisense A9): installed on request only; a reader of an earlier install goes when it is switched off
if [ "$USE_SIDEKEY" = yes ] && [ "$VOICE_ON" = yes ]; then
    inst_py "$REPO/termux/bin/sidekey-ptt" "$PREFIX/bin/sidekey-ptt"
elif [ -f "$PREFIX/bin/sidekey-ptt" ] && grep -q 'sidekey-ptt' "$PREFIX/bin/sidekey-ptt" 2>/dev/null; then
    pkill -f 'sidekey-ptt' 2>/dev/null || true
    rm -f "$PREFIX/bin/sidekey-ptt"
    say "  Seitentasten-Leser entfernt (abgewählt)"
elif [ "$USE_SIDEKEY" = yes ]; then
    say "  Seitentaste: ohne die Sprachsteuerung nicht eingerichtet"
fi

say "== 4/5 Migration der alten Popup-Bridge (v1)"
if [ "$DO_MIGRATE" = 1 ]; then
    OLD_FILES=""
    for f in "$HOME"/bin/root-bridge-watch.sh "$HOME"/bin/root-bridge-confirm.sh \
             "$HOME"/bin/bridge-lib.sh* "$HOME"/bin/ubuntu-switch.sh* "$HOME"/bin/ubuntu-toggle.sh* \
             "$HOME"/bin/shortcut-backup-* "$HOME"/bin/fix-bashrc.sh "$HOME"/bin/androidsu \
             "$HOME/.termux/boot/10-ubuntu-bridge.sh" \
             "$HOME/.shortcuts/U Toggle" "$HOME/.shortcuts/U Switch" "$HOME/.shortcuts/U 2" \
             "$HOME/.shortcuts/icons/U Toggle.png" "$HOME/.shortcuts/icons/U Switch.png" \
             "$HOME/.shortcuts/icons/U 2.png"; do
        [ -e "$f" ] && OLD_FILES="$OLD_FILES
$f"
    done
    if [ -n "$OLD_FILES" ] || pgrep -f 'root-bridge-watch\.sh' >/dev/null 2>&1; then
        pkill -f 'root-bridge-watch\.sh' 2>/dev/null || true
        tmux kill-window -t "ubuntu:bridge" 2>/dev/null || true
        bk="$BRIDGE_DIR/backup-$STAMP"
        mkdir -p "$bk"
        printf '%s\n' "$OLD_FILES" | while IFS= read -r f; do
            [ -n "$f" ] || continue
            mv "$f" "$bk/" && say "  verschoben nach $bk: ${f#$HOME/}"
        done
        sed -i '/^alias ubuntu=~\/bin\/ubuntu-toggle\.sh$/d' "$HOME/.bashrc" 2>/dev/null || true
    else
        say "  nichts zu migrieren"
    fi
    rm -f "$BRIDGE_DIR"/req-*.txt "$BRIDGE_DIR"/res-*.txt 2>/dev/null || true
    # Keep the lock of a RUNNING daemon: deleting it makes the next `rootbridge start` spawn a second
    # daemon while the old one keeps polling. Only leftovers (no pid, dead pid, e.g. from v1) go.
    lock_pid="$(cat "$BRIDGE_DIR/.lock/pid" 2>/dev/null || true)"
    if ! { [[ "$lock_pid" =~ ^[0-9]+$ ]] && kill -0 "$lock_pid" 2>/dev/null; }; then
        rm -rf "$BRIDGE_DIR/.lock" 2>/dev/null || true
    fi
else
    say "  übersprungen"
fi

say "== 5/5 Gast ($(sed -n 's/^DISTRO=//p' "$CFG" | tail -n 1))"
if [ "$DO_GUEST" = 1 ]; then
    DISTRO="$(sed -n 's/^DISTRO=//p' "$CFG" | tail -n 1)"; DISTRO="${DISTRO:-ubuntu}"
    GROOT=""
    for c in "$PREFIX/var/lib/proot-distro/containers/$DISTRO/rootfs" \
             "$PREFIX/var/lib/proot-distro/installed-rootfs/$DISTRO"; do
        [ -d "$c" ] && GROOT="$c" && break
    done
    if [ -z "$GROOT" ] && [ "$DO_SETUP" = 1 ]; then
        say "  Gast '$DISTRO' fehlt: proot-distro install $DISTRO (Download, das dauert)"
        proot-distro install "$DISTRO" || die "proot-distro install $DISTRO ist fehlgeschlagen (Netz? Speicherplatz?). Erneut starten: bash install.sh"
        SETUP_DID=1
        for c in "$PREFIX/var/lib/proot-distro/containers/$DISTRO/rootfs" \
                 "$PREFIX/var/lib/proot-distro/installed-rootfs/$DISTRO"; do
            [ -d "$c" ] && GROOT="$c" && break
        done
    fi
    [ -n "$GROOT" ] || die "Gast '$DISTRO' nicht gefunden (proot-distro list). Ohne --no-setup legt install.sh ihn an; oder mit --no-guest überspringen."
    STAGE="$GROOT/var/tmp/termux-rootbridge-install"
    rm -rf "$STAGE"; mkdir -p "$STAGE"
    cp -r "$REPO/guest/." "$STAGE/"
    # Setup, part 3: python3 / curl / certificates and Claude Code in the guest. Looked up from outside
    # (a link that points outside the guest only counts as missing: setup-guest.sh then looks properly)
    guest_ready() {
        local h="${ROOTBRIDGE_GUEST_HOME:-/root}"
        { [ -e "$GROOT/usr/bin/python3" ] && [ -e "$GROOT/usr/bin/curl" ] && [ -s "$GROOT/etc/ssl/certs/ca-certificates.crt" ]; } || return 1
        if [ "$USE_CLAUDE" = yes ]; then
            { [ -x "$GROOT$h/.local/bin/claude" ] || [ -x "$GROOT/usr/local/bin/claude" ] || [ -x "$GROOT/usr/bin/claude" ]; } || return 1
        fi
        if [ "$USE_CODEX" = yes ]; then
            # ~/.local/bin/codex is a link with an absolute target inside the guest: the link itself counts
            { [ -x "$GROOT$h/.local/bin/codex" ] || [ -L "$GROOT$h/.local/bin/codex" ]; } || return 1
            [ -e "$GROOT/usr/bin/git" ] || return 1
        fi
        if [ "$VOICE_ON" = yes ]; then
            [ -e "$GROOT/usr/bin/rec" ] || return 1      # sox: Claude Code records through it
        fi
        if [ "$USE_CLAUDE" = yes ] && [ "$USE_CODEX" = yes ]; then
            { [ -e "$GROOT/usr/bin/node" ] || [ -e "$GROOT/usr/bin/nodejs" ]; } || return 1
            compgen -G "$GROOT$h/.claude/plugins/cache/openai-codex/codex/*/" >/dev/null || return 1
        fi
        return 0
    }
    if [ "$DO_SETUP" = 1 ] && ! guest_ready; then
        say "  Gast: Voraussetzungen, Claude Code und Codex einrichten (Claude Code: $USE_CLAUDE, Codex: $USE_CODEX)"
        proot-distro login "$DISTRO" -- bash /var/tmp/termux-rootbridge-install/setup-guest.sh \
            --claude "$USE_CLAUDE" --codex "$USE_CODEX" --voice "$VOICE_ON" \
            || die "Die Einrichtung im Gast ist fehlgeschlagen. Erneut starten: bash install.sh"
        SETUP_DID=1
    fi
    GUEST_ARGS=(--src /var/tmp/termux-rootbridge-install --autonomous "$AUTONOMOUS" --claude "$USE_CLAUDE" --codex "$USE_CODEX" --voice "$VOICE_ON")
    if [ -n "$REMOTE_NAME" ]; then GUEST_ARGS+=(--remote-name "$REMOTE_NAME"); fi
    if [ "$MODEL_SET" = 1 ]; then GUEST_ARGS+=(--model "$MODEL"); fi
    if [ "$DO_COLORS" = 1 ]; then GUEST_ARGS+=(--theme "$CLAUDE_THEME"); fi
    if [ -n "$APT_MODE" ]; then GUEST_ARGS+=(--apt-upgrade "$APT_MODE"); fi
    if [ -n "$CLAUDE_UPD_MODE" ]; then GUEST_ARGS+=(--claude-update "$CLAUDE_UPD_MODE"); fi
    if [ -n "$CODEX_UPD_MODE" ]; then GUEST_ARGS+=(--codex-update "$CODEX_UPD_MODE"); fi
    proot-distro login "$DISTRO" -- bash /var/tmp/termux-rootbridge-install/install-guest.sh "${GUEST_ARGS[@]}"
    rm -rf "$STAGE"
else
    say "  übersprungen (--no-guest)"
fi

say
say "Fertig. Weiter:"
say "  rootbridge status        # Zustand prüfen"
say "  source ~/.bashrc         # Kurzbefehle in dieser Termux-Shell laden (oder ein neues Fenster öffnen)"
say "  ubuntu                   # Ubuntu-Shell öffnen (auch Widget 'Ubuntu')"
if [ "$USE_CLAUDE" = yes ]; then
    say "  claude                   # Claude-Code-Sitzung öffnen (legt sie an; auch Widget 'Claude')"
    say "  claude -n                # neue Claude-Unterhaltung in einem eigenen Fenster starten"
fi
if [ "$USE_CODEX" = yes ]; then
    say "  codex                    # Codex-Sitzung öffnen (legt sie an; auch Widget 'Codex')"
fi
say "  rootbridge start         # Daemon + Sitzung (Termux:Boot ruft das nach einem Neustart auf)"
say "Normale Termux-Fenster bleiben reine Shells; Claude Code und Codex starten nicht mehr automatisch."
if [ "$DO_GUEST" = 1 ] && [ "$AUTONOMOUS" = yes ] && [ "$USE_CLAUDE" = yes ]; then
    say "Claude Code startet im Bypass-Modus im Ordner /root/work; Android-Root-Befehle fragen weiter nach."
fi
if [ "$USE_CLAUDE" = yes ]; then
    say "Nach dem ersten Start: Claude Code neu starten, damit die Managed Settings gelten."
fi
if [ "$DO_GUEST" = 1 ] && [ "$USE_CODEX" = yes ]; then
    say "Codex: einmal anmelden mit   rootbridge codex-login   (der Browser öffnet sich)."
    if [ "$USE_CLAUDE" = yes ]; then
        say "Bis dahin blockiert der Pre-Commit-Review jeden Commit von Claude Code (Notausgang: rootbridge codex-off)."
        say "Beim Start eines der beiden Fenster werden beide aktualisiert (claude update, codex update)."
    else
        say "Beim Start von Codex wird Codex aktualisiert (codex update)."
    fi
fi
if [ "$SETUP_DID" = 1 ]; then
    say "Noch von Hand: Root-Freigabe für Termux bestätigen (Root-Manager fragt bei der ersten Anfrage), Termux:Boot einmal öffnen,"
    if [ "$USE_CLAUDE" = yes ]; then
        say "das Widget 'Claude' auf den Homescreen legen, beim ersten Start in Claude Code anmelden (/login, der Browser öffnet sich)."
    else
        say "das Widget 'Codex' auf den Homescreen legen, Codex anmelden (rootbridge codex-login)."
    fi
fi
if [ "$VOICE_ON" = yes ]; then
    say "Sprache: /voice in Claude Code (Modus hold, Alt+K); 'ptt start' / 'ptt stop' halten die Taste für dich (rootbridge voice status prüft das Mikrofon)."
    if [ "$USE_SIDEKEY" = yes ]; then
        say "Seitentaste: Langdruck = aufnehmen, loslassen = stoppen. In den E-Ink-Einstellungen den Langdruck auf 'Nothing' stellen."
    fi
fi
if [ "$DO_EXTRAKEYS" = 1 ]; then
    say "Zusatztasten: S-TAB (Shift+Tab; Wisch nach oben = Tab) und KEYBOARD stehen in ~/.termux/termux.properties."
fi
if [ "$DO_COLORS" = 1 ]; then
    say "Farben: der E-Paper-Termux bringt das helle und das dunkle Schema selbst mit und folgt dem Telefon (eigene Dateien: ~/.termux/colors-light.properties, colors-dark.properties, colors.properties). Claude Code nutzt das Theme '$CLAUDE_THEME' (Auto epaper: ANSI-Farben des Termux-Schemas, wechselt mit dem Telefon live zwischen hell und dunkel)."
fi
