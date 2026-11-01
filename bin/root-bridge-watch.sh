#!/data/data/com.termux/files/usr/bin/bash
# Root-Bridge-Wächter: läuft unsichtbar im Hintergrund (eigenes tmux-Fenster).
# Beobachtet ~/.rootbridge/req-*.txt und zeigt jede Anfrage als tmux-Popup
# direkt über dem aktuell sichtbaren Fenster an - kein Fenster-Wechsel nötig.
# Nur eine Instanz gleichzeitig (Lock in $BRIDGE_DIR/.lock) - verhindert
# doppelte Popups, falls z. B. ubuntu-switch.sh mehrfach einen Wächter startet.

source "$(dirname "$0")/bridge-lib.sh"

LOCK="$BRIDGE_DIR/.lock"

cleanup() {
    # rm -rf statt rmdir: der Lock enthält die pid-Datei, ein reines rmdir
    # würde an "Directory not empty" scheitern und den Lock für immer stehen lassen.
    rm -rf "$LOCK" 2>/dev/null
}

if ! mkdir "$LOCK" 2>/dev/null; then
    OTHER_PID="$(cat "$LOCK/pid" 2>/dev/null)"
    if [ -n "$OTHER_PID" ] && kill -0 "$OTHER_PID" 2>/dev/null; then
        echo "root-bridge-watch.sh läuft bereits (PID $OTHER_PID) - beende diese Instanz." >&2
        exit 0
    fi
    # Lock verwaist (alter Prozess tot) - übernehmen.
    rm -rf "$LOCK" 2>/dev/null
    mkdir "$LOCK" 2>/dev/null || exit 0
fi
echo "$$" > "$LOCK/pid"
# HUP mit aufnehmen: `tmux kill-window`/Session-Ende schickt SIGHUP, nicht TERM -
# ohne HUP im Trap bliebe der Lock nach jedem Fenster-Kill verwaist zurück.
# Wichtig: bei INT/TERM/HUP muss explizit `exit` folgen - ein Bash-Trap allein
# beendet den Prozess NICHT, sonst liefe der Wächter als Waise ohne Lock weiter
# (und ein zweiter könnte parallel starten - genau das, was der Lock verhindern soll).
trap cleanup EXIT
trap 'cleanup; exit 0' INT TERM HUP

# Aufräumen vom letzten Lauf: verwaiste res-Dateien (Client hat nie abgeholt)
# und uralte req-Dateien (niemand hat sie je bearbeitet) entfernen.
rm -f "$BRIDGE_DIR"/res-*.txt 2>/dev/null
for OLDREQ in "$BRIDGE_DIR"/req-*.txt; do
    [ -e "$OLDREQ" ] || continue
    OLDREQ_MTIME="$(stat -c %Y "$OLDREQ" 2>/dev/null)"
    [ -n "$OLDREQ_MTIME" ] || continue
    AGE=$(( $(date +%s) - OLDREQ_MTIME ))
    [ "$AGE" -gt "$BRIDGE_STALE_TIMEOUT" ] && rm -f "$OLDREQ"
done

while true; do
    for REQ in "$BRIDGE_DIR"/req-*.txt; do
        [ -e "$REQ" ] || continue
        ID="$(basename "$REQ" .txt)"
        ID="${ID#req-}"
        POPUP_CMD="$HOME/bin/root-bridge-confirm.sh $(printf '%q' "$ID")"
        tmux display-popup -t "$BRIDGE_SESSION" -E -w 90% -h 40% "$POPUP_CMD"
    done
    sleep 1
done
