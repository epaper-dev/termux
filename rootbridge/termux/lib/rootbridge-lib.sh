# shellcheck shell=bash
# shellcheck disable=SC2034  # the settings below are read by the scripts that source this file
# rootbridge-lib.sh - shared helpers of termux-rootbridge (sourced, not run).
# Used by rootbridge-daemon and the rootbridge CLI inside Termux.

# --- defaults ---------------------------------------------------------------
BRIDGE_DIR="${BRIDGE_DIR:-$HOME/.rootbridge}"
RB_CONFIG="${ROOTBRIDGE_CONFIG:-$HOME/.config/termux-rootbridge/config}"

DISTRO="ubuntu"
WORKDIR="/root/work"
SESSION="ubuntu"
STALE_TIMEOUT=70        # requests older than this were abandoned by androidsu
ASK_TIMEOUT=120         # seconds the Android dialog waits for your answer (no answer = refused)
POLL_INTERVAL=0.5
SU_ARGS="-c"            # "-mm -c" = global mount namespace (Magisk)
AUTH_OPEN="auto"        # auto | copy | off   (used by the Claude hook)
CLAUDE_ARGS=""
TOOL_CLAUDE="on"        # on | off: Claude Code is part of this installation (install.sh --no-claude sets off)
TOOL_CODEX="on"         # on | off: Codex is part of this installation (install.sh --no-codex sets off)
TOOL_OPENCODE="off"     # on | off: OpenCode is part of this installation (install.sh --opencode sets on)
VOICE="on"              # on | off: voice dictation for Claude Code (sox, PulseAudio, microphone); install.sh --no-voice sets off
SPEAK=""                # on | off: reading Claude's answers aloud (PulseAudio plays it); install.sh --no-speak sets off;
                        # empty (a config from before it): follows VOICE, as it was part of it
SIDEKEY="off"           # on | off: side key of the Hisense A9 as push to talk (sidekey-ptt); install.sh --sidekey sets on
HEADSET=""              # on | off: long press on the key of a wired headset toggles push to talk (headset-ptt); install.sh --headset sets on;
                        # empty (not decided, a config from before it): follows SIDEKEY, as the reader always read both keys
HOMEKEY="off"           # on | off: long press on Home toggles push to talk (Termux as the assistant, set by install.sh --home-key)
AUTOSTART_DELAY=3
PTT_TARGET=""           # tmux target that `ptt` presses its key in (empty = "<SESSION>:claude")
PTT_KEY="M-k"           # tmux key name; Claude Code: "voice:pushToTalk" bound to meta+k in ~/.claude/keybindings.json
PTT_MODE="auto"         # auto | hold | tap: the mode of Claude Code's /voice (auto reads it from the settings of the guest); hold: `ptt start` repeats the key until `ptt stop`, tap: it presses the key once
PTT_INTERVAL=50         # milliseconds between the repeats of hold mode
PTT_WARMUP=1200         # milliseconds between the first key and the repeats of hold mode (Claude Code starts its recorder with the first key; under 2000)
PTT_MAX=120             # seconds after which hold mode / tap mode stop waiting for `ptt stop`
PTT_BEEP="on"           # on | off: a high beep when the recorder of Claude Code runs after `ptt start` (speak now), a low one when it ends
THEME_FOLLOW="on"       # on | off: "Auto epaper" follows light/dark (rootbridge theme)
THEME_RESTART="off"     # on | off: fallback, restart Claude Code (--continue) after a change
GUEST_ISOLATE="on"      # on | off: guest sessions see nothing of Termux but the bridge directory (proot-distro --isolated)

# Test hooks / binaries. Taken from the environment only, never from the
# config file, because the config file lies in a directory the guest can write.
RB_SU="${RB_SU:-su}"
RB_TMUX="${RB_TMUX:-tmux}"
RB_OPEN_CMD="${RB_OPEN_CMD:-termux-open-url}"
RB_CLIP_CMD="${RB_CLIP_CMD:-termux-clipboard-set}"
RB_ASK_CMD="${RB_ASK_CMD:-${PREFIX:-/data/data/com.termux/files/usr}/libexec/termux-api}"   # the client behind termux-dialog
RB_ASK_MIN_MS="${RB_ASK_MIN_MS:-1000}"   # a Yes sooner than this after the dialog appeared does not count
RB_PROC_DIR="${RB_PROC_DIR:-/proc}"
RB_STORAGE_DIR="${RB_STORAGE_DIR:-/storage/self/primary}"

