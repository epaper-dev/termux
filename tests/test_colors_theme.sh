#!/usr/bin/env bash
# Test: light colour scheme (~/.termux/colors.properties), reload at every start and the
# Claude Code theme.
#   1. guest installer: --theme writes "theme" into ~/.claude/settings.json (staging root)
#   2. install.sh with a fake HOME/PREFIX: colors.properties, reload, --no-colors, --theme hand-over
#   3. the autostart block in ~/.bashrc: reload comes BEFORE `rootbridge start`
#   4. Termux:Widget shortcuts reload first
# Nothing real is touched: fake HOME/PREFIX, `proot-distro`, `termux-reload-settings` and
# `rootbridge` are stubs that only write a log line (no pkill/tmux/clipboard, --no-migrate).
#   bash tests/test_colors_theme.sh
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GUEST="$ROOT/guest/install-guest.sh"
INSTALL="$ROOT/install.sh"
COLORS="$ROOT/termux/colors.properties"

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
export ROOTBRIDGE_GUEST_HOME=/home/tester

PASS=0; FAIL=0
check() {   # check <name> <expected> <actual>
    if [ "$2" = "$3" ]; then PASS=$((PASS + 1)); printf 'ok    %s\n' "$1"
    else FAIL=$((FAIL + 1)); printf 'FAIL  %s\n      erwartet: %s\n      erhalten: %s\n' "$1" "$2" "$3"; fi
}

jget() {   # jget <file> <key>: value of a top-level key ("-" if missing / unreadable)
    python3 -I - "$1" "$2" <<'PY'
import json, sys
try:
    print(json.load(open(sys.argv[1], encoding="utf-8")).get(sys.argv[2], "-"))
except (OSError, ValueError):
    print("-")
PY
}

# ------------------------------------------------------------ 1. guest installer
settings() { printf '%s' "$1$ROOTBRIDGE_GUEST_HOME/.claude/settings.json"; }
baks() { find "$1$ROOTBRIDGE_GUEST_HOME/.claude" -name 'settings.json.bak-*' 2>/dev/null | wc -l | tr -d ' '; }
ginstall() {  # ginstall <stage> [args...]  (quiet; output in $T/guest.log)
    local stage="$1"; shift
    bash "$GUEST" --root "$stage" --autonomous no "$@" > "$T/guest.log" 2>&1
}

S="$T/g1"
ginstall "$S" --theme light
check "Gast neu: Installer läuft"                     0 "$?"
check "Gast neu: theme=light"                         light "$(jget "$(settings "$S")" theme)"
check "Gast neu: keine Sicherung (Datei war neu)"     0 "$(baks "$S")"

before="$(cksum < "$(settings "$S")")"
ginstall "$S" --theme light
check "Zweiter Lauf: Datei unverändert"               "$before" "$(cksum < "$(settings "$S")")"
check "Zweiter Lauf: keine Sicherung"                 0 "$(baks "$S")"
check "Zweiter Lauf: meldet 'schon gesetzt'"          1 "$(grep -c 'schon gesetzt' "$T/guest.log")"

S="$T/g2"; mkdir -p "$S$ROOTBRIDGE_GUEST_HOME/.claude"
printf '%s\n' '{"model":"opusplan","theme":"dark","language":"german","tui":"fullscreen"}' > "$(settings "$S")"
ginstall "$S" --theme light
check "Bestehende Datei: theme ersetzt"               light "$(jget "$(settings "$S")" theme)"
check "Bestehende Datei: model bleibt"                opusplan "$(jget "$(settings "$S")" model)"
check "Bestehende Datei: language bleibt"             german "$(jget "$(settings "$S")" language)"
check "Bestehende Datei: tui bleibt"                  fullscreen "$(jget "$(settings "$S")" tui)"
check "Bestehende Datei: eine Sicherung"              1 "$(baks "$S")"

# already "light" but formatted differently: not rewritten, no backup
S="$T/g3"; mkdir -p "$S$ROOTBRIDGE_GUEST_HOME/.claude"
printf '%s' '{"theme":   "light","x":1}' > "$(settings "$S")"
before="$(cksum < "$(settings "$S")")"
ginstall "$S" --theme light
check "Schon light: Datei byte-gleich"                "$before" "$(cksum < "$(settings "$S")")"
check "Schon light: keine Sicherung"                  0 "$(baks "$S")"

