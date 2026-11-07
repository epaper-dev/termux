#!/usr/bin/env bash
# Test: `rootbridge theme light|dark` (called by the tmux hooks client-light-theme / client-dark-theme)
# switches only the light/dark part of "base" in the guest's ~/.claude/themes/epaper.json ("Auto epaper"),
# keeps the variant (-daltonized, -ansi) and everything else, does nothing without the file or with
# THEME_FOLLOW=off, and restarts Claude Code (respawn-pane, --continue) only with THEME_RESTART=on.
# Also: the tmux snippet sets both hooks. Fake HOME/PREFIX, `tmux` is a stub that only logs.
#   bash tests/test_theme_follow.sh
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

PASS=0; FAIL=0
check() {   # check <name> <expected> <actual>
    if [ "$2" = "$3" ]; then PASS=$((PASS + 1)); printf 'ok    %s\n' "$1"
    else FAIL=$((FAIL + 1)); printf 'FAIL  %s\n      erwartet: %s\n      erhalten: %s\n' "$1" "$2" "$3"; fi
}

mkdir -p "$T/bin" "$T/lib/termux-root-bridge" "$T/stubs" "$T/home/.config/termux-root-bridge"
sed "1s|^#!.*|#!$(command -v bash)|" "$ROOT/termux/bin/rootbridge" > "$T/bin/rootbridge"
cp "$ROOT/termux/lib/rootbridge-lib.sh" "$T/lib/termux-root-bridge/rootbridge-lib.sh"
cat > "$T/stubs/tmux" <<'EOF'
#!/bin/bash
echo "tmux $*" >> "$STUB_LOG"
[ "$1" = has-session ] && exit "${STUB_HAS_SESSION:-0}"
exit 0
EOF
chmod +x "$T/bin/rootbridge" "$T/stubs/tmux"
export STUB_LOG="$T/stub.log" BRIDGE_DIR="$T/bridge"
CONF="$T/home/.config/termux-root-bridge/config"
RFS="$T/prefix/var/lib/proot-distro/installed-rootfs/ubuntu"
EP="$RFS/root/.claude/themes/epaper.json"

rb() {   # rb <args...>: run the copied rootbridge; exit code in $RC
    : > "$STUB_LOG"
    env HOME="$T/home" PREFIX="$T/prefix" PATH="$T/stubs:$PATH" "$T/bin/rootbridge" "$@" > "$T/out.txt" 2>&1
    RC=$?
}
theme() {   # theme <base>: a theme file like the guest installer writes it
    mkdir -p "$(dirname "$EP")"
    printf '%s\n' '{' '  "name": "Auto epaper",' "  \"base\": \"$1\"," '  "overrides": {}' '}' > "$EP"
}
base() { sed -n 's/.*"base"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$EP"; }

# no guest / no theme file: nothing happens, no error
rb theme dark
check "Ohne Gast: Exit 0"                       0 "$RC"
check "Ohne Gast: keine Ausgabe"                "" "$(cat "$T/out.txt")"
mkdir -p "$RFS/root"
rb theme dark
check "Ohne Theme-Datei: Exit 0"                0 "$RC"
check "Ohne Theme-Datei: keine Datei angelegt"  no "$([ -e "$EP" ] && echo yes || echo no)"

# every variant switches light <-> dark and keeps its variant
for pair in "light-daltonized dark dark-daltonized" "dark-daltonized light light-daltonized" \
            "light-ansi dark dark-ansi" "dark-ansi light light-ansi" "light dark dark" "dark light light"; do
    read -r from want to <<< "$pair"
    theme "$from"; rb theme "$want"
    check "$from + theme $want -> $to"          "0 $to" "$RC $(base)"
done

# already right: file not touched
theme dark-daltonized; before="$(cksum < "$EP")"; touch -d '2020-01-01' "$EP"
rb theme dark
check "Schon dunkel: Datei unverändert"         "$before 2020" "$(cksum < "$EP") $(date -r "$EP" +%Y)"

# the rest of the file stays (name, overrides, formatting)
printf '%s\n' '{"name":"Mein epaper","base": "light-ansi","overrides":{"text":"ansi:black","base":"x"}}' > "$EP"
rb theme dark
check "Rest der Datei bleibt"                   '{"name":"Mein epaper","base": "dark-ansi","overrides":{"text":"ansi:black","base":"x"}}' "$(cat "$EP")"
check "Keine Temp-Datei übrig"                  0 "$(find "$(dirname "$EP")" -name '*.tmp.*' | wc -l)"

# unknown base: untouched
printf '%s\n' '{"name":"x","base":"neon","overrides":{}}' > "$EP"; before="$(cksum < "$EP")"
rb theme dark
check "Unbekannte Basis: unverändert"           "0 $before" "$RC $(cksum < "$EP")"

# wrong argument
rb theme
check "Ohne Argument: Exit 1"                   1 "$RC"
rb theme blue
check "Falsches Argument: Exit 1"               1 "$RC"

# default: no restart
theme light-daltonized; rb theme dark
check "Standard: kein Neustart"                 0 "$(grep -c 'respawn-pane' "$STUB_LOG")"

# THEME_RESTART=on: Claude Code restarts with --continue, but only on a change
printf 'THEME_RESTART=on\n' > "$CONF"
theme light-daltonized; rb theme dark
check "THEME_RESTART=on: Neustart"              1 "$(grep -c 'respawn-pane -k -t ubuntu:claude proot-distro login ubuntu -- /usr/local/bin/rootbridge-claude --continue' "$STUB_LOG")"
rb theme dark
check "THEME_RESTART=on: ohne Wechsel kein Neustart" 0 "$(grep -c 'respawn-pane' "$STUB_LOG")"
theme light-daltonized; STUB_HAS_SESSION=1 rb theme dark
check "THEME_RESTART=on: ohne Session kein Neustart" "dark-daltonized 0" "$(base) $(grep -c 'respawn-pane' "$STUB_LOG")"

# THEME_FOLLOW=off: nothing changes
printf 'THEME_FOLLOW=off\nTHEME_RESTART=on\n' > "$CONF"
theme light-daltonized; rb theme dark
check "THEME_FOLLOW=off: unverändert"           "0 light-daltonized 0" "$RC $(base) $(grep -c 'respawn-pane' "$STUB_LOG")"
printf 'THEME_FOLLOW=maybe\n' > "$CONF"
rb theme dark
check "Ungültiger Wert: Standard (folgt)"       dark-daltonized "$(base)"

# the tmux snippet sets both hooks
check "tmux: Hook hell"   1 "$(grep -c "^set-hook -g client-light-theme 'run-shell -b \"rootbridge theme light\"'$" "$ROOT/termux/tmux.conf.snippet")"
check "tmux: Hook dunkel" 1 "$(grep -c "^set-hook -g client-dark-theme 'run-shell -b \"rootbridge theme dark\"'$" "$ROOT/termux/tmux.conf.snippet")"

# the status line uses the terminal colours
check "tmux: Statusleiste in Terminalfarben" 1 "$(grep -c '^set -g status-style default$' "$ROOT/termux/tmux.conf.snippet")"
check "tmux: aktives Fenster fett"          1 "$(grep -c '^set -g window-status-current-style bold$' "$ROOT/termux/tmux.conf.snippet")"

# rootbridge-claude passes --continue on to Claude Code
check "rootbridge-claude: --continue" 1 "$(grep -c '^\[ "${1:-}" = --continue \] && extra+=(--continue)$' "$ROOT/guest/bin/rootbridge-claude")"

echo
echo "Ergebnis: $PASS bestanden, $FAIL fehlgeschlagen"
[ "$FAIL" = 0 ]
