#!/usr/bin/env bash
# install.sh - termux-root-bridge v2 installer. Run it in a TERMUX shell
# (not inside proot): the daemon needs real `su` outside proot.
#
#   bash install.sh [--no-guest] [--no-boot] [--no-migrate] [--no-colors] [--no-widgets]
#                   [--autonomous yes|no|ask] [--no-deps-check] [--remote-name NAME]
#                   [--apt-upgrade daily|always|off | --no-apt-upgrade]
#
# What it does (idempotent, with backups):
#   1. installs rootbridge + rootbridge-daemon into $PREFIX/bin
#   2. config ~/.config/termux-root-bridge/config (--remote-name NAME is stored there as
#      REMOTE_NAME and reused by every later install), tmux clipboard settings
#   3. light colour scheme ~/.termux/colors.properties (--no-colors skips it and the
#      Claude Code theme), a ~/.bashrc block (alias `ubuntu`, reloads the Termux settings
#      in every new shell; ordinary Termux windows stay plain shells, Claude Code starts
#      via the widgets, `ubuntu` or `rootbridge attach`), the Termux:Widget shortcuts
#      "Claude" and "Ubuntu" with icons (an icon you already have stays; icons of the
#      earlier names "Claude Code" / "Ubuntu Shell" / "Claude >_" / "Ubuntu >_" are carried
#      over; --no-widgets skips all this), optional boot script
#   4. migrates the old popup based bridge (v1) away
#   5. installs the guest part (hooks, androidsu, managed settings, Claude Code
#      theme "light-ansi") via proot-distro. The guest runs apt-get update + upgrade
#      at the start of the Claude Code session, at most once a day (--no-apt-upgrade
#      turns it off, --apt-upgrade always runs it at every start; the choice is stored
#      in the Termux config as APT_UPGRADE and reused by every later install)

set -eu

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
BRIDGE_DIR="${BRIDGE_DIR:-$HOME/.rootbridge}"
STAMP="$(date +%Y%m%d%H%M%S)"
BEGIN='# >>> termux-root-bridge >>>'
END='# <<< termux-root-bridge <<<'

DO_GUEST=1; DO_BOOT=1; DO_MIGRATE=1; DO_COLORS=1; DO_WIDGETS=1; DEPS=1; AUTONOMOUS=ask
CLAUDE_THEME=light-ansi   # ANSI-only: uses the 16 colours of colors.properties, readable in Termux
REMOTE_NAME=""; REMOTE_NAME_SET=0
APT_MODE=""; APT_MODE_SET=0
NAME_RE='^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$'
APT_RE='^(daily|always|off)$'
while [ $# -gt 0 ]; do
    case "$1" in
        --no-guest) DO_GUEST=0 ;;
        --no-boot) DO_BOOT=0 ;;
        --no-migrate) DO_MIGRATE=0 ;;
        --no-colors) DO_COLORS=0 ;;
        --no-widgets) DO_WIDGETS=0 ;;
        --no-deps-check) DEPS=0 ;;
        --autonomous) AUTONOMOUS="$2"; shift ;;
        --remote-name)
            [ $# -ge 2 ] || { echo "--remote-name braucht einen Namen" >&2; exit 2; }
            REMOTE_NAME="$2"; REMOTE_NAME_SET=1; shift ;;
        --apt-upgrade)
            [ $# -ge 2 ] || { echo "--apt-upgrade braucht daily, always oder off" >&2; exit 2; }
            APT_MODE="$2"; APT_MODE_SET=1; shift ;;
        --no-apt-upgrade) APT_MODE=off; APT_MODE_SET=1 ;;
        -h|--help) sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unbekannte Option: $1" >&2; exit 2 ;;
    esac
    shift
done

if [ "$REMOTE_NAME_SET" = 1 ] && ! [[ "$REMOTE_NAME" =~ $NAME_RE ]]; then
    echo "--remote-name: ungültiger Name '$REMOTE_NAME' (erlaubt: Buchstaben, Ziffern, . _ -; max. 64 Zeichen; nicht mit - beginnen)" >&2
    exit 2
fi

if [ "$APT_MODE_SET" = 1 ] && ! [[ "$APT_MODE" =~ $APT_RE ]]; then
    echo "--apt-upgrade: ungültiger Wert '$APT_MODE' (erlaubt: daily, always, off)" >&2
    exit 2
fi

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

