#!/usr/bin/env bash
# Test: install.sh writes no colour file (the app has the schemes built in), removes colour files that earlier versions
# installed and that are still unchanged, leaves everything else alone, reload at every start and the Claude Code theme (custom:epaper, "Auto epaper").
#   1. guest installer: --theme writes "theme" into ~/.claude/settings.json (staging root)
#   2. install.sh with a fake HOME/PREFIX: no colour file, former files, reload, --no-colors, --theme hand-over
#   3. the block in ~/.bashrc: reload in every new shell, no autostart; ubuntu / claude / codex shortcuts;
#      an old autostart block and ubuntu alias are replaced when install.sh runs again
#   4. Termux:Widget shortcuts reload first
# Nothing real is touched: fake HOME/PREFIX, `proot-distro`, `termux-reload-settings` and
# `rootbridge` are stubs that only write a log line (no pkill/tmux/clipboard, --no-migrate).
#   bash tests/test_colors_theme.sh
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GUEST="$ROOT/guest/install-guest.sh"
INSTALL="$ROOT/install.sh"
FORMER="$ROOT/tests/fixtures/former-colors.properties"            # colors.properties of versions up to PR #4
FORMER_LIGHT="$ROOT/tests/fixtures/former-colors-light.properties" # colors-light.properties of PR #5

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
    bash "$GUEST" --root "$stage" --autonomous no --model none --voice no "$@" > "$T/guest.log" 2>&1
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
for name in auto dark light light-daltonized dark-daltonized light-ansi dark-ansi custom:epaper; do
    S="$T/v-$name"
    ginstall "$S" --theme "$name"
    check "Gültiges Theme '$name'"                    "0 $name" "$? $(jget "$(settings "$S")" theme)"
done

# custom:epaper creates ~/.claude/themes/epaper.json once; a file of yours stays
EP="$T/v-custom:epaper$ROOTBRIDGE_GUEST_HOME/.claude/themes/epaper.json"
check "custom:epaper: Theme-Datei angelegt"           "Auto epaper light-ansi" "$(jget "$EP" name) $(jget "$EP" base)"
check "Andere Themes legen keine Theme-Datei an"      0 "$(ls "$T/v-dark-ansi$ROOTBRIDGE_GUEST_HOME/.claude/themes" 2>/dev/null | wc -l)"
printf '%s\n' '{"name":"Mein epaper","base":"dark-ansi","overrides":{"text":"ansi:black"}}' > "$EP"
before="$(cksum < "$EP")"
ginstall "$T/v-custom:epaper" --theme custom:epaper
check "custom:epaper: vorhandene Theme-Datei bleibt"  "$before" "$(cksum < "$EP")"

# a file exactly as the earlier version created it (daltonized base) moves to the ANSI base, light/dark stays
for m in light dark; do
    printf '%s\n' '{' '  "name": "Auto epaper",' "  \"base\": \"$m-daltonized\"," '  "overrides": {}' '}' > "$EP"
    ginstall "$T/v-custom:epaper" --theme custom:epaper
    check "Frühere Datei $m-daltonized -> $m-ansi"     "$m-ansi Auto epaper" "$(jget "$EP" base) $(jget "$EP" name)"
done
check "Umstellung: keine Temp-Datei übrig"            0 "$(find "$(dirname "$EP")" -name '*.new.*' | wc -l)"
# changed in any way (here: an override): stays daltonized
printf '%s\n' '{' '  "name": "Auto epaper",' '  "base": "dark-daltonized",' '  "overrides": {"text": "ansi:white"}' '}' > "$EP"
ginstall "$T/v-custom:epaper" --theme custom:epaper
check "Geänderte frühere Datei bleibt daltonized"     dark-daltonized "$(jget "$EP" base)"

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
        bash "$INSTALL" --no-boot --no-migrate --no-deps-check --no-extra-keys --no-setup --no-voice --autonomous no "$@" > "$T/install.log" 2>&1
}
reloads() { grep -c '^reload$' "$RB_LOG" || true; }
cbaks() { find "$1/.termux" -name 'colors*.properties.bak-*' 2>/dev/null | wc -l | tr -d ' '; }
gsettings() { printf '%s' "$GUEST_ROOT$ROOTBRIDGE_GUEST_HOME/.claude/settings.json"; }
nocolors() { find "$1/.termux" -maxdepth 1 -name 'colors*.properties*' 2>/dev/null | wc -l | tr -d ' '; }

