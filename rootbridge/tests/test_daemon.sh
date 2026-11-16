#!/usr/bin/env bash
# Integration test: androidsu client + rootbridge-daemon with a fake `su`, a fake Android dialog
# (termux-dialog) and a fake browser opener. Runs anywhere bash and python3 exist.
#   bash tests/test_daemon.sh
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib.sh
. "$ROOT/tests/lib.sh"
DAEMON="$ROOT/termux/bin/rootbridge-daemon"
CLIENT="$ROOT/guest/bin/androidsu"
OPENER="$ROOT/guest/bin/rootbridge-open"

make_tmp
mkdir -p "$T/bridge" "$T/home" "$T/bin" "$T/tmp"

# fake su: `fake-su [-mm] -c <cmd>` -> logs, then runs the command with sh
cat > "$T/fake-su" <<'EOF'
#!/bin/sh
while [ "$1" != "-c" ]; do shift; done
shift
echo "$1" >> "$(dirname "$0")/su.log"
exec sh -c "$1"
EOF
# fake termux-api client: `fake-ask Dialog --es input_title <t> --es input_hint <text> --es input_yes <Ja> ...`; the answer is
# the content of ask.answer, what it was asked is in ask.log (title and first line of the text) and ask.extras (the rest)
cat > "$T/fake-ask" <<'EOF'
#!/bin/sh
d="$(dirname "$0")"
shift
title=""; hint=""; yes=""; no=""; tmo=""; txt=""; modal=""
while [ $# -gt 0 ]; do
    case "$1:$2" in
        --es:input_title) title="$3"; shift 3 ;;
        --es:input_hint) hint="$3"; shift 3 ;;
        --es:input_yes) yes="$3"; shift 3 ;;
        --es:input_no) no="$3"; shift 3 ;;
        --ei:input_timeout) tmo="$3"; shift 3 ;;
        --es:input_timeout_text) txt="$3"; shift 3 ;;
        --ez:input_modal) modal="$3"; shift 3 ;;
        *) shift ;;
    esac
done
echo "START $title|$(printf '%s' "$hint" | head -n 1)" >> "$d/ask.log"
echo "yes=$yes no=$no timeout=$tmo text=$txt modal=$modal hint=$(printf '%s' "$hint" | tr '\n' '|')" > "$d/ask.extras"
ans="$(cat "$d/ask.answer" 2>/dev/null)"
case "$ans" in seq:*)
    list="${ans#seq:}"; ans="${list%%,*}"; rest="${list#*,}"
    if [ "$rest" = "$list" ]; then rest=""; fi
    if [ -n "$rest" ]; then printf 'seq:%s' "$rest"; else printf 'no'; fi > "$d/ask.answer" ;;
esac
case "$ans" in
    yes)     echo '{"code": 0, "text": "yes"}' ;;
    no)      echo '{"code": 0, "text": "no"}' ;;
    dismiss) echo '{"code": -2, "text": ""}' ;;
    garbage) echo 'huh' ;;
    fail)    exit 1 ;;
    slow)    sleep 5; echo '{"code": 0, "text": "yes"}' ;;
    slowyes) sleep 1; echo '{"code": 0, "text": "yes"}' ;;
esac
echo "END" >> "$d/ask.log"
EOF
cat > "$T/fake-open" <<'EOF'
#!/bin/sh
echo "$1" >> "$(dirname "$0")/open.log"
EOF
cat > "$T/fake-clip" <<'EOF'
#!/bin/sh
cat > "$(dirname "$0")/clip.txt"
EOF
chmod +x "$T/fake-su" "$T/fake-ask" "$T/fake-open" "$T/fake-clip"
printf '#!/bin/bash\nexec bash "%s" "$@"\n' "$CLIENT" > "$T/bin/androidsu"
chmod +x "$T/bin/androidsu"

