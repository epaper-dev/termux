#!/usr/bin/env bash
# Test: `rootbridge shell` is a plain guest shell - it must NOT create the tmux session / start Claude
# Code in the background (it used to: session_create ran rootbridge-claude, and leaving the shell with
# `exit` dropped the user into the Claude window). `rootbridge attach` still creates the session.
# Nothing real is touched: `rootbridge` and its lib are copied next to a stub daemon, `tmux` and
# `proot-distro` are stubs that only write a log line, fake HOME/PREFIX/BRIDGE_DIR.
#   bash tests/test_rootbridge_shell.sh
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib.sh
. "$ROOT/tests/lib.sh"

T="$(mktemp -d)"
# the stub daemon sleeps: stop exactly that process (by pid, never by name) and clean up
cleanup() {
    local p
    p="$(cat "$T/bridge/.lock/pid" 2>/dev/null)"
    [ -n "$p" ] && kill "$p" 2>/dev/null
    rm -rf "$T"
}
trap cleanup EXIT


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
if [ "$1" = list-clients ]; then
    [ -z "${STUB_LIST_FAIL:-}" ] || { echo "no server running" >&2; exit 1; }
    [ -z "${STUB_CLIENTS:-}" ] || echo "0 /dev/pts/9"
    [ -z "${STUB_CONTROL:-}" ] || echo "1 /dev/pts/ctl"
fi
exit 0
EOF
cat > "$T/stubs/proot-distro" <<'EOF'
#!/bin/bash
echo "proot-distro $*" >> "$STUB_LOG"
exit 0
EOF
printf '#!/bin/bash\nexit 0\n' > "$T/stubs/termux-reload-settings"   # the widget calls it: never the real one
# attach runs `rootbridge voice start`, which ends PulseAudio servers it does not know: on a machine with PulseAudio (Termux) the
# real programs would end (or start) the real server, so pulseaudio, pgrep and pkill are stubs that do nothing here
for c in pulseaudio pgrep pkill; do printf '#!/bin/bash\nexit 1\n' > "$T/stubs/$c"; done
chmod +x "$T/bin/rootbridge" "$T/bin/rootbridge-daemon" "$T/stubs/tmux" "$T/stubs/proot-distro" "$T/stubs/termux-reload-settings" "$T/stubs/pulseaudio" "$T/stubs/pgrep" "$T/stubs/pkill"
export STUB_LOG="$T/stub.log" BRIDGE_DIR="$T/bridge"
export RB_STORAGE_DIR="$T/no-storage"   # the shared storage of the machine must not change what the tests expect
# guest sessions are isolated by default: nothing of Termux but the bridge directory (GUEST_ISOLATE)
ISO="--isolated --bind $T/bridge:$T/bridge"
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
check "shell: proot-distro login ubuntu (isoliert), sonst nichts" "proot-distro login ubuntu $ISO" "$(grep '^proot-distro ' "$STUB_LOG")"
check "shell: kein Befehl hinter 'login ubuntu'"       0 "$(calls '^proot-distro login ubuntu.* -- ')"
check "shell: tmux wird nie aufgerufen"                0 "$(calls '^tmux ')"
check "shell: rootbridge-claude wird nie gestartet"    0 "$(calls 'rootbridge-claude')"

# --- shell again, daemon already running: not started twice
rb bash "$T/bin/rootbridge" shell
check "shell (Daemon läuft): kein zweiter Daemon"      0 "$(calls '^daemon-start$')"
check "shell (Daemon läuft): proot-distro login"       1 "$(calls '^proot-distro login ubuntu '"$ISO"'$')"
check "shell (Daemon läuft): tmux nie aufgerufen"      0 "$(calls '^tmux ')"

# --- shell while a Claude session is running: it stays untouched (no new window, no attach)
rb env STUB_HAS_SESSION=0 bash "$T/bin/rootbridge" shell
check "shell bei laufender Sitzung: tmux nie aufgerufen" 0 "$(calls '^tmux ')"
check "shell bei laufender Sitzung: eigene Shell"      1 "$(calls '^proot-distro login ubuntu '"$ISO"'$')"

# --- attach still creates the session (with Claude) and attaches
rb bash "$T/bin/rootbridge" attach
check "attach: Exit 0"                                 0 "$RC"
check "attach: legt die Sitzung mit rootbridge-claude an" 1 "$(calls '^tmux new-session -d -s ubuntu -n claude proot-distro login ubuntu '"$ISO"' -- /usr/local/bin/rootbridge-claude$')"
check "attach: hängt sich an"                          1 "$(calls '^tmux attach -t =ubuntu$')"

rb env STUB_HAS_SESSION=0 bash "$T/bin/rootbridge" attach
check "attach bei laufender Sitzung: keine neue Sitzung" 0 "$(calls '^tmux new-session')"
check "attach bei laufender Sitzung: hängt sich an"    1 "$(calls '^tmux attach -t =ubuntu$')"

# --- a Termux session already shows the tmux session: the widget's new one takes over, the old one is detached
rb env STUB_HAS_SESSION=0 STUB_CLIENTS=1 STUB_CONTROL=1 bash "$T/bin/rootbridge" attach
check "attach, schon angehängt: Exit 0"                0 "$RC"
check "attach, schon angehängt: erst anhängen, dann das alte Fenster trennen" 1 "$(calls '^tmux attach -t =ubuntu ; detach-client -t /dev/pts/9$')"
check "attach, schon angehängt: der Steuer-Client bleibt" 0 "$(calls 'detach-client -t /dev/pts/ctl')"
check "attach, schon angehängt: kein getrenntes Fenster vor dem attach" 0 "$(calls '^tmux detach-client')"
rb env STUB_HAS_SESSION=0 STUB_CLIENTS=1 bash "$T/bin/rootbridge" attach codex
check "attach codex, schon angehängt: nur die Codex-Sitzung" 1 "$(calls '^tmux attach -t =ubuntu-codex ; detach-client -t /dev/pts/9$')"
check "attach codex: Claudes Sitzung wird nicht angefasst"    0 "$(calls '^tmux .*-t =ubuntu\($\|:\)')"
rb env STUB_HAS_SESSION=0 STUB_CONTROL=1 bash "$T/bin/rootbridge" attach
check "attach, nur ein Steuer-Client: nichts getrennt"  0 "$(calls 'detach-client')"
check "attach, nur ein Steuer-Client: hängt sich an"    1 "$(calls '^tmux attach -t =ubuntu$')"

rb env STUB_HAS_SESSION=0 STUB_LIST_FAIL=1 bash "$T/bin/rootbridge" attach
check "attach, Clients nicht lesbar: nichts getrennt, hängt sich an" 1 "$(calls '^tmux attach -t =ubuntu$')"
check "attach, Clients nicht lesbar: Warnung"          1 "$(grep -c 'Clients der Sitzung sind nicht lesbar' "$T/out.txt")"

# --- help text and widget
check "help nennt: shell startet Claude Code nicht"    1 "$(bash "$T/bin/rootbridge" help 2>&1 | grep -c 'does not start Claude Code')"
# the widget runs `exec rootbridge shell` through PATH: put the copy under test in front of any installed one
rb env PATH="$T/bin:$T/stubs:$PATH" bash "$ROOT/termux/shortcuts/ubuntu"
check "Widget 'ubuntu': nur proot-distro login"     "proot-distro login ubuntu $ISO" "$(grep '^proot-distro ' "$STUB_LOG")"
check "Widget 'ubuntu': tmux nie aufgerufen"        0 "$(calls '^tmux ')"



echo
finish