# --- config (parsed as data, never sourced) ---------------------------------
rb_load_config() {
    local line key val
    [ -r "$RB_CONFIG" ] || return 0
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in ''|'#'*) continue ;; esac
        key="${line%%=*}"
        val="${line#*=}"
        val="${val%\"}"; val="${val#\"}"; val="${val%\'}"; val="${val#\'}"
        case "$key" in
            DISTRO|SESSION)
                [[ "$val" =~ ^[A-Za-z0-9._-]+$ ]] && printf -v "$key" '%s' "$val" ;;
            WORKDIR)
                [[ "$val" =~ ^/[A-Za-z0-9._/-]*$ ]] && WORKDIR="$val" ;;
            STALE_TIMEOUT|ASK_TIMEOUT|AUTOSTART_DELAY)
                [[ "$val" =~ ^[0-9]{1,6}$ ]] && printf -v "$key" '%s' "$val" ;;
            POLL_INTERVAL)
                [[ "$val" =~ ^[0-9]{1,2}(\.[0-9]{1,3})?$ ]] && POLL_INTERVAL="$val" ;;
            SU_ARGS)
                case "$val" in "-c"|"-mm -c") SU_ARGS="$val" ;; esac ;;
            AUTH_OPEN)
                case "$val" in auto|copy|off) AUTH_OPEN="$val" ;; esac ;;
            PTT_TARGET)
                [[ "$val" =~ ^[A-Za-z0-9._:@%=-]{1,64}$ ]] && PTT_TARGET="$val" ;;
            PTT_KEY)
                [[ "$val" =~ ^[A-Za-z0-9-]{1,16}$ ]] && PTT_KEY="$val" ;;
            PTT_MODE)
                case "$val" in auto|hold|tap) PTT_MODE="$val" ;; esac ;;
            PTT_INTERVAL)
                [[ "$val" =~ ^[0-9]{2,4}$ ]] && [ "$val" -ge 20 ] && PTT_INTERVAL="$val" ;;
            PTT_WARMUP)
                [[ "$val" =~ ^[0-9]{1,4}$ ]] && [ "$val" -le 1500 ] && PTT_WARMUP="$val" ;;
            PTT_MAX)
                [[ "$val" =~ ^[0-9]{1,4}$ ]] && [ "$val" -ge 1 ] && PTT_MAX="$val" ;;
            THEME_FOLLOW|THEME_RESTART|GUEST_ISOLATE|TOOL_CLAUDE|TOOL_CODEX|TOOL_OPENCODE|VOICE|SPEAK|SIDEKEY|HEADSET|HOMEKEY|PTT_BEEP)
                case "$val" in on|off) printf -v "$key" '%s' "$val" ;; esac ;;
            CLAUDE_ARGS)
                [[ "$val" =~ ^[A-Za-z0-9._\ =:/,-]*$ ]] && CLAUDE_ARGS="$val" ;;
        esac
    done < "$RB_CONFIG"
}

# --- small helpers ----------------------------------------------------------
rb_valid_id() { [[ "$1" =~ ^[A-Za-z0-9_]+$ ]]; }

# Appends one tab separated line: time, decision, exit code, command.
rb_audit() {
    local decision="$1" code="$2" detail="$3"
    mkdir -p "$BRIDGE_DIR"
    printf '%s\t%s\t%s\t%s\n' "$(date -Is)" "$decision" "$code" "$detail" \
        >> "$BRIDGE_DIR/audit.log"
}

# Atomic file write: rb_write_atomic <file> <line1> <rest...>
rb_write_atomic() {
    local file="$1" first="$2" rest="${3-}" tmp
    tmp="$file.tmp.$$"
    printf '%s\n%s\n' "$first" "$rest" > "$tmp" && mv -f "$tmp" "$file"
}

# --- guest sessions ----------------------------------------------------------
# rb_login_opts: the options of every `proot-distro login` that opens a guest session (agents and shells), as one
# string. proot-distro hands the guest the Termux home and usr by default, and with them the daemon, the su wrapper and
# the files Termux runs at its next start. --isolated takes all of that away; only the bridge directory (the requests
# and refusals), the shared storage (/sdcard: your files, nothing of Termux) and, for voice, the PulseAudio cookie are
# bound in. The installer logins do not use this.
# rb_audio: PulseAudio is needed, for the microphone (VOICE) or for reading aloud (SPEAK, empty: as VOICE)
rb_audio() { [ "$VOICE" = on ] || [ "${SPEAK:-$VOICE}" = on ]; }

# rb_playback_verified: the PulseAudio server that runs is the one voice_start started for reading aloud only (voice_pids,
# from the rootbridge command, against the note voice_start wrote)
rb_playback_verified() {
    local note="$HOME/.cache/rootbridge-pulse-playback-only" running
    [ -s "$note" ] && declare -F voice_pids >/dev/null || return 1
    running="$(voice_pids)" && [ -n "$running" ] && [ "$running" = "$(cat "$note" 2>/dev/null)" ]
}

rb_login_opts() {
    local opts cookie="$HOME/.config/pulse/cookie"
    [ "$GUEST_ISOLATE" = on ] || return 0
    mkdir -p "$BRIDGE_DIR"
    opts="--isolated --bind $BRIDGE_DIR:$BRIDGE_DIR"
    if [ -d "$RB_STORAGE_DIR" ]; then opts="$opts --bind $RB_STORAGE_DIR:/sdcard --bind $RB_STORAGE_DIR:/storage/emulated/0"; fi
    # the cookie lets the guest into PulseAudio; for reading aloud only just while the server voice_start started with
    # module loading shut runs (its pid in the note in ~/.cache is the one running), so the guest cannot load a microphone.
    # Known and accepted (2026-11-23): with the cookie the guest can listen to the monitor of the output, i.e. to what
    # Termux programs play through this PulseAudio (in practice our own reading aloud; Android apps do not play through it).
    if rb_audio && [ -r "$cookie" ] && { [ "$VOICE" = on ] || rb_playback_verified; }; then
        opts="$opts --bind $cookie:$cookie"
    fi
    printf '%s' "$opts"
}

