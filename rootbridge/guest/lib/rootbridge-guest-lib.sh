# shellcheck shell=bash
# rootbridge-guest-lib.sh - helpers shared by the guest scripts of termux-rootbridge (androidsu, rootbridge-claude,
# rootbridge-codex, rootbridge-opencode, rootbridge-update, rootbridge-apt, rootbridge-open). Sourced, not run. Installed to
# /usr/local/lib/termux-rootbridge/ by install-guest.sh; the tests point ROOTBRIDGE_GUEST_LIB at the copy in the repo.

CONF="${ROOTBRIDGE_CONF:-/etc/termux-rootbridge.conf}"

# --- config (read as data, never sourced) -----------------------------------------------------------------------------
# conf_raw KEY: the value of KEY (the last one) with the quotes stripped; fails if the key is not there, even if its value
# is empty. Only sed and tail: the guest scripts also run with a minimal PATH.
conf_raw() {
    [ -r "$CONF" ] || return 1
    local v
    v="$(sed -n "s/^$1=/=/p" "$CONF" | tail -n 1)"      # "=value" when the key is there, even with an empty value
    [ -n "$v" ] || return 1
    v="${v#=}"
    v="${v%\"}"; v="${v#\"}"; v="${v%\'}"; v="${v#\'}"
    printf '%s' "$v"
}

# conf_get KEY: like conf_raw, but also fails if the value is empty
conf_get() {
    local v
    v="$(conf_raw "$1")" || return 1
    [ -n "$v" ] && printf '%s' "$v"
}

# --- file descriptor limit --------------------------------------------------------------------------------------------
# Claude Code closes every file descriptor up to RLIMIT_NOFILE after each fork. Under proot every close() is a trapped
# syscall (~80 us), so Android's limit of 32768 costs 2.5-4 s per started process (hooks, Bash tool, rg, ...). Bun raises
# the soft limit back to the hard one, so both go down. Only ever lowered, and only for Claude (callers run this in a
# subshell); NOFILE_LIMIT=0 in the config switches it off.
limit_nofile() {
    local n cur
    n="$(conf_get NOFILE_LIMIT || echo 2048)"
    case "$n" in ''|0|*[!0-9]*) return 0 ;; esac
    cur="$(ulimit -Hn)"
    case "$cur" in
        unlimited) ;;
        ''|*[!0-9]*) return 0 ;;
        *) [ "$cur" -gt "$n" ] || return 0 ;;
    esac
    ulimit -n "$n" 2>/dev/null || true
}

# --- "at most every N hours" steps (apt upgrade, claude update, codex update) -----------------------------------------
# update_interval MODE: print the minimum distance in seconds between two successful runs: 6h | <N>h (1-999) | daily |
# always (0 = at every start). Fails with 1 for "off" and with 2 for an unknown value (nothing is printed then).
update_interval() {
    case "$1" in
        off) return 1 ;;
        always) echo 0 ;;
        daily) echo 86400 ;;
        *) if [[ "$1" =~ ^[1-9][0-9]{0,2}h$ ]]; then echo $(( ${1%h} * 3600 )); else return 2; fi ;;
    esac
}

# stamp_age FILE: print the seconds since the last success noted in FILE; fails if there is no valid stamp
stamp_age() {
    local last now
    [ -r "$1" ] || return 1
    last="$(head -n 1 "$1" 2>/dev/null)"
    now="$(date +%s)"
    [[ "$last" =~ ^[0-9]{9,12}$ ]] && [ "$last" -le "$now" ] || return 1
    echo $(( now - last ))
}

# --- session entry points (rootbridge-claude, rootbridge-codex, rootbridge-opencode) ---------------------------------
# enter_workdir: the working directory of the session (WORKDIR from the config), /root if it is missing
enter_workdir() {
    cd "$(conf_get WORKDIR || echo /root/work)" 2>/dev/null || cd /root || exit 1
}

# run_maintenance: apt-get update + upgrade, then the updates of the tools (rootbridge-update). Each step decides by
# itself whether it is due, and none of them blocks the start.
run_maintenance() {
    if command -v rootbridge-apt >/dev/null 2>&1; then rootbridge-apt || true; fi
    if command -v rootbridge-update >/dev/null 2>&1; then rootbridge-update || true; fi
}

# after_tool NAME COMMAND CODE: after the tool ended. A clean end (quit = 0, Ctrl+C = 130) ends the script, so the tmux
# window (and, if it is the last one, the session and the widget's Termux window) close too. On an error the shell stays open.
after_tool() {
    case "$3" in 0|130) exit 0 ;; esac
    echo
    echo "$1 wurde mit Code $3 beendet. Neu starten mit: $2   (Shell bleibt offen)"
    exec bash -l
}