check "Repo liefert keine Farbdatei mehr (colors*.properties)" 0 "$(find "$ROOT/termux" -maxdepth 1 -name 'colors*.properties' | wc -l | tr -d ' ')"
check "Fixture: frühere colors.properties ist die helle Palette"        "background=#FFFFFF" "$(grep '^background=' "$FORMER")"
check "Fixture: frühere Palette hat 16 Farben"        16 "$(grep -c '^color[0-9]*=#[0-9A-Fa-f]\{6\}$' "$FORMER")"
# the checksums install.sh knows are those of the files that earlier versions installed
check "Prüfsumme colors.properties früherer Versionen" "$(sha256sum < "$FORMER" | cut -d' ' -f1)" "$(grep -o 'colors\.properties:[0-9a-f]\{64\}' "$INSTALL" | cut -d: -f2)"
check "Prüfsumme colors-light.properties aus PR #5"   "$(sha256sum < "$FORMER_LIGHT" | cut -d' ' -f1)" "$(grep -o 'colors-light\.properties:[0-9a-f]\{64\}' "$INSTALL" | cut -d: -f2)"

rinstall "$H"
check "install.sh: läuft durch"                       0 "$?"
check "Frisches Home: keine Farbdatei angelegt"       0 "$(nocolors "$H")"
check "Frisches Home: kein Reload durch den Installer" 0 "$(reloads)"
check "Gast bekam --theme custom:epaper"              1 "$(grep -c -- '--theme custom:epaper' "$STUB_LOG")"
check "Gast: theme=custom:epaper in settings.json"    custom:epaper "$(jget "$(gsettings)" theme)"
check "Gast: Auto epaper mit Basis light-ansi"        light-ansi "$(jget "$GUEST_ROOT$ROOTBRIDGE_GUEST_HOME/.claude/themes/epaper.json" base)"
check "Schlussmeldung nennt die eingebauten Schemata" 1 "$(grep -c '^Farben: der E-Paper-Termux bringt' "$T/install.log")"

rinstall "$H"
check "Zweiter Lauf: läuft durch"                     0 "$?"
check "Zweiter Lauf: weiterhin keine Farbdatei"       0 "$(nocolors "$H")"
check "Zweiter Lauf: .bashrc-Block genau einmal"      1 "$(grep -c '^# >>> termux-rootbridge >>>$' "$H/.bashrc")"

# files that earlier versions installed and that are unchanged go (no backup needed: the content is in the repo history)
for pair in "former-colors:colors.properties:$FORMER" "former-light:colors-light.properties:$FORMER_LIGHT"; do
    n="${pair%%:*}"; rest="${pair#*:}"; fname="${rest%%:*}"; src="${rest#*:}"
    HF1="$T/home-$n"; mkdir -p "$HF1/.termux"; cp "$src" "$HF1/.termux/$fname"; : > "$RB_LOG"
    rinstall "$HF1"
    check "Frühere $fname: läuft durch"               0 "$?"
    check "Frühere $fname: entfernt"                  nein "$([ -e "$HF1/.termux/$fname" ] && echo ja || echo nein)"
    check "Frühere $fname: Meldung"                   1 "$(grep -c "entfernt: .*/$fname" "$T/install.log")"
    check "Frühere $fname: keine Sicherung, nichts Neues" 0 "$(nocolors "$HF1")"
    check "Frühere $fname: Reload genau einmal"       1 "$(reloads)"
done
HB="$T/home-both"; mkdir -p "$HB/.termux"; cp "$FORMER" "$HB/.termux/colors.properties"; cp "$FORMER_LIGHT" "$HB/.termux/colors-light.properties"; : > "$RB_LOG"
rinstall "$HB"
check "Beide früheren Dateien: beide entfernt"        0 "$(nocolors "$HB")"
check "Beide früheren Dateien: Reload genau einmal"   1 "$(reloads)"

