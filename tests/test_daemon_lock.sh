#!/usr/bin/env bash
# Test: the daemon lock. Leaked daemons happened because (1) install.sh deleted the lock of a RUNNING
# daemon on every run, so the next `rootbridge start` spawned a second one while the old one kept
# polling, and (2) a daemon's cleanup removed the lock even when a successor owned it.
#   1. real rootbridge-daemon loop in a temp BRIDGE_DIR: own lock only, leftover daemons stop themselves,
#      a vanished lock is taken again, a stale lock is taken over
#   2. install.sh (migration step): keeps the lock of a live daemon, removes leftovers
# Nothing real is touched: temp BRIDGE_DIR/HOME/PREFIX, `pkill`/`pgrep`/`tmux` are logging stubs, and the
# processes the test starts are stopped by their pid (never by name).
#   bash tests/test_daemon_lock.sh
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DAEMON="$ROOT/termux/bin/rootbridge-daemon"
INSTALL="$ROOT/install.sh"

T="$(mktemp -d)"
PIDS=()
trap 'for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null; done; rm -rf "$T"' EXIT

PASS=0; FAIL=0
check() {   # check <name> <expected> <actual>
    if [ "$2" = "$3" ]; then PASS=$((PASS + 1)); printf 'ok    %s\n' "$1"
    else FAIL=$((FAIL + 1)); printf 'FAIL  %s\n      erwartet: %s\n      erhalten: %s\n' "$1" "$2" "$3"; fi
}

# a zombie still answers `kill -0`: look at the process state instead
alive() { local s; s="$(ps -o stat= -p "$1" 2>/dev/null)"; [ -n "$s" ] && [ "${s#Z}" = "$s" ]; }
wait_until() {   # wait_until <seconds> <cmd...>: poll every 0.1 s
    local n=$(( $1 * 10 )); shift
    while [ "$n" -gt 0 ]; do "$@" && return 0; sleep 0.1; n=$((n - 1)); done
    return 1
}
sleeper() { sleep 300 & SLEEPER=$!; PIDS+=("$SLEEPER"); }   # a harmless live process with a known pid
dead_pid() { true & local p=$!; wait "$p"; echo "$p"; }

# ------------------------------------------------------------ 1. the daemon loop
mkdir -p "$T/home/.config/termux-root-bridge" "$T/bridge"
printf 'POLL_INTERVAL=0.2\n' > "$T/home/.config/termux-root-bridge/config"
export HOME="$T/home" BRIDGE_DIR="$T/bridge" ROOTBRIDGE_CONFIG="$T/home/.config/termux-root-bridge/config"
export RB_SU="$T/no-su" RB_OPEN_CMD="$T/no-open" RB_CLIP_CMD="$T/no-clip" TERMUX_BIN="$T/no-termux-bin"
LOCK="$BRIDGE_DIR/.lock"
lock_pid() { cat "$LOCK/pid" 2>/dev/null; }
lock_is() { [ "$(lock_pid)" = "$1" ]; }
dead() { ! alive "$1"; }
start_daemon() {   # start_daemon: DPID = pid of a new daemon, waits until it owns the lock
    bash "$DAEMON" >> "$T/daemon.log" 2>&1 < /dev/null &
    DPID=$!; PIDS+=("$DPID")
    wait_until 5 lock_is "$DPID"
}

start_daemon
check "Daemon A startet und besitzt das Lock"          "$DPID" "$(lock_pid)"
A="$DPID"
wait_until 5 test -e "$BRIDGE_DIR/.alive"
check "Daemon A schreibt den Herzschlag"               ja "$([ -e "$BRIDGE_DIR/.alive" ] && echo ja || echo nein)"

out="$(bash "$DAEMON" 2>&1)"; code=$?
check "Zweiter Start bei laufendem Daemon: Exit 0"     0 "$code"
check "Zweiter Start: meldet 'läuft bereits'"          1 "$(printf '%s\n' "$out" | grep -c 'läuft bereits')"
check "Zweiter Start: Lock bleibt bei A"               "$A" "$(lock_pid)"
check "Zweiter Start: A läuft weiter"                  ja "$(alive "$A" && echo ja || echo nein)"

