#!/usr/bin/env bash
# Test: `ptt start|stop|toggle|status` (push to talk through a tmux key).
#   - settings from the rootbridge config (read as data, bad values ignored): PTT_TARGET, PTT_KEY, PTT_MODE,
#     PTT_INTERVAL, PTT_WARMUP, PTT_MAX
#   - hold mode: `start` presses the key and repeats it (after PTT_WARMUP) until `stop`, a second `start` does not
#     start a second repeater, the repeater ends by itself after PTT_MAX, no window means nothing happens; it stops
#     when the recorder of Claude Code (`rec ... --buffer 1024 -t raw`) that started after it ends, or none starts
#   - tap mode: one press for `start`, one for `stop`, no press without a matching `start`, a stale mark is ignored;
#     `toggle` presses once every time (the program knows whether it records)
#   - auto mode (default): the mode of Claude Code's /voice, read from its settings; an explicit hold or tap wins
#   - install.sh puts `ptt` into $PREFIX/bin (made by test_widgets.sh), uninstall.sh removes it
# Nothing real is touched: `tmux` is a logging stub (PTT_TMUX), state and config live in a temp dir.
#   bash tests/test_ptt.sh
# shellcheck disable=SC1090  # the library is sourced from a variable on purpose
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib.sh
. "$ROOT/tests/lib.sh"
PTT="$ROOT/termux/bin/ptt"
LIB="$ROOT/termux/lib/rootbridge-lib.sh"

T="$(mktemp -d)"
trap 'rm -rf "$T"; pkill -f "$T" 2>/dev/null; true' EXIT


LOG="$T/tmux.log"
cat > "$T/tmux" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$PTT_TEST_LOG"
[ "${PTT_TEST_NOWINDOW:-0}" = 1 ] && exit 1
[ "$1" = display-message ] && [ "${*: -1}" = '#{pane_pid}' ] && echo "${PTT_TEST_PANE:-}"
exit 0
EOF
chmod +x "$T/tmux"
export PTT_TEST_LOG="$LOG"

CONF="$T/config"
export ROOTBRIDGE_CONFIG="$CONF"
export ROOTBRIDGE_LIB="$LIB"
export PTT_TMUX="$T/tmux"
export PTT_STATE_DIR="$T/state"
export PTT_CLAUDE_SETTINGS="$T/claude-settings.json"      # never the real settings of the guest
export PTT_PROC="$T/proc"                                  # only the fake recorders below: ptt start ends recorders it finds
mkdir -p "$PTT_PROC"

reset() { rm -rf "$T/state" "$LOG"; : > "$LOG"; unset PTT_TEST_NOWINDOW; }
presses() { grep -c '^send-keys' "$LOG"; }
runptt() { bash "$PTT" "$@"; }

# ------------------------------------------------------------------ usage, bad input
reset; printf '' > "$CONF"
check "ohne Argument: Hilfe, Exit 0"                      0 "$(runptt >/dev/null 2>&1; echo $?)"
check "Hilfe nennt start und stop"                        2 "$(runptt help | grep -c -E '^  ptt (start|stop) ')"
check "unbekannter Befehl: Exit 2"                        2 "$(runptt nope >/dev/null 2>&1; echo $?)"

# ------------------------------------------------------------------ hold mode
reset; printf 'PTT_INTERVAL=20\nPTT_WARMUP=0\n' > "$CONF"
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
reset; printf 'PTT_INTERVAL=20\nPTT_WARMUP=0\nPTT_MAX=1\n' > "$CONF"
runptt start
sleep 3.2
check "hold: PTT_MAX beendet den Wiederholer, status idle" idle "$(runptt status)"
n3="$(presses)"; sleep 0.4
check "hold: danach keine Wiederholung"                   "$n3" "$(presses)"
check "hold: PTT_MAX 1 s ergibt nur wenige Tasten"        ja "$([ "$n3" -le 60 ] && echo ja || echo nein)"

# a stale file (repeater killed) is not "talking" forever
reset; mkdir -p "$T/state"; echo old > "$T/state/hold.pid"; touch -d '10 minutes ago' "$T/state/hold.pid"
printf 'PTT_MAX=5\n' > "$CONF"
check "hold: veraltete Datei zaehlt nicht als talking"    idle "$(runptt status)"

# no window: nothing happens, exit 0
reset; printf '' > "$CONF"
check "hold: ohne Fenster Exit 0"                         0 "$(PTT_TEST_NOWINDOW=1 runptt start; echo $?)"
check "hold: ohne Fenster kein Zustand"                   idle "$(runptt status)"

