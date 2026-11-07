#!/usr/bin/env bash
# Integration test: androidsu client + rootbridge-daemon (+ guard hook) with a
# fake `su` and a fake browser opener. Runs anywhere bash and python3 exist.
#   bash tests/test_daemon.sh
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DAEMON="$ROOT/termux/bin/rootbridge-daemon"
CLIENT="$ROOT/guest/bin/androidsu"
OPENER="$ROOT/guest/bin/rootbridge-open"
GUARD="$ROOT/guest/claude/android-root-guard.py"

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bridge/tickets" "$T/home" "$T/bin"

# fake su: `fake-su [-mm] -c <cmd>` -> logs, then runs the command with sh
cat > "$T/fake-su" <<'EOF'
#!/bin/sh
while [ "$1" != "-c" ]; do shift; done
shift
echo "$1" >> "$(dirname "$0")/su.log"
exec sh -c "$1"
EOF
cat > "$T/fake-open" <<'EOF'
#!/bin/sh
echo "$1" >> "$(dirname "$0")/open.log"
EOF
cat > "$T/fake-clip" <<'EOF'
#!/bin/sh
cat > "$(dirname "$0")/clip.txt"
EOF
chmod +x "$T/fake-su" "$T/fake-open" "$T/fake-clip"
printf '#!/bin/bash\nexec bash "%s" "$@"\n' "$CLIENT" > "$T/bin/androidsu"
chmod +x "$T/bin/androidsu"

export HOME="$T/home" BRIDGE_DIR="$T/bridge" ROOTBRIDGE_DIR="$T/bridge"
export RB_SU="$T/fake-su" RB_OPEN_CMD="$T/fake-open" RB_CLIP_CMD="$T/fake-clip"
export TERMUX_BIN="$T/no-termux-bin"
export ROOTBRIDGE_TTY_CONFIRM=0 ROOTBRIDGE_CONF="$T/none.conf" ROOTBRIDGE_CONFIG="$T/none.cfg"
unset CLAUDECODE ROOTBRIDGE_TICKET

PASS=0; FAIL=0
check() {   # check <name> <expected> <actual>
    if [ "$2" = "$3" ]; then PASS=$((PASS + 1)); printf 'ok    %s\n' "$1"
    else FAIL=$((FAIL + 1)); printf 'FAIL  %s\n      erwartet: %s\n      erhalten: %s\n' "$1" "$2" "$3"; fi
}
contains() { # contains <name> <needle> <haystack>
    case "$3" in *"$2"*) PASS=$((PASS + 1)); printf 'ok    %s\n' "$1" ;;
        *) FAIL=$((FAIL + 1)); printf 'FAIL  %s\n      "%s" nicht in: %s\n' "$1" "$2" "$3" ;; esac
}

mkticket() {  # mkticket <cmd> <ttl> [hash]  -> prints id
    local id hash
    id="$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
    hash="${3:-$(printf '%s' "$1" | sha256sum | cut -d' ' -f1)}"
    printf '%s\n%s\n%s\n' "$(( $(date +%s) + $2 ))" "$hash" "$1" > "$BRIDGE_DIR/tickets/$id"
    echo "$id"
}

OUT=""; CODE=""
run_client() {  # run_client <androidsu args...>; env (ROOTBRIDGE_TICKET...) is inherited
    ( bash "$CLIENT" "$@" > "$T/out" 2> "$T/err"; echo $? > "$T/code" ) &
    local pid=$!
    sleep 0.7
    bash "$DAEMON" --once
    wait "$pid"
    OUT="$(cat "$T/out")"; CODE="$(cat "$T/code")"
}
su_runs() { [ -f "$T/su.log" ] && wc -l < "$T/su.log" | tr -d ' ' || echo 0; }

echo "== androidsu + daemon"
run_client 'echo hi'
check "ohne Ticket: Exitcode 99" 99 "$CODE"
contains "ohne Ticket: Hinweis" "keine Freigabe aus Claude Code" "$OUT"
check "ohne Ticket: su nie aufgerufen" 0 "$(su_runs)"

id="$(mkticket 'echo hi' 60)"
ROOTBRIDGE_TICKET="$id" run_client 'echo hi'
check "mit Ticket: Exitcode 0" 0 "$CODE"
check "mit Ticket: Ausgabe" "hi" "$OUT"
check "mit Ticket: su einmal aufgerufen" 1 "$(su_runs)"
check "Ticket verbraucht" "" "$(ls "$BRIDGE_DIR/tickets")"

