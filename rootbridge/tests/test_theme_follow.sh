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

mkdir -p "$T/bin" "$T/lib/termux-rootbridge" "$T/stubs" "$T/home/.config/termux-rootbridge"
sed "1s|^#!.*|#!$(command -v bash)|" "$ROOT/termux/bin/rootbridge" > "$T/bin/rootbridge"
cp "$ROOT/termux/lib/rootbridge-lib.sh" "$T/lib/termux-rootbridge/rootbridge-lib.sh"
cat > "$T/stubs/tmux" <<'EOF'
#!/bin/bash
echo "tmux $*" >> "$STUB_LOG"
[ "$1" = has-session ] && exit "${STUB_HAS_SESSION:-0}"
exit 0
EOF
chmod +x "$T/bin/rootbridge" "$T/stubs/tmux"
export STUB_LOG="$T/stub.log" BRIDGE_DIR="$T/bridge"
CONF="$T/home/.config/termux-rootbridge/config"
RFS="$T/prefix/var/lib/proot-distro/installed-rootfs/ubuntu"
EP="$RFS/root/.claude/themes/epaper.json"

rb() {   # rb <args...>: run the copied rootbridge; exit code in $RC
    : > "$STUB_LOG"
    env HOME="$T/home" PREFIX="$T/prefix" PATH="$T/stubs:$PATH" "$T/bin/rootbridge" "$@" > "$T/out.txt" 2>&1
    RC=$?
}
theme() {   # theme <base>: a theme file with "overrides": {} (the form earlier versions wrote)
    mkdir -p "$(dirname "$EP")"
    printf '%s\n' '{' '  "name": "Auto epaper",' "  \"base\": \"$1\"," '  "overrides": {}' '}' > "$EP"
}
fn_from() {   # fn_from <script>: the epaper_theme() function of a script as shell code (any indentation)
    awk '/^[[:space:]]*epaper_theme\(\) \{/ { on = 1; match($0, /^[[:space:]]*/); ind = RLENGTH }
         on { print }
         on && /^[[:space:]]*\}$/ { match($0, /^[[:space:]]*/); if (RLENGTH == ind) exit }' "$1"
}
file_from() {   # file_from <script> <base> [plain]: what that script's epaper_theme() writes
    ( eval "$(fn_from "$1")"; epaper_theme "$2" "${3:-}" )
}
canon() {   # canon <base>: the file as the guest installer writes it now (light-ansi with the shimmer override)
    mkdir -p "$(dirname "$EP")"
    file_from "$ROOT/guest/install-guest.sh" "$1" > "$EP"
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

# Auto epaper as the installer writes it now: light-ansi carries the shimmer override (Claude Code's
# inactiveShimmer is ansi:white = color7 there, hollow on white), dark-ansi and the other bases do not
SHIM='"inactiveShimmer": "ansi:black"'
canon light-ansi
check "Kanonisch light-ansi: Override vorhanden"          1 "$(grep -c "$SHIM" "$EP")"
canon dark-ansi
check "Kanonisch dark-ansi: kein Override"                0 "$(grep -c inactiveShimmer "$EP")"
canon light-ansi; rb theme dark
check "Kanonisch light-ansi + dark: Datei wie neu"        "0 $(file_from "$ROOT/guest/install-guest.sh" dark-ansi | cksum)" "$RC $(cksum < "$EP")"
check "dark-ansi: Override weg"                           0 "$(grep -c inactiveShimmer "$EP")"
rb theme light
check "dark-ansi + light: Override wieder da"             "0 $(file_from "$ROOT/guest/install-guest.sh" light-ansi | cksum)" "$RC $(cksum < "$EP")"
check "Kanonisch: Wechsel gültiges JSON"                  light-ansi "$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["base"])' "$EP")"
check "Kanonisch: Override im JSON"                       ansi:black "$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["overrides"]["inactiveShimmer"])' "$EP")"
check "Kanonisch: keine Temp-Datei übrig"                 0 "$(find "$(dirname "$EP")" -name '*.tmp.*' | wc -l)"

# the former form (light-ansi / dark-ansi with "overrides": {}) is rewritten whole as well
theme light-ansi; rb theme dark; rb theme light
check "Frühere Form: nach Hin und Zurück kanonisch"       "$(file_from "$ROOT/guest/install-guest.sh" light-ansi | cksum)" "$(cksum < "$EP")"
theme dark-ansi; rb theme light
check "Frühere Form dark-ansi + light: kanonisch"         "$(file_from "$ROOT/guest/install-guest.sh" light-ansi | cksum)" "$(cksum < "$EP")"
# the other bases keep "overrides": {} in both modes
theme light-daltonized; rb theme dark
check "daltonized: weiter ohne Override"                  0 "$(grep -c inactiveShimmer "$EP")"
# an own override next to the shimmer: only the base changes, the file stays yours
printf '%s\n' '{' '  "name": "Auto epaper",' '  "base": "light-ansi",' '  "overrides": {' '    "inactiveShimmer": "ansi:black",' '    "text": "ansi:blue"' '  }' '}' > "$EP"
rb theme dark
check "Eigene Overrides: nur die Basis wechselt"          "dark-ansi 1 1" "$(base) $(grep -c '"text": "ansi:blue"' "$EP") $(grep -c "$SHIM" "$EP")"

# rootbridge and the guest installer write the same bytes (and the extraction really found both functions)
check "epaper_theme in rootbridge gefunden"           1 "$(file_from "$ROOT/termux/bin/rootbridge" light-ansi | grep -c "$SHIM")"
check "epaper_theme im Gast-Installer gefunden"       1 "$(file_from "$ROOT/guest/install-guest.sh" light-ansi | grep -c "$SHIM")"
for b in light-ansi dark-ansi light dark light-daltonized dark-daltonized; do
    check "Gleiche Bytes ($b)"                            "$(file_from "$ROOT/guest/install-guest.sh" "$b" | cksum)" "$(file_from "$ROOT/termux/bin/rootbridge" "$b" | cksum)"
    check "Gleiche Bytes ($b, plain)"                     "$(file_from "$ROOT/guest/install-guest.sh" "$b" plain | cksum)" "$(file_from "$ROOT/termux/bin/rootbridge" "$b" plain | cksum)"
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
