#!/usr/bin/env bash
# Test: NOFILE_LIMIT - Claude Code is started with a lower file-descriptor limit.
#
# Why: Claude Code closes every fd up to RLIMIT_NOFILE after each fork. Under proot every close() is a
# trapped syscall, so Android's limit of 32768 costs 2.5-4 s per started process (hooks, Bash tool, ...).
#
# Nothing real is started: from guest/bin/rootbridge-claude only the functions conf_get/limit_nofile are
# cut out (the script itself never runs - it would start `claude update` and rootbridge-apt), and the
# claude() function of the generated .bashrc gets a stubbed `command`.
#   bash tests/test_nofile_limit.sh
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/guest/bin/rootbridge-claude"
UPDATER="$ROOT/guest/bin/rootbridge-update"
INSTALLER="$ROOT/guest/install-guest.sh"

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

PASS=0; FAIL=0
check() {   # check <name> <expected> <actual>
    if [ "$2" = "$3" ]; then PASS=$((PASS + 1)); printf 'ok    %s\n' "$1"
    else FAIL=$((FAIL + 1)); printf 'FAIL  %s\n      erwartet: %s\n      erhalten: %s\n' "$1" "$2" "$3"; fi
}

# The tests start from a limit they can lower from: 8192, or the machine's hard limit if that is lower
# (a session started by rootbridge-claude already runs with NOFILE_LIMIT, and a hard limit cannot be
# raised again). w N = what a run with NOFILE_LIMIT=N has to end up with: N if that is below START,
# otherwise START (limits are only ever lowered).
HARD="$(ulimit -Hn)"
case "$HARD" in
    unlimited) START=8192 ;;
    ''|*[!0-9]*) echo "ABBRUCH: ulimit -Hn liefert '$HARD'." >&2; exit 1 ;;
    *) START=$(( HARD < 8192 ? HARD : 8192 )) ;;
esac
w() { if [ "$START" -gt "$1" ]; then echo "$1"; else echo "$START"; fi; }
if ! bash -c "ulimit -n $START" 2>/dev/null; then
    echo "ABBRUCH: ulimit -n $START ist hier nicht setzbar." >&2
    exit 1
fi
if [ "$START" -le 2048 ]; then
    echo "Hinweis: Hard-Limit hier nur $HARD - das Absenken auf 2048 ist so nicht zu beobachten (voll prüfbar"
    echo "         außerhalb einer Claude-Sitzung und in der CI); Werte unter $START und 'nie erhöhen' schon."
fi

conf() { printf '%s\n' "$@" > "$T/test.conf"; export ROOTBRIDGE_CONF="$T/test.conf"; }

# ---------------------------------------------------------------- guest/bin/rootbridge-claude
bash -n "$SCRIPT" 2>/dev/null
check "rootbridge-claude: Syntax in Ordnung" 0 "$?"

FUNCS="$(sed -n '/^conf_get() {/,/^}/p;/^limit_nofile() {/,/^}/p' "$SCRIPT")"
export FUNCS
case "$FUNCS" in
    *"limit_nofile()"*"conf_get()"*|*"conf_get()"*"limit_nofile()"*) ;;
    *) echo "ABBRUCH: conf_get/limit_nofile nicht in $SCRIPT gefunden." >&2; exit 1 ;;
esac

# lim: <soft>/<hard> inside the subshell that limit_nofile runs in, and in the parent shell afterwards
lim() {
    bash -c 'ulimit -n '"$START"'; CONF="$1"; eval "$FUNCS"
             sub="$( limit_nofile; echo "$(ulimit -Sn)/$(ulimit -Hn)" )"
             echo "$sub parent=$(ulimit -Sn)/$(ulimit -Hn)"' _ "$1"
}
P="parent=$START/$START"

conf 'WORKDIR=/root/workspace'
check "ohne NOFILE_LIMIT: Standard 2048"             "$(w 2048)/$(w 2048) $P"  "$(lim "$T/test.conf")"
check "Konfig fehlt: Standard 2048"                  "$(w 2048)/$(w 2048) $P"  "$(lim "$T/gibt-es-nicht.conf")"
conf 'NOFILE_LIMIT=1024'
check "NOFILE_LIMIT=1024"                            "$(w 1024)/$(w 1024) $P"  "$(lim "$T/test.conf")"
conf 'NOFILE_LIMIT="4096"'
check "NOFILE_LIMIT=\"4096\" (in Anführungszeichen)" "$(w 4096)/$(w 4096) $P"  "$(lim "$T/test.conf")"
conf 'NOFILE_LIMIT=1024' 'NOFILE_LIMIT=3000'
check "mehrere Zeilen: die letzte gilt"              "$(w 3000)/$(w 3000) $P"  "$(lim "$T/test.conf")"
conf 'NOFILE_LIMIT=0'
check "NOFILE_LIMIT=0: nichts ändern"                "$START/$START $P" "$(lim "$T/test.conf")"
conf 'NOFILE_LIMIT=abc'
check "NOFILE_LIMIT=abc: nichts ändern"              "$START/$START $P" "$(lim "$T/test.conf")"
conf 'NOFILE_LIMIT=16384'
check "Limit über dem aktuellen: nie erhöhen"        "$START/$START $P" "$(lim "$T/test.conf")"
conf 'NOFILE_LIMIT='
check "NOFILE_LIMIT leer: Standard 2048"             "$(w 2048)/$(w 2048) $P"  "$(lim "$T/test.conf")"

