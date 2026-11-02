#!/usr/bin/env bash
# Test: the claude() wrapper that guest/install-guest.sh writes into the guest ~/.bashrc.
# Installs into a staging root, sources the generated block and replaces `command`
# with a stub, so no real Claude Code (or anything else) is started.
#   bash tests/test_claude_wrapper.sh
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALLER="$ROOT/guest/install-guest.sh"

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
export ROOTBRIDGE_GUEST_HOME=/home/tester
STAGE="$T/stage"
BASHRC="$STAGE$ROOTBRIDGE_GUEST_HOME/.bashrc"

PASS=0; FAIL=0
check() {   # check <name> <expected> <actual>
    if [ "$2" = "$3" ]; then PASS=$((PASS + 1)); printf 'ok    %s\n' "$1"
    else FAIL=$((FAIL + 1)); printf 'FAIL  %s\n      erwartet: %s\n      erhalten: %s\n' "$1" "$2" "$3"; fi
}

bash "$INSTALLER" --root "$STAGE" --autonomous no > "$T/install.log" 2>&1
check "Installer läuft im Staging-Root" 0 "$?"
check "bashrc: Syntax in Ordnung" 0 "$(bash -n "$BASHRC" 2>/dev/null; echo $?)"

BLOCK="$(sed -n '/# >>> termux-root-bridge >>>/,/# <<< termux-root-bridge <<</p' "$BASHRC" 2>/dev/null)"
export BLOCK
if [ -z "$BLOCK" ]; then
    echo "ABBRUCH: kein claude()-Block im Staging-.bashrc gefunden, siehe $T/install.log:" >&2
    cat "$T/install.log" >&2
    exit 1
fi

# call <args...>: what would `command claude` receive? (conf comes from $ROOTBRIDGE_CONF)
# `command` is stubbed and `claude` has a harmless fallback, so the real Claude Code
# can never be started from here, even if the generated block is broken.
call() {
    bash -c 'command() { printf "%s" "$*"; }; claude() { printf "BLOCK-FEHLT"; }; eval "$BLOCK"; claude "$@"' _ "$@"
}
BASE="claude --allow-dangerously-skip-permissions"

conf() { printf '%s\n' "$@" > "$T/test.conf"; export ROOTBRIDGE_CONF="$T/test.conf"; }

conf 'WORKDIR=/root/workspace' 'CLAUDE_ARGS="--remote-control android --continue"'
check "Name aus CLAUDE_ARGS: claude"                "$BASE --remote-control android"                "$(call)"
check "--continue wird nicht übernommen"            "$BASE --remote-control android --continue"     "$(call --continue)"
check "claude --resume bekommt den Namen"           "$BASE --remote-control android --resume"       "$(call --resume)"
check "-p: kein Remote Control"                     "$BASE -p hi"                                   "$(call -p hi)"
check "--print: kein Remote Control"                "$BASE --print hi"                              "$(call --print hi)"
check "--version: kein Remote Control"              "$BASE --version"                               "$(call --version)"
check "--help: kein Remote Control"                 "$BASE --help"                                  "$(call --help)"
check "eigener Name hat Vorrang, nur einmal"        "$BASE --remote-control foo"                    "$(call --remote-control foo)"
check "Unterbefehl update unverändert"              "claude update"                                 "$(call update)"
check "Unterbefehl mcp unverändert"                 "claude mcp list"                               "$(call mcp list)"

conf 'CLAUDE_ARGS=--remote-control=node2'
check "Schreibweise --remote-control=name"          "$BASE --remote-control node2"                  "$(call)"

conf 'CLAUDE_ARGS="--remote-control a"' 'CLAUDE_ARGS="--remote-control b"'
check "mehrere Zeilen: die letzte gilt"             "$BASE --remote-control b"                      "$(call)"

conf 'CLAUDE_ARGS="--continue"'
check "CLAUDE_ARGS ohne Remote Control"             "$BASE"                                         "$(call)"
conf 'CLAUDE_ARGS="--remote-control --continue"'
check "--remote-control ohne Namen: nichts"         "$BASE"                                         "$(call)"
conf 'WORKDIR=/root/workspace'
check "Konfig ohne CLAUDE_ARGS"                     "$BASE"                                         "$(call)"
export ROOTBRIDGE_CONF="$T/gibt-es-nicht.conf"
check "Konfig fehlt"                                "$BASE"                                         "$(call)"

# idempotent: second run changes nothing and leaves exactly one block
before="$(cksum < "$BASHRC")"
baks() { find "$STAGE$ROOTBRIDGE_GUEST_HOME" -name '.bashrc.bak-*' | wc -l | tr -d ' '; }
baks_before="$(baks)"
bash "$INSTALLER" --root "$STAGE" --autonomous no > "$T/install2.log" 2>&1
check "zweiter Lauf: .bashrc unverändert"           "$before"                                       "$(cksum < "$BASHRC")"
check "zweiter Lauf: genau ein Block"               1 "$(grep -c '# >>> termux-root-bridge >>>' "$BASHRC")"
check "zweiter Lauf: keine neue .bashrc-Sicherung"  "$baks_before"                                  "$(baks)"

bash "$INSTALLER" --root "$STAGE" --uninstall > "$T/uninstall.log" 2>&1
check "Deinstallation entfernt den Block"           0 "$(grep -c 'termux-root-bridge' "$BASHRC")"

echo
echo "Ergebnis: $PASS bestanden, $FAIL fehlgeschlagen"
[ "$FAIL" -eq 0 ]