# warmup: the repeats begin PTT_WARMUP ms after the first key (Claude Code arms its release timer with the second key,
# after its recorder has started)
reset; printf 'PTT_INTERVAL=20\nPTT_WARMUP=600\n' > "$CONF"
runptt start; sleep 0.35
check "warmup: in der Pause nur die erste Taste"          1 "$(presses)"
sleep 1.5
check "warmup: danach wird die Taste wiederholt"          ja "$([ "$(presses)" -ge 4 ] && echo ja || echo nein)"
runptt stop; sleep 0.2
reset; printf 'PTT_INTERVAL=20\nPTT_WARMUP=400\n' > "$CONF"
runptt start; sleep 0.1; runptt stop; sleep 0.8
check "warmup: stop in der Pause, danach keine Wiederholung" 1 "$(presses)"

# the recorder of Claude Code: the repeater keeps going while the recorder that started after it runs, stops when that
# recorder ends, and stops when none comes (an older recorder does not count)
fake_rec() { bash -c 'exec -a rec python3 -c "import time; time.sleep(30)" --buffer 1024 -t raw' & FAKE=$!; ln -s "/proc/$FAKE" "$PTT_PROC/$FAKE"; }
reset; printf 'PTT_INTERVAL=20\nPTT_WARMUP=0\n' > "$CONF"
runptt start; sleep 0.2; fake_rec; sleep 0.6
check "rec: mit Recorder wird wiederholt"                talking "$(runptt status)"
kill "$FAKE"; wait "$FAKE" 2>/dev/null; sleep 0.4
check "rec: Recorder beendet, Wiederholer stoppt"        idle "$(runptt status)"
n4="$(presses)"; sleep 0.4
check "rec: danach keine Taste mehr"                      "$n4" "$(presses)"
# a recorder left in the target window (below its pane process: here the test shell) is ended at start; one elsewhere stays
ln -s "/proc/$$" "$PTT_PROC/$$"
reset; fake_rec; sleep 0.3; PTT_TEST_PANE=999999 runptt start; sleep 0.3
check "rec: Recorder in einem anderen Fenster bleibt"     laeuft "$(kill -0 "$FAKE" 2>/dev/null && echo laeuft || echo weg)"
runptt stop; sleep 0.2; kill "$FAKE"; wait "$FAKE" 2>/dev/null
reset; fake_rec; sleep 0.3; PTT_TEST_NOWINDOW=1 PTT_TEST_PANE=$$ runptt start; sleep 0.3
check "rec: ohne Zielfenster wird nichts beendet"         laeuft "$(kill -0 "$FAKE" 2>/dev/null && echo laeuft || echo weg)"
kill "$FAKE"; wait "$FAKE" 2>/dev/null
reset; fake_rec; mkdir -p "$T/state"; : > "$T/state/hold.end"; PTT_TEST_PANE=$$ runptt start; sleep 0.3
check "rec: gleich nach stop (Claude beendet noch) bleibt er" laeuft "$(kill -0 "$FAKE" 2>/dev/null && echo laeuft || echo weg)"
runptt stop; sleep 0.2; kill "$FAKE"; wait "$FAKE" 2>/dev/null
reset; fake_rec; sleep 0.3; PTT_TEST_PANE=$$ runptt start; sleep 0.8
check "rec: liegengebliebener Recorder wird beim Start beendet" weg "$(kill -0 "$FAKE" 2>/dev/null && echo laeuft || echo weg)"
wait "$FAKE" 2>/dev/null
check "rec: danach wird auf den neuen gewartet"           talking "$(runptt status)"
sleep 4.5
check "rec: kein neuer Recorder, Wiederholer stoppt"      idle "$(runptt status)"
# stop: a recorder left behind by the stop is ended 3.5 s later, unless a new start came
reset; printf 'PTT_INTERVAL=20\nPTT_WARMUP=0\n' > "$CONF"
PTT_TEST_PANE=$$ runptt start; sleep 0.2; fake_rec; sleep 0.3; PTT_TEST_PANE=$$ runptt stop; sleep 1
check "stop: Recorder läuft zunächst weiter (Claude beendet noch)" laeuft "$(kill -0 "$FAKE" 2>/dev/null && echo laeuft || echo weg)"
sleep 3.5
check "stop: liegengebliebener Recorder nach 3,5 s beendet" weg "$(kill -0 "$FAKE" 2>/dev/null && echo laeuft || echo weg)"
wait "$FAKE" 2>/dev/null
reset; PTT_TEST_PANE=$$ runptt start; sleep 0.2; fake_rec; sleep 0.3; PTT_TEST_PANE=$$ runptt stop; sleep 1
PTT_TEST_PANE=$$ runptt start; sleep 3.5
check "stop: neuer Start dazwischen, Recorder bleibt"     laeuft "$(kill -0 "$FAKE" 2>/dev/null && echo laeuft || echo weg)"
runptt stop; kill "$FAKE"; wait "$FAKE" 2>/dev/null; sleep 4
reset; PTT_TEST_PANE=$$ runptt start; sleep 0.3; PTT_TEST_PANE=$$ runptt stop; sleep 0.3; fake_rec; sleep 4
check "stop: von Hand gestartete Aufnahme danach bleibt"   laeuft "$(kill -0 "$FAKE" 2>/dev/null && echo laeuft || echo weg)"
kill "$FAKE"; wait "$FAKE" 2>/dev/null
reset; fake_rec; sleep 0.3; PTT_TEST_PANE=$$ runptt stop; sleep 4
check "stop ohne Sitzung: laufende Aufnahme bleibt"       laeuft "$(kill -0 "$FAKE" 2>/dev/null && echo laeuft || echo weg)"
check "stop ohne Sitzung: kein hold.end, kein hold.recs"  "nein nein" "$([ -e "$T/state/hold.end" ] && echo ja || echo nein) $([ -e "$T/state/hold.recs" ] && echo ja || echo nein)"
kill "$FAKE"; wait "$FAKE" 2>/dev/null
reset; printf 'PTT_MODE=tap\n' > "$CONF"; fake_rec; sleep 0.3; PTT_TEST_PANE=$$ runptt start; sleep 0.3
check "rec: im Modus tap bleibt ein laufender Recorder"   laeuft "$(kill -0 "$FAKE" 2>/dev/null && echo laeuft || echo weg)"
runptt stop; kill "$FAKE"; wait "$FAKE" 2>/dev/null