# --- who asks, and your answer -------------------------------------------------
# rb_requester <request id>: sets RB_AGENT ("Claude Code", "Codex", "OpenCode" or "") and RB_AGENT_PID (not for OpenCode:
# it has no hook that reads the notes, they would pile up). The id starts with the pid of
# the androidsu that wrote the request (no pid namespace under proot); its ancestors show the agent, by process name
# (comm: from outside proot /proc/<pid>/exe is not the program). Only a hint for the dialog and for the event file,
# never a reason to allow anything.
rb_requester() {
    local pid="${1%%_*}" i
    RB_AGENT=""; RB_AGENT_PID=""
    for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16; do
        [[ "$pid" =~ ^[0-9]+$ ]] && [ "$pid" -gt 1 ] || return 0
        case "$(cat "$RB_PROC_DIR/$pid/comm" 2>/dev/null)" in
            claude) RB_AGENT="Claude Code" ;;
            codex) RB_AGENT="Codex" ;;
            opencode) RB_AGENT="OpenCode"; return 0 ;;
        esac
        if [ -n "$RB_AGENT" ]; then RB_AGENT_PID="$pid"; return 0; fi
        pid="$(sed -n 's/^PPid:[[:space:]]*//p' "$RB_PROC_DIR/$pid/status" 2>/dev/null)"
    done
}

# rb_ask_texts: the words of the dialog in the language of the phone (RB_LANG overrides: de, es, en; anything else is English)
rb_ask_texts() {
    local lang="${RB_LANG:-}"
    [ -n "$lang" ] || lang="$(getprop persist.sys.locale 2>/dev/null)"
    [ -n "$lang" ] || lang="$(getprop ro.product.locale 2>/dev/null)"
    [ -n "$lang" ] || lang="$(getprop persist.sys.language 2>/dev/null)"
    lang="${lang%%[-_]*}"
    case "${lang,,}" in
        de) RB_T_YES="Ja";  RB_T_NO="Nein"; RB_T_LEFT="noch %d s" ;;
        es) RB_T_YES="Sí";  RB_T_NO="No";   RB_T_LEFT="quedan %d s" ;;
        *)  RB_T_YES="Yes"; RB_T_NO="No";   RB_T_LEFT="%d s left" ;;
    esac
}

# rb_ask <who> <command>: you decide in an Android dialog; the answer is the output of the dialog itself, not a file the
# guest could write. Returns 0 = yes, 1 = no, 2 = no answer in time, 3 = dialog failed (termux-api missing, ...).
# The dialog is asked through the termux-api client with a few extras that our Termux:API build understands: the buttons in
# the language of the phone, a title that counts down to ASK_TIMEOUT (the dialog closes itself then) and a dialog that only
# a tap on Yes or No answers. The stock Termux:API ignores the extras: English buttons, no countdown, and a dismissed dialog
# (a tap outside, the keyboard, another app) shows again until ASK_TIMEOUT; a Yes within RB_ASK_MIN_MS of the dialog
# appearing is a slip while typing and is asked again.
# One dialog at a time: flock on a file in the private tmp directory of Termux (not in the bridge directory). The lock
# goes away with the process, also when it is killed; a mkdir lock is not atomic everywhere (not under proot). A lock that
# cannot be opened or taken (no flock, no writable tmp directory) means no dialog: result 3, the request is refused.
rb_ask() {
    local who="$1" cmd="$2" out rc start deadline left ms result=3
    { exec 9>"${TMPDIR:-/tmp}/rootbridge-ask.flock"; } 2>/dev/null || return 3     # no lock, no dialog
    if ! flock 9 2>/dev/null; then exec 9>&-; return 3; fi
    rb_ask_texts
    deadline=$(( $(date +%s) + ASK_TIMEOUT ))
    while :; do
        left=$(( deadline - $(date +%s) ))
        if [ "$left" -le 0 ]; then result=2; break; fi
        start="$(date +%s%N)"
        out="$(timeout "$left" "$RB_ASK_CMD" Dialog --es input_method confirm \
                  --es input_title "Android-Root: ${who:-Shell}" --es input_hint "$cmd" \
                  --es input_yes "$RB_T_YES" --es input_no "$RB_T_NO" \
                  --ei input_timeout "$left" --es input_timeout_text "$RB_T_LEFT" --ez input_modal true \
                  2>/dev/null < /dev/null 9>&-)"
        rc=$?
        ms=$(( ($(date +%s%N) - start) / 1000000 ))
        if [ "$rc" -eq 124 ]; then result=2; break; fi
        if [ "$rc" -ne 0 ]; then result=3; break; fi
        case "$out" in
            *'"text": "yes"'*|*'"text":"yes"'*)
                if [ "$ms" -ge "$RB_ASK_MIN_MS" ]; then result=0; break; fi ;;
            *'"text": "no"'*|*'"text":"no"'*) result=1; break ;;
            *'"code"'*) ;;
            *) result=3; break ;;
        esac
        sleep 1                    # dismissed or slipped: show it again
    done
    exec 9>&-
    return "$result"
}