# without --theme an existing theme stays
S="$T/g4"; mkdir -p "$S$ROOTBRIDGE_GUEST_HOME/.claude"
printf '%s\n' '{"theme":"dark"}' > "$(settings "$S")"
ginstall "$S"
check "Ohne --theme bleibt das Theme"                 dark "$(jget "$(settings "$S")" theme)"
check "Ohne --theme: keine Sicherung"                 0 "$(baks "$S")"

# --autonomous yes and --theme together, both keys end up in the file
S="$T/g5"; mkdir -p "$S$ROOTBRIDGE_GUEST_HOME/.claude"
printf '%s\n' '{"model":"opusplan"}' > "$(settings "$S")"
bash "$GUEST" --root "$S" --autonomous yes --theme light-ansi > "$T/guest.log" 2>&1
check "--autonomous yes + --theme: Installer läuft"   0 "$?"
check "--autonomous yes + --theme: Bypass-Schalter"   True "$(jget "$(settings "$S")" skipDangerousModePermissionPrompt)"
check "--autonomous yes + --theme: theme"             light-ansi "$(jget "$(settings "$S")" theme)"
check "--autonomous yes + --theme: model bleibt"      opusplan "$(jget "$(settings "$S")" model)"

# every valid name is accepted
for name in dark light light-daltonized dark-daltonized light-ansi dark-ansi; do
    S="$T/v-$name"
    ginstall "$S" --theme "$name"
    check "Gültiges Theme '$name'"                    "0 $name" "$? $(jget "$(settings "$S")" theme)"
done

# invalid names: abort with 2 before anything is written
for bad in "" Light neon "light;id" 'a b' '$(id)' "-x" "../light"; do
    S="$T/bad"; rm -rf "$S"
    bash "$GUEST" --root "$S" --autonomous no --theme "$bad" > /dev/null 2>&1
    code=$?
    check "ungültiges Theme '${bad:0:12}': Abbruch mit 2" 2 "$code"
    check "ungültiges Theme '${bad:0:12}': nichts geschrieben" nein "$([ -e "$S" ] && echo ja || echo nein)"
done
bash "$GUEST" --root "$T/bad" --theme > /dev/null 2>&1
check "--theme ohne Wert: Abbruch mit 2"              2 "$?"

# a settings.json that is not valid JSON is left alone (warning, installer still succeeds)
S="$T/g6"; mkdir -p "$S$ROOTBRIDGE_GUEST_HOME/.claude"
printf '%s\n' '{ this is not json' > "$(settings "$S")"
before="$(cksum < "$(settings "$S")")"
ginstall "$S" --theme light
check "Kaputte settings.json: Installer läuft"        0 "$?"
check "Kaputte settings.json: Datei unberührt"        "$before" "$(cksum < "$(settings "$S")")"
check "Kaputte settings.json: Warnung"                1 "$(grep -c 'kein gültiges JSON' "$T/guest.log")"
check "Kaputte settings.json: keine Sicherung"        0 "$(baks "$S")"