printf 'ASK_TIMEOUT=4\n' > "$T/test.cfg"
export HOME="$T/home" BRIDGE_DIR="$T/bridge" ROOTBRIDGE_DIR="$T/bridge" TMPDIR="$T/tmp"
export RB_SU="$T/fake-su" RB_ASK_CMD="$T/fake-ask" RB_OPEN_CMD="$T/fake-open" RB_CLIP_CMD="$T/fake-clip"
export RB_PROC_DIR="$T/proc" RB_ASK_MIN_MS=0 RB_LANG=en   # a Yes of the fake dialog comes at once; English unless a test says otherwise
export TERMUX_BIN="$T/no-termux-bin"
export ROOTBRIDGE_CONF="$T/none.conf" ROOTBRIDGE_CONFIG="$T/test.cfg"
unset CLAUDECODE ROOTBRIDGE_TICKET

contains() { # contains <name> <needle> <haystack>
    case "$3" in *"$2"*) PASS=$((PASS + 1)); printf 'ok    %s\n' "$1" ;;
        *) FAIL=$((FAIL + 1)); printf 'FAIL  %s\n      "%s" nicht in: %s\n' "$1" "$2" "$3" ;; esac
}

answer() { printf '%s' "$1" > "$T/ask.answer"; }
asks() { [ -f "$T/ask.log" ] && grep -c '^START' "$T/ask.log" | tr -d ' ' || echo 0; }

OUT=""; CODE=""
run_client() {  # run_client <androidsu args...>
    ( bash "$CLIENT" "$@" > "$T/out" 2> "$T/err"; echo $? > "$T/code" ) &
    local pid=$!
    sleep 0.7
    bash "$DAEMON" --once
    wait "$pid"
    OUT="$(cat "$T/out")"; CODE="$(cat "$T/code")"
}
su_runs() { [ -f "$T/su.log" ] && wc -l < "$T/su.log" | tr -d ' ' || echo 0; }

echo "== androidsu + daemon: du entscheidest im Dialog"
answer yes
run_client 'echo hi'
check "Ja: Exitcode 0" 0 "$CODE"
check "Ja: Ausgabe" "hi" "$OUT"
check "Ja: su einmal aufgerufen" 1 "$(su_runs)"
check "Ja: ein Dialog, mit Befehl und Titel (ohne erkannten Agenten: Shell)" "START Android-Root: Shell|echo hi" "$(grep '^START' "$T/ask.log" | tail -n 1)"

answer no
run_client 'echo hi'
check "Nein: 99" 99 "$CODE"
contains "Nein: Grund und Hinweis gegen Umgehung" "Der Nutzer hat die Root-Anfrage in Termux abgelehnt. Keine Umgehung" "$OUT"
check "Nein: su nicht erneut aufgerufen" 1 "$(su_runs)"

answer dismiss
n="$(asks)"
run_client 'echo hi'
check "Dialog nur weggedrückt, nie beantwortet: nach ASK_TIMEOUT 99, su nicht aufgerufen" "99 1" "$CODE $(su_runs)"
contains "Dialog nur weggedrückt: Grund ist die fehlende Antwort" "Keine Antwort auf die Rückfrage" "$OUT"
check "Dialog weggedrückt: er wurde mehrmals neu gezeigt" ja "$([ "$(( $(asks) - n ))" -ge 2 ] && echo ja || echo nein)"

answer garbage
run_client 'echo hi'
check "Unverständliche Dialog-Antwort: 99" 99 "$CODE"
contains "Unverständliche Antwort: Grund" "ließ sich nicht anzeigen" "$OUT"

answer fail
run_client 'echo hi'
check "Dialog scheitert: 99, su nicht aufgerufen" "99 1" "$CODE $(su_runs)"

RB_ASK_CMD="$T/gibt-es-nicht" run_client 'echo hi'
check "Dialog-Programm fehlt: 99, su nicht aufgerufen" "99 1" "$CODE $(su_runs)"