# rb_event <agent pid> <decision> <command>: a note for the hook of that agent (events/<pid>-<ns>: line 1 the decision,
# line 2 the command). Only informative: a forged note can mislead the agent but gives it no rights.
rb_event() {
    [ -n "$1" ] || return 0
    mkdir -p "$BRIDGE_DIR/events"
    rb_write_atomic "$BRIDGE_DIR/events/$1-$(date +%s%N)" "$2" "$(printf '%s' "$3" | head -c 300 | tr '\n' ' ')"
}

# --- URLs -------------------------------------------------------------------
# Only plain https URLs, no whitespace/control/quote characters, <= 8 KiB.
# The same URL rule as the regex in guest/bin/rootbridge-open and VALID_RE in guest/claude/auth-url-hook.py (the guest
# checks, and this daemon checks again): change all three together.
RB_URL_RE='^https://[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?(:[0-9]{1,5})?([/?#][^[:space:][:cntrl:]"'"'"'<>`\\]*)?$'
rb_valid_url() {
    [ "${#1}" -le 8192 ] && [[ "$1" =~ $RB_URL_RE ]]
}
rb_url_host() {
    local h="${1#https://}"
    h="${h%%[/?#]*}"
    printf '%s' "${h%%:*}"
}

# --- speech output (guest/claude/speak.py) -------------------------------------
# rb_speak_mark <name>: a new file <name> in the bridge directory (its mtime tells the guest when). Made in the own temp folder
# of Termux and moved with mv -T (replaces a link instead of following it), like the switches of reading aloud.
rb_speak_mark() {
    local tmp
    tmp="$(mktemp 2>/dev/null)" || return 1
    mv -fT "$tmp" "$BRIDGE_DIR/$1" 2>/dev/null && return 0
    rm -f "$tmp"
    return 1
}

# rb_speak_stop: end what the guest is reading aloud. Its player writes the id of its process group to speak.pid in the
# bridge directory (no pid namespace under proot). The guest can write there, so the pid only counts when that process is
# really the player ("speak.py --run"); the same check as player_pid() in speak.py. Only a regular file, read with a time
# limit: a FIFO there must not hold up a caller. It also puts a new speak-stopped in place: the texts that wait for their
# turn, and a --progress hook of the guest that is still waiting for its note, then do not start reading after the stop.
rb_speak_stop() {
    local pid
    rb_speak_mark speak-stopped || true
    pid="$(rb_speak_player)" || return 0
    kill -TERM -- "-$pid" 2>/dev/null || true
}

# rb_speak_hold: the guest pauses its reading for a few seconds (speak-hold), until the recorder of Claude Code runs, which
# keeps it paused; afterwards it goes on where it stopped. ptt calls it before its key, so nothing is read into the start of
# the recording. What is already on its way (the player looks every 0.1 s; its pipe and SoX hold 4 KiB each, PulseAudio
# 200 ms; see speak.py) is heard while Claude Code starts its recorder, which takes half a second or more after the key.
# (A stop signal does not hold a process under proot, so the player holds itself.) Without speak-hold, or with a player of
# an older guest (it does not know speak-hold: no "pauses" at the end of its command line), the reading ends as before.
rb_speak_hold() {
    local pid
    if rb_speak_mark speak-hold; then
        pid="$(rb_speak_player)" || return 0
        tr '\0' ' ' < "$RB_PROC_DIR/$pid/cmdline" 2>/dev/null | grep -qE 'speak\.py --run [0-9]{20} [0-9-]+ pauses ' && return 0
    fi
    rb_speak_stop
}

