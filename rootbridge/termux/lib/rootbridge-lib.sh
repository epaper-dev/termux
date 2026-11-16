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
PTT_MODE="hold"         # hold | tap: `ptt start` repeats the key until `ptt stop` (hold), or presses it once (tap)
PTT_INTERVAL=50         # milliseconds between the repeats of hold mode
PTT_MAX=120             # seconds after which hold mode / tap mode stop waiting for `ptt stop`
THEME_FOLLOW="on"       # on | off: "Auto epaper" follows light/dark (rootbridge theme)
THEME_RESTART="off"     # on | off: fallback, restart Claude Code (--continue) after a change
GUEST_ISOLATE="on"      # on | off: guest sessions see nothing of Termux but the bridge directory (proot-distro --isolated)

# Test hooks / binaries. Taken from the environment only, never from the
# config file, because the config file lies in a directory the guest can write.
RB_SU="${RB_SU:-su}"
RB_OPEN_CMD="${RB_OPEN_CMD:-termux-open-url}"
RB_CLIP_CMD="${RB_CLIP_CMD:-termux-clipboard-set}"
RB_ASK_CMD="${RB_ASK_CMD:-termux-dialog}"
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
                case "$val" in hold|tap) PTT_MODE="$val" ;; esac ;;
            PTT_INTERVAL)
                [[ "$val" =~ ^[0-9]{2,4}$ ]] && [ "$val" -ge 20 ] && PTT_INTERVAL="$val" ;;
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
# the androidsu that wrote the request (no pid namespace under proot); its ancestors show the agent. Only a hint for the
# dialog and for the event file, never a reason to allow anything.
rb_requester() {
    local pid="${1%%_*}" exe i
    RB_AGENT=""; RB_AGENT_PID=""
    for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16; do
        [[ "$pid" =~ ^[0-9]+$ ]] && [ "$pid" -gt 1 ] || return 0
        exe="$(readlink "$RB_PROC_DIR/$pid/exe" 2>/dev/null)"
        case "$exe" in
            */claude/versions/*|*/claude) RB_AGENT="Claude Code" ;;
            */codex) RB_AGENT="Codex" ;;
        esac
        if [ -n "$RB_AGENT" ]; then RB_AGENT_PID="$pid"; return 0; fi
        pid="$(sed -n 's/^PPid:[[:space:]]*//p' "$RB_PROC_DIR/$pid/status" 2>/dev/null)"
    done
}

# rb_ask <who> <command>: you decide in an Android dialog; the answer is the output of the dialog itself, not a file the
# guest could write. Returns 0 = yes, 1 = no, 2 = no answer in time, 3 = dialog failed (termux-api missing, ...).
# One dialog at a time: the lock lives in the private tmp directory of Termux, not in the bridge directory.
rb_ask() {
    local who="$1" cmd="$2" lock out rc
    lock="${TMPDIR:-/tmp}/rootbridge-ask.lock"
    until mkdir "$lock" 2>/dev/null; do
        # a lock left behind by a killed daemon
        if [ -n "$(find "$lock" -maxdepth 0 -mmin +$(( ASK_TIMEOUT / 60 + 2 )) 2>/dev/null)" ]; then rm -rf "$lock"; fi
        sleep 0.5
    done
    out="$(timeout "$ASK_TIMEOUT" "$RB_ASK_CMD" confirm -t "Android-Root: ${who:-Shell}" -i "$cmd" 2>/dev/null < /dev/null)"
    rc=$?
    rmdir "$lock" 2>/dev/null
    [ "$rc" -ne 124 ] || return 2
    [ "$rc" -eq 0 ] || return 3
    case "$out" in
        *'"text": "yes"'*|*'"text":"yes"'*) return 0 ;;
        *'"code"'*) return 1 ;;
    esac
    return 3
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
