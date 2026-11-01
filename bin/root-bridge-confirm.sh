#!/data/data/com.termux/files/usr/bin/bash
# Wird per `tmux display-popup` gestartet, $1 = Request-ID.
# Zeigt die Root-Anfrage deutlich als Overlay, verlangt 'y' + Enter innerhalb
# von BRIDGE_ANSWER_TIMEOUT, führt bei Bestätigung `su -c` aus und protokolliert
# jede Entscheidung (ALLOW/DENY/STALE/NO-SU/EMPTY) im Audit-Log.

source "$(dirname "$0")/bridge-lib.sh"

ID="$1"
REQ="$BRIDGE_DIR/req-$ID.txt"
RES="$BRIDGE_DIR/res-$ID.txt"
RES_TMP="$RES.tmp.$$"

# Schreibt res atomar (tmp + mv), damit der pollende Client nie eine
# halb geschriebene Datei sieht.
write_res() {
    printf '%s\n%s\n' "$1" "$2" > "$RES_TMP"
    mv -f "$RES_TMP" "$RES"
}

CMD="$(cat "$REQ" 2>/dev/null)"

if [ -z "$CMD" ]; then
    write_res 98 "Leere oder verschwundene Anfrage."
    log_audit "EMPTY" 98 ""
    rm -f "$REQ"
    exit 0
fi

# Stale-Check: Ist die Anfrage älter als das Poll-Timeout von androidsu, hat der
# Client längst aufgegeben - ohne Popup ablehnen statt nutzlos nachzufragen.
REQ_MTIME="$(stat -c %Y "$REQ" 2>/dev/null)"
if [ -n "$REQ_MTIME" ]; then
    REQ_AGE=$(( $(date +%s) - REQ_MTIME ))
    if [ "$REQ_AGE" -gt "$BRIDGE_STALE_TIMEOUT" ]; then
        write_res 99 "Abgelehnt (Anfrage war bereits abgelaufen, kein Popup angezeigt)."
        log_audit "STALE" 99 "$CMD"
        rm -f "$REQ"
        exit 0
    fi
fi

if ! command -v su >/dev/null 2>&1; then
    write_res 127 "su nicht gefunden - kein Android-Root verfügbar."
    log_audit "NO-SU" 127 "$CMD"
    rm -f "$REQ"
    exit 0
fi

clear
echo "════════════════════════════════════════"
echo " ⚠  ANDROID-ROOT ANGEFRAGT"
echo "════════════════════════════════════════"
echo "Befehl: $CMD"
echo ""

ANSWER=""
read -t "$BRIDGE_ANSWER_TIMEOUT" -p "Mit 'y' + Enter bestätigen (${BRIDGE_ANSWER_TIMEOUT}s Timeout): " ANSWER

if [ "$ANSWER" = "y" ]; then
    OUTPUT="$(su -c "$CMD" 2>&1)"
    CODE=$?
    write_res "$CODE" "$OUTPUT"
    log_audit "ALLOW" "$CODE" "$CMD"
    echo "Ausgeführt (Exitcode $CODE)."
else
    write_res 99 "Abgelehnt (kein y oder Timeout)."
    log_audit "DENY" 99 "$CMD"
    echo "Abgelehnt."
fi

sleep 2
rm -f "$REQ"