# the sentences that speak.py --command keeps from Claude (STOP_PHRASES, OFF_PHRASES, ON_PHRASES, RESUME_PHRASES,
# REPEAT_SENTENCE_PHRASES, REPEAT_TEXT_PHRASES, WHOLE_PHRASES,
# ALL_PHRASES, SHORT_PHRASES, HELP_PHRASES there; written the same way:
# lower case, marks out): only these leave the input line (rb_prompt_clear). tests/test_voice.sh checks that both lists match.
RB_SPEAK_SENTENCES=(
    "beende die sprachausgabe" "stoppe die sprachausgabe" "stopp die sprachausgabe" "beende die sprachansage"
    "stoppe die sprachansage" "stoppe jetzt die sprachansage" "hör auf zu reden" "höre auf zu reden" "beende das vorlesen"
    "stoppe das vorlesen" "stopp das vorlesen" "stop reading aloud" "stop the speech" "stop talking now"
    "schalte die sprachausgabe aus" "schalte das vorlesen aus" "sprachausgabe dauerhaft aus" "turn speech off"
    "turn reading off" "switch speech off"
    "schalte die sprachausgabe ein" "schalte die sprachausgabe an" "schalte das vorlesen ein" "schalte das vorlesen an"
    "starte die sprachausgabe" "starte das vorlesen" "turn speech on" "turn reading on" "switch speech on"
    "fahre mit dem vorlesen fort" "lies den text weiter" "lies weiter vor" "lese weiter vor" "lies bitte weiter vor"
    "continue reading aloud"
    "wiederhole den letzten satz" "lies den letzten satz nochmal" "lies den letzten satz noch mal" "repeat the last sentence"
    "wiederhole den text nochmal" "wiederhole den text noch mal" "lies das nochmal vor" "lies das noch mal vor"
    "wiederhole die letzte ausgabe" "repeat the last text" "wiederhole den text" "lies es nochmal vor"
    "lese es nochmal vor" "lies es noch mal vor" "lese es noch mal vor" "lies nochmal vor"
    "lese nochmal vor" "lies noch mal vor" "lese noch mal vor"
    "lies alles vor" "lese alles vor" "lies mir alles vor" "lese mir alles vor" "lies die ganze antwort vor"
    "lies mir die ganze antwort vor" "lies den gesamten text vor" "lies mir den gesamten text vor"
    "lese mir den gesamten text vor" "read everything aloud" "read the whole answer"
    "lese den kompletten text" "lies den kompletten text" "lese den kompletten text vor" "lies den kompletten text vor"
    "lese den ganzen text" "lies den ganzen text" "lese den ganzen text vor" "lies den ganzen text vor"
    "lies mir den ganzen text vor" "lies die komplette antwort vor" "read the whole text"
    "lies immer alles vor"
    "lies mir immer alles vor" "lese immer alles vor" "lies ab jetzt alles vor" "lies ab jetzt immer alles vor"
    "always read everything" "always read the whole answer" "lies nur die kurzfassung vor"
    "lies immer nur die kurzfassung vor" "lies ab jetzt nur die kurzfassung vor" "lies die kurzfassung vor"
    "lies mir die kurzfassung vor" "lese mir die kurzfassung vor" "lies nur die zusammenfassung vor"
    "lies nur das wichtigste vor" "read only the summary" "read only the short version" "always read only the summary"
    "welche sprachbefehle gibt es" "zeige die sprachbefehle" "zeig mir die sprachbefehle" "zeige mir die sprachbefehle"
    "show the speech commands"
)

# rb_prompt_clear: called by the daemon every round. Claude Code puts a prompt that a hook blocked back into its input line,
# also the sentences that stop reading or switch it (speak.py --command); speak.py writes such a sentence to prompt-clear.
# A line is emptied (Ctrl+U) only while it still holds just that sentence, so nothing typed since is lost. Claude Code may
# put it back a little later, and a failed tmux call is logged: tried again each round for a few seconds, then the file goes.
rb_prompt_clear() {
    local f="$BRIDGE_DIR/prompt-clear" want sentence panes pane screen line cleared=0 failed=0
    [ -e "$f" ] || [ -L "$f" ] || return 0
    if [ ! -f "$f" ] || [ -L "$f" ] || [ $(( $(date +%s) - $(stat -c %Y "$f" 2>/dev/null || echo 0) )) -gt 3 ]; then
        [ -f "$f" ] && [ ! -L "$f" ] && echo "$(date '+%F %T') Eingabezeile nicht geleert: der Satz kam in keinem Claude-Code-Fenster an" >&2
        rm -f "$f"
        return 0
    fi
    want="$(timeout 1 head -c 512 "$f" 2>/dev/null)"
    # the guest can write anything there: only one of our sentences is taken (written as speak.py writes it to compare)
    sentence="$(python3 -I -c 'import re, sys; print(" ".join(re.sub(r"[\W_]+", " ", sys.argv[1].lower()).split()))' \
        "$want" 2>/dev/null)"
    if [[ -z $want || $'\n'"$(printf '%s\n' "${RB_SPEAK_SENTENCES[@]}")"$'\n' != *$'\n'"$sentence"$'\n'* ]]; then
        echo "$(date '+%F %T') Eingabezeile nicht geleert: kein Satz zum Vorlesen in prompt-clear" >&2
        rm -f "$f"
        return 0
    fi
    # each pane of the Claude Code window of the session (claude; PTT_TARGET when set): its input box, from the last row with the prompt sign to the frame below it; a draft of more
    # rows is not ours. tmux cannot read and press in one step: what is typed in the few milliseconds between goes as well.
    if ! panes="$("$RB_TMUX" list-panes -s -t "$SESSION" -F '#{window_name} #{pane_id}' 2>/dev/null)"; then
        echo "$(date '+%F %T') Eingabezeile: tmux list-panes -t $SESSION gescheitert" >&2
        return 0                                                  # next round
    fi
    for pane in $(awk -v t="${PTT_TARGET#*:}" '$1 == "claude" || $1 == t { print $2 }' <<< "$panes"); do
        if ! screen="$("$RB_TMUX" capture-pane -p -t "$pane" 2>/dev/null)"; then
            echo "$(date '+%F %T') Eingabezeile: tmux capture-pane -t $pane gescheitert" >&2
            failed=1
            continue
        fi
        line="$(awk '/^❯/ { box = $0; n = 1; open = 1; next } open && /^─/ { open = 0; next } open { box = box "\n" $0; n++ }
                     END { if (n == 1) print box }' <<< "$screen")"
        line="${line#❯}"
        line="${line#$'\xc2\xa0'}"                              # the NBSP after the prompt sign
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        [ "$line" = "$want" ] || continue
        if "$RB_TMUX" send-keys -t "$pane" C-u 2>/dev/null; then
            cleared=1
        else
            echo "$(date '+%F %T') Eingabezeile von $pane nicht geleert (tmux send-keys)" >&2
            failed=1
        fi
    done
    [ "$cleared" = 1 ] && [ "$failed" = 0 ] || return 0      # not (yet) back in a line, or tmux failed: next round
    rm -f "$f"
}

