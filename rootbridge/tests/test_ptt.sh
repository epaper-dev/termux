#!/usr/bin/env bash
# Test: `ptt start|stop|toggle|status` (push to talk through a tmux key).
#   - settings from the rootbridge config (read as data, bad values ignored): PTT_TARGET, PTT_KEY, PTT_MODE,
#     PTT_INTERVAL, PTT_MAX
#   - hold mode: `start` presses the key and repeats it until `stop`, a second `start` does not start a second
#     repeater, the repeater ends by itself after PTT_MAX, no window means nothing happens
#   - tap mode: one press for `start`, one for `stop`, no press without a matching `start`, a stale mark is ignored
#   - install.sh puts `ptt` into $PREFIX/bin (made by test_widgets.sh), uninstall.sh removes it
# Nothing real is touched: `tmux` is a logging stub (PTT_TMUX), state and config live in a temp dir.
#   bash tests/test_ptt.sh
# shellcheck disable=SC1090  # the library is sourced from a variable on purpose
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PTT="$ROOT/termux/bin/ptt"
LIB="$ROOT/termux/lib/rootbridge-lib.sh"

T="$(mktemp -d)"
trap 'rm -rf "$T"; pkill -f "$T" 2>/dev/null; true' EXIT

PASS=0; FAIL=0
check() {   # check <name> <expected> <actual>
    if [ "$2" = "$3" ]; then PASS=$((PASS + 1)); printf 'ok    %s\n' "$1"
    else FAIL=$((FAIL + 1)); printf 'FAIL  %s\n      erwartet: %s\n      erhalten: %s\n' "$1" "$2" "$3"; fi
}

LOG="$T/tmux.log"
cat > "$T/tmux" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$PTT_TEST_LOG"
[ "${PTT_TEST_NOWINDOW:-0}" = 1 ] && exit 1
exit 0
EOF
chmod +x "$T/tmux"
export PTT_TEST_LOG="$LOG"

CONF="$T/config"
export ROOTBRIDGE_CONFIG="$CONF"
export ROOTBRIDGE_LIB="$LIB"
export PTT_TMUX="$T/tmux"
export PTT_STATE_DIR="$T/state"

reset() { rm -rf "$T/state" "$LOG"; : > "$LOG"; unset PTT_TEST_NOWINDOW; }
presses() { grep -c '^send-keys' "$LOG"; }
runptt() { bash "$PTT" "$@"; }

# ------------------------------------------------------------------ usage, bad input
reset; printf '' > "$CONF"
check "ohne Argument: Hilfe, Exit 0"                      0 "$(runptt >/dev/null 2>&1; echo $?)"
check "Hilfe nennt start und stop"                        2 "$(runptt help | grep -c -E '^  ptt (start|stop) ')"
check "unbekannter Befehl: Exit 2"                        2 "$(runptt nope >/dev/null 2>&1; echo $?)"

# ------------------------------------------------------------------ hold mode
reset; printf 'PTT_INTERVAL=20\n' > "$CONF"
runptt start
check "hold: start drueckt sofort die Taste (Standard)"   "send-keys -t ubuntu:claude M-k" "$(head -n 1 "$LOG")"
check "hold: status nach start"                           talking "$(runptt status)"
sleep 0.5
n1="$(presses)"
check "hold: die Taste wird wiederholt"                   ja "$([ "$n1" -ge 4 ] && echo ja || echo nein)"
tok="$(cat "$T/state/hold.pid")"
runptt start
check "hold: zweiter start startet keinen zweiten Wiederholer" "$tok" "$(cat "$T/state/hold.pid")"
runptt stop
check "hold: status nach stop"                            idle "$(runptt status)"
sleep 0.3
n2="$(presses)"
sleep 0.4
check "hold: nach stop keine Wiederholung mehr"           "$n2" "$(presses)"
check "hold: stop ohne start ist harmlos, Exit 0"         0 "$(runptt stop; echo $?)"
check "hold: stop sendet selbst keine Taste"              "$n2" "$(presses)"

# start again after stop works
runptt start; sleep 0.2
check "hold: erneuter start nach stop"                    talking "$(runptt status)"
runptt stop; sleep 0.2

# toggle
reset
runptt toggle
check "toggle: erster Aufruf startet"                     talking "$(runptt status)"
runptt toggle
check "toggle: zweiter Aufruf stoppt"                     idle "$(runptt status)"
sleep 0.2