answer slow
run_client 'echo hi'
check "Keine Antwort in ASK_TIMEOUT: 99" 99 "$CODE"
contains "Keine Antwort: Grund" "Keine Antwort auf die Rückfrage" "$OUT"
check "Keine Antwort: su nicht aufgerufen" 1 "$(su_runs)"
check "Dialog-Sperre wieder frei" ja "$(flock -n "$T/tmp/rootbridge-ask.flock" true && echo ja || echo nein)"

echo "== Dialog: Sprache des Telefons, Countdown, nicht wegdrückbar"
answer yes
run_client 'echo hi'
ex="$(cat "$T/ask.extras")"
contains "Englisch: Tasten Yes und No" "yes=Yes no=No" "$ex"
contains "Frist: input_timeout bis ASK_TIMEOUT" "timeout=" "$ex"
check "Frist: input_timeout liegt zwischen 1 und ASK_TIMEOUT" ja "$(t="${ex#*timeout=}"; t="${t%% *}"; [ "$t" -ge 1 ] && [ "$t" -le 4 ] && echo ja || echo nein)"
contains "Countdown-Text" "text=%d s left" "$ex"
contains "Nur Tippen auf die Tasten: input_modal" "modal=true" "$ex"
case "$ex" in *"hint=echo hi||Answer by "[0-9][0-9]:[0-9][0-9]:[0-9][0-9]) PASS=$((PASS + 1)); echo "ok    Text: Befehl, Leerzeile, Frist als Uhrzeit" ;; *) FAIL=$((FAIL + 1)); echo "FAIL  Text: Befehl, Leerzeile, Frist als Uhrzeit: $ex" ;; esac
RB_LANG=de run_client 'echo hi'
contains "Deutsch: Ja und Nein, noch %d s, Antwort bis" "yes=Ja no=Nein timeout=" "$(cat "$T/ask.extras")"
contains "Deutsch: Countdown-Text" "text=noch %d s" "$(cat "$T/ask.extras")"
contains "Deutsch: Frist im Text" "||Antwort bis " "$(cat "$T/ask.extras")"
RB_LANG=es-ES run_client 'echo hi'
contains "Spanisch (es-ES): Sí und No" "yes=Sí no=No" "$(cat "$T/ask.extras")"
RB_LANG=fr run_client 'echo hi'
contains "Unbekannte Sprache: Englisch" "yes=Yes no=No" "$(cat "$T/ask.extras")"

echo "== Sperre nicht nutzbar: kein Dialog, abgelehnt"
rm -f "$T/tmp/rootbridge-ask.flock"; mkdir "$T/tmp/rootbridge-ask.flock"   # a directory where the lock file should be
answer yes
n="$(asks)"; r="$(su_runs)"
run_client 'echo ohne-sperre'
check "Sperre nicht zu öffnen: 99, kein Dialog, su nicht aufgerufen" "99 $n $r" "$CODE $(asks) $(su_runs)"
contains "Sperre nicht zu öffnen: Grund" "ließ sich nicht anzeigen" "$OUT"
rmdir "$T/tmp/rootbridge-ask.flock"

echo "== weggedrückt oder zu schnell: der Dialog kommt wieder"
answer seq:dismiss,yes
n="$(asks)"
run_client 'echo nach-dem-wegdruecken'
check "Weggedrückt, dann Ja: der Dialog kommt wieder, Ja gilt" "0 nach-dem-wegdruecken $(( n + 2 ))" "$CODE $OUT $(asks)"
answer seq:dismiss,no
run_client 'echo hi'
check "Weggedrückt, dann Nein: abgelehnt" 99 "$CODE"
RB_ASK_MIN_MS=500 answer seq:yes,no
n="$(asks)"
RB_ASK_MIN_MS=500 run_client 'echo zu-schnell'
check "Ja binnen RB_ASK_MIN_MS gilt nicht: neu gefragt, dann Nein" "99 $(( n + 2 ))" "$CODE $(asks)"
answer slowyes
RB_ASK_MIN_MS=500 run_client 'echo bedacht'
check "Ja nach der Mindestzeit gilt" "0 bedacht" "$CODE $OUT"
answer yes