# a newer owner takes over the lock: the old daemon must notice and stop, and must NOT delete the new lock
sleeper; B="$SLEEPER"
echo "$B" > "$LOCK/pid"
wait_until 5 dead "$A"
check "Lock gehört einem Nachfolger: A beendet sich"   nein "$(alive "$A" && echo ja || echo nein)"
check "Lock des Nachfolgers bleibt erhalten"           "$B" "$(lock_pid)"
check "A meldet den Grund im Log"                      1 "$(grep -c 'Lock gehört einem anderen Daemon' "$T/daemon.log")"
wait "$A" 2>/dev/null

# the lock vanished (an installer run deleted it): the daemon takes it again and keeps running
kill "$B" 2>/dev/null; rm -rf "$LOCK"
start_daemon; C="$DPID"
rm -rf "$LOCK"
wait_until 5 lock_is "$C"
check "Lock gelöscht: C nimmt es sich wieder"          "$C" "$(lock_pid)"
check "Lock gelöscht: C läuft weiter"                  ja "$(alive "$C" && echo ja || echo nein)"

# a normal stop removes its own lock
kill -TERM "$C"; wait "$C" 2>/dev/null
check "TERM: eigenes Lock wird entfernt"               nein "$([ -e "$LOCK" ] && echo ja || echo nein)"

# TERM while a successor owns the lock: the successor's lock must survive
start_daemon; D="$DPID"
sleeper; E="$SLEEPER"
echo "$E" > "$LOCK/pid"
kill -TERM "$D"; wait "$D" 2>/dev/null
check "TERM bei fremdem Lock: Lock des Nachfolgers bleibt" "$E" "$(lock_pid)"
kill "$E" 2>/dev/null; rm -rf "$LOCK"

# a stale lock (dead pid) is still taken over
mkdir -p "$LOCK"; dead_pid > "$LOCK/pid"
start_daemon; F="$DPID"
check "Veraltetes Lock (toter Prozess): F übernimmt"   "$F" "$(lock_pid)"
kill -TERM "$F"; wait "$F" 2>/dev/null

# ------------------------------------------------ 2. install.sh keeps a live lock
H="$T/ihome"; P="$T/prefix"; BR="$H/.rootbridge"
mkdir -p "$H" "$P/bin" "$T/stubs"
for s in pkill pgrep tmux; do   # install.sh's v1 migration would call these: logging stubs only
    printf '#!/bin/bash\necho "%s $*" >> "$STUB_LOG"\nexit 1\n' "$s" > "$T/stubs/$s"
done
chmod +x "$T/stubs"/*
export STUB_LOG="$T/stub.log"; : > "$STUB_LOG"
inst() {   # inst: install.sh with the migration step (no guest, no colours, no deps check)
    HOME="$H" PREFIX="$P" PATH="$T/stubs:$PATH" ROOTBRIDGE_ALLOW_GUEST=1 BRIDGE_DIR="$BR" \
        bash "$INSTALL" --no-guest --no-boot --no-colors --no-deps-check --no-extra-keys > "$T/install.log" 2>&1
}

mkdir -p "$BR/.lock"; sleeper; L="$SLEEPER"; echo "$L" > "$BR/.lock/pid"
: > "$BR/req-old.txt"
inst
check "install.sh (Daemon läuft): Exit 0"              0 "$?"
check "install.sh (Daemon läuft): Lock bleibt"         "$L" "$(cat "$BR/.lock/pid" 2>/dev/null)"
check "install.sh: alte Anfragen werden weiter geräumt" nein "$([ -e "$BR/req-old.txt" ] && echo ja || echo nein)"
inst
check "install.sh zweimal: Lock bleibt"                "$L" "$(cat "$BR/.lock/pid" 2>/dev/null)"

dead_pid > "$BR/.lock/pid"
inst
check "install.sh (toter Prozess im Lock): Lock weg"   nein "$([ -e "$BR/.lock" ] && echo ja || echo nein)"

mkdir -p "$BR/.lock"          # v1 leftover: a lock directory without a pid file
inst
check "install.sh (Lock ohne pid, v1-Rest): Lock weg"  nein "$([ -e "$BR/.lock" ] && echo ja || echo nein)"

inst
check "install.sh (kein Lock): Exit 0"                 0 "$?"
check "install.sh: kein pkill/pgrep/tmux nötig"        0 "$(grep -c '^pkill\|^tmux' "$STUB_LOG")"

echo
echo "Ergebnis: $PASS bestanden, $FAIL fehlgeschlagen"
[ "$FAIL" -eq 0 ]