# ------------------------------------------------------------------ settings
reset; printf 'PTT_TARGET=work:codex\nPTT_KEY=C-g\nPTT_INTERVAL=20\n' > "$CONF"
runptt start; runptt stop
check "Konfig: Ziel und Taste"                            "send-keys -t work:codex C-g" "$(head -n 1 "$LOG")"
reset; printf 'SESSION=mine\n' > "$CONF"
runptt start; runptt stop
check "Standardziel folgt SESSION"                        "send-keys -t mine:claude M-k" "$(head -n 1 "$LOG")"
reset; printf 'PTT_TARGET=a;rm -rf /\nPTT_KEY=M k\nPTT_MODE=loud\nPTT_INTERVAL=5\nPTT_WARMUP=3000\nPTT_MAX=0\n' > "$CONF"
runptt start; runptt stop
check "Konfig: ungueltige Werte werden ignoriert"         "send-keys -t ubuntu:claude M-k" "$(head -n 1 "$LOG")"
check "Konfig: ungueltiger Modus bleibt auto"             auto "$(. "$LIB"; ROOTBRIDGE_CONFIG="$CONF" rb_load_config; echo "$PTT_MODE")"
check "Konfig: PTT_INTERVAL unter 20 ms wird ignoriert"   50 "$(. "$LIB"; RB_CONFIG="$CONF" rb_load_config; echo "$PTT_INTERVAL")"
check "Konfig: PTT_WARMUP ueber 1500 ms wird ignoriert" 1200 "$(. "$LIB"; RB_CONFIG="$CONF" rb_load_config; echo "$PTT_WARMUP")"
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

# toggle in tap mode presses every time: Claude Code knows whether it records, a mark of ours may be wrong
reset; printf 'PTT_MODE=tap\n' > "$CONF"
mkdir -p "$T/state"; : > "$T/state/tap.flag"; touch -d '10 minutes ago' "$T/state/tap.flag"
runptt toggle; runptt toggle; runptt toggle
check "tap: toggle drueckt jedes Mal, auch bei veralteter Markierung" 3 "$(presses)"