# Both claude starts of the script go through limit_nofile (in a subshell, so the shell afterwards keeps its limit)
check "claude update läuft über limit_nofile"        1 "$(grep -c 'limit_nofile; exec timeout 180 "\$claude_bin" update' "$UPDATER")"
check "Claude-Start läuft über limit_nofile"         1 "$(grep -c 'limit_nofile; exec "\$claude_bin" --allow-dangerously-skip-permissions' "$SCRIPT")"

# ---------------------------------------------------------------- claude() in the generated ~/.bashrc
export ROOTBRIDGE_GUEST_HOME=/home/tester
STAGE="$T/stage"
BASHRC="$STAGE$ROOTBRIDGE_GUEST_HOME/.bashrc"
STAGED_CONF="$STAGE/etc/termux-rootbridge.conf"

bash "$INSTALLER" --root "$STAGE" --autonomous no > "$T/install.log" 2>&1
check "Installer läuft im Staging-Root" 0 "$?"
check "bashrc: Syntax in Ordnung" 0 "$(bash -n "$BASHRC" 2>/dev/null; echo $?)"
check "Installer schreibt NOFILE_LIMIT=2048 in die Konfig" 1 "$(grep -c '^NOFILE_LIMIT=2048$' "$STAGED_CONF" 2>/dev/null)"

BLOCK="$(sed -n '/# >>> termux-rootbridge >>>/,/# <<< termux-rootbridge <<</p' "$BASHRC" 2>/dev/null)"
export BLOCK
if [ -z "$BLOCK" ]; then
    echo "ABBRUCH: kein claude()-Block im Staging-.bashrc gefunden, siehe $T/install.log:" >&2
    cat "$T/install.log" >&2
    exit 1
fi

# call <args...>: what would `command claude` receive, and with which limits? `command` is stubbed and
# `claude` has a harmless fallback, so the real Claude Code can never be started from here.
call() {
    bash -c 'ulimit -n '"$START"'
             command() { printf "%s hard=%s soft=%s" "$*" "$(ulimit -Hn)" "$(ulimit -Sn)"; }
             claude() { printf "BLOCK-FEHLT"; }
             eval "$BLOCK"; claude "$@"' _ "$@"
}
BASE="claude --allow-dangerously-skip-permissions"

conf 'WORKDIR=/root/workspace'
check "claude(): Standard 2048"                      "$BASE hard=$(w 2048) soft=$(w 2048)" "$(call)"
check "claude update: ebenfalls 2048"                "claude update hard=$(w 2048) soft=$(w 2048)" "$(call update)"
check "claude -p: ebenfalls 2048"                    "$BASE -p hi hard=$(w 2048) soft=$(w 2048)" "$(call -p hi)"
export ROOTBRIDGE_CONF="$T/gibt-es-nicht.conf"
check "claude(): Konfig fehlt, Standard 2048"        "$BASE hard=$(w 2048) soft=$(w 2048)" "$(call)"
conf 'NOFILE_LIMIT=1024'
check "claude(): NOFILE_LIMIT=1024"                  "$BASE hard=$(w 1024) soft=$(w 1024)" "$(call)"
conf 'NOFILE_LIMIT="4096"'
check "claude(): NOFILE_LIMIT=\"4096\""              "$BASE hard=$(w 4096) soft=$(w 4096)" "$(call)"
conf 'NOFILE_LIMIT='"'"'3000'"'"
check "claude(): NOFILE_LIMIT='3000'"                "$BASE hard=$(w 3000) soft=$(w 3000)" "$(call)"
conf 'NOFILE_LIMIT=0'
check "claude(): NOFILE_LIMIT=0 ändert nichts"       "$BASE hard=$START soft=$START" "$(call)"
conf 'NOFILE_LIMIT=abc'
check "claude(): NOFILE_LIMIT=abc ändert nichts"     "$BASE hard=$START soft=$START" "$(call)"
conf 'NOFILE_LIMIT=16384'
check "claude(): Limit über dem aktuellen, nie erhöhen" "$BASE hard=$START soft=$START" "$(call)"

# the interactive shell keeps its limit, and claude's exit status comes through
conf 'WORKDIR=/root/workspace'
after="$(bash -c 'ulimit -n '"$START"'; command() { :; }; eval "$BLOCK"; claude >/dev/null; echo "$(ulimit -Sn)/$(ulimit -Hn)"')"
check "Shell behält ihr Limit nach claude()"         "$START/$START" "$after"
status="$(bash -c 'command() { return 7; }; eval "$BLOCK"; claude; echo $?' 2>/dev/null)"
check "Exit-Status von claude kommt durch"           7 "$status"

# the second installer run keeps the user's value
sed -i 's/^NOFILE_LIMIT=.*/NOFILE_LIMIT=1024/' "$STAGED_CONF"
bash "$INSTALLER" --root "$STAGE" --autonomous no > "$T/install2.log" 2>&1
check "zweiter Lauf behält den eigenen Wert"         1 "$(grep -c '^NOFILE_LIMIT=1024$' "$STAGED_CONF")"
check "zweiter Lauf: NOFILE_LIMIT nur einmal"        1 "$(grep -c '^NOFILE_LIMIT=' "$STAGED_CONF")"

echo
echo "Ergebnis: $PASS bestanden, $FAIL fehlgeschlagen"
[ "$FAIL" -eq 0 ]