ROOTBRIDGE_TICKET="$id" run_client 'echo hi'
check "Ticket wiederverwendet: 99" 99 "$CODE"
contains "Ticket wiederverwendet: Grund" "unbekannt oder schon benutzt" "$OUT"
check "Ticket wiederverwendet: su nicht erneut" 1 "$(su_runs)"

id="$(mkticket 'echo hi' -5)"
ROOTBRIDGE_TICKET="$id" run_client 'echo hi'
check "abgelaufenes Ticket: 99" 99 "$CODE"
contains "abgelaufenes Ticket: Grund" "abgelaufen" "$OUT"

id="$(mkticket 'echo other' 60)"
ROOTBRIDGE_TICKET="$id" run_client 'echo hi'
check "Ticket für anderen Befehl: 99" 99 "$CODE"
contains "Ticket für anderen Befehl: Grund" "anderen Befehl" "$OUT"
check "Ticket für anderen Befehl: su nicht aufgerufen" 1 "$(su_runs)"

ROOTBRIDGE_TICKET="not-a-ticket" run_client 'echo hi'
check "ungültige Ticket-ID: 99" 99 "$CODE"

id="$(mkticket 'exit 7' 60)"
ROOTBRIDGE_TICKET="$id" run_client 'exit 7'
check "Exitcode wird durchgereicht" 7 "$CODE"

id="$(mkticket 'echo a; echo b >&2; echo c' 60)"
ROOTBRIDGE_TICKET="$id" run_client 'echo a; echo b >&2; echo c'
check "stdout+stderr zusammen, mehrzeilig" "$(printf 'a\nb\nc')" "$OUT"

id="$(mkticket 'sleep 4; echo spaet' 60)"
ROOTBRIDGE_TICKET="$id" ROOTBRIDGE_ACK_TIMEOUT=2 run_client 'sleep 4; echo spaet'
check "langer Befehl überlebt ACK-Timeout" "spaet" "$OUT"

echo "== veraltete Anfrage"
printf '%s\n' "echo stale" > "$BRIDGE_DIR/req-old_1.txt"
touch -d '10 minutes ago' "$BRIDGE_DIR/req-old_1.txt"
bash "$DAEMON" --once; sleep 0.3
check "STALE: Antwort 99" 99 "$(head -n 1 "$BRIDGE_DIR/res-old_1.txt")"
rm -f "$BRIDGE_DIR/res-old_1.txt"

echo "== Konfiguration wird nicht ausgeführt"
cat > "$T/evil.cfg" <<EOF
SU_ARGS=-c; touch $T/pwned
RB_SU=/bin/false
TICKET_TTL=abc
\$(touch $T/pwned2)
EOF
( ROOTBRIDGE_CONFIG="$T/evil.cfg"; . "$ROOT/termux/lib/rootbridge-lib.sh"; rb_load_config
  printf '%s|%s\n' "$SU_ARGS" "$TICKET_TTL" > "$T/cfgresult" )
check "unzulässige Config-Werte ignoriert" "-c|1800" "$(cat "$T/cfgresult")"
check "Config-Datei nicht ausgeführt" "no" "$([ -e "$T/pwned" ] || [ -e "$T/pwned2" ] && echo yes || echo no)"

echo "== Guard-Hook + androidsu + Daemon (Ende zu Ende)"
printf 'BRIDGE_DIR=%s\nTICKET_TTL=60\n' "$BRIDGE_DIR" > "$T/guard.conf"
hook_out="$(printf '%s' '{"tool_name":"Bash","tool_input":{"command":"androidsu '"'"'echo ende-zu-ende'"'"'"}}' \
    | ROOTBRIDGE_CONF="$T/guard.conf" python3 -I "$GUARD")"
newcmd="$(printf '%s' "$hook_out" | python3 -I -c 'import json,sys; print(json.load(sys.stdin)["hookSpecificOutput"]["updatedInput"]["command"])')"
contains "Hook liefert Befehl mit Ticket" "ROOTBRIDGE_TICKET=" "$newcmd"
( env PATH="$T/bin:$PATH" bash -c "$newcmd" > "$T/out" 2> "$T/err"; echo $? > "$T/code" ) &
pid=$!; sleep 0.7; bash "$DAEMON" --once; wait "$pid"
check "Hook-Ticket akzeptiert (Hash-Format passt)" "ende-zu-ende" "$(cat "$T/out")"
check "Hook-Ticket: Exitcode 0" 0 "$(cat "$T/code")"