# ------------------------------------------------------------------ auto mode: the mode of Claude Code
modeis() { reset; printf '%s\n' "${2:-}" > "$CONF"; printf '%s' "$1" > "$PTT_CLAUDE_SETTINGS"; }
modeis '{"voice":{"enabled":true,"mode":"tap"}}'
runptt toggle; runptt toggle
check "auto: Claude Code im Modus tap, toggle drueckt je einmal"        2 "$(presses)"
check "auto: tap, kein Wiederholer"                                      idle "$(runptt status)"
modeis '{"voice":{"enabled":true,"mode":"hold"}}' 'PTT_INTERVAL=20
PTT_WARMUP=0'
runptt toggle; sleep 0.4
check "auto: Claude Code im Modus hold, toggle startet den Wiederholer" talking "$(runptt status)"
check "auto: hold, die Taste wird wiederholt"                            ja "$([ "$(presses)" -ge 4 ] && echo ja || echo nein)"
runptt toggle; sleep 0.2
check "auto: hold, zweites toggle stoppt"                                idle "$(runptt status)"
modeis '{"voice":{"enabled":true}}' 'PTT_INTERVAL=20'
runptt start; sleep 0.3
check "auto: ohne mode in den Einstellungen gilt hold"                   talking "$(runptt status)"
runptt stop; sleep 0.2
modeis 'kein json' 'PTT_INTERVAL=20'
runptt start; sleep 0.3
check "auto: kaputte Einstellungen, es gilt hold"                        talking "$(runptt status)"
runptt stop; sleep 0.2
reset; printf 'PTT_INTERVAL=20\n' > "$CONF"; rm -f "$PTT_CLAUDE_SETTINGS"
runptt start; sleep 0.3
check "auto: ohne Einstellungsdatei gilt hold"                           talking "$(runptt status)"
runptt stop; sleep 0.2
modeis '{"voice":{"mode":"tap"}}' 'PTT_MODE=hold
PTT_INTERVAL=20'
runptt start; sleep 0.3
check "ausdruecklich hold gewinnt gegen Claudes tap"                     talking "$(runptt status)"
runptt stop; sleep 0.2
modeis '{"voice":{"mode":"hold"}}' 'PTT_MODE=tap'
runptt start; runptt stop
check "ausdruecklich tap gewinnt gegen Claudes hold (je ein Druck)"      2 "$(presses)"
check "PTT_MODE=auto steht in der Konfig"                                auto "$(printf 'PTT_MODE=auto\n' > "$CONF"; . "$LIB"; ROOTBRIDGE_CONFIG="$CONF" rb_load_config; echo "$PTT_MODE")"
rm -f "$PTT_CLAUDE_SETTINGS"

# ------------------------------------------------------------------ reading aloud ends before the microphone starts
# the player of the guest (speak.py --run) is stood in for by a process group leader with that command line; its pid in speak.pid
export BRIDGE_DIR="$T/bridge"; mkdir -p "$BRIDGE_DIR"
player() {
    setsid bash -c 'exec -a "python3 -I /usr/local/lib/termux-rootbridge/speak.py --run" sleep 30' < /dev/null > /dev/null 2>&1 &
    echo $! > "$BRIDGE_DIR/speak.pid"; sleep 0.3
}
alive() { kill -0 "$(cat "$BRIDGE_DIR/speak.pid")" 2>/dev/null && echo laeuft || echo beendet; }
reset; printf 'PTT_INTERVAL=20\nPTT_WARMUP=0\nPTT_MODE=hold\n' > "$CONF"; player
runptt start; sleep 0.3
check "hold: start beendet das Vorlesen"                  beendet "$(alive)"
runptt stop; sleep 0.2
reset; printf 'PTT_MODE=tap\n' > "$CONF"; player
runptt toggle
check "tap: toggle (Home-Langdruck) beendet das Vorlesen" beendet "$(alive)"
reset; printf 'PTT_MODE=tap\n' > "$CONF"; player
PTT_TEST_NOWINDOW=1 runptt start
check "start ohne Fenster beendet das Vorlesen trotzdem"  beendet "$(alive)"
unset BRIDGE_DIR

# ------------------------------------------------------------------ install
check "ptt ist ausfuehrbar"                               ja "$([ -x "$PTT" ] && echo ja || echo nein)"
check "ptt hat den Termux-Shebang-Platz (env bash)"       "#!/usr/bin/env bash" "$(head -n 1 "$PTT")"
check "install.sh installiert ptt"                        1 "$(grep -c 'inst "\$REPO/termux/bin/ptt"' "$ROOT/install.sh")"
check "uninstall.sh entfernt ptt"                         1 "$(grep -c 'PREFIX/bin/ptt' "$ROOT/uninstall.sh")"

finish