# anything the user changed or made stays untouched, with a note for a file that is not empty
HU="$T/home-user"; mkdir -p "$HU/.termux"; : > "$RB_LOG"
printf '%s\n' 'background=#123456' > "$HU/.termux/colors.properties"
printf '%s\n' 'background=#654321' > "$HU/.termux/colors-light.properties"
printf '%s\n' 'background=#111111' > "$HU/.termux/colors-dark.properties"
rinstall "$HU"
check "Eigene Dateien: colors.properties unberührt"   "background=#123456" "$(cat "$HU/.termux/colors.properties")"
check "Eigene Dateien: colors-light.properties unberührt" "background=#654321" "$(cat "$HU/.termux/colors-light.properties")"
check "Eigene Dateien: colors-dark.properties unberührt"  "background=#111111" "$(cat "$HU/.termux/colors-dark.properties")"
check "Eigene Dateien: Hinweis für die zwei bekannten Namen" 2 "$(grep -c 'bleibt (von dir geändert)' "$T/install.log")"
check "Eigene Dateien: keine Sicherung"               0 "$(cbaks "$HU")"
check "Eigene Dateien: kein Reload"                   0 "$(reloads)"
# a changed copy of a former file (one byte more) is the user's file as well
HC="$T/home-changed"; mkdir -p "$HC/.termux"; { cat "$FORMER"; echo "color99=#000000"; } > "$HC/.termux/colors.properties"; : > "$RB_LOG"
rinstall "$HC"
check "Geänderte frühere Palette: bleibt"             1 "$([ -f "$HC/.termux/colors.properties" ] && echo 1 || echo 0)"
check "Geänderte frühere Palette: kein Reload"        0 "$(reloads)"

# --no-colors: no colours file, no theme, installer still exits 0
H2="$T/home2"; mkdir -p "$H2"; : > "$STUB_LOG"; : > "$RB_LOG"; rm -rf "$GUEST_ROOT"
rinstall "$H2" --no-colors
check "--no-colors: läuft durch (Exit 0)"             0 "$?"
check "--no-colors: keine Farbdatei"                  0 "$(nocolors "$H2")"
check "--no-colors: kein Reload durch den Installer"  0 "$(reloads)"
check "--no-colors: kein --theme an den Gast"         0 "$(grep -c -- '--theme' "$STUB_LOG")"
check "--no-colors: theme nicht gesetzt"              - "$(jget "$(gsettings)" theme)"
check "--no-colors: Farbschema-Hinweis fehlt am Ende" 0 "$(grep -c '^Farben:' "$T/install.log")"

# an earlier install left theme "light" (or the user picked "dark"): the installer sets custom:epaper, keeps the rest
H5="$T/home5"; mkdir -p "$H5"; rm -rf "$GUEST_ROOT"; mkdir -p "$(dirname "$(gsettings)")"
printf '%s\n' '{"model":"opusplan","theme":"light"}' > "$(gsettings)"
rinstall "$H5"
check "Altes Theme 'light' wird zu custom:epaper"     custom:epaper "$(jget "$(gsettings)" theme)"
check "Altes Theme: model bleibt"                     opusplan "$(jget "$(gsettings)" model)"

# --no-colors leaves existing colours files alone, even the colors.properties of earlier versions
H3="$T/home3"; mkdir -p "$H3/.termux"; cp "$FORMER" "$H3/.termux/colors.properties"
before="$(cksum < "$H3/.termux/colors.properties")"
rinstall "$H3" --no-colors
check "--no-colors: vorhandene Farbdatei unberührt"   "$before" "$(cksum < "$H3/.termux/colors.properties")"
check "--no-colors: keine Sicherung"                  0 "$(cbaks "$H3")"

# --no-guest: no guest installer call, no colour file either
H4="$T/home4"; mkdir -p "$H4"; : > "$STUB_LOG"
rinstall "$H4" --no-guest
check "--no-guest: läuft durch, keine Farbdatei"      0 "$(nocolors "$H4")"
check "--no-guest: Gast-Installer nicht aufgerufen"   0 "$(wc -l < "$STUB_LOG" | tr -d ' ')"

# --help lists the option and is not cut off
help_out="$(bash "$INSTALL" --help 2>&1)"
check "--help nennt [--no-colors]"                    1 "$(printf '%s\n' "$help_out" | grep -c -- '\[--no-colors\]')"
check "--help endet mit dem Gast-Schritt"             1 "$(printf '%s\n' "$help_out" | tail -n 1 | grep -c 'stored as CLAUDE_UPDATE')"