# rb_speak_player: prints the pid in speak.pid when that process is the player of the guest (see rb_speak_stop), else fails.
rb_speak_player() {
    local pid f="$BRIDGE_DIR/speak.pid"
    [ -f "$f" ] && [ ! -L "$f" ] || return 1
    pid="$(timeout 1 head -c 16 "$f" 2>/dev/null | tr -d '[:space:]')"
    [[ "$pid" =~ ^[0-9]{1,9}$ ]] || return 1
    tr '\0' ' ' < "$RB_PROC_DIR/$pid/cmdline" 2>/dev/null | grep -q 'speak\.py --run' || return 1
    printf '%s\n' "$pid"
}

# rb_find_recorders <proc dir>: REC_PIDS = the running recorders of Claude Code's /voice (SoX: `rec ... --buffer 1024 -t raw ...`),
# read from the proc dir without starting a process
rb_find_recorders() {
    local d args
    REC_PIDS=()
    for d in "$1"/[0-9]*; do
        mapfile -d '' -t args 2>/dev/null < "$d/cmdline" || continue   # 2> first: a process can be gone by now
        if [[ ${args[0]-} == *rec && " ${args[*]} " == *" --buffer 1024 -t raw "* ]]; then REC_PIDS+=("${d##*/}"); fi
    done
}

# rb_fresh_recorders: drop from REC_PIDS the recorders the daemon has seen for RB_REC_MAX seconds (300) or longer: Claude Code
# sometimes leaves one running, and it would keep the music down and the reading paused for good. The pid is remembered from
# the round it was first seen (the age of a process is not to be trusted under proot); the recorder itself is left alone.
# The recorders that count no more go to rec-stale in the bridge directory, one "<pid> <start time>" per line (the start
# time from /proc/<pid>/stat, so a pid used again later is not taken for it), and the reading in the guest does not wait for
# them either (speak.py recording()). A file left by an earlier daemon goes in the first round.
declare -gA RB_REC_SEEN=()   # recorder pid: $SECONDS of the round it was first seen, "old" once it counts no more
rb_fresh_recorders() {
    local pid stale tmp fresh=() max="${RB_REC_MAX:-300}"
    local -A seen=()
    for pid in "${REC_PIDS[@]}"; do
        seen[$pid]="${RB_REC_SEEN[$pid]:-$SECONDS}"
        if [ "${seen[$pid]}" != old ] && (( SECONDS - seen[$pid] >= max )); then
            echo "$(date '+%F %T') Aufnahme $pid läuft seit $max s: zählt nicht mehr (Musik wieder laut)" >&2
            seen[$pid]=old
        fi
        [ "${seen[$pid]}" = old ] || fresh+=("$pid")
    done
    RB_REC_SEEN=()
    stale=""
    for pid in "${!seen[@]}"; do
        RB_REC_SEEN[$pid]="${seen[$pid]}"
        [ "${seen[$pid]}" != old ] || stale+="$pid $(rb_proc_start "$pid")"$'\n'
    done
    REC_PIDS=("${fresh[@]}")
    # written only when it changes; never through a path in the bridge (the guest can put a link there): a private temp
    # file moved over it, like rb_speak_focus_tell
    if [ "$stale" != "$RB_REC_STALE" ]; then
        if [ -z "$stale" ]; then
            rm -f "$BRIDGE_DIR/rec-stale" && { RB_REC_STALE=""; return 0; }
        elif tmp="$(mktemp 2>/dev/null)"; then
            if printf '%s' "$stale" > "$tmp" && mv -fT "$tmp" "$BRIDGE_DIR/rec-stale" 2>/dev/null; then
                RB_REC_STALE="$stale"
                return 0
            fi
            rm -f "$tmp"
        fi
        echo "$(date '+%F %T') $BRIDGE_DIR/rec-stale nicht geschrieben: das Vorlesen wartet weiter auf die Aufnahme" >&2
    fi
}
RB_REC_STALE="?"   # not known yet: the first round writes or removes the file

# rb_proc_start <pid>: the start time of the process (field 22 of /proc/<pid>/stat, after the name in parentheses)
rb_proc_start() {
    local stat fields
    stat="$(< "$RB_PROC_DIR/$1/stat")" 2>/dev/null || return 0
    read -r -a fields <<< "${stat##*) }"
    printf '%s' "${fields[19]-}"
}

