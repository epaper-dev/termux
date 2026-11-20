#!/usr/bin/env bash
# Test: voice dictation for Claude Code (/voice) and the side key as push to talk.
#   - rootbridge-lib.sh: VOICE (default on) and SIDEKEY (default off), only on|off
#   - `rootbridge voice start|stop|status|grant`: PulseAudio, the microphone source, Android's permission (su is a stub)
#   - `rootbridge attach|start` start PulseAudio (VOICE=on) and the side key reader (SIDEKEY=on)
#   - install.sh: --voice / --no-voice / --sidekey / --no-sidekey, the stored choice, ~/.config/pulse/default.pa (ours, a user's own
#     file stays, updates keep a backup), sidekey-ptt with the Termux python shebang, pkg install pulseaudio, the microphone
#     permission only on a terminal, --voice handed to the guest
#   - install-guest.sh: keybindings.json (meta+k = voice:pushToTalk) and "voice" in settings.json, never over a choice of the user
#   - setup-guest.sh: sox only with Claude Code and voice; uninstall.sh removes sidekey-ptt and our default.pa only
# Nothing real is touched: pulseaudio, pactl, su, pkg, tmux and proot-distro are stubs, HOME/PREFIX/guest root are temp dirs.
#   bash tests/test_voice.sh
# shellcheck disable=SC1090  # the library is sourced from a variable on purpose
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib.sh
. "$ROOT/tests/lib.sh"
LIB="$ROOT/termux/lib/rootbridge-lib.sh"
RBSRC="$ROOT/termux/bin/rootbridge"
INSTALL="$ROOT/install.sh"
UNINSTALL="$ROOT/uninstall.sh"
GUEST="$ROOT/guest/install-guest.sh"
SETUP="$ROOT/guest/setup-guest.sh"

T="$(mktemp -d)"
# the stand-in PulseAudio servers (sleep processes of this test) end with it
trap 'kill "$(cat "$T/bridge/.lock/pid" 2>/dev/null)" $(cat "$T/state/pa.servers" 2>/dev/null) 2>/dev/null; rm -rf "$T"' EXIT

has() { [ -e "$1" ] && echo ja || echo nein; }
baks() { compgen -G "$1" | wc -l | tr -d ' '; }   # how many files match the glob
count() { grep -c -- "$2" "$1" 2>/dev/null || true; }

# =========================================================================== 1. the library
CONF="$T/lib.conf"
libget() { ( ROOTBRIDGE_CONFIG="$CONF" . "$LIB"; rb_load_config; eval "printf '%s' \"\$$1\"" ); }
: > "$CONF"
check "Lib: VOICE ist standardmäßig on"                    on "$(libget VOICE)"
check "Lib: SIDEKEY ist standardmäßig off"                 off "$(libget SIDEKEY)"
printf 'VOICE=off\nSIDEKEY=on\n' > "$CONF"
check "Lib: VOICE=off wird gelesen"                        off "$(libget VOICE)"
check "Lib: SIDEKEY=on wird gelesen"                       on "$(libget SIDEKEY)"
printf 'VOICE=maybe\nSIDEKEY=1\n' > "$CONF"
check "Lib: ungültiger Wert für VOICE wird ignoriert"      on "$(libget VOICE)"
check "Lib: ungültiger Wert für SIDEKEY wird ignoriert"    off "$(libget SIDEKEY)"

# =========================================================================== 2. rootbridge voice
mkdir -p "$T/bin" "$T/lib/termux-rootbridge" "$T/stubs" "$T/vstubs" "$T/home/.config/termux-rootbridge" "$T/prefix/bin"
sed "1s|^#!.*|#!$(command -v bash)|" "$RBSRC" > "$T/bin/rootbridge"
cp "$LIB" "$T/lib/termux-rootbridge/rootbridge-lib.sh"
cat > "$T/bin/rootbridge-daemon" <<'EOF'
#!/bin/bash
echo "daemon-start" >> "$STUB_LOG"
mkdir -p "$BRIDGE_DIR/.lock"
echo $$ > "$BRIDGE_DIR/.lock/pid"
touch "$BRIDGE_DIR/.alive"
sleep 60
EOF
cat > "$T/stubs/tmux" <<'EOF'
#!/bin/bash
echo "tmux $*" >> "$STUB_LOG"
[ "$1" = has-session ] && exit "${STUB_HAS_SESSION:-1}"
exit 0
EOF
printf '#!/bin/bash\necho "proot-distro $*" >> "$STUB_LOG"\nexit 0\n' > "$T/stubs/proot-distro"
# PulseAudio as a state machine in files. Every server is a real process of this test (a sleep), its pid a line
# in $T/state/pa.servers: rootbridge ends servers by pid with kill, so they must be ours and nothing else. pa.running holds the
# pid of the server --check knows (through its pid file). pgrep -x pulseaudio lists the living ones and writes their status into
# the fake /proc (RB_PROC_DIR): TracerPid 0 (a server of Termux), or 4242 for the pids in pa.guest (a server in a proot guest).
# pa.stubborn: pids that pgrep lists although they do not exist (a server that does not end). The source exists once it was
# loaded with the permission ($T/perm).
# (not a copy of sleep named pulseaudio: a multicall coreutils binary does not run under another name)
mkdir -p "$T/proc"
cat > "$T/vstubs/pulseaudio" <<'EOF'
#!/bin/bash
echo "pulseaudio $*" >> "$STUB_LOG"
case "$1" in
    --check) [ -s "$STUB_STATE/pa.running" ] && kill -0 "$(cat "$STUB_STATE/pa.running")" 2>/dev/null ;;
    --start) "$STUB_FAKEPA" 600 > /dev/null 2>&1 &
             echo $! >> "$STUB_STATE/pa.servers"; echo $! > "$STUB_STATE/pa.running"
             [ -e "$STUB_STATE/perm" ] && touch "$STUB_STATE/source"; exit 0 ;;
    --kill) [ -s "$STUB_STATE/pa.running" ] || exit 1
            kill "$(cat "$STUB_STATE/pa.running")" 2>/dev/null; rm -f "$STUB_STATE/pa.running" "$STUB_STATE/source"; exit 0 ;;
esac
EOF
printf '#!/bin/bash\necho "pkill $*" >> "$STUB_LOG"\nexit 1\n' > "$T/vstubs/pkill"
cat > "$T/vstubs/pactl" <<'EOF'
#!/bin/bash
echo "pactl $*" >> "$STUB_LOG"
case "$1 $2" in
    "list short") [ -e "$STUB_STATE/source" ] && printf '1\tOpenSL_ES_source\tmodule-sles-source.c\ts16le 2ch 44100Hz\tIDLE\n'; exit 0 ;;
    "load-module module-sles-source") [ -e "$STUB_STATE/perm" ] || { echo "Failure: Module initialization failed" >&2; exit 1; }; touch "$STUB_STATE/source"; exit 0 ;;
esac
exit 0
EOF
cat > "$T/vstubs/su" <<'EOF'
#!/bin/bash
echo "su $*" >> "$STUB_LOG"
[ "${STUB_SU_FAIL:-0}" = 1 ] && exit 1
# no Termux:API: pm grant refuses its package
[ "${STUB_SU_NOAPI:-0}" = 1 ] && case "$*" in *com.termux.api*) exit 1 ;; esac
case "$*" in *voice_interaction_service*) printf '%s\n' "${STUB_ASSISTANT:-null}"; exit 0 ;; esac
touch "$STUB_STATE/perm"
exit 0
EOF
printf '#!/bin/bash\necho "sidekey-ptt $*" >> "$STUB_LOG"\nexit 0\n' > "$T/vstubs/sidekey-ptt"
cat > "$T/vstubs/pgrep" <<'EOF'
#!/bin/bash
[ "${STUB_PGREP_FAIL:-0}" = 1 ] && exit 2
[ "$*" = "-x pulseaudio" ] || exit 1
found=1
for pid in $(cat "$STUB_STATE/pa.servers" "$STUB_STATE/pa.stubborn" 2>/dev/null); do
    grep -qx "$pid" "$STUB_STATE/pa.stubborn" 2>/dev/null || kill -0 "$pid" 2>/dev/null || continue
    tracer=0; grep -qx "$pid" "$STUB_STATE/pa.guest" 2>/dev/null && tracer=4242
    # STUB_NOSTATUS: no status; the /proc entry exists only for a living process
    if [ "${STUB_NOSTATUS:-0}" = 1 ]; then kill -0 "$pid" 2>/dev/null && mkdir -p "$RB_PROC_DIR/$pid"; echo "$pid"; found=0; continue; fi
    mkdir -p "$RB_PROC_DIR/$pid"; printf 'Name:\tpulseaudio\nTracerPid:\t%s\n' "$tracer" > "$RB_PROC_DIR/$pid/status"
    echo "$pid"; found=0
