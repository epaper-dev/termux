#!/usr/bin/env bash
# install.sh - termux-root-bridge v2 installer. Run it in a TERMUX shell
# (not inside proot): the daemon needs real `su` outside proot.
#
#   bash install.sh [--no-guest] [--no-boot] [--no-migrate]
#                   [--autonomous yes|no|ask] [--no-deps-check]
#
# What it does (idempotent, with backups):
#   1. installs rootbridge + rootbridge-daemon into $PREFIX/bin
#   2. config ~/.config/termux-root-bridge/config, tmux clipboard settings
#   3. autostart block in ~/.bashrc, Termux:Widget shortcuts, optional boot script
#   4. migrates the old popup based bridge (v1) away
#   5. installs the guest part (hooks, androidsu, managed settings) via proot-distro

set -eu

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
BRIDGE_DIR="${BRIDGE_DIR:-$HOME/.rootbridge}"
STAMP="$(date +%Y%m%d%H%M%S)"
BEGIN='# >>> termux-root-bridge >>>'
END='# <<< termux-root-bridge <<<'

DO_GUEST=1; DO_BOOT=1; DO_MIGRATE=1; DEPS=1; AUTONOMOUS=ask
while [ $# -gt 0 ]; do
    case "$1" in
        --no-guest) DO_GUEST=0 ;;
        --no-boot) DO_BOOT=0 ;;
        --no-migrate) DO_MIGRATE=0 ;;
        --no-deps-check) DEPS=0 ;;
        --autonomous) AUTONOMOUS="$2"; shift ;;
        -h|--help) sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unbekannte Option: $1" >&2; exit 2 ;;
    esac
    shift
done

say() { printf '%s\n' "$*"; }
die() { echo "install.sh: $*" >&2; exit 1; }

[ -d "$PREFIX/bin" ] || die "Das sieht nicht nach Termux aus (PREFIX=$PREFIX). Dieses Skript in einer Termux-Shell starten."
if [ -z "${ROOTBRIDGE_ALLOW_GUEST:-}" ] && [ "$(id -u)" -eq 0 ] \
        && [ -f /etc/os-release ] && grep -qi ubuntu /etc/os-release 2>/dev/null; then
    die "Du bist im Ubuntu-Gast. Bitte in einer normalen Termux-Shell ausführen (nicht in proot-distro)."
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

backup() { [ -e "$1" ] && cp -p "$1" "$1.bak-$STAMP" && say "  Sicherung: $1.bak-$STAMP" || true; }

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

command -v python3 >/dev/null 2>&1 || die "python3 fehlt (pkg install python)"

say "== 1/5 Programme"
inst "$REPO/termux/bin/rootbridge"        "$PREFIX/bin/rootbridge"
inst "$REPO/termux/bin/rootbridge-daemon" "$PREFIX/bin/rootbridge-daemon"
inst "$REPO/termux/lib/rootbridge-lib.sh" "$PREFIX/lib/termux-root-bridge/rootbridge-lib.sh"
chmod 644 "$PREFIX/lib/termux-root-bridge/rootbridge-lib.sh"

say "== 2/5 Konfiguration"
CFG="$HOME/.config/termux-root-bridge/config"
mkdir -p "$(dirname "$CFG")" "$BRIDGE_DIR"
chmod 700 "$BRIDGE_DIR"
if [ ! -e "$CFG" ]; then
    cat > "$CFG" <<'EOF'
# termux-root-bridge - read as data (no shell code is executed)
DISTRO=ubuntu
WORKDIR=/root/workspace
SESSION=ubuntu
TICKET_TTL=1800
# SU_ARGS=-mm -c      # global mount namespace (Magisk), if paths look empty
AUTOSTART_DELAY=3
EOF
    say "  neu: $CFG"
fi
TMP_SNIP="$(mktemp)"; cp "$REPO/termux/tmux.conf.snippet" "$TMP_SNIP"
set_block "$HOME/.tmux.conf" "$TMP_SNIP"; rm -f "$TMP_SNIP"

say "== 3/5 Autostart, Widgets"
TMP_RC="$(mktemp)"
cat > "$TMP_RC" <<'EOF'
alias ubuntu='rootbridge attach'
if [[ $- == *i* ]] && [ -z "${TMUX:-}" ] && [ -z "${ROOTBRIDGE_NO_AUTOSTART:-}" ] \
        && command -v rootbridge >/dev/null 2>&1; then
    rootbridge start
fi
EOF
set_block "$HOME/.bashrc" "$TMP_RC"; rm -f "$TMP_RC"
if [ -d "$HOME/.shortcuts" ] || command -v termux-widget >/dev/null 2>&1; then
    mkdir -p "$HOME/.shortcuts"
    for f in "Claude Code" "Ubuntu Shell"; do
        inst "$REPO/termux/shortcuts/$f" "$HOME/.shortcuts/$f"
    done
fi
if [ "$DO_BOOT" = 1 ] && [ -d "$HOME/.termux/boot" ]; then
    inst "$REPO/termux/boot/10-rootbridge.sh" "$HOME/.termux/boot/10-rootbridge.sh"
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
    rm -rf "$BRIDGE_DIR/.lock" 2>/dev/null || true
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
    [ -n "$GROOT" ] || die "Gast '$DISTRO' nicht gefunden (proot-distro list). Mit --no-guest überspringen."
    STAGE="$GROOT/var/tmp/termux-root-bridge-install"
    rm -rf "$STAGE"; mkdir -p "$STAGE"
    cp -r "$REPO/guest/." "$STAGE/"
    proot-distro login "$DISTRO" -- bash /var/tmp/termux-root-bridge-install/install-guest.sh \
        --src /var/tmp/termux-root-bridge-install --autonomous "$AUTONOMOUS"
    rm -rf "$STAGE"
else
    say "  übersprungen (--no-guest)"
fi

say
say "Fertig. Weiter:"
say "  rootbridge status        # Zustand prüfen"
say "  rootbridge start         # Daemon + Claude Code (startet auch beim Öffnen von Termux)"
say "Nach dem ersten Start: Claude Code neu starten, damit die Managed Settings gelten."