# rb_speak_focus: called by the daemon every round. While the guest reads aloud (a live player in speak.pid) or Claude Code
# records for /voice (a recorder, rb_find_recorders), our
# Termux:API holds the audio focus for speech (AudioFocus): Android turns music down, like for a navigation app, and
# lets it up again when the player and the recorder are gone. A phone call (or the focus lost to one) ends the reading: PulseAudio would
# play right into it. The answer for a new player goes to speak-focus ("<pid> <answer>"); the player waits for it before
# it plays, and does not play during a call.
# Once asked for, the focus counts as held until Android confirms the release (a request without an answer in time may
# have been granted); the held state is also kept in a file in the private temp folder of Termux, so a daemon started
# after one that was killed releases it too (rb_speak_focus_resume).
# When Termux:API does not answer (the stock one never answers AudioFocus), the daemon asks less and less often (after
# 2, 4, ... up to 128 rounds) and tells the player "off" meanwhile; once it answers again, every round.
RB_SPEAK_FOCUS=""        # "" or held
RB_SPEAK_FOCUS_PID=""    # the player that speak-focus answers
RB_FOCUS_HELD="${TMPDIR:-/tmp}/rootbridge-audio-focus"
rb_focus_miss=0          # questions in a row without an answer
rb_focus_skip=0          # rounds left before the next question
rb_focus_state() {   # rb_focus_state <""|held>
    RB_SPEAK_FOCUS="$1"
    if [ "$1" = held ]; then : > "$RB_FOCUS_HELD" 2>/dev/null; else rm -f "$RB_FOCUS_HELD" 2>/dev/null; fi
    return 0
}
rb_speak_focus_resume() {
    [ ! -e "$RB_FOCUS_HELD" ] || RB_SPEAK_FOCUS=held
}
rb_focus_missed() {
    rb_focus_miss=$((rb_focus_miss + 1))
    rb_focus_skip=$((1 << (rb_focus_miss < 7 ? rb_focus_miss : 7)))
}
rb_speak_focus() {
    local pid answer
    [ "$rb_focus_skip" -eq 0 ] || rb_focus_skip=$((rb_focus_skip - 1))
    REC_PIDS=()
    [ "$VOICE" != on ] || rb_find_recorders "$RB_PROC_DIR"
    rb_fresh_recorders
    if pid="$(rb_speak_player)" || [ "${#REC_PIDS[@]}" -gt 0 ]; then
        if [ "$rb_focus_skip" -gt 0 ]; then answer=off
        else
            answer="$(rb_audio_focus status)"
            case "$answer" in
                none|lost) rb_focus_state held   # until a release is confirmed: Android may hold an earlier request
                           answer="$(rb_audio_focus request)" ;;
            esac
            case "$answer" in
                held|granted) rb_focus_state held; answer=granted ;;
                call) rb_speak_stop ;;
                denied) ;;                      # someone else holds it: read anyway, the next round asks again
                *) rb_focus_missed; answer=off ;;
            esac
            [ "$answer" = off ] || rb_focus_miss=0
        fi
        if [ -n "$pid" ] && [ "$pid" != "$RB_SPEAK_FOCUS_PID" ]; then
            rb_speak_focus_tell "$pid $answer" && RB_SPEAK_FOCUS_PID="$pid"
        fi
    elif [ "$RB_SPEAK_FOCUS" = held ] && [ "$rb_focus_skip" -eq 0 ]; then
        case "$(rb_audio_focus release)" in
            released) rb_focus_state ""; rb_focus_miss=0 ;;
            failed) rb_focus_miss=0 ;;          # Android keeps it: asked again next round
            *) rb_focus_missed ;;
        esac
    fi
}

# rb_speak_focus_tell <line>: speak-focus for the player; made in the own temp folder of Termux and moved with mv -T
# (replaces a link of the guest instead of following it)
rb_speak_focus_tell() {
    local tmp
    tmp="$(mktemp 2>/dev/null)" || return 1
    if printf '%s\n' "$1" > "$tmp" && mv -fT "$tmp" "$BRIDGE_DIR/speak-focus" 2>/dev/null; then return 0; fi
    rm -f "$tmp"
    return 1
}

# rb_audio_focus <request|release|status>: one word from AudioFocus of our Termux:API (empty when it does not answer)
rb_audio_focus() {
    timeout 2 "$RB_ASK_CMD" AudioFocus --es action "$1" 2>/dev/null < /dev/null | head -n 1 | tr -d '[:space:]'
}