done
exit "$found"
EOF
printf '#!/bin/bash\nexec "$@"\n' > "$T/vstubs/setsid"
chmod +x "$T/bin/rootbridge" "$T/bin/rootbridge-daemon" "$T/stubs"/* "$T/vstubs"/*
mkdir -p "$T/state"
STUB_FAKEPA="$(command -v sleep)"
export STUB_LOG="$T/stub.log" STUB_STATE="$T/state" BRIDGE_DIR="$T/bridge" STUB_FAKEPA RB_PROC_DIR="$T/proc"
RBC="$T/home/.config/termux-rootbridge/config"
rb() {   # rb [env VAR=..] <args...>: the copied rootbridge, voice stubs on the PATH; exit code in $RC
    : > "$STUB_LOG"
    env HOME="$T/home" PREFIX="$T/prefix" RB_SU="$T/vstubs/su" PATH="$T/stubs:$T/vstubs:$PATH" "$@" > "$T/out.txt" 2>&1
    RC=$?
}
reset_pa() {   # also ends the stand-in servers
    # shellcheck disable=SC2046
    kill $(cat "$T/state/pa.servers" 2>/dev/null) 2>/dev/null; rm -rf "$T/state"/* "$T/proc"/*
}
spawn_pa() { "$STUB_FAKEPA" 600 > /dev/null 2>&1 & echo $! >> "$T/state/pa.servers"; LAST_PA=$!; }   # a server --check does not know
alive() { local n=0 pid; for pid in "$@"; do kill -0 "$pid" 2>/dev/null && n=$((n + 1)); done; echo "$n"; }
calls() { grep -c -- "$1" "$STUB_LOG" || true; }
: > "$RBC"; reset_pa

# no PulseAudio installed at all: a PATH with every program of the machine except PulseAudio and the tools that end processes
# (on a machine with PulseAudio the real server must stay)
mkdir -p "$T/nopa"
IFS=: read -r -a dirs <<< "$PATH"
for d in "${dirs[@]}"; do
    for f in "$d"/*; do
        n="${f##*/}"
        case "$n" in pulseaudio|pactl|pgrep|pkill|killall) continue ;; esac
        [ -x "$f" ] && [ ! -e "$T/nopa/$n" ] && ln -s "$f" "$T/nopa/$n"
    done
done
: > "$STUB_LOG"
env HOME="$T/home" PREFIX="$T/prefix" PATH="$T/stubs:$T/nopa" bash "$T/bin/rootbridge" voice status > "$T/out.txt" 2>&1; RC=$?
check "voice status ohne PulseAudio: Hinweis, Exit 0"     "0 1" "$RC $(count "$T/out.txt" 'nicht installiert')"
env HOME="$T/home" PREFIX="$T/prefix" PATH="$T/stubs:$T/nopa" bash "$T/bin/rootbridge" voice start > "$T/out.txt" 2>&1; RC=$?
check "voice start ohne PulseAudio: kein Fehler"          0 "$RC"

# without the microphone permission: PulseAudio runs, the source is missing
rb bash "$T/bin/rootbridge" voice start
check "voice start: startet PulseAudio"                   1 "$(calls '^pulseaudio --start --exit-idle-time=-1$')"
check "voice start ohne Berechtigung: versucht die Quelle zu laden" 1 "$(calls '^pactl load-module module-sles-source$')"
check "voice start ohne Berechtigung: Status meldet FEHLT" 1 "$(count "$T/out.txt" 'Mikrofon: *FEHLT')"
check "voice start ohne Berechtigung: Exit 0"             0 "$RC"
rb bash "$T/bin/rootbridge" voice start
check "voice start bei laufendem PulseAudio: kein zweiter Start" 0 "$(calls '^pulseaudio --start')"

# grant: su -c 'pm grant ...', then the source is loaded
rb bash "$T/bin/rootbridge" voice grant
check "voice grant: su -c pm grant com.termux.api RECORD_AUDIO (dort deklariert)" 1 "$(calls "^su -c pm grant com.termux.api android.permission.RECORD_AUDIO$")"
check "voice grant: ein Treffer genügt, kein zweiter su-Aufruf" 1 "$(calls '^su ')"
check "voice grant: Exit 0 und Meldung"                   "0 1" "$RC $(count "$T/out.txt" 'Mikrofon-Berechtigung für Termux erteilt')"
check "voice grant: lädt die Quelle und setzt 200 %"      "1 1" "$(calls '^pactl load-module module-sles-source$') $(calls '^pactl set-source-volume OpenSL_ES_source 131072$')"
rb bash "$T/bin/rootbridge" voice status
check "voice status danach: PulseAudio läuft, Mikrofon ok" "1 1" "$(count "$T/out.txt" 'PulseAudio: *läuft') $(count "$T/out.txt" 'Mikrofon: *ok')"
rb bash "$T/bin/rootbridge" voice start
check "voice start mit Quelle: lädt nichts nach"          0 "$(calls '^pactl load-module')"

rb bash "$T/bin/rootbridge" voice stop
check "voice stop: pulseaudio --kill"                     1 "$(calls '^pulseaudio --kill$')"
# also a server without a pid file (--check does not know it) ends
reset_pa; spawn_pa; P1=$LAST_PA
rb bash "$T/bin/rootbridge" voice stop
check "voice stop: beendet auch Server ohne pid-Datei"     "0 0" "$RC $(alive "$P1")"
# a server that does not end: stop says so and fails; start then starts no further one
reset_pa; echo 999999999 > "$T/state/pa.stubborn"
rb bash "$T/bin/rootbridge" voice stop
check "voice stop: ein Server bleibt, Fehler mit Meldung"  "1 1" "$RC $(count "$T/out.txt" 'PulseAudio läuft noch.*999999999')"
rb bash "$T/bin/rootbridge" voice start
check "voice start: ein Server bleibt, Hinweis, Sitzung startet trotzdem (Exit 0)" "0 1" "$RC $(count "$T/out.txt" 'lassen sich nicht beenden')"
check "voice start: neben dem hartnäckigen Server startet kein weiterer" 0 "$(calls '^pulseaudio --start')"
# the status of a server cannot be read: stop does not claim success; a pid gone meanwhile (no /proc entry) is skipped
reset_pa; spawn_pa; P1=$LAST_PA
rb env STUB_NOSTATUS=1 bash "$T/bin/rootbridge" voice stop
check "voice stop: Status nicht lesbar, Fehler"            "1 1" "$RC $(alive "$P1")"
reset_pa; echo 999999999 > "$T/state/pa.stubborn"
rb env STUB_NOSTATUS=1 bash "$T/bin/rootbridge" voice stop
check "voice stop: Status nicht lesbar, aber Server schon weg: ok" 0 "$RC"
reset_pa; echo 999999999 > "$T/state/pa.stubborn"; mkdir -p "$T/proc/999999999"
rb env STUB_NOSTATUS=1 bash "$T/bin/rootbridge" voice stop
check "voice stop: Status nicht lesbar, Prozess noch da: Fehler" 1 "$RC"
# pgrep fails: stop does not claim success, start ends nothing and goes on as before
reset_pa
rb env STUB_PGREP_FAIL=1 bash "$T/bin/rootbridge" voice stop
check "voice stop: pgrep schlägt fehl, Fehler"             "1 1" "$RC $(count "$T/out.txt" 'pgrep schlug fehl')"
rb env STUB_PGREP_FAIL=1 bash "$T/bin/rootbridge" voice start
check "voice start: pgrep schlägt fehl, startet wie bisher" "0 1" "$RC $(calls '^pulseaudio --start')"