answer yes
run_client 'exit 7'
check "Exitcode wird durchgereicht" 7 "$CODE"
run_client 'echo a; echo b >&2; echo c'
check "stdout+stderr zusammen, mehrzeilig" "$(printf 'a\nb\nc')" "$OUT"
ROOTBRIDGE_ACK_TIMEOUT=2 run_client 'sleep 4; echo spaet'
check "langer Befehl überlebt ACK-Timeout" "spaet" "$OUT"

# nothing the guest can write counts as a confirmation: old tickets and ack files are ignored
answer no
mkdir -p "$BRIDGE_DIR/tickets"
printf '%s\n%s\n%s\n' "$(( $(date +%s) + 600 ))" "$(printf '%s' 'echo hi' | sha256sum | cut -d' ' -f1)" 'echo hi' > "$BRIDGE_DIR/tickets/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
before="$(su_runs)"
ROOTBRIDGE_TICKET=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa run_client 'echo hi'
check "Altes Ticket zählt nicht: 99, su nicht aufgerufen" "99 $before" "$CODE $(su_runs)"
printf '%s\n' 'echo forged' > "$BRIDGE_DIR/req-forged_1.txt"; : > "$BRIDGE_DIR/approve-forged_1"; : > "$BRIDGE_DIR/ack-forged_1"
bash "$DAEMON" --once; sleep 0.3
check "Gefälschte Freigabe-Dateien zählen nicht" "99 $before" "$(head -n 1 "$BRIDGE_DIR/res-forged_1.txt") $(su_runs)"
rm -f "$BRIDGE_DIR/res-forged_1.txt" "$BRIDGE_DIR/approve-forged_1" "$BRIDGE_DIR/ack-forged_1"

echo "== Länge und Zeichen der Anzeige"
n="$(asks)"
long="echo $(head -c 4100 /dev/zero | tr '\0' x)"
answer yes
run_client "$long"
check "Zu langer Befehl: 99 ohne Dialog" "99 $n" "$CODE $(asks)"
contains "Zu langer Befehl: Grund" "zu lang für die Rückfrage" "$OUT"
run_client "$(printf 'echo ok\001\033[31mrot')"
check "Steuerzeichen stehen nicht im Dialog" "START Android-Root: Shell|echo ok[31mrot" "$(grep '^START' "$T/ask.log" | tail -n 1)"

echo "== Anfragender: Claude Code, Codex, keiner"
mkproc() {  # mkproc <pid> <ppid> <process name>: what Termux reads from /proc/<pid>/{status,comm} (not exe: under proot it is no program)
    mkdir -p "$T/proc/$1"
    printf 'Name:\t%s\nPPid:\t%s\n' "$3" "$2" > "$T/proc/$1/status"
    printf '%s\n' "$3" > "$T/proc/$1/comm"
}
mkproc 4000 1 claude
mkproc 4100 4000 bash                                      # rootbridge-claude, Bash tool
mkproc 4242 4100 bash                                      # androidsu
mkproc 5000 1 codex
mkproc 5242 5000 bash
mkproc 6242 1 bash                                         # a plain shell
rm -rf "$BRIDGE_DIR/events"; answer no
for rid in 4242_1 5242_1 6242_1; do
    printf '%s\n' 'echo wer' > "$BRIDGE_DIR/req-$rid.txt"
    bash "$DAEMON" --once; sleep 0.3