# ----------------------------------------------- 2. install.sh (fake Termux)
H="$T/home"; P="$T/prefix"; GROOT="$T/groot"; GUEST_ROOT="$T/guestroot"
mkdir -p "$H" "$P/bin" "$GROOT/var/tmp" "$T/stubs" "$P/var/lib/proot-distro/containers/ubuntu"
ln -s "$GROOT" "$P/var/lib/proot-distro/containers/ubuntu/rootfs"
cat > "$T/stubs/proot-distro" <<'EOF'
#!/bin/bash
# fake proot-distro: logs the call and runs the guest installer against a staging root
echo "$*" >> "$STUB_LOG"
[ "$1" = login ] || exit 0
shift 3                                   # login DISTRO --
shift                                     # bash
script="$STUB_GROOT$1"; shift
args=()
while [ $# -gt 0 ]; do
    case "$1" in /var/tmp/*) args+=("$STUB_GROOT$1") ;; *) args+=("$1") ;; esac
    shift
done
exec bash "$script" --root "$STUB_GUEST_ROOT" "${args[@]}"
EOF
cat > "$T/stubs/termux-reload-settings" <<'EOF'
#!/bin/bash
echo reload >> "$RB_LOG"
EOF
cat > "$T/stubs/rootbridge" <<'EOF'
#!/bin/bash
echo "rootbridge $*" >> "$RB_LOG"
EOF
chmod +x "$T/stubs/proot-distro" "$T/stubs/termux-reload-settings" "$T/stubs/rootbridge"
export STUB_LOG="$T/proot.log" STUB_GROOT="$GROOT" STUB_GUEST_ROOT="$GUEST_ROOT" RB_LOG="$T/rb.log"
: > "$STUB_LOG"; : > "$RB_LOG"
[ -x "$T/stubs/proot-distro" ] && [ -x "$T/stubs/rootbridge" ] && [ -d "$P/bin" ] \
    || { echo "ABBRUCH: Testumgebung unvollständig" >&2; exit 1; }

rinstall() {  # rinstall <home> [args...]  (fake HOME/PREFIX, stubs first in PATH, no migration, no deps check)
    local home="$1"; shift
    HOME="$home" PREFIX="$P" PATH="$T/stubs:$PATH" ROOTBRIDGE_ALLOW_GUEST=1 BRIDGE_DIR="$home/.rootbridge" \
        bash "$INSTALL" --no-boot --no-migrate --no-deps-check --autonomous no "$@" > "$T/install.log" 2>&1
}
reloads() { grep -c '^reload$' "$RB_LOG" || true; }
cbaks() { find "$1/.termux" -name 'colors.properties.bak-*' 2>/dev/null | wc -l | tr -d ' '; }
gsettings() { printf '%s' "$GUEST_ROOT$ROOTBRIDGE_GUEST_HOME/.claude/settings.json"; }
CF="$H/.termux/colors.properties"

check "Repo-Farbdatei: background=#FFFFFF"            "background=#FFFFFF" "$(grep '^background=' "$COLORS")"
check "Repo-Farbdatei: 16 Farben"                     16 "$(grep -c '^color[0-9]*=#[0-9A-Fa-f]\{6\}$' "$COLORS")"

rinstall "$H"
check "install.sh: läuft durch"                       0 "$?"
check "colors.properties: Inhalt wie im Repo"         0 "$(cmp -s "$COLORS" "$CF"; echo $?)"
check "colors.properties: Modus 600"                  600 "$(stat -c %a "$CF")"
check "Neu geschrieben: Reload genau einmal"          1 "$(reloads)"
check "Gast bekam --theme light-ansi"                 1 "$(grep -c -- '--theme light-ansi' "$STUB_LOG")"
check "Gast: theme=light-ansi in settings.json"       light-ansi "$(jget "$(gsettings)" theme)"
check "Neu geschrieben: keine Sicherung"              0 "$(cbaks "$H")"

cksum_before="$(cksum < "$CF")"
rinstall "$H"
check "Zweiter Lauf: läuft durch"                     0 "$?"
check "Zweiter Lauf: Farbdatei unverändert"           "$cksum_before" "$(cksum < "$CF")"
check "Zweiter Lauf: keine Sicherung"                 0 "$(cbaks "$H")"
check "Zweiter Lauf: kein weiterer Reload"            1 "$(reloads)"
check "Zweiter Lauf: .bashrc-Block genau einmal"      1 "$(grep -c '^# >>> termux-root-bridge >>>$' "$H/.bashrc")"

# a different colours file is replaced, the old one is kept as a backup, reload runs again
printf '%s\n' 'background=#123456' > "$CF"
rinstall "$H"
check "Fremde Farbdatei: ersetzt"                     0 "$(cmp -s "$COLORS" "$CF"; echo $?)"
check "Fremde Farbdatei: eine Sicherung"              1 "$(cbaks "$H")"
check "Fremde Farbdatei: Sicherung hat den alten Inhalt" "background=#123456" "$(cat "$H"/.termux/colors.properties.bak-*)"
check "Fremde Farbdatei: Reload erneut"               2 "$(reloads)"

# --no-colors: no colours file, no theme, installer still exits 0
H2="$T/home2"; mkdir -p "$H2"; : > "$STUB_LOG"; : > "$RB_LOG"; rm -rf "$GUEST_ROOT"
rinstall "$H2" --no-colors
check "--no-colors: läuft durch (Exit 0)"             0 "$?"
check "--no-colors: keine colors.properties"          nein "$([ -e "$H2/.termux/colors.properties" ] && echo ja || echo nein)"
check "--no-colors: kein Reload durch den Installer"  0 "$(reloads)"
check "--no-colors: kein --theme an den Gast"         0 "$(grep -c -- '--theme' "$STUB_LOG")"
check "--no-colors: theme nicht gesetzt"              - "$(jget "$(gsettings)" theme)"
check "--no-colors: Farbschema-Hinweis fehlt am Ende" 0 "$(grep -c '^Farben:' "$T/install.log")"

# an earlier install left theme "light" (or the user picked "dark"): the installer sets light-ansi, keeps the rest
H5="$T/home5"; mkdir -p "$H5"; rm -rf "$GUEST_ROOT"; mkdir -p "$(dirname "$(gsettings)")"
printf '%s\n' '{"model":"opusplan","theme":"light"}' > "$(gsettings)"
rinstall "$H5"
check "Altes Theme 'light' wird zu light-ansi"        light-ansi "$(jget "$(gsettings)" theme)"
check "Altes Theme: model bleibt"                     opusplan "$(jget "$(gsettings)" model)"

# --no-colors leaves an existing colours file alone
H3="$T/home3"; mkdir -p "$H3/.termux"; printf '%s\n' 'background=#abcdef' > "$H3/.termux/colors.properties"
before="$(cksum < "$H3/.termux/colors.properties")"
rinstall "$H3" --no-colors
check "--no-colors: vorhandene Farbdatei unberührt"   "$before" "$(cksum < "$H3/.termux/colors.properties")"
check "--no-colors: keine Sicherung"                  0 "$(cbaks "$H3")"

# --no-guest still installs the colours (and calls no guest installer)
H4="$T/home4"; mkdir -p "$H4"; : > "$STUB_LOG"
rinstall "$H4" --no-guest
check "--no-guest: Farben trotzdem installiert"       0 "$(cmp -s "$COLORS" "$H4/.termux/colors.properties"; echo $?)"
check "--no-guest: Gast-Installer nicht aufgerufen"   0 "$(wc -l < "$STUB_LOG" | tr -d ' ')"

# --help lists the option and is not cut off
help_out="$(bash "$INSTALL" --help 2>&1)"
check "--help nennt [--no-colors]"                    1 "$(printf '%s\n' "$help_out" | grep -c -- '\[--no-colors\]')"
check "--help endet mit dem Gast-Schritt"             1 "$(printf '%s\n' "$help_out" | tail -n 1 | grep -c 'proot-distro')"

# ---------------------------------------------- 3. autostart block in ~/.bashrc
run_bashrc() {  # run_bashrc [env assignments...]: interactive bash with the installed ~/.bashrc
    : > "$RB_LOG"
    env -u TMUX -u ROOTBRIDGE_NO_AUTOSTART HOME="$H" PATH="$T/stubs:$PATH" "$@" bash -i -c true > /dev/null 2>&1
    tr '\n' '|' < "$RB_LOG"
}
check "Start in der Termux-Shell: erst Reload, dann Start"  "reload|rootbridge start|" "$(run_bashrc)"
check "ROOTBRIDGE_NO_AUTOSTART: nur Reload"                 "reload|" "$(run_bashrc ROOTBRIDGE_NO_AUTOSTART=1)"
check "In tmux (TMUX gesetzt): weder Reload noch Start"     "" "$(run_bashrc TMUX=/tmp/tmux-0/default,1,0)"
: > "$RB_LOG"
env -u TMUX HOME="$H" PATH="$T/stubs:$PATH" bash -c 'true' > /dev/null 2>&1
check "Nicht interaktiv: nichts"                            "" "$(tr '\n' '|' < "$RB_LOG")"

# ----------------------------------------------------------- 4. widgets
for w in "Claude Code:rootbridge attach" "Ubuntu Shell:rootbridge shell"; do
    f="$ROOT/termux/shortcuts/${w%%:*}"
    : > "$RB_LOG"
    PATH="$T/stubs:$PATH" bash "$f" > /dev/null 2>&1
    check "Widget '${w%%:*}': erst Reload, dann ${w#*:}"    "reload|${w#*:}|" "$(tr '\n' '|' < "$RB_LOG")"
done

echo
echo "Ergebnis: $PASS bestanden, $FAIL fehlgeschlagen"
[ "$FAIL" -eq 0 ]