# more than one server, or one that --check does not know (its pid file is gone), keeps the microphone on: start ends them, then one
reset_pa; touch "$T/state/perm"
rb bash "$T/bin/rootbridge" voice start; P1="$(cat "$T/state/pa.running")"
spawn_pa; P2=$LAST_PA; spawn_pa; P3=$LAST_PA
rb bash "$T/bin/rootbridge" voice status
check "voice status: drei Server, Warnung"                1 "$(count "$T/out.txt" 'WARNUNG: *3 PulseAudio-Server laufen')"
rb bash "$T/bin/rootbridge" voice start
check "voice start bei drei Servern: beendet alle, startet einen" "0 1" "$(alive "$P1" "$P2" "$P3") $(calls '^pulseaudio --start')"
check "voice start bei drei Servern: danach keine Warnung" 0 "$(count "$T/out.txt" 'WARNUNG')"
reset_pa; touch "$T/state/perm"; spawn_pa; P1=$LAST_PA
rb bash "$T/bin/rootbridge" voice status
check "voice status: Server ohne pid-Datei wird gemeldet"  1 "$(count "$T/out.txt" 'läuft, aber ohne pid-Datei')"
rb bash "$T/bin/rootbridge" voice start
check "voice start bei einem Server ohne pid-Datei: neu gestartet, nicht daneben" "0 1" "$(alive "$P1") $(calls '^pulseaudio --start')"
P1="$(cat "$T/state/pa.running")"
rb bash "$T/bin/rootbridge" voice start
check "voice start bei einem erkannten Server: nichts beendet, nichts gestartet" "1 0" "$(alive "$P1") $(calls '^pulseaudio --start')"
# a PulseAudio in a proot guest (traced by proot) is not ours: it stays, and does not count
spawn_pa; PG=$LAST_PA; echo "$PG" > "$T/state/pa.guest"
rb bash "$T/bin/rootbridge" voice start
check "voice start: Server im Gast bleibt, unserer auch"   "1 1 0" "$(alive "$PG") $(alive "$P1") $(calls '^pulseaudio --start')"
rb bash "$T/bin/rootbridge" voice stop
check "voice stop: Server im Gast bleibt, unserer endet"   "0 1 0" "$RC $(alive "$PG") $(alive "$P1")"

reset_pa
rb env STUB_SU_FAIL=1 bash "$T/bin/rootbridge" voice grant
check "voice grant: su verweigert, Fehler und Hinweis"    "1 1" "$RC $(count "$T/out.txt" 'pm grant ist fehlgeschlagen')"
check "voice grant: Hinweis nennt Termux:API, beide Pakete versucht" "1 2" "$(count "$T/out.txt" 'Termux:API') $(calls '^su ')"
reset_pa
rb env STUB_SU_NOAPI=1 bash "$T/bin/rootbridge" voice grant
check "voice grant ohne Termux:API: Rückfall auf com.termux" "0 1 1" "$RC $(calls '^su -c pm grant com.termux android.permission.RECORD_AUDIO$') $(calls '^su -c pm grant com.termux.api ')"
reset_pa
rb env RB_SU="$T/gibt-es-nicht" bash "$T/bin/rootbridge" voice grant
check "voice grant ohne su: Fehler"                       1 "$RC"
# assistant: Termux push to talk as Android's digital assistant (root)
rb bash "$T/bin/rootbridge" voice assistant on
check "voice assistant on: su -c cmd role add-role-holder"  "0 1" "$RC $(calls '^su -c cmd role add-role-holder --user 0 android.app.role.ASSISTANT com.termux$')"
check "voice assistant on: Meldung"                       1 "$(count "$T/out.txt" 'jetzt der digitale Assistent')"
rb bash "$T/bin/rootbridge" voice assistant off
check "voice assistant off: su -c cmd role remove-role-holder" "0 1" "$RC $(calls '^su -c cmd role remove-role-holder --user 0 android.app.role.ASSISTANT com.termux$')"
rb env STUB_ASSISTANT=com.termux/.app.assist.PttVoiceInteractionService bash "$T/bin/rootbridge" voice assistant
check "voice assistant (status): Termux ist Assistent"    "0 1" "$RC $(count "$T/out.txt" 'Assistent: *Termux push to talk')"
check "voice assistant status: liest voice_interaction_service" 1 "$(calls '^su -c settings get secure voice_interaction_service$')"
rb env STUB_ASSISTANT= bash "$T/bin/rootbridge" voice assistant status
check "voice assistant status: keiner, mit Hinweis"       "0 1" "$RC $(count "$T/out.txt" 'Assistent: *keiner - rootbridge voice assistant on')"
rb env "STUB_ASSISTANT=com.google.android.googlequicksearchbox/com.google.android.voiceinteraction.GsaVoiceInteractionService" bash "$T/bin/rootbridge" voice assistant status
check "voice assistant status: ein anderer Assistent"     1 "$(count "$T/out.txt" 'Assistent: *com.google.android.googlequicksearchbox - rootbridge')"
rb env STUB_SU_FAIL=1 bash "$T/bin/rootbridge" voice assistant on
check "voice assistant on: su verweigert, Fehler"         "1 1" "$RC $(count "$T/out.txt" 'ließ sich nicht setzen')"
rb env RB_SU="$T/gibt-es-nicht" bash "$T/bin/rootbridge" voice assistant on
check "voice assistant ohne su: Fehler"                   1 "$RC"
rb bash "$T/bin/rootbridge" voice assistant nope
check "voice assistant: unbekannter Befehl"               "1 1" "$RC $(count "$T/out.txt" 'voice assistant: on')"
rb bash "$T/bin/rootbridge" voice nope
check "voice: unbekannter Befehl"                         "1 1" "$RC $(count "$T/out.txt" 'voice: start')"

# speak: the switch for reading aloud (the file speak-off in the bridge directory) and stopping the player of the guest
rm -rf "$BRIDGE_DIR"
# voice speak checks the player through the real /proc (RB_PROC_DIR is the fake one of the PulseAudio cases above)
rb env RB_PROC_DIR=/proc bash "$T/bin/rootbridge" voice speak
check "voice speak (status): standardmäßig an"            "0 Vorlesen: an" "$RC $(cat "$T/out.txt")"
rb env RB_PROC_DIR=/proc bash "$T/bin/rootbridge" voice speak off
check "voice speak off: Schalterdatei, Meldung"           "0 ja Vorlesen: aus" "$RC $(has "$BRIDGE_DIR/speak-off") $(cat "$T/out.txt")"
rb env RB_PROC_DIR=/proc bash "$T/bin/rootbridge" voice speak toggle
check "voice speak toggle (aus): wieder an"               "nein Vorlesen: an" "$(has "$BRIDGE_DIR/speak-off") $(cat "$T/out.txt")"
rb env RB_PROC_DIR=/proc bash "$T/bin/rootbridge" voice speak toggle
check "voice speak toggle (an): aus"                      "ja Vorlesen: aus" "$(has "$BRIDGE_DIR/speak-off") $(cat "$T/out.txt")"
rb env RB_PROC_DIR=/proc bash "$T/bin/rootbridge" voice speak status
check "voice speak status: aus"                           "Vorlesen: aus" "$(cat "$T/out.txt")"
rb bash "$T/bin/rootbridge" status
check "status zeigt den Schalter fürs Vorlesen"           1 "$(count "$T/out.txt" '^  Vorlesen: *aus$')"
rb env RB_PROC_DIR=/proc bash "$T/bin/rootbridge" voice speak on
check "voice speak on: Schalterdatei weg"                 "nein Vorlesen: an" "$(has "$BRIDGE_DIR/speak-off") $(cat "$T/out.txt")"
# the guest can write the bridge directory: a link there must not let `off` write into a file of Termux
echo wertvoll > "$T/termux-datei"; ln -s "$T/termux-datei" "$BRIDGE_DIR/speak-off"
rb env RB_PROC_DIR=/proc bash "$T/bin/rootbridge" voice speak off
check "voice speak off über einem Link: Ziel unberührt, Schalter ist eine eigene Datei" "0 wertvoll ja nein" \
    "$RC $(cat "$T/termux-datei") $([ -f "$BRIDGE_DIR/speak-off" ] && echo ja || echo nein) $([ -L "$BRIDGE_DIR/speak-off" ] && echo ja || echo nein)"
rb env RB_PROC_DIR=/proc bash "$T/bin/rootbridge" voice speak on
mkdir -p "$T/boot"; ln -s "$T/boot" "$BRIDGE_DIR/speak-off"
rb env RB_PROC_DIR=/proc bash "$T/bin/rootbridge" voice speak off
check "voice speak off über einem Link auf einen Ordner: nichts landet darin" "0 0 ja" \
    "$RC $(find "$T/boot" -mindepth 1 | wc -l | tr -d ' ') $([ -f "$BRIDGE_DIR/speak-off" ] && [ ! -L "$BRIDGE_DIR/speak-off" ] && echo ja || echo nein)"