# the repeater ends by itself (PTT_MAX), the status goes with it
reset; printf 'PTT_INTERVAL=20\nPTT_MAX=1\n' > "$CONF"
runptt start
sleep 3.2
check "hold: PTT_MAX beendet den Wiederholer, status idle" idle "$(runptt status)"
n3="$(presses)"; sleep 0.4
check "hold: danach keine Wiederholung"                   "$n3" "$(presses)"
check "hold: PTT_MAX 1 s ergibt nur wenige Tasten"        ja "$([ "$n3" -le 150 ] && echo ja || echo nein)"

# a stale file (repeater killed) is not "talking" forever
reset; mkdir -p "$T/state"; echo old > "$T/state/hold.pid"; touch -d '10 minutes ago' "$T/state/hold.pid"
printf 'PTT_MAX=5\n' > "$CONF"
check "hold: veraltete Datei zaehlt nicht als talking"    idle "$(runptt status)"

# no window: nothing happens, exit 0
reset; printf '' > "$CONF"
check "hold: ohne Fenster Exit 0"                         0 "$(PTT_TEST_NOWINDOW=1 runptt start; echo $?)"
check "hold: ohne Fenster kein Zustand"                   idle "$(runptt status)"

# ------------------------------------------------------------------ settings
reset; printf 'PTT_TARGET=work:codex\nPTT_KEY=C-g\nPTT_INTERVAL=20\n' > "$CONF"
runptt start; runptt stop
check "Konfig: Ziel und Taste"                            "send-keys -t work:codex C-g" "$(head -n 1 "$LOG")"
reset; printf 'SESSION=mine\n' > "$CONF"
runptt start; runptt stop
check "Standardziel folgt SESSION"                        "send-keys -t mine:claude M-k" "$(head -n 1 "$LOG")"
reset; printf 'PTT_TARGET=a;rm -rf /\nPTT_KEY=M k\nPTT_MODE=loud\nPTT_INTERVAL=5\nPTT_MAX=0\n' > "$CONF"
runptt start; runptt stop
check "Konfig: ungueltige Werte werden ignoriert"         "send-keys -t ubuntu:claude M-k" "$(head -n 1 "$LOG")"
check "Konfig: ungueltiger Modus bleibt hold"             hold "$(. "$LIB"; ROOTBRIDGE_CONFIG="$CONF" rb_load_config; echo "$PTT_MODE")"
check "Konfig: PTT_INTERVAL unter 20 ms wird ignoriert"   50 "$(. "$LIB"; RB_CONFIG="$CONF" rb_load_config; echo "$PTT_INTERVAL")"
check "Konfig: PTT_MAX 0 wird ignoriert"                  120 "$(. "$LIB"; RB_CONFIG="$CONF" rb_load_config; echo "$PTT_MAX")"

# ------------------------------------------------------------------ tap mode
reset; printf 'PTT_MODE=tap\n' > "$CONF"
runptt start
check "tap: start drueckt einmal"                         1 "$(presses)"
check "tap: status nach start"                            talking "$(runptt status)"
runptt start
check "tap: zweiter start drueckt nicht noch einmal"      1 "$(presses)"
runptt stop
check "tap: stop drueckt einmal"                          2 "$(presses)"
check "tap: status nach stop"                             idle "$(runptt status)"
runptt stop
check "tap: stop ohne start drueckt nichts"               2 "$(presses)"
runptt toggle; runptt toggle
check "tap: toggle zweimal = start und stop"              4 "$(presses)"

# a mark older than PTT_MAX (the program ended the recording itself long ago) is ignored
reset; printf 'PTT_MODE=tap\nPTT_MAX=5\n' > "$CONF"
mkdir -p "$T/state"; : > "$T/state/tap.flag"; touch -d '10 minutes ago' "$T/state/tap.flag"
runptt stop
check "tap: veraltete Markierung, stop drueckt nichts"    0 "$(presses)"
check "tap: veraltete Markierung wird entfernt"           nein "$([ -e "$T/state/tap.flag" ] && echo ja || echo nein)"

# ------------------------------------------------------------------ install
check "ptt ist ausfuehrbar"                               ja "$([ -x "$PTT" ] && echo ja || echo nein)"
check "ptt hat den Termux-Shebang-Platz (env bash)"       "#!/usr/bin/env bash" "$(head -n 1 "$PTT")"
check "install.sh installiert ptt"                        1 "$(grep -c 'inst "\$REPO/termux/bin/ptt"' "$ROOT/install.sh")"
check "uninstall.sh entfernt ptt"                         1 "$(grep -c 'PREFIX/bin/ptt' "$ROOT/uninstall.sh")"

printf '\nErgebnis: %d bestanden, %d fehlgeschlagen\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
