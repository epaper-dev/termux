#!/usr/bin/env bash
# Test: when Claude Code ends cleanly (/exit = 0, Ctrl+C = 130), guest/bin/rootbridge-claude ends too, so
# the tmux window/session and the widget's Termux window close. After an error exit the guest shell
# stays open (the message stays readable).
#   Nothing real is started: from rootbridge-claude only conf_get, limit_nofile and after_claude are cut
#   out, plus the two launch lines (Claude start + `after_claude "$?"`), run against a stub `claude`
#   and a stub `bash` (the shell `exec bash -l` would start).
#   bash tests/test_session_exit.sh
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/guest/bin/rootbridge-claude"
REAL_BASH="$(command -v bash)"

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

PASS=0; FAIL=0
check() {   # check <name> <expected> <actual>
    if [ "$2" = "$3" ]; then PASS=$((PASS + 1)); printf 'ok    %s\n' "$1"
    else FAIL=$((FAIL + 1)); printf 'FAIL  %s\n      erwartet: %s\n      erhalten: %s\n' "$1" "$2" "$3"; fi
}

bash -n "$SCRIPT" 2>/dev/null
check "rootbridge-claude: Syntax in Ordnung" 0 "$?"

# ------------------------------------------------ cut out the parts
FUNCS="$(sed -n '/^conf_get() {/,/^}/p;/^limit_nofile() {/,/^}/p;/^after_claude() {/,/^}/p' "$SCRIPT")"
export FUNCS
for fn in conf_get limit_nofile after_claude; do
    case "$FUNCS" in
        *"$fn() {"*) ;;
        *) echo "ABBRUCH: $fn() nicht in $SCRIPT gefunden." >&2; exit 1 ;;
    esac
done

LAUNCH="$(grep -A1 -F 'limit_nofile; exec "$claude_bin" --allow-dangerously-skip-permissions' "$SCRIPT")"
if [ "$(printf '%s\n' "$LAUNCH" | wc -l | tr -d ' ')" != 2 ]; then
    echo "ABBRUCH: Claude-Start (2 Zeilen) nicht in $SCRIPT gefunden." >&2; exit 1
fi

# ------------------------------------------------ static checks
check "Auf den Claude-Start folgt direkt: after_claude \"\$?\"" 'after_claude "$?"' "$(printf '%s\n' "$LAUNCH" | sed -n 2p)"
check "Letzte Skriptzeile ist after_claude \"\$?\" (kein unbedingtes exec bash -l)" 'after_claude "$?"' \
    "$(grep -v '^[[:space:]]*$' "$SCRIPT" | tail -n 1)"
check "Kein exec bash -l auf oberster Ebene"            0 "$(grep -c '^exec bash -l' "$SCRIPT")"
check "claude nicht gefunden: Shell bleibt (Nachinstallieren)" 1 \
    "$(sed -n '/^if \[ -z "\$claude_bin" \]/,/^fi/p' "$SCRIPT" | grep -c 'exec bash -l')"

# ------------------------------------------------ run with stubs
mkdir -p "$T/stubs"
cat > "$T/stubs/bash" <<'EOF'
#!/bin/bash
# stands in for the guest shell: records its arguments, ends with 42
printf '%s\n' "$*" >> "$MARKER"
exit 42
EOF
cat > "$T/claude-stub" <<'EOF'
#!/bin/bash
exit "${STUB_CODE:-0}"
EOF
chmod +x "$T/stubs/bash" "$T/claude-stub"
printf 'NOFILE_LIMIT=0\n' > "$T/test.conf"

run_launch() {   # run_launch <exit code of the stub claude>  ->  OUT, RC
    : > "$T/marker"
    OUT="$(STUB_CODE="$1" MARKER="$T/marker" PATH="$T/stubs:$PATH" "$REAL_BASH" -c \
        'CONF="$1"; claude_bin="$2"; extra=(); eval "$FUNCS"; '"$LAUNCH"'; echo NACHHER' \
        _ "$T/test.conf" "$T/claude-stub" 2>&1)"
    RC=$?
}

count() { printf '%s\n' "$1" | grep -c -- "$2"; }

for code in 0 130; do
    run_launch "$code"
    check "Claude endet mit $code: Skript endet mit 0"           0 "$RC"
    check "Claude endet mit $code: keine Shell gestartet"        0 "$(wc -l < "$T/marker" | tr -d ' ')"
    check "Claude endet mit $code: nichts läuft danach weiter"   0 "$(count "$OUT" NACHHER)"
    check "Claude endet mit $code: keine Fehlermeldung"          0 "$(count "$OUT" 'wurde mit Code')"
done

for code in 1 2 137; do
    run_launch "$code"
    check "Claude endet mit $code: Shell wird gestartet (bash -l)" "-l" "$(head -n 1 "$T/marker")"
    check "Claude endet mit $code: Code steht in der Meldung"      1 "$(count "$OUT" "wurde mit Code $code beendet")"
    check "Claude endet mit $code: Meldung nennt 'claude' zum Neustart" 1 "$(count "$OUT" 'Neu starten mit: claude')"
    check "Claude endet mit $code: Shell ersetzt das Skript (exec)" 42 "$RC"
    check "Claude endet mit $code: nichts läuft nach der Shell"    0 "$(count "$OUT" NACHHER)"
done

echo
echo "Ergebnis: $PASS bestanden, $FAIL fehlgeschlagen"
[ "$FAIL" -eq 0 ]