done
check "Dialog nennt Claude Code" "START Android-Root: Claude Code|echo wer" "$(grep '^START' "$T/ask.log" | tail -n 3 | sed -n 1p)"
check "Dialog nennt Codex" "START Android-Root: Codex|echo wer" "$(grep '^START' "$T/ask.log" | tail -n 3 | sed -n 2p)"
check "Dialog ohne erkannten Agenten: Shell" "START Android-Root: Shell|echo wer" "$(grep '^START' "$T/ask.log" | tail -n 3 | sed -n 3p)"
check "Ereignisse nur für erkannte Agenten (4000 und 5000)" "4000 5000" "$(ls "$BRIDGE_DIR/events" | sed 's/-.*//' | sort -u | tr '\n' ' ' | sed 's/ $//')"
ev="$(ls "$BRIDGE_DIR/events"/4000-* | head -n 1)"
check "Ereignis: Entscheidung und Befehl" "DENY-USER echo wer" "$(sed -n 1p "$ev") $(sed -n 2p "$ev")"
rm -f "$BRIDGE_DIR"/res-*_1.txt "$BRIDGE_DIR"/ack-*_1

echo "== Zwei Anfragen gleichzeitig: ein Dialog nach dem anderen"
: > "$T/ask.log"; answer slowyes
printf '%s\n' 'echo eins' > "$BRIDGE_DIR/req-7001_1.txt"; printf '%s\n' 'echo zwei' > "$BRIDGE_DIR/req-7002_1.txt"
bash "$DAEMON" --once
check "Dialoge überlappen nicht: START, END, START, END" "START END START END" "$(sed 's/ .*//' "$T/ask.log" | tr '\n' ' ' | sed 's/ $//')"
rm -f "$BRIDGE_DIR"/res-700*_1.txt "$BRIDGE_DIR"/ack-700*_1

echo "== veraltete Anfrage"
printf '%s\n' "echo stale" > "$BRIDGE_DIR/req-old_1.txt"
touch -d '10 minutes ago' "$BRIDGE_DIR/req-old_1.txt"
n="$(asks)"
bash "$DAEMON" --once; sleep 0.3
check "STALE: Antwort 99, ohne Dialog" "99 $n" "$(head -n 1 "$BRIDGE_DIR/res-old_1.txt") $(asks)"
rm -f "$BRIDGE_DIR/res-old_1.txt"

echo "== Konfiguration wird nicht ausgeführt"
cat > "$T/evil.cfg" <<EOF
SU_ARGS=-c; touch $T/pwned
RB_SU=/bin/false
RB_ASK_CMD=/bin/true
ASK_TIMEOUT=abc
\$(touch $T/pwned2)
EOF
( ROOTBRIDGE_CONFIG="$T/evil.cfg"; . "$ROOT/termux/lib/rootbridge-lib.sh"; rb_load_config
  printf '%s|%s|%s\n' "$SU_ARGS" "$ASK_TIMEOUT" "$RB_ASK_CMD" > "$T/cfgresult" )
check "unzulässige Config-Werte ignoriert, Dialog-Programm bleibt aus der Umgebung" "-c|120|$T/fake-ask" "$(cat "$T/cfgresult")"
check "Config-Datei nicht ausgeführt" "no" "$([ -e "$T/pwned" ] || [ -e "$T/pwned2" ] && echo yes || echo no)"
( ROOTBRIDGE_CONFIG="$T/test.cfg"; . "$ROOT/termux/lib/rootbridge-lib.sh"; rb_load_config; echo "$ASK_TIMEOUT" > "$T/cfgresult" )
check "ASK_TIMEOUT aus der Config" 4 "$(cat "$T/cfgresult")"

echo "== Audit-Log"
log="$(cat "$BRIDGE_DIR/audit.log")"
for d in ALLOW DENY-USER ASK-FAIL ASK-TIMEOUT STALE; do contains "Audit: $d" "$d" "$log"; done
check "Audit: keine Ticket-Entscheidungen mehr" 0 "$(grep -c 'TICKET' "$BRIDGE_DIR/audit.log")"

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
finish