rb env RB_PROC_DIR=/proc bash "$T/bin/rootbridge" voice speak on
# a FIFO in place of speak.pid must not hold up a stop (ptt start runs it before its key)
mkfifo "$BRIDGE_DIR/speak.pid"
s=$SECONDS; rb bash "$T/bin/rootbridge" voice speak stop
check "voice speak stop: eine FIFO als speak.pid hält nicht auf" "0 ja" "$RC $([ $((SECONDS - s)) -le 2 ] && echo ja || echo nein)"
rm -f "$BRIDGE_DIR/speak.pid"
rb env RB_PROC_DIR=/proc bash "$T/bin/rootbridge" voice speak nope
check "voice speak: unbekannter Befehl"                   "1 1" "$RC $(count "$T/out.txt" 'voice speak: on')"
# a stand-in for the player of the guest: a process group leader whose command line says "speak.py --run"
player() {   # player <argv0>: starts it, its pid in $PLAYER
    setsid bash -c 'exec -a "$1" sleep 30' _ "$1" < /dev/null > /dev/null 2>&1 &
    PLAYER=$!
    sleep 0.3
}
alive() { kill -0 "$1" 2>/dev/null && echo läuft || echo beendet; }
player "python3 -I /usr/local/lib/termux-rootbridge/speak.py --run"
echo "$PLAYER" > "$BRIDGE_DIR/speak.pid"
rb env RB_PROC_DIR=/proc bash "$T/bin/rootbridge" voice speak stop
sleep 0.3
check "voice speak stop: beendet den Abspieler, Exit 0"  "0 beendet" "$RC $(alive "$PLAYER")"
player "sleep-ohne-kennung"
echo "$PLAYER" > "$BRIDGE_DIR/speak.pid"
rb env RB_PROC_DIR=/proc bash "$T/bin/rootbridge" voice speak stop
sleep 0.3
check "voice speak stop: ein fremder Prozess in speak.pid bleibt" "0 läuft" "$RC $(alive "$PLAYER")"
kill "$PLAYER" 2>/dev/null
echo "1; rm -rf /" > "$BRIDGE_DIR/speak.pid"
rb env RB_PROC_DIR=/proc bash "$T/bin/rootbridge" voice speak stop
check "voice speak stop: Unsinn in speak.pid ist harmlos" 0 "$RC"
rm -f "$BRIDGE_DIR/speak.pid"
rb env RB_PROC_DIR=/proc bash "$T/bin/rootbridge" voice speak stop
check "voice speak stop ohne Abspieler: Exit 0"           0 "$RC"
player "python3 -I /usr/local/lib/termux-rootbridge/speak.py --run"
echo "$PLAYER" > "$BRIDGE_DIR/speak.pid"
rb env RB_PROC_DIR=/proc bash "$T/bin/rootbridge" voice speak off
sleep 0.3
check "voice speak off: beendet auch, was gerade gelesen wird" beendet "$(alive "$PLAYER")"
rb env RB_PROC_DIR=/proc bash "$T/bin/rootbridge" voice speak on

# the command line of `rootbridge help` and `status`
rb bash "$T/bin/rootbridge" help
check "help nennt voice start|stop|status|grant"          1 "$(count "$T/out.txt" 'rootbridge voice start|stop|status|grant')"
rb bash "$T/bin/rootbridge" status
check "status (VOICE on): zeigt den Abschnitt Sprache"    1 "$(count "$T/out.txt" '^Sprache (/voice):')"
printf 'VOICE=off\n' > "$RBC"
rb bash "$T/bin/rootbridge" status
check "status (VOICE off): nennt --no-voice"              1 "$(count "$T/out.txt" '--no-voice')"
: > "$RBC"

# =========================================================================== 3. start and attach start what runs next to the session
reset_pa
rb bash "$T/bin/rootbridge" attach
check "attach (VOICE on): PulseAudio gestartet"           1 "$(calls '^pulseaudio --start')"
sleep 0.3
check "attach (SIDEKEY off): kein Seitentasten-Leser"     0 "$(calls '^sidekey-ptt')"
reset_pa; printf 'SIDEKEY=on\n' > "$RBC"
rb bash "$T/bin/rootbridge" attach
sleep 0.3
check "attach (SIDEKEY on): Seitentasten-Leser gestartet" 1 "$(calls '^sidekey-ptt')"
reset_pa; printf 'VOICE=off\n' > "$RBC"
rb bash "$T/bin/rootbridge" start --no-attach
check "start (VOICE off): PulseAudio bleibt aus"          0 "$(calls '^pulseaudio --start')"
reset_pa; printf 'SIDEKEY=on\n' > "$RBC"
rb bash "$T/bin/rootbridge" start --no-attach
sleep 0.3
check "start --no-attach: PulseAudio und Seitentaste"     "1 1" "$(calls '^pulseaudio --start') $(calls '^sidekey-ptt')"
rb bash "$T/bin/rootbridge" shell
check "shell: weder PulseAudio noch Seitentaste"          "0 0" "$(calls '^pulseaudio --start') $(calls '^sidekey-ptt')"
: > "$RBC"

