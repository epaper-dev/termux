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
VOICE="on"              # on | off: voice dictation for Claude Code (sox, PulseAudio, microphone); install.sh --no-voice sets off
SIDEKEY="off"           # on | off: side key of the Hisense A9 as push to talk (sidekey-ptt); install.sh --sidekey sets on
AUTOSTART_DELAY=3
PTT_TARGET=""           # tmux target that `ptt` presses its key in (empty = "<SESSION>:claude")
PTT_KEY="M-k"           # tmux key name; Claude Code: "voice:pushToTalk" bound to meta+k in ~/.claude/keybindings.json
PTT_MODE="auto"         # auto | hold | tap: the mode of Claude Code's /voice (auto reads it from the settings of the guest); hold: `ptt start` repeats the key until `ptt stop`, tap: it presses the key once
PTT_INTERVAL=50         # milliseconds between the repeats of hold mode
PTT_WARMUP=1200         # milliseconds between the first key and the repeats of hold mode (Claude Code starts its recorder with the first key; under 2000)
PTT_MAX=120             # seconds after which hold mode / tap mode stop waiting for `ptt stop`
THEME_FOLLOW="on"       # on | off: "Auto epaper" follows light/dark (rootbridge theme)
THEME_RESTART="off"     # on | off: fallback, restart Claude Code (--continue) after a change
GUEST_ISOLATE="on"      # on | off: guest sessions see nothing of Termux but the bridge directory (proot-distro --isolated)

# Test hooks / binaries. Taken from the environment only, never from the
# config file, because the config file lies in a directory the guest can write.
RB_SU="${RB_SU:-su}"
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
            THEME_FOLLOW|THEME_RESTART|GUEST_ISOLATE|TOOL_CLAUDE|TOOL_CODEX|VOICE|SIDEKEY)
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
rb_login_opts() {
    local opts cookie="$HOME/.config/pulse/cookie"
    [ "$GUEST_ISOLATE" = on ] || return 0
    mkdir -p "$BRIDGE_DIR"
    opts="--isolated --bind $BRIDGE_DIR:$BRIDGE_DIR"
    if [ -d "$RB_STORAGE_DIR" ]; then opts="$opts --bind $RB_STORAGE_DIR:/sdcard --bind $RB_STORAGE_DIR:/storage/emulated/0"; fi
    if [ "$VOICE" = on ] && [ -r "$cookie" ]; then opts="$opts --bind $cookie:$cookie"; fi
    printf '%s' "$opts"
}

# --- who asks, and your answer -------------------------------------------------
# rb_requester <request id>: sets RB_AGENT ("Claude Code", "Codex" or "") and RB_AGENT_PID. The id starts with the pid of
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
# rb_speak_stop: end what the guest is reading aloud. Its player writes the id of its process group to speak.pid in the
# bridge directory (no pid namespace under proot). The guest can write there, so the pid only counts when that process is
# really the player ("speak.py --run"); the same check as player_pid() in speak.py. Only a regular file, read with a time
# limit: a FIFO there must not hold up `ptt start` before its key.
rb_speak_stop() {
    local pid f="$BRIDGE_DIR/speak.pid"
    [ -f "$f" ] && [ ! -L "$f" ] || return 0
    pid="$(timeout 1 head -c 16 "$f" 2>/dev/null | tr -d '[:space:]')"
    [[ "$pid" =~ ^[0-9]{1,9}$ ]] || return 0
    tr '\0' ' ' < "$RB_PROC_DIR/$pid/cmdline" 2>/dev/null | grep -q 'speak\.py --run' || return 0
    kill -TERM -- "-$pid" 2>/dev/null || true
}