echo "== Audit-Log"
log="$(cat "$BRIDGE_DIR/audit.log")"
contains "Audit: ALLOW" "ALLOW" "$log"
contains "Audit: DENY-NOTICKET" "DENY-NOTICKET" "$log"
contains "Audit: DENY-TICKET" "DENY-TICKET" "$log"
contains "Audit: STALE" "STALE" "$log"

echo "== URLs öffnen"
open_url() {  # open_url <url>  -> CODE
    ( bash "$OPENER" "$1" > "$T/out" 2> "$T/err"; echo $? > "$T/code" ) &
    local pid=$!
    sleep 0.7
    bash "$DAEMON" --once
    wait "$pid"
    CODE="$(cat "$T/code")"
}
: > "$BRIDGE_DIR/.alive"     # heartbeat: daemon "läuft"
open_url 'https://example.com/oauth/authorize?client_id=abc&state=x%20y'
check "https-URL: Exitcode 0" 0 "$CODE"
check "https-URL: Opener bekam URL" 'https://example.com/oauth/authorize?client_id=abc&state=x%20y' "$(cat "$T/open.log")"
check "https-URL: Zwischenablage" 'https://example.com/oauth/authorize?client_id=abc&state=x%20y' "$(cat "$T/clip.txt")"

before="$(wc -l < "$T/open.log" | tr -d ' ')"
for bad in 'http://example.com/' 'javascript:alert(1)' 'file:///sdcard/x' 'https://exa mple.com/' \
           'https://example.com/a"b' "https://example.com/a'b" 'https://example.com/a<b' 'ftp://example.com/'; do
    open_url "$bad"
    check "abgelehnt (Client): $bad" 2 "$CODE"
done
check "abgelehnte URLs erreichen den Opener nie" "$before" "$(wc -l < "$T/open.log" | tr -d ' ')"

# a hostile client skipping its own validation: the daemon validates again
printf '%s\n' 'javascript:alert(1)' > "$BRIDGE_DIR/open-evil_1.url"
bash "$DAEMON" --once; sleep 0.3
check "Daemon prüft URL selbst nochmal" 2 "$(head -n 1 "$BRIDGE_DIR/open-res-evil_1")"
check "Opener weiter unberührt" "$before" "$(wc -l < "$T/open.log" | tr -d ' ')"

# copy-only: clipboard yes, browser no
before="$(wc -l < "$T/open.log" | tr -d ' ')"
: > "$BRIDGE_DIR/.alive"
open_url_copy() {
    ( bash "$OPENER" --copy-only "$1" > "$T/out" 2> "$T/err"; echo $? > "$T/code" ) &
    local pid=$!
    sleep 0.7
    bash "$DAEMON" --once
    wait "$pid"
    CODE="$(cat "$T/code")"
}
: > "$T/clip.txt"
open_url_copy 'https://login.example.org/a?b=c'
check "copy-only: Exitcode 0" 0 "$CODE"
check "copy-only: Zwischenablage" 'https://login.example.org/a?b=c' "$(cat "$T/clip.txt")"
check "copy-only: Browser nicht geöffnet" "$before" "$(wc -l < "$T/open.log" | tr -d ' ')"

rm -f "$BRIDGE_DIR/.alive"
( bash "$OPENER" --copy-only 'https://login.example.org/x' > /dev/null 2> "$T/err"; echo $? > "$T/code" )
check "ohne Daemon und ohne Termux-Tool: copy-only schlägt fehl" 1 "$(cat "$T/code")"
( bash "$OPENER" 'https://login.example.org/x' > /dev/null 2> "$T/err"; echo $? > "$T/code" )
check "ohne Daemon und ohne Termux-Tool: open schlägt fehl" 1 "$(cat "$T/code")"
contains "Fehlermeldung nennt die URL" "https://login.example.org/x" "$(cat "$T/err")"

echo
echo "Ergebnis: $PASS bestanden, $FAIL fehlgeschlagen"
[ "$FAIL" -eq 0 ]