# =========================================================================== 4. install.sh (Termux part)
H="$T/ih"; P="$T/ip"; GROOT="$P/var/lib/proot-distro/containers/ubuntu/rootfs"
mkdir -p "$H" "$P/bin" "$P/etc/pulse" "$GROOT/var/tmp" "$T/istubs"
ln -sf "$(command -v bash)" "$P/bin/bash"
cp "$ROOT/tests/stubs/proot-distro-guest-scripts" "$T/istubs/proot-distro"
printf '#!/bin/bash\nexit 0\n' > "$T/istubs/termux-reload-settings"
printf '#!/bin/bash\necho "rootbridge $*" >> "$STUB_LOG"\nexit 1\n' > "$T/istubs/rootbridge"
# the side key reader is a file: setsid "starts" it (never the real reader, it runs su), pkill ends it (unless STUB_READER_STAYS=1),
# pgrep -f <the reader> sees it (unless STUB_READER_DIES=1: it left right after the start)
cat > "$T/istubs/pkill" <<'EOF'
#!/bin/bash
echo "pkill $*" >> "$STUB_LOG"
[ "${STUB_READER_STAYS:-0}" = 1 ] || rm -f "$STUB_LOG.reader"
exit 1
EOF
printf '#!/bin/bash\necho "setsid $*" >> "$STUB_LOG"\n[ "${STUB_READER_DIES:-0}" = 1 ] || : > "$STUB_LOG.reader"\nexit 0\n' > "$T/istubs/setsid"
printf '#!/bin/bash\ncase "$*" in *sidekey-ptt*) [ -e "$STUB_LOG.reader" ] ;; *) exit 1 ;; esac\n' > "$T/istubs/pgrep"
chmod +x "$T/istubs"/*
export STUB_GROOT="$GROOT" STUB_GUEST_ROOT="$T/iguest"
ILOG="$T/i.log"
irun() {   # irun [args...]: Termux part and guest part (staging root); HOME/PREFIX stay between runs
    rm -rf "$T/iguest"; : > "$ILOG"
    STUB_LOG="$ILOG" HOME="$H" PREFIX="$P" PATH="$T/istubs:$PATH" ROOTBRIDGE_ALLOW_GUEST=1 BRIDGE_DIR="$H/.rootbridge" \
        bash "$INSTALL" --no-boot --no-migrate --no-deps-check --no-extra-keys --no-colors --no-setup "$@" > "$T/install.log" 2>&1 < /dev/null
    IRC=$?
}
ICFG="$H/.config/termux-rootbridge/config"
iget() { sed -n "s/^$1=//p" "$ICFG" 2>/dev/null | tail -n 1; }
PA="$H/.config/pulse/default.pa"
guestargs() { grep 'install-guest.sh' "$ILOG" | tail -n 1; }

irun
check "install.sh ohne Option: läuft"                      0 "$IRC"
check "install.sh: default.pa angelegt"                    ja "$(has "$PA")"
check "install.sh: default.pa bindet Termux' eigene Datei ein (PREFIX eingesetzt)" 1 "$(count "$PA" "^\.include $P/etc/pulse/default.pa$")"
check "install.sh: default.pa: TCP nur auf 127.0.0.1 (listen)" 1 "$(count "$PA" '^load-module module-native-protocol-tcp listen=127.0.0.1$')"
check "install.sh: default.pa: kein anonymer Zugang, keine IP-Liste (beide umgehen das Cookie)" 0 "$(grep -v '^#' "$PA" | grep -c 'auth-anonymous\|auth-ip-acl')"
check "install.sh: default.pa lädt die Mikrofonquelle, 200 %" "1 1" "$(count "$PA" '^load-module module-sles-source$') $(count "$PA" '^set-source-volume OpenSL_ES_source 131072$')"
check "install.sh: default.pa: Fehler der Quelle stoppen PulseAudio nicht (.nofail)" 1 "$(count "$PA" '^\.nofail$')"
check "install.sh: kein @PREFIX@ mehr in default.pa"       0 "$(count "$PA" '@PREFIX@')"
check "install.sh: kein Seitentasten-Leser ohne --sidekey" nein "$(has "$P/bin/sidekey-ptt")"
check "install.sh: gibt --voice yes an den Gast"           1 "$(guestargs | grep -c -- '--voice yes')"
check "install.sh: Gast hat die Tastenbelegung"            1 "$(count "$T/iguest/root/.claude/keybindings.json" 'voice:pushToTalk')"
check "install.sh: nichts über VOICE/SIDEKEY gespeichert"  "" "$(iget VOICE)$(iget SIDEKEY)"
check "install.sh: nicht auf einem Terminal: Hinweis auf rootbridge voice grant" 1 "$(count "$T/install.log" 'rootbridge voice grant')"
check "install.sh: nicht auf einem Terminal: kein Root-Befehl" 0 "$(count "$ILOG" '^rootbridge voice')"
check "install.sh: Abschlussmeldung nennt /voice und ptt"  1 "$(count "$T/install.log" "^Sprache: /voice.*ptt start")"
check "install.sh: Abschlussmeldung nennt das Vorlesen"    1 "$(count "$T/install.log" "^Vorlesen: .*rootbridge voice speak")"
check "install.sh: Widgets Vorlesen und Stopp in tasks/ (Hintergrund)" "ja ja" "$(has "$H/.shortcuts/tasks/Vorlesen") $(has "$H/.shortcuts/tasks/Stopp")"
check "install.sh: Widget Vorlesen schaltet um, Stopp stoppt" "1 1" "$(count "$H/.shortcuts/tasks/Vorlesen" '^msg="$(rootbridge voice speak toggle') $(count "$H/.shortcuts/tasks/Stopp" '^exec rootbridge voice speak stop$')"
check "install.sh: Gast hat speak.py und rootbridge-speak" "ja ja" "$(has "$T/iguest/usr/local/lib/termux-rootbridge/speak.py") $(has "$T/iguest/usr/local/bin/rootbridge-speak")"
check "install.sh: Gast-Hooks Stop (vorlesen) und UserPromptSubmit (stoppen)" "1 1" "$(count "$T/iguest/etc/claude-code/managed-settings.json" 'speak.py --hook') $(count "$T/iguest/etc/claude-code/managed-settings.json" 'speak.py --stop')"
irun --no-voice
check "install.sh --no-voice: Widgets Vorlesen und Stopp entfernt" "nein nein" "$(has "$H/.shortcuts/tasks/Vorlesen") $(has "$H/.shortcuts/tasks/Stopp")"
check "install.sh --no-voice: Gast ohne Vorlesen"          "nein nein 0" "$(has "$T/iguest/usr/local/lib/termux-rootbridge/speak.py") $(has "$T/iguest/usr/local/bin/rootbridge-speak") $(count "$T/iguest/etc/claude-code/managed-settings.json" 'speak.py')"
printf '#!/bin/sh\necho mine\n' > "$H/.shortcuts/tasks/Stopp"
irun --no-voice
check "install.sh --no-voice: ein eigenes Widget Stopp bleibt" ja "$(has "$H/.shortcuts/tasks/Stopp")"
rm -f "$H/.shortcuts/tasks/Stopp"
irun --voice
check "install.sh --voice: Widgets wieder da"              "ja ja" "$(has "$H/.shortcuts/tasks/Vorlesen") $(has "$H/.shortcuts/tasks/Stopp")"
check "install.sh: keine Backup-Datei bei der ersten Installation" 0 "$(baks "$H/.config/pulse/*bak*")"

irun
check "install.sh zweimal: default.pa unverändert, kein Backup" 0 "$(baks "$H/.config/pulse/*bak*")"

# an older version of our file is replaced, with a backup; a file of the user stays
sed -i 's/131072/65536/' "$PA"
irun
check "install.sh: alte Fassung unserer default.pa wird ersetzt" 1 "$(count "$PA" '131072')"
check "install.sh: ... mit Backup"                         1 "$(baks "$H/.config/pulse/default.pa.bak*")"
rm -f "$H/.config/pulse"/default.pa.bak-*
printf '# my own pulse setup\nload-module module-null-sink\n' > "$PA"
irun
check "install.sh: eigene default.pa bleibt"               "# my own pulse setup" "$(head -n 1 "$PA")"
check "install.sh: eigene default.pa: Meldung"             1 "$(count "$T/install.log" 'deine eigene Datei')"
rm -f "$PA"

# --no-voice: stored, nothing of voice is set up, the guest hears it
irun --no-voice
check "--no-voice: läuft, VOICE=off gespeichert"           "0 off" "$IRC $(iget VOICE)"
check "--no-voice: keine default.pa"                       nein "$(has "$PA")"
check "--no-voice: gibt --voice no an den Gast"            1 "$(guestargs | grep -c -- '--voice no')"
check "--no-voice: Gast ohne Tastenbelegung"               nein "$(has "$T/iguest/root/.claude/keybindings.json")"
check "--no-voice: Meldung"                                1 "$(count "$T/install.log" 'übersprungen (--no-voice)')"
irun
check "ohne Option nach --no-voice: bleibt aus (Konfig)"   "0 nein" "$IRC $(has "$PA")"
check "ohne Option nach --no-voice: Meldung aus der Konfig" 1 "$(count "$T/install.log" 'Sprache: abgewählt')"
irun --voice
check "--voice: wieder an, VOICE=on gespeichert"           "0 on ja" "$IRC $(iget VOICE) $(has "$PA")"
irun
check "ohne Option nach --voice: bleibt an"                ja "$(has "$PA")"

# without Claude Code there is no /voice
rm -f "$PA"
irun --no-claude
check "--no-claude: keine Sprachsteuerung (keine default.pa)" "0 nein" "$IRC $(has "$PA")"
check "--no-claude: gibt --voice no an den Gast"           1 "$(guestargs | grep -c -- '--voice no')"
irun --claude

# --sidekey
irun --sidekey
check "--sidekey: läuft, SIDEKEY=on gespeichert"           "0 on" "$IRC $(iget SIDEKEY)"
check "--sidekey: sidekey-ptt installiert, ausführbar"     "ja ja" "$(has "$P/bin/sidekey-ptt") $([ -x "$P/bin/sidekey-ptt" ] && echo ja || echo nein)"
check "--sidekey: Shebang zeigt auf das Python von Termux" "#!$P/bin/python3" "$(head -n 1 "$P/bin/sidekey-ptt")"
check "--sidekey: Meldung zum Langdruck 'Nothing'"         1 "$(count "$T/install.log" "Langdruck auf 'Nothing'")"
check "--sidekey: Leser neu gestartet (alter beendet, neuer im Hintergrund)" "1 1 1" "$(count "$ILOG" "^pkill -f .*python.* $P/bin/sidekey-ptt") $(count "$ILOG" "^setsid nohup $P/bin/sidekey-ptt$") $(count "$T/install.log" 'Seitentasten-Leser gestartet')"
STUB_READER_STAYS=1 irun --sidekey
check "--sidekey: alter Leser endet nicht, kein zweiter, Meldung" "0 1" "$(count "$ILOG" '^setsid') $(count "$T/install.log" 'der alte läuft noch')"
rm -f "$ILOG.reader"
STUB_READER_DIES=1 irun --sidekey
check "--sidekey: neuer Leser endet sofort, Meldung"        "1 1" "$(count "$ILOG" '^setsid') $(count "$T/install.log" 'Start fehlgeschlagen')"
irun
check "ohne Option nach --sidekey: bleibt installiert (Konfig)" "ja" "$(has "$P/bin/sidekey-ptt")"
check "ohne Option nach --sidekey: Meldung aus der Konfig" 1 "$(count "$T/install.log" 'Seitentaste: an (aus der Konfig')"
irun --no-sidekey
check "--no-sidekey: entfernt, SIDEKEY=off gespeichert"    "nein off" "$(has "$P/bin/sidekey-ptt") $(iget SIDEKEY)"
check "--no-sidekey: beendet einen laufenden Leser, startet keinen" "1 0" "$(count "$ILOG" "^pkill -f .*python.* $P/bin/sidekey-ptt") $(count "$ILOG" "^setsid")"
irun
check "ohne Option nach --no-sidekey: bleibt aus"          nein "$(has "$P/bin/sidekey-ptt")"
irun --sidekey --no-voice
check "--sidekey --no-voice: abgelehnt (Exit 2)"           2 "$IRC"
irun --no-voice
irun --sidekey
check "--sidekey bei gespeichertem VOICE=off: kein Leser, Meldung" "nein 1" "$(has "$P/bin/sidekey-ptt") $(count "$T/install.log" 'ohne die Sprachsteuerung nicht eingerichtet')"
irun --voice --no-sidekey

# a file of the user called sidekey-ptt is not ours: --no-sidekey leaves it
printf '#!/bin/sh\necho mine\n' > "$P/bin/sidekey-ptt"
irun --no-sidekey
check "--no-sidekey: ein fremdes Programm gleichen Namens bleibt" "ja" "$(has "$P/bin/sidekey-ptt")"
rm -f "$P/bin/sidekey-ptt"

# the root step on a terminal (ROOTBRIDGE_FORCE_INTERACTIVE stands in for one): only with --setup and only when the microphone is missing
# (an installed rootbridge needs a bash at $P/bin/bash: linked above)
SP="$T/sp"; SH="$T/sh"; rm -rf "$SP" "$SH"; mkdir -p "$SP/bin" "$SP/etc/pulse" "$SH" "$T/sstubs"
ln -sf "$(command -v bash)" "$SP/bin/bash"
for c in tmux proot-distro termux-open-url; do printf '#!/bin/bash\nexit 0\n' > "$T/sstubs/$c"; done
cat > "$T/sstubs/pkg" <<'EOF'
#!/bin/bash
echo "pkg $*" >> "$STUB_LOG"
# the package is "installed" when its program is in $PREFIX/bin
case "$*" in *pulseaudio*) printf '#!/bin/sh\n' > "$PREFIX/bin/pulseaudio"; chmod +x "$PREFIX/bin/pulseaudio" ;; esac
exit 0
EOF
cp "$T/vstubs/su" "$T/sstubs/su"
# install.sh runs `rootbridge voice start`, which ends PulseAudio servers it finds: pgrep must be the stub (it lists only the
# servers of this test), or the test ends the real PulseAudio of the device it runs on
cp "$T/vstubs/pgrep" "$T/vstubs/pkill" "$T/sstubs/"
chmod +x "$T/sstubs"/*
mkdir -p "$T/sbindir"
cp "$T/vstubs/pulseaudio" "$T/vstubs/pactl" "$T/sbindir/"   # the programs the voice code finds in the PATH: never the real ones
sinst() {   # sinst [env VAR=..] [args]: install.sh with real setup, no guest; the root step runs as on a terminal
    reset_pa; : > "$ILOG"; rm -f "$SP/bin/pulseaudio"
    env HOME="$SH" PREFIX="$SP" PATH="$T/sbindir:$T/sstubs:$PATH" ROOTBRIDGE_ALLOW_GUEST=1 BRIDGE_DIR="$SH/.rootbridge" \
        STUB_LOG="$ILOG" STUB_STATE="$T/state" RB_SU="$T/sstubs/su" \
        ROOTBRIDGE_FORCE_INTERACTIVE=1 "$@" > "$T/install.log" 2>&1 < /dev/null
    IRC=$?
}
sinst bash "$INSTALL" --no-guest --no-migrate --no-extra-keys --no-colors --no-boot
check "Setup: läuft"                                       0 "$IRC"
check "Setup: pkg install -y pulseaudio"                   1 "$(count "$ILOG" '^pkg install -y .*pulseaudio$')"
check "Setup: pulseaudio ohne empfohlene Pakete"          1 "$(count "$ILOG" '^pkg install -y .*-o APT::Install-Recommends=false pulseaudio$')"
check "Setup am Terminal: Mikrofon fehlt, su -c pm grant"  1 "$(count "$ILOG" '^su -c pm grant com.termux.api android.permission.RECORD_AUDIO$')"
check "Setup am Terminal: Quelle ist danach da"            ja "$(has "$T/state/source")"
sinst bash "$INSTALL" --no-guest --no-migrate --no-extra-keys --no-colors --no-boot --no-voice
check "Setup --no-voice: kein pulseaudio-Paket, kein su"   "0 0" "$(count "$ILOG" 'pulseaudio') $(count "$ILOG" '^su ')"
# the permission is there already (the source exists after the start): no root command
reset_pa; touch "$T/state/perm"
: > "$ILOG"; rm -f "$SP/bin/pulseaudio"
env HOME="$SH" PREFIX="$SP" PATH="$T/sbindir:$T/sstubs:$PATH" ROOTBRIDGE_ALLOW_GUEST=1 BRIDGE_DIR="$SH/.rootbridge" \
    STUB_LOG="$ILOG" STUB_STATE="$T/state" RB_SU="$T/sstubs/su" \
    ROOTBRIDGE_FORCE_INTERACTIVE=1 bash "$INSTALL" --no-guest --no-migrate --no-extra-keys --no-colors --no-boot --voice > "$T/install.log" 2>&1 < /dev/null
check "Setup mit Berechtigung: kein Root-Befehl"           0 "$(count "$ILOG" '^su ')"
check "Setup mit Berechtigung: Meldung 'Mikrofon: ok'"     1 "$(count "$T/install.log" 'Mikrofon: ok')"
# --no-setup never asks for root
sinst bash "$INSTALL" --no-guest --no-migrate --no-extra-keys --no-colors --no-boot --no-setup --voice
check "--no-setup: kein Root-Befehl"                       0 "$(count "$ILOG" '^su ')"

# =========================================================================== 5. install-guest.sh
GA="$T/ga"; rm -rf "$GA"; mkdir -p "$GA"
gi() {   # gi <root> [args]: the guest installer against a staging root
    local r="$1"; shift
    bash "$GUEST" --src "$ROOT/guest" --root "$r" "$@" > "$T/guest.log" 2>&1
    GRC=$?
}
kb() { python3 -I -c "import json,sys; d=json.load(open(sys.argv[1])); print(json.dumps(d,sort_keys=True))" "$1"; }
sv() { python3 -I -c "import json,sys; print(json.dumps(json.load(open(sys.argv[1])).get('voice'),sort_keys=True))" "$1/root/.claude/settings.json"; }

gi "$GA" --claude yes --codex no
check "Gast frisch: läuft"                                 0 "$GRC"
check "Gast frisch: keybindings.json mit meta+k"           '{"$schema": "https://www.schemastore.org/claude-code-keybindings.json", "bindings": [{"bindings": {"meta+k": "voice:pushToTalk"}, "context": "Chat"}]}' "$(kb "$GA/root/.claude/keybindings.json")"
check "Gast frisch: .bashrc setzt PULSE_COOKIE (Cookie im Termux-Home)" 1 "$(count "$GA/root/.bashrc" '^\[ -r /data/data/com.termux/files/home/.config/pulse/cookie \] && export PULSE_COOKIE=')"
check "Gast frisch: voice in settings.json"                '{"enabled": true, "mode": "tap"}' "$(sv "$GA")"
MS="$GA/etc/claude-code/managed-settings.json"
hookcmd() { python3 -I -c "import json,sys; print(' '.join(h['command'] for e in json.load(open(sys.argv[1])).get('hooks',{}).get(sys.argv[2],[]) for h in e['hooks'] if 'speak.py' in h['command']))" "$1" "$2"; }
check "Gast frisch: Stop-Hook liest vor (mit Marker für die Deinstallation)" "/usr/bin/python3 -I /usr/local/lib/termux-rootbridge/speak.py --hook" "$(hookcmd "$MS" Stop)"
check "Gast frisch: UserPromptSubmit-Hook stoppt das Vorlesen" "/usr/bin/python3 -I /usr/local/lib/termux-rootbridge/speak.py --stop" "$(hookcmd "$MS" UserPromptSubmit)"
check "Gast frisch: speak.py und rootbridge-speak"         "ja ja" "$(has "$GA/usr/local/lib/termux-rootbridge/speak.py") $(has "$GA/usr/local/bin/rootbridge-speak")"
check "Gast frisch: rootbridge-speak mit dem Python des Gasts" 1 "$(count "$GA/usr/local/bin/rootbridge-speak" '^exec /usr/bin/python3 -I .*/usr/local/lib/termux-rootbridge/speak.py')"
KBSUM="$(cksum < "$GA/root/.claude/keybindings.json")"; SSUM="$(cksum < "$GA/root/.claude/settings.json")"
gi "$GA" --claude yes --codex no
check "Gast zweimal: keybindings.json unverändert"         "$KBSUM" "$(cksum < "$GA/root/.claude/keybindings.json")"
check "Gast zweimal: settings.json unverändert"            "$SSUM" "$(cksum < "$GA/root/.claude/settings.json")"
check "Gast zweimal: kein Backup der Tastenbelegung"       0 "$(baks "$GA/root/.claude/keybindings.json.bak*")"
check "Gast zweimal: Meldung 'schon gesetzt'"              1 "$(count "$T/guest.log" 'meta+k = voice:pushToTalk ist schon gesetzt')"