# ---------------------------------------------- 3. block in ~/.bashrc
run_bashrc() {  # run_bashrc <home> [env assignments...]: interactive bash with that ~/.bashrc
    local home="$1"; shift
    : > "$RB_LOG"
    env -u TMUX HOME="$home" PATH="$T/stubs:$PATH" "$@" bash -i -c true > /dev/null 2>&1
    tr '\n' '|' < "$RB_LOG"
}
check "Neues Termux-Fenster: nur Reload, kein Start"        "reload|" "$(run_bashrc "$H")"
check "Block enthält kein 'rootbridge start'"               0 "$(grep -c 'rootbridge start' "$H/.bashrc")"
check "Alte Variable ROOTBRIDGE_NO_AUTOSTART ändert nichts" "reload|" "$(run_bashrc "$H" ROOTBRIDGE_NO_AUTOSTART=1)"
check "In tmux (TMUX gesetzt): weder Reload noch Start"     "" "$(run_bashrc "$H" TMUX=/tmp/tmux-0/default,1,0)"
: > "$RB_LOG"
env -u TMUX HOME="$H" PATH="$T/stubs:$PATH" bash -c 'true' > /dev/null 2>&1
check "Nicht interaktiv: nichts"                            "" "$(tr '\n' '|' < "$RB_LOG")"
run_shortcut() {  # run_shortcut <home> <command>: execute a shortcut from the installed .bashrc
    local home="$1" cmd="$2"
    : > "$RB_LOG"
    env -u TMUX HOME="$home" PATH="$T/stubs:$PATH" bash -i -c "$cmd" > /dev/null 2>&1
    tr '\n' '|' < "$RB_LOG"
}
for entry in "ubuntu:shell" "claude:attach claude" "codex:attach codex" \
             "claude -n:attach claude -n" "claude --new:attach claude --new"; do
    check "Kurzbefehl ${entry%%:*}: richtiger Aufruf" "reload|rootbridge ${entry#*:}|" "$(run_shortcut "$H" "${entry%%:*}")"
done

# an old autostart block (earlier version) is replaced, the user's own lines stay
H6="$T/home6"; mkdir -p "$H6"
cat > "$H6/.bashrc" <<'EOF'
# my own line
# >>> termux-rootbridge >>>
alias ubuntu='rootbridge attach'
if [[ $- == *i* ]] && [ -z "${TMUX:-}" ] && [ -z "${ROOTBRIDGE_NO_AUTOSTART:-}" ] \
        && command -v rootbridge >/dev/null 2>&1; then
    rootbridge start
fi
# <<< termux-rootbridge <<<
export MYVAR=1
EOF
check "Altes .bashrc: startet vor der Migration"            "rootbridge start|" "$(run_bashrc "$H6" | sed 's/^reload|//')"
rinstall "$H6" --no-guest
check "Altes .bashrc: Installer läuft"                     0 "$?"
check "Altes .bashrc: kein 'rootbridge start' mehr"         0 "$(grep -c 'rootbridge start' "$H6/.bashrc")"
check "Altes .bashrc: Block genau einmal"                   1 "$(grep -c '^# >>> termux-rootbridge >>>$' "$H6/.bashrc")"
check "Altes .bashrc: eigene Zeilen bleiben"                2 "$(grep -c '^# my own line$\|^export MYVAR=1$' "$H6/.bashrc")"
check "Altes .bashrc: danach nur Reload"                    "reload|" "$(run_bashrc "$H6")"
check "Altes .bashrc: ubuntu öffnet jetzt die Shell"        "reload|rootbridge shell|" "$(run_shortcut "$H6" ubuntu)"
check "Altes .bashrc: claude öffnet Claude Code"            "reload|rootbridge attach claude|" "$(run_shortcut "$H6" claude)"
check "Altes .bashrc: codex öffnet Codex"                    "reload|rootbridge attach codex|" "$(run_shortcut "$H6" codex)"
before="$(cksum < "$H6/.bashrc")"
rinstall "$H6" --no-guest
check "Neue Kurzbefehle: zweiter Installationslauf unverändert" "$before" "$(cksum < "$H6/.bashrc")"

# ----------------------------------------------------------- 4. widgets
for w in "claude:rootbridge attach" "ubuntu:rootbridge shell"; do
    f="$ROOT/termux/shortcuts/${w%%:*}"
    : > "$RB_LOG"
    PATH="$T/stubs:$PATH" bash "$f" > /dev/null 2>&1
    check "Widget '${w%%:*}': erst Reload, dann ${w#*:}"    "reload|${w#*:}|" "$(tr '\n' '|' < "$RB_LOG")"
done

echo
echo "Ergebnis: $PASS bestanden, $FAIL fehlgeschlagen"
[ "$FAIL" -eq 0 ]
