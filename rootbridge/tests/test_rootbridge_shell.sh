#!/usr/bin/env bash
# Test: `rootbridge shell` is a plain guest shell - it must NOT create the tmux session / start Claude
# Code in the background (it used to: session_create ran rootbridge-claude, and leaving the shell with
# `exit` dropped the user into the Claude window). `rootbridge attach` still creates the session.
# Nothing real is touched: `rootbridge` and its lib are copied next to a stub daemon, `tmux` and
# `proot-distro` are stubs that only write a log line, fake HOME/PREFIX/BRIDGE_DIR.
#   bash tests/test_rootbridge_shell.sh
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

T="$(mktemp -d)"
# the stub daemon sleeps: stop exactly that process (by pid, never by name) and clean up
cleanup() {
    local p
    p="$(cat "$T/bridge/.lock/pid" 2>/dev/null)"
    [ -n "$p" ] && kill "$p" 2>/dev/null
    rm -rf "$T"
}
trap cleanup EXIT

PASS=0; FAIL=0
check() {   # check <name> <expected> <actual>
    if [ "$2" = "$3" ]; then PASS=$((PASS + 1)); printf 'ok    %s\n' "$1"
    else FAIL=$((FAIL + 1)); printf 'FAIL  %s\n      erwartet: %s\n      erhalten: %s\n' "$1" "$2" "$3"; fi
}

mkdir -p "$T/bin" "$T/lib/termux-rootbridge" "$T/stubs" "$T/home" "$T/prefix/bin"
# like install.sh: point the shebang at the real bash (`#!/usr/bin/env bash` does not work everywhere,
# e.g. /usr/bin/env of this proot guest is broken); the widget runs `rootbridge` directly
sed "1s|^#!.*|#!$(command -v bash)|" "$ROOT/termux/bin/rootbridge" > "$T/bin/rootbridge"
cp "$ROOT/termux/lib/rootbridge-lib.sh" "$T/lib/termux-rootbridge/rootbridge-lib.sh"
cat > "$T/bin/rootbridge-daemon" <<'EOF'
#!/bin/bash
# stub daemon: records its start, publishes pid and "alive" marker like the real one
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
cat > "$T/stubs/proot-distro" <<'EOF'
#!/bin/bash
echo "proot-distro $*" >> "$STUB_LOG"
exit 0
EOF
printf '#!/bin/bash\nexit 0\n' > "$T/stubs/termux-reload-settings"   # the widget calls it: never the real one
chmod +x "$T/bin/rootbridge" "$T/bin/rootbridge-daemon" "$T/stubs/tmux" "$T/stubs/proot-distro" "$T/stubs/termux-reload-settings"
export STUB_LOG="$T/stub.log" BRIDGE_DIR="$T/bridge"
: > "$STUB_LOG"

rb() {   # rb <args...> [with env STUB_HAS_SESSION]: run the copied rootbridge; exit code in $RC
    : > "$STUB_LOG"
    env HOME="$T/home" PREFIX="$T/prefix" PATH="$T/stubs:$PATH" "$@" > "$T/out.txt" 2>&1
    RC=$?
}
calls() { grep -c "$1" "$STUB_LOG" || true; }

# --- shell, daemon not running yet
rb bash "$T/bin/rootbridge" shell
check "shell: Exit 0"                                  0 "$RC"
check "shell: Daemon wird gestartet (für androidsu)"   1 "$(calls '^daemon-start$')"
check "shell: proot-distro login ubuntu, sonst nichts" "proot-distro login ubuntu" "$(grep '^proot-distro ' "$STUB_LOG")"
check "shell: kein Befehl hinter 'login ubuntu'"       0 "$(calls '^proot-distro login ubuntu --')"
check "shell: tmux wird nie aufgerufen"                0 "$(calls '^tmux ')"
check "shell: rootbridge-claude wird nie gestartet"    0 "$(calls 'rootbridge-claude')"

# --- shell again, daemon already running: not started twice
rb bash "$T/bin/rootbridge" shell
check "shell (Daemon läuft): kein zweiter Daemon"      0 "$(calls '^daemon-start$')"
check "shell (Daemon läuft): proot-distro login"       1 "$(calls '^proot-distro login ubuntu$')"
check "shell (Daemon läuft): tmux nie aufgerufen"      0 "$(calls '^tmux ')"

# --- shell while a Claude session is running: it stays untouched (no new window, no attach)
rb env STUB_HAS_SESSION=0 bash "$T/bin/rootbridge" shell
check "shell bei laufender Sitzung: tmux nie aufgerufen" 0 "$(calls '^tmux ')"
check "shell bei laufender Sitzung: eigene Shell"      1 "$(calls '^proot-distro login ubuntu$')"

# --- attach still creates the session (with Claude) and attaches
rb bash "$T/bin/rootbridge" attach
check "attach: Exit 0"                                 0 "$RC"
check "attach: legt die Sitzung mit rootbridge-claude an" 1 "$(calls '^tmux new-session -d -s ubuntu -n claude proot-distro login ubuntu -- /usr/local/bin/rootbridge-claude$')"
check "attach: hängt sich an"                          1 "$(calls '^tmux attach -t ubuntu$')"

rb env STUB_HAS_SESSION=0 bash "$T/bin/rootbridge" attach
check "attach bei laufender Sitzung: keine neue Sitzung" 0 "$(calls '^tmux new-session')"
check "attach bei laufender Sitzung: hängt sich an"    1 "$(calls '^tmux attach -t ubuntu$')"

# --- help text and widget
check "help nennt: shell startet Claude Code nicht"    1 "$(bash "$T/bin/rootbridge" help 2>&1 | grep -c 'does not start Claude Code')"
# the widget runs `exec rootbridge shell` through PATH: put the copy under test in front of any installed one
rb env PATH="$T/bin:$T/stubs:$PATH" bash "$ROOT/termux/shortcuts/ubuntu"
check "Widget 'ubuntu': nur proot-distro login"     "proot-distro login ubuntu" "$(grep '^proot-distro ' "$STUB_LOG")"
check "Widget 'ubuntu': tmux nie aufgerufen"        0 "$(calls '^tmux ')"

echo
echo "Ergebnis: $PASS bestanden, $FAIL fehlgeschlagen"
[ "$FAIL" -eq 0 ]