# the user's choices stay
GB="$T/gb"; rm -rf "$GB"; mkdir -p "$GB/root/.claude"
echo '{"voice":{"enabled":false,"mode":"tap"}}' > "$GB/root/.claude/settings.json"
echo '{"bindings":[{"context":"Chat","bindings":{"ctrl+t":"voice:pushToTalk"}}]}' > "$GB/root/.claude/keybindings.json"
gi "$GB" --claude yes --codex no
check "Gast: eigenes voice in settings.json bleibt"        '{"enabled": false, "mode": "tap"}' "$(sv "$GB")"
check "Gast: schon belegtes voice:pushToTalk bleibt"       '{"bindings": [{"bindings": {"ctrl+t": "voice:pushToTalk"}, "context": "Chat"}]}' "$(kb "$GB/root/.claude/keybindings.json")"
check "Gast: Meldung 'schon belegt'"                       1 "$(count "$T/guest.log" 'voice:pushToTalk ist schon belegt')"
# an existing file with other bindings gets the binding added (and a backup)
GC="$T/gc"; rm -rf "$GC"; mkdir -p "$GC/root/.claude"
echo '{"bindings":[{"context":"Chat","bindings":{"ctrl+g":null}},{"context":"Global","bindings":{"ctrl+o":"app:toggleTranscript"}}]}' > "$GC/root/.claude/keybindings.json"
gi "$GC" --claude yes --codex no
check "Gast: meta+k kommt in den Chat-Block, der Rest bleibt" '{"bindings": [{"bindings": {"ctrl+g": null, "meta+k": "voice:pushToTalk"}, "context": "Chat"}, {"bindings": {"ctrl+o": "app:toggleTranscript"}, "context": "Global"}]}' "$(kb "$GC/root/.claude/keybindings.json")"
check "Gast: ... mit Backup"                               1 "$(baks "$GC/root/.claude/keybindings.json.bak*")"
# meta+k is taken by something else
GD="$T/gd"; rm -rf "$GD"; mkdir -p "$GD/root/.claude"
echo '{"bindings":[{"context":"Chat","bindings":{"meta+k":"chat:other"}}]}' > "$GD/root/.claude/keybindings.json"
gi "$GD" --claude yes --codex no
check "Gast: meta+k anders belegt: Datei bleibt"           '{"bindings": [{"bindings": {"meta+k": "chat:other"}, "context": "Chat"}]}' "$(kb "$GD/root/.claude/keybindings.json")"
check "Gast: meta+k anders belegt: Hinweis"                1 "$(count "$T/guest.log" 'meta+k ist anders belegt')"
# not JSON
GE="$T/ge"; rm -rf "$GE"; mkdir -p "$GE/root/.claude"
echo 'not json {' > "$GE/root/.claude/keybindings.json"
gi "$GE" --claude yes --codex no
check "Gast: kaputte Datei bleibt, Installer läuft durch"  "0 not json {" "$GRC $(cat "$GE/root/.claude/keybindings.json")"
# switched off
GF="$T/gf"; rm -rf "$GF"; mkdir -p "$GF"
gi "$GF" --claude yes --codex no --voice no
check "Gast --voice no: .bashrc ohne PULSE_COOKIE"         0 "$(count "$GF/root/.bashrc" 'PULSE_COOKIE')"
check "Gast --voice no: keine Tastenbelegung, kein voice" "nein null" "$(has "$GF/root/.claude/keybindings.json") $(sv "$GF")"
check "Gast --voice no: kein Vorlesen (Programm, Hooks)"   "nein nein 0" "$(has "$GF/usr/local/lib/termux-rootbridge/speak.py") $(has "$GF/usr/local/bin/rootbridge-speak") $(count "$GF/etc/claude-code/managed-settings.json" 'speak.py')"
gi "$GA" --claude yes --codex no --voice no
check "Gast erst mit, dann --voice no: Vorlesen wieder weg" "nein nein 0" "$(has "$GA/usr/local/lib/termux-rootbridge/speak.py") $(has "$GA/usr/local/bin/rootbridge-speak") $(count "$MS" 'speak.py')"
check "Gast --voice no: die Hooks von rootbridge bleiben"  2 "$(count "$MS" 'rootbridge-hook.py')"
gi "$GA" --claude yes --codex no
gi "$GA" --uninstall
check "Gast deinstalliert: Vorlesen weg"                   "nein nein" "$(has "$GA/usr/local/lib/termux-rootbridge/speak.py") $(has "$GA/usr/local/bin/rootbridge-speak")"
GG="$T/gg"; rm -rf "$GG"; mkdir -p "$GG"
gi "$GG" --claude no --codex yes
check "Gast ohne Claude Code: keine Tastenbelegung"        nein "$(has "$GG/root/.claude/keybindings.json")"
check "Gast ohne Claude Code: .bashrc ohne PULSE_COOKIE"   0 "$(count "$GG/root/.bashrc" 'PULSE_COOKIE')"
gi "$GG" --claude yes --voice maybe
check "Gast: --voice maybe wird abgelehnt"                 2 "$GRC"