backup() {
    [ -e "$1" ] || return 0
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
# REMOTE_NAME=android   # name in the Remote Control view (claude.ai/code); set with install.sh --remote-name
# APT_UPGRADE=daily     # apt-get update + upgrade in the guest at session start: daily | always | off; set with install.sh --apt-upgrade / --no-apt-upgrade
EOF
    say "  neu: $CFG"
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
else
    # no option given: reuse the name stored by an earlier install
    v="$(sed -n 's/^REMOTE_NAME=//p' "$CFG" | tail -n 1)"
    v="${v%\"}"; v="${v#\"}"; v="${v%\'}"; v="${v#\'}"
    if [[ "$v" =~ $NAME_RE ]]; then REMOTE_NAME="$v"; say "  Remote-Control-Name aus der Konfig: $REMOTE_NAME"; fi
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
TMP_SNIP="$(mktemp)"; cp "$REPO/termux/tmux.conf.snippet" "$TMP_SNIP"
set_block "$HOME/.tmux.conf" "$TMP_SNIP"; rm -f "$TMP_SNIP"

say "== 3/5 Farben, Shell-Block, Widgets"
if [ "$DO_COLORS" = 1 ]; then
    # chmod 600: Termux itself creates the file that way
    if put_data "$REPO/termux/colors.properties" "$HOME/.termux/colors.properties" 600; then
        command -v termux-reload-settings >/dev/null 2>&1 && termux-reload-settings || true
    fi
else
    say "  Farbschema übersprungen (--no-colors)"
fi
TMP_RC="$(mktemp)"
cat > "$TMP_RC" <<'EOF'
alias ubuntu='rootbridge attach'
if [[ $- == *i* ]] && [ -z "${TMUX:-}" ]; then
    # load ~/.termux/colors.properties in every new Termux shell (Claude Code is NOT started here:
    # use the widget "Claude", `ubuntu` or `rootbridge attach`)
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
    for pair in "claude:Claude" "ubuntu:Ubuntu"; do
        src="${pair%%:*}"; name="${pair#*:}"
        inst "$REPO/termux/shortcuts/$src" "$SC/$name"
        # the default icon only if there is none: an icon the user chose stays
        if [ ! -e "$SC/icons/$name.png" ]; then
            cp "$REPO/termux/shortcuts/icons/$src.png" "$SC/icons/$name.png"
            say "  Icon: $SC/icons/$name.png"
        fi
    done
else
    say "  Widgets übersprungen (--no-widgets)"
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
    [ -n "$GROOT" ] || die "Gast '$DISTRO' nicht gefunden (proot-distro list). Mit --no-guest überspringen."
    STAGE="$GROOT/var/tmp/termux-root-bridge-install"
    rm -rf "$STAGE"; mkdir -p "$STAGE"
    cp -r "$REPO/guest/." "$STAGE/"
    GUEST_ARGS=(--src /var/tmp/termux-root-bridge-install --autonomous "$AUTONOMOUS")
    if [ -n "$REMOTE_NAME" ]; then GUEST_ARGS+=(--remote-name "$REMOTE_NAME"); fi
    if [ "$DO_COLORS" = 1 ]; then GUEST_ARGS+=(--theme "$CLAUDE_THEME"); fi
    if [ -n "$APT_MODE" ]; then GUEST_ARGS+=(--apt-upgrade "$APT_MODE"); fi
    proot-distro login "$DISTRO" -- bash /var/tmp/termux-root-bridge-install/install-guest.sh "${GUEST_ARGS[@]}"
    rm -rf "$STAGE"
else
    say "  übersprungen (--no-guest)"
fi

say
say "Fertig. Weiter:"
say "  rootbridge status        # Zustand prüfen"
say "  ubuntu                   # an die Claude-Code-Sitzung anhängen (legt sie an; auch Widget 'Claude')"
say "  rootbridge start         # Daemon + Sitzung (Termux:Boot ruft das nach einem Neustart auf)"
say "Normale Termux-Fenster bleiben reine Shells; Claude Code startet nicht mehr automatisch."
say "Nach dem ersten Start: Claude Code neu starten, damit die Managed Settings gelten."
if [ "$DO_COLORS" = 1 ]; then
    say "Farben: ~/.termux/colors.properties wird in jeder neuen Termux-Shell und von den Widgets geladen; Claude Code nutzt das Theme '$CLAUDE_THEME'."
fi