# rb_perf: what this device has and whether that suits what needs computing power on it: reading aloud (Piper and
# Articulino, about 230 MB of models), the S1 router (a 183 MB ONNX classifier; 14-26 ms on server CPUs, its model card)
# and Skejja (voice commands; about 200 MB of memory and 0.2 s on a Raspberry Pi 4, its model card). Prints KEY=VALUE lines:
# CORES (online), MHZ (the highest clock), MEM_MB, FREE_MB (memory available), DISK_MB (free under $PREFIX), DOTPROD (yes|no:
# the int8 dot product of the CPU), SCORE (a count in bash per millisecond; the Hisense A9 makes about 140), SUMMARY, and per
# use FIT_<USE> (yes | tight | no) and TEXT_<USE> (the verdict in words, with the reason). A value that cannot be read is
# left out of the verdict. Bash only: install.sh measures before python3 is there.
# Test hooks (environment): RB_PROC_DIR, RB_SYS_DIR, RB_PERF_SCORE (instead of the count).
rb_perf() {
    local cpu="${RB_SYS_DIR:-/sys}/devices/system/cpu" cores=0 mhz=0 mem=0 free=0 disk=0 dot=no score="" f k v x part i t0 t1
    if read -r v 2>/dev/null < "$cpu/online"; then
        for part in ${v//,/ }; do
            [[ "$part" =~ ^([0-9]+)(-([0-9]+))?$ ]] || continue
            cores=$((cores + ${BASH_REMATCH[3]:-${BASH_REMATCH[1]}} - BASH_REMATCH[1] + 1))
        done
    fi
    [ "$cores" -gt 0 ] || { cores="$(nproc 2>/dev/null)" && [[ "$cores" =~ ^[0-9]+$ ]]; } || cores=0
    for f in "$cpu"/cpu[0-9]*/cpufreq/cpuinfo_max_freq; do
        if read -r v 2>/dev/null < "$f" && [[ "$v" =~ ^[0-9]+$ ]] && [ $((v / 1000)) -gt "$mhz" ]; then mhz=$((v / 1000)); fi
    done
    if [ -r "$RB_PROC_DIR/meminfo" ]; then
        while read -r k v x; do
            [[ "$v" =~ ^[0-9]+$ ]] || continue
            case "$k" in MemTotal:) mem=$((v / 1024)) ;; MemAvailable:) free=$((v / 1024)) ;; esac
        done < "$RB_PROC_DIR/meminfo"
    fi
    { read -r x; read -r x x x v x; } < <(df -Pk "${PREFIX:-/}" 2>/dev/null) && [[ "${v:-}" =~ ^[0-9]+$ ]] && disk=$((v / 1024))
    grep -qw asimddp "$RB_PROC_DIR/cpuinfo" 2>/dev/null && dot=yes
    score="${RB_PERF_SCORE:-}"
    if [ -z "$score" ] && [ -n "${EPOCHREALTIME:-}" ]; then
        t0="${EPOCHREALTIME//[!0-9]/}"
        for ((i = 0; i < 50000; i++)); do :; done
        t1="${EPOCHREALTIME//[!0-9]/}"
        if [ "$t1" -gt "$t0" ]; then score=$((50000 * 1000 / (t1 - t0))); fi
    fi
    printf 'CORES=%s\nMHZ=%s\nMEM_MB=%s\nFREE_MB=%s\nDISK_MB=%s\nDOTPROD=%s\nSCORE=%s\n' \
        "$cores" "$mhz" "$mem" "$free" "$disk" "$dot" "$score"
    v=""
    [ "$cores" -gt 0 ] && v+="$cores Kerne"
    [ "$mhz" -gt 0 ] && v+=" bis $((mhz / 1000)),$((mhz % 1000 / 100)) GHz"
    [ "$mem" -gt 0 ] && v+="${v:+, }$(rb_gb "$mem") GB RAM"
    [ "$free" -gt 0 ] && v+=" ($(rb_gb "$free") GB frei)"
    [ "$disk" -gt 0 ] && v+="${v:+, }$(rb_gb "$disk") GB Platz"
    [ -n "$score" ] && v+="${v:+, }Rechentest $score"
    printf 'SUMMARY=%s\n' "${v:-nicht messbar}"
    #           use    cores  free MB  disk MB  score (0: not judged)
    rb_perf_fit SPEAK  4      1024     1024     60
    rb_perf_fit S1     4      1024     512      60
    rb_perf_fit SKEJJA 2      512      512      0
}

# rb_gb <MB>: gigabytes with one decimal, German style (2,3)
rb_gb() { printf '%d,%d' $(($1 / 1024)) $(($1 % 1024 * 10 / 1024)); }

# rb_perf_fit <use> <cores> <free MB> <disk MB> <score>: the verdict of rb_perf for one use (reads its measured values). Below
# a value: tight; below half the cores or the memory, or below the space: no.
rb_perf_fit() {
    local why="" fit=yes text
    if [ "$cores" -gt 0 ] && [ "$cores" -lt "$2" ]; then
        why+="${why:+, }$cores Kerne (empfohlen $2)"; [ $((cores * 2)) -ge "$2" ] || fit=no
    fi
    if [ "$free" -gt 0 ] && [ "$free" -lt "$3" ]; then
        why+="${why:+, }$(rb_gb "$free") GB RAM frei (empfohlen $(rb_gb "$3"))"; [ $((free * 2)) -ge "$3" ] || fit=no
    fi
    if [ "$disk" -gt 0 ] && [ "$disk" -lt "$4" ]; then
        why+="${why:+, }$(rb_gb "$disk") GB Platz (empfohlen $(rb_gb "$4"))"; fit=no
    fi
    if [ "$5" -gt 0 ] && [ -n "$score" ] && [ "$score" -lt "$5" ]; then
        why+="${why:+, }langsam (Rechentest $score, empfohlen $5)"
    fi
    if [ "$fit" = yes ] && [ -n "$why" ]; then fit=tight; fi
    case "$fit" in
        yes) text=geeignet ;;
        tight) text="knapp: $why" ;;
        *) text="nicht geeignet: $why" ;;
    esac
    printf 'FIT_%s=%s\nTEXT_%s=%s\n' "$1" "$fit" "$1" "$text"
}