# =========================================================================== 6. setup-guest.sh: sox
mkdir -p "$T/gstubs" "$T/ghome"
cat > "$T/gstubs/apt-get" <<'EOF'
#!/bin/bash
echo "apt-get $*" >> "$STUB_LOG"
exit 0
EOF
for c in python3 curl shellcheck; do printf '#!/bin/bash\nexit 0\n' > "$T/gstubs/$c"; done
printf '#!/bin/bash\nexit 0\n' > "$T/gstubs/git"
chmod +x "$T/gstubs"/*
mkdir -p "$T/gbin"
for c in bash sh mktemp rm ls timeout cat sed tr head tail dirname basename env mkdir chmod mv; do
    p="$(command -v "$c")" && ln -sf "$p" "$T/gbin/$c"
done
mkdir -p "$T/ghome/.local/bin"; printf '#!/bin/bash\nexit 0\n' > "$T/ghome/.local/bin/claude"; chmod +x "$T/ghome/.local/bin/claude"
printf 'x' > "$T/ca.crt"
# Piper: present (a venv with piper and the voice) unless a test removes it; never the real /opt/piper
PIPER="$T/piper"
piper_present() {
    mkdir -p "$PIPER/bin" "$PIPER/voices"
    printf '#!/bin/bash\nexit 0\n' > "$PIPER/bin/piper"; chmod +x "$PIPER/bin/piper"
    echo x > "$PIPER/voices/de_DE-kerstin-medium.onnx"; echo x > "$PIPER/voices/de_DE-kerstin-medium.onnx.json"
}
piper_present
gs() {   # gs [args]: setup-guest.sh with everything present except what the test removes
    : > "$ILOG"
    env -i PATH="$T/gstubs:$T/gbin" HOME="$T/ghome" ROOTBRIDGE_GUEST_HOME="$T/ghome" ROOTBRIDGE_CA_BUNDLE="$T/ca.crt" STUB_LOG="$ILOG" \
        PIPER_DIR="$PIPER" STUB_PIPER="$PIPER" STUB_ENSUREPIP="${STUB_ENSUREPIP:-0}" STUB_PIP_RC="${STUB_PIP_RC:-0}" \
        STUB_VOICE_RC="${STUB_VOICE_RC:-0}" bash "$SETUP" "$@" > "$T/setup.log" 2>&1
    SRC_RC=$?
}
gs --codex no
check "setup-guest: Claude Code und Voice: apt-get install sox libsox-fmt-pulse" "0 1" "$SRC_RC $(count "$ILOG" '^apt-get install -y --no-install-recommends sox libsox-fmt-pulse$')"
gs --codex no --voice no
check "setup-guest --voice no: kein sox"                   "0 0" "$SRC_RC $(count "$ILOG" 'sox')"
gs --claude no --codex yes
check "setup-guest ohne Claude Code: kein sox"             0 "$(count "$ILOG" 'sox')"
printf '#!/bin/bash\nexit 0\n' > "$T/gstubs/rec"; chmod +x "$T/gstubs/rec"
gs --codex no
check "setup-guest: rec ist da, kein apt für sox"          0 "$(count "$ILOG" 'sox')"
rm -f "$T/gstubs/rec"
gs --codex no --voice maybe
check "setup-guest --voice maybe: abgelehnt"               1 "$SRC_RC"
printf '#!/bin/bash\nexit 0\n' > "$T/gstubs/rec"; chmod +x "$T/gstubs/rec"
gs --codex no
check "setup-guest: Piper und Stimme da, nichts zu tun"   "0 0 1" "$SRC_RC $(count "$ILOG" '.') $(count "$T/setup.log" 'piper ist schon installiert')"
# no Piper: a venv, pip install piper-tts, then the voice. python3 is a stub: ensurepip as STUB_ENSUREPIP says, -m venv makes pip and python3
cat > "$T/gstubs/python3" <<'EOF'
#!/bin/bash
echo "python3 $*" >> "$STUB_LOG"
case "$*" in
    *"import ensurepip"*) exit "${STUB_ENSUREPIP:-0}" ;;
    "-m venv "*) mkdir -p "$3/bin"
        printf '#!/bin/bash\necho "pip $*" >> "$STUB_LOG"\nprintf "#!/bin/bash\\n" > "$STUB_PIPER/bin/piper"; chmod +x "$STUB_PIPER/bin/piper"\nexit "${STUB_PIP_RC:-0}"\n' > "$3/bin/pip"
        cat > "$3/bin/python3" <<'VPY'
#!/bin/bash
echo "venv-python3 $*" >> "$STUB_LOG"
# the downloader: both files into --download-dir ($4), a partial model and no .json with STUB_VOICE_RC
if [ "$2" = piper.download_voices ]; then
    if [ "${STUB_VOICE_RC:-0}" = 0 ]; then echo model > "$4/$5.onnx"; echo '{"audio": {"sample_rate": 22050}}' > "$4/$5.onnx.json"
    else echo teil > "$4/$5.onnx"; exit 1; fi
fi
exit 0
VPY
        chmod +x "$3/bin/pip" "$3/bin/python3" ;;
esac
exit 0
EOF
chmod +x "$T/gstubs/python3"
rm -rf "$PIPER"
gs --codex no
check "setup-guest ohne Piper: venv, pip install piper-tts" "0 1 1" "$SRC_RC $(count "$ILOG" "^python3 -m venv $PIPER$") $(count "$ILOG" '^pip install -q piper-tts$')"
check "setup-guest ohne Piper: lädt die Stimme kerstin-medium in einen Zwischenordner" 1 "$(count "$ILOG" "^venv-python3 -m piper.download_voices --download-dir $PIPER/voices/.download de_DE-kerstin-medium$")"
check "setup-guest: die Stimme liegt danach an ihrem Platz, ohne Zwischenordner" "ja ja nein" "$(has "$PIPER/voices/de_DE-kerstin-medium.onnx") $(has "$PIPER/voices/de_DE-kerstin-medium.onnx.json") $(has "$PIPER/voices/.download")"
check "setup-guest: venv geht (ensurepip da): kein apt"   0 "$(count "$ILOG" '^apt-get')"
rm -rf "$PIPER"
gs --codex no --voice no
check "setup-guest --voice no: kein Piper"                 "0 0" "$SRC_RC $(count "$ILOG" 'venv')"
gs --claude no --codex yes
check "setup-guest ohne Claude Code: kein Piper"           0 "$(count "$ILOG" 'venv')"
STUB_ENSUREPIP=1 gs --codex no
check "setup-guest ohne ensurepip: apt-get install python3-venv" 1 "$(count "$ILOG" '^apt-get install -y --no-install-recommends python3-venv$')"
rm -rf "$PIPER"
STUB_PIP_RC=1 gs --codex no
check "setup-guest: pip scheitert, Fehler mit Hinweis"     "1 1" "$SRC_RC $(count "$T/setup.log" 'Piper ließ sich nicht installieren')"
rm -rf "$PIPER"
STUB_VOICE_RC=1 gs --codex no
check "setup-guest: Stimme scheitert, Fehler mit Hinweis"  "1 1" "$SRC_RC $(count "$T/setup.log" 'Stimme de_DE-kerstin-medium ließ sich nicht laden')"
check "setup-guest: ein halber Download gilt nicht als Stimme" "nein nein" "$(has "$PIPER/voices/de_DE-kerstin-medium.onnx") $(has "$PIPER/voices/.download")"
printf '#!/bin/bash\nexit 0\n' > "$T/gstubs/python3"; chmod +x "$T/gstubs/python3"
rm -f "$T/gstubs/rec"; piper_present

# =========================================================================== 7. uninstall.sh
H2="$T/uh"; P2="$T/up"; mkdir -p "$H2/.config/pulse" "$P2/bin"
printf '#!/bin/sh\n# sidekey-ptt\n' > "$P2/bin/sidekey-ptt"
printf '# termux-rootbridge voice: x\n' > "$H2/.config/pulse/default.pa"
run_un() { : > "$ILOG"; STUB_LOG="$ILOG" HOME="$H2" PREFIX="$P2" PATH="$T/istubs:$PATH" bash "$UNINSTALL" --no-guest > "$T/uninstall.log" 2>&1; }
mkdir -p "$H2/.shortcuts/tasks"
cp "$ROOT/termux/shortcuts/speak" "$H2/.shortcuts/tasks/Vorlesen"; cp "$ROOT/termux/shortcuts/speak-stop" "$H2/.shortcuts/tasks/Stopp"
run_un
check "uninstall: sidekey-ptt weg, Leser beendet"          "nein 1" "$(has "$P2/bin/sidekey-ptt") $(count "$ILOG" '^pkill -f sidekey-ptt')"
check "uninstall: Widgets Vorlesen und Stopp weg"          "nein nein" "$(has "$H2/.shortcuts/tasks/Vorlesen") $(has "$H2/.shortcuts/tasks/Stopp")"
printf '#!/bin/sh\necho mine\n' > "$H2/.shortcuts/tasks/Stopp"
run_un
check "uninstall: ein eigenes Widget Stopp bleibt"         ja "$(has "$H2/.shortcuts/tasks/Stopp")"
check "uninstall: unsere default.pa weg"                   nein "$(has "$H2/.config/pulse/default.pa")"
printf '# my own\n' > "$H2/.config/pulse/default.pa"
printf '#!/bin/sh\necho mine\n' > "$P2/bin/sidekey-ptt"
run_un
check "uninstall: eigene default.pa bleibt"                ja "$(has "$H2/.config/pulse/default.pa")"
check "uninstall: fremdes sidekey-ptt bleibt"              ja "$(has "$P2/bin/sidekey-ptt")"

# =========================================================================== 8. rootbridge-claude and the PulseAudio cookie
CL="$ROOT/guest/bin/rootbridge-claude"
snip() { sed -n '/^pulse_cookie=/,/^\[ -r "\$pulse_cookie" \]/p' "$CL" | sed "s|^pulse_cookie=.*|pulse_cookie=$1|"; }
echo cookie > "$T/cookie"
check "rootbridge-claude: PULSE_COOKIE gesetzt, wenn das Cookie lesbar ist" "$T/cookie" "$(env -u PULSE_COOKIE bash -c "$(snip "$T/cookie"); echo \"\${PULSE_COOKIE:-leer}\"")"
check "rootbridge-claude: ohne Cookie bleibt PULSE_COOKIE leer"             leer "$(env -u PULSE_COOKIE bash -c "$(snip "$T/gibt-es-nicht"); echo \"\${PULSE_COOKIE:-leer}\"")"
check "rootbridge-claude: der Pfad ist das Termux-Home"                     1 "$(count "$CL" '^pulse_cookie=/data/data/com.termux/files/home/.config/pulse/cookie$')"

# =========================================================================== 9. the program itself
check "sidekey-ptt ist ausführbar"                         ja "$([ -x "$ROOT/termux/bin/sidekey-ptt" ] && echo ja || echo nein)"
check "sidekey-ptt kompiliert"                             0 "$(python3 -I -c "import sys; compile(open(sys.argv[1]).read(), 'x', 'exec')" "$ROOT/termux/bin/sidekey-ptt" >/dev/null 2>&1; echo $?)"
check "help von install.sh nennt --voice und --sidekey"    "1 1" "$(bash "$INSTALL" --help 2>&1 | grep -c -- '^--voice / --no-voice') $(bash "$INSTALL" --help 2>&1 | grep -c -- '^--sidekey / --no-sidekey')"

finish
