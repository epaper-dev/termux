# shellcheck shell=bash
# shellcheck disable=SC2034  # the settings below are read by the scripts that source this file
# rootbridge-lib.sh - shared helpers of termux-root-bridge (sourced, not run).
# Used by rootbridge-daemon and the rootbridge CLI inside Termux.

# --- defaults ---------------------------------------------------------------
BRIDGE_DIR="${BRIDGE_DIR:-$HOME/.rootbridge}"
RB_CONFIG="${ROOTBRIDGE_CONFIG:-$HOME/.config/termux-root-bridge/config}"

DISTRO="ubuntu"
WORKDIR="/root/workspace"
SESSION="ubuntu"
TICKET_TTL=1800
STALE_TIMEOUT=70        # requests older than this were abandoned by androidsu
POLL_INTERVAL=0.5
SU_ARGS="-c"            # "-mm -c" = global mount namespace (Magisk)
AUTH_OPEN="auto"        # auto | copy | off   (used by the Claude hook)
CLAUDE_ARGS=""
AUTOSTART_DELAY=3

# Test hooks / binaries. Taken from the environment only, never from the
# config file, because the config file lies in a directory the guest can write.
RB_SU="${RB_SU:-su}"
RB_OPEN_CMD="${RB_OPEN_CMD:-termux-open-url}"
RB_CLIP_CMD="${RB_CLIP_CMD:-termux-clipboard-set}"

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
            TICKET_TTL|STALE_TIMEOUT|AUTOSTART_DELAY)
                [[ "$val" =~ ^[0-9]{1,6}$ ]] && printf -v "$key" '%s' "$val" ;;
            POLL_INTERVAL)
                [[ "$val" =~ ^[0-9]{1,2}(\.[0-9]{1,3})?$ ]] && POLL_INTERVAL="$val" ;;
            SU_ARGS)
                case "$val" in "-c"|"-mm -c") SU_ARGS="$val" ;; esac ;;
            AUTH_OPEN)
                case "$val" in auto|copy|off) AUTH_OPEN="$val" ;; esac ;;
            CLAUDE_ARGS)
                [[ "$val" =~ ^[A-Za-z0-9._\ =:/,-]*$ ]] && CLAUDE_ARGS="$val" ;;
        esac
    done < "$RB_CONFIG"
}

# --- small helpers ----------------------------------------------------------
rb_sha256() { printf '%s' "$1" | sha256sum | cut -d' ' -f1; }

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

# --- tickets ----------------------------------------------------------------
# Ticket file: line 1 = expiry (epoch), line 2 = sha256 of the command,
# line 3 = display text. Single use: claimed by an atomic rename.
RB_TICKET_REASON=""
rb_consume_ticket() {
    local tid="$1" want="$2" file claimed exp hash
    RB_TICKET_REASON="kein gültiges Ticket"
    [[ "$tid" =~ ^[0-9a-f]{32}$ ]] || return 1
    file="$BRIDGE_DIR/tickets/$tid"
    [ -f "$file" ] || { RB_TICKET_REASON="Ticket unbekannt oder schon benutzt"; return 1; }
    claimed="$file.used.$$"
    mv "$file" "$claimed" 2>/dev/null || { RB_TICKET_REASON="Ticket schon benutzt"; return 1; }
    { IFS= read -r exp; IFS= read -r hash; } < "$claimed"
    rm -f "$claimed"
    [[ "$exp" =~ ^[0-9]+$ ]] || { RB_TICKET_REASON="Ticket beschädigt"; return 1; }
    if [ "$(date +%s)" -gt "$exp" ]; then
        RB_TICKET_REASON="Ticket abgelaufen - Befehl in Claude Code neu bestätigen"
        return 1
    fi
    if [ "$hash" != "$want" ]; then
        RB_TICKET_REASON="Ticket gehört zu einem anderen Befehl"
        return 1
    fi
    return 0
}

# --- URLs -------------------------------------------------------------------
# Only plain https URLs, no whitespace/control/quote characters, <= 8 KiB.
RB_URL_RE='^https://[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?(:[0-9]{1,5})?([/?#][^[:space:][:cntrl:]"'"'"'<>`\\]*)?$'
rb_valid_url() {
    [ "${#1}" -le 8192 ] && [[ "$1" =~ $RB_URL_RE ]]
}
rb_url_host() {
    local h="${1#https://}"
    h="${h%%[/?#]*}"
    printf '%s' "${h%%:*}"
}
