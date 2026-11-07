#!/usr/bin/env bash
# Test: Termux:Widget shortcuts "Claude" / "Ubuntu" and their icons (install.sh / uninstall.sh).
#   - installed under the new names, with the default icon (one for both widgets) where no icon exists or the icon is
#     a default icon of an earlier version (icons/legacy); an icon the user chose stays
#   - upgrade from the earlier names "Claude Code" / "Ubuntu Shell" and "Claude >_" / "Ubuntu >_": the user's
#     icons are carried over, our old scripts and their *.bak-* files leave the widget list (Termux:Widget
#     lists EVERY file there)
#   - backups of ~/.shortcuts and ~/.termux/boot files go to $BRIDGE_DIR/backups (Termux:Boot runs EVERY file)
#   - --no-widgets, idempotence, uninstall keeps an icon the user chose
#   - the committed PNGs (widget.png and the legacy ones) are valid
# Nothing real is touched: fake HOME/PREFIX/BRIDGE_DIR; `rootbridge` (uninstall.sh calls `rootbridge stop`!),
# `tmux`, `pkill` and `pgrep` are logging stubs, --no-guest --no-migrate.
#   bash tests/test_widgets.sh
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL="$ROOT/install.sh"
UNINSTALL="$ROOT/uninstall.sh"
ICONS="$ROOT/termux/shortcuts/icons"

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

PASS=0; FAIL=0
check() {   # check <name> <expected> <actual>
    if [ "$2" = "$3" ]; then PASS=$((PASS + 1)); printf 'ok    %s\n' "$1"
    else FAIL=$((FAIL + 1)); printf 'FAIL  %s\n      erwartet: %s\n      erhalten: %s\n' "$1" "$2" "$3"; fi
}
has() { [ -e "$1" ] && echo ja || echo nein; }
files() { ( cd "$1" && find .shortcuts .termux .rootbridge -type f 2>/dev/null | sort ); }

W1="Claude"; W2="Ubuntu"
P="$T/prefix"; mkdir -p "$P/bin" "$T/stubs"
# uninstall.sh runs `rootbridge stop` if it finds one: never the real one (it would end the user's session)
for s in rootbridge tmux pkill pgrep; do
    printf '#!/bin/bash\necho "%s $*" >> "$STUB_LOG"\nexit 1\n' "$s" > "$T/stubs/$s"
done
chmod +x "$T/stubs"/*
export STUB_LOG="$T/stub.log"; : > "$STUB_LOG"

rinstall() {  # rinstall <home> [args...]
    local home="$1"; shift
    HOME="$home" PREFIX="$P" PATH="$T/stubs:$PATH" ROOTBRIDGE_ALLOW_GUEST=1 BRIDGE_DIR="$home/.rootbridge" \
        bash "$INSTALL" --no-guest --no-migrate --no-colors --no-deps-check --no-extra-keys "$@" > "$T/install.log" 2>&1
}
runinstall_uninstall() {  # <home>
    HOME="$1" PREFIX="$P" PATH="$T/stubs:$PATH" bash "$UNINSTALL" --no-guest > "$T/uninstall.log" 2>&1
}

# ---------------------------------------------------- 1. fresh device (no ~/.shortcuts yet)
H1="$T/h1"; mkdir -p "$H1"
rinstall "$H1"
check "frisch: Installer läuft"                        0 "$?"
SC="$H1/.shortcuts"
check "frisch: Widget '$W1' angelegt"                  ja "$(has "$SC/$W1")"
check "frisch: Widget '$W2' angelegt"                  ja "$(has "$SC/$W2")"
check "frisch: '$W1' ist ausführbar"                   ja "$([ -x "$SC/$W1" ] && echo ja || echo nein)"
check "frisch: '$W1' ruft rootbridge attach"           1 "$(grep -c '^exec rootbridge attach$' "$SC/$W1")"
check "frisch: '$W2' ruft rootbridge shell"            1 "$(grep -c '^exec rootbridge shell$' "$SC/$W2")"
check "frisch: Termux-Shebang"                         "#!$P/bin/bash" "$(head -n 1 "$SC/$W1")"
check "frisch: Icon '$W1.png' angelegt"                0 "$(cmp -s "$ICONS/widget.png" "$SC/icons/$W1.png"; echo $?)"
check "frisch: Icon '$W2.png' angelegt"                0 "$(cmp -s "$ICONS/widget.png" "$SC/icons/$W2.png"; echo $?)"
check "frisch: keine alten Namen"                      nein "$(has "$SC/Claude Code")"

before="$(files "$H1")"
rinstall "$H1"
check "zweiter Lauf: Dateien unverändert"              "$before" "$(files "$H1")"
check "zweiter Lauf: Icon bleibt"                      0 "$(cmp -s "$ICONS/widget.png" "$SC/icons/$W1.png"; echo $?)"

# ---------------------------------------- 2. upgrade from the old names, with the user's own icons
H2="$T/h2"; mkdir -p "$H2/.shortcuts/icons" "$H2/.termux/boot"
SC="$H2/.shortcuts"
printf '#!/data/data/com.termux/files/usr/bin/bash\nexec rootbridge attach\n' > "$SC/Claude Code"
printf '#!/data/data/com.termux/files/usr/bin/bash\nexec rootbridge shell\n'  > "$SC/Ubuntu Shell"
cp "$SC/Claude Code" "$SC/Claude Code.bak-20261103134415"
cp "$SC/Ubuntu Shell" "$SC/Ubuntu Shell.bak-20261103134415"
printf 'USERICON-CLAUDE' > "$SC/icons/Claude Code.png"
printf 'USERICON-UBUNTU' > "$SC/icons/Ubuntu Shell.png"
printf '#!/bin/bash\nold boot script\n' > "$H2/.termux/boot/10-rootbridge.sh"
chmod +x "$SC/Claude Code" "$SC/Ubuntu Shell" "$H2/.termux/boot/10-rootbridge.sh"
BR="$H2/.rootbridge"

rinstall "$H2"
check "Umstieg: Installer läuft"                       0 "$?"
check "Umstieg: neues Widget '$W1'"                    ja "$(has "$SC/$W1")"
check "Umstieg: neues Widget '$W2'"                    ja "$(has "$SC/$W2")"
check "Umstieg: altes 'Claude Code' ist weg"           nein "$(has "$SC/Claude Code")"
check "Umstieg: altes 'Ubuntu Shell' ist weg"          nein "$(has "$SC/Ubuntu Shell")"
check "Umstieg: Kopie des alten Skripts in backups"    1 "$(find "$BR/backups" -name 'Claude Code.old-*' | wc -l | tr -d ' ')"
check "Umstieg: keine *.bak-* mehr in der Widget-Liste" 0 "$(find "$SC" -maxdepth 1 -name '*.bak-*' | wc -l | tr -d ' ')"
check "Umstieg: die Sicherungen liegen in backups"     2 "$(find "$BR/backups" -name '*Claude Code.bak-*' -o -name '*Ubuntu Shell.bak-*' | wc -l | tr -d ' ')"
check "Umstieg: Icon des Users wandert mit (Claude)"   USERICON-CLAUDE "$(cat "$SC/icons/$W1.png" 2>/dev/null)"
check "Umstieg: Icon des Users wandert mit (Ubuntu)"   USERICON-UBUNTU "$(cat "$SC/icons/$W2.png" 2>/dev/null)"
check "Umstieg: alte Icon-Namen sind weg"              nein "$(has "$SC/icons/Claude Code.png")"
check "Umstieg: kein Standard-Icon über das des Users" 1 "$(grep -c USERICON "$SC/icons/$W1.png")"
check "Boot-Skript: keine *.bak-* neben dem Original"  0 "$(find "$H2/.termux/boot" -name '*.bak-*' | wc -l | tr -d ' ')"
check "Boot-Skript: Sicherung in backups"              1 "$(find "$BR/backups" -name '10-rootbridge.sh.bak-*' | wc -l | tr -d ' ')"
check "Boot-Skript: neu installiert"                   1 "$(grep -c 'rootbridge start --no-attach' "$H2/.termux/boot/10-rootbridge.sh")"

before="$(files "$H2")"
rinstall "$H2"
check "Umstieg, zweiter Lauf: nichts ändert sich"      "$before" "$(files "$H2")"

# ----------------- 2b. upgrade from the intermediate names "Claude >_" / "Ubuntu >_" (the state of the device)
H6="$T/h6"; mkdir -p "$H6/.shortcuts/icons"
SC="$H6/.shortcuts"; BR="$H6/.rootbridge"
printf '#!/data/data/com.termux/files/usr/bin/bash\nexec rootbridge attach\n' > "$SC/Claude >_"
printf '#!/data/data/com.termux/files/usr/bin/bash\nexec rootbridge shell\n'  > "$SC/Ubuntu >_"
chmod +x "$SC/Claude >_" "$SC/Ubuntu >_"
printf 'USERICON-CLAUDE' > "$SC/icons/Claude >_.png"
printf 'USERICON-UBUNTU' > "$SC/icons/Ubuntu >_.png"
rinstall "$H6"
check ">_-Umstieg: Installer läuft"                    0 "$?"
check ">_-Umstieg: neues Widget '$W1'"                 ja "$(has "$SC/$W1")"
check ">_-Umstieg: neues Widget '$W2'"                 ja "$(has "$SC/$W2")"
check ">_-Umstieg: 'Claude >_' ist weg"                nein "$(has "$SC/Claude >_")"
check ">_-Umstieg: 'Ubuntu >_' ist weg"                nein "$(has "$SC/Ubuntu >_")"
check ">_-Umstieg: Kopie in backups"                   1 "$(find "$BR/backups" -name 'Claude >_.old-*' | wc -l | tr -d ' ')"
check ">_-Umstieg: Icon des Users (Claude)"            USERICON-CLAUDE "$(cat "$SC/icons/$W1.png" 2>/dev/null)"
check ">_-Umstieg: Icon des Users (Ubuntu)"            USERICON-UBUNTU "$(cat "$SC/icons/$W2.png" 2>/dev/null)"
check ">_-Umstieg: alte Icon-Namen sind weg"           nein "$(has "$SC/icons/Claude >_.png")"
check ">_-Umstieg: genau zwei Widgets in der Liste"    2 "$(find "$SC" -maxdepth 1 -type f | wc -l | tr -d ' ')"
before="$(files "$H6")"
rinstall "$H6"
check ">_-Umstieg, zweiter Lauf: nichts ändert sich"   "$before" "$(files "$H6")"

# both earlier generations at once: the newer ">_" icon wins, both old scripts go
H7="$T/h7"; mkdir -p "$H7/.shortcuts/icons"
SC="$H7/.shortcuts"
printf '#!/bin/bash\nexec rootbridge attach\n' > "$SC/Claude Code"
printf '#!/bin/bash\nexec rootbridge attach\n' > "$SC/Claude >_"
printf 'ICON-OLD' > "$SC/icons/Claude Code.png"
printf 'ICON-NEWER' > "$SC/icons/Claude >_.png"
rinstall "$H7"
check "beide Generationen: das neuere Icon gewinnt"    ICON-NEWER "$(cat "$SC/icons/$W1.png" 2>/dev/null)"
check "beide Generationen: beide alten Skripte weg"    "nein nein" "$(has "$SC/Claude Code") $(has "$SC/Claude >_")"
check "beide Generationen: neues Widget da"            ja "$(has "$SC/$W1")"

# ------------------------------------------------- 3. an old script that is not ours stays
H3="$T/h3"; mkdir -p "$H3/.shortcuts"
printf '#!/bin/bash\necho my own script\n' > "$H3/.shortcuts/Claude Code"
rinstall "$H3"
check "fremdes 'Claude Code'-Skript bleibt"            ja "$(has "$H3/.shortcuts/Claude Code")"
check "fremdes Skript: neues Widget trotzdem da"       ja "$(has "$H3/.shortcuts/$W1")"

# --------------------------------------------- 4. an icon the user already chose is never replaced
H4="$T/h4"; mkdir -p "$H4/.shortcuts/icons"
printf 'MY-ICON' > "$H4/.shortcuts/icons/$W1.png"
rinstall "$H4"
check "vorhandenes Icon bleibt unangetastet"           MY-ICON "$(cat "$H4/.shortcuts/icons/$W1.png")"
check "fehlendes Icon (Ubuntu) kommt als Standard"     0 "$(cmp -s "$ICONS/widget.png" "$H4/.shortcuts/icons/$W2.png"; echo $?)"

# the default icons of earlier versions are replaced by the new one, also under the older names; run twice: no change
H9="$T/h9"; mkdir -p "$H9/.shortcuts/icons"
cp "$ICONS/legacy/claude.png" "$H9/.shortcuts/icons/$W1.png"
cp "$ICONS/legacy/ubuntu.png" "$H9/.shortcuts/icons/Ubuntu >_.png"
rinstall "$H9"
check "frühere Standard-Icons: '$W1.png' ersetzt"       0 "$(cmp -s "$ICONS/widget.png" "$H9/.shortcuts/icons/$W1.png"; echo $?)"
check "frühere Standard-Icons: '>_' wandert und wird ersetzt" 0 "$(cmp -s "$ICONS/widget.png" "$H9/.shortcuts/icons/$W2.png"; echo $?)"
check "frühere Standard-Icons: alter Name ist weg"       nein "$(has "$H9/.shortcuts/icons/Ubuntu >_.png")"
check "frühere Standard-Icons: Meldung"                  2 "$(grep -c '^  Icon: ' "$T/install.log")"
before="$(cksum < "$H9/.shortcuts/icons/$W1.png")"
rinstall "$H9"
check "zweiter Lauf: Icon unverändert"                   "$before" "$(cksum < "$H9/.shortcuts/icons/$W1.png")"
check "zweiter Lauf: keine Icon-Meldung"                 0 "$(grep -c '^  Icon: ' "$T/install.log")"

# ------------------------------------------------------------------------- 5. --no-widgets
H5="$T/h5"; mkdir -p "$H5"
rinstall "$H5" --no-widgets
check "--no-widgets: Installer läuft"                  0 "$?"
check "--no-widgets: kein ~/.shortcuts"                nein "$(has "$H5/.shortcuts")"

# ----------------------------------------------------------------------------- 6. uninstall
runinstall_uninstall "$H4"
check "uninstall: Widget '$W1' weg"                    nein "$(has "$H4/.shortcuts/$W1")"
check "uninstall: Widget '$W2' weg"                    nein "$(has "$H4/.shortcuts/$W2")"
check "uninstall: eigenes Icon des Users bleibt"       MY-ICON "$(cat "$H4/.shortcuts/icons/$W1.png" 2>/dev/null)"
check "uninstall: Standard-Icon wird entfernt"         nein "$(has "$H4/.shortcuts/icons/$W2.png")"
check "uninstall: das echte rootbridge wurde nie benutzt (nur der Stub)" 1 "$(grep -c '^rootbridge stop' "$STUB_LOG")"

# uninstall removes our scripts under every name, but not a script of the user that happens to be called "Claude"
H8="$T/h8"; mkdir -p "$H8/.shortcuts/icons"
printf '#!/bin/bash\necho my own widget\n' > "$H8/.shortcuts/Claude"
printf '#!/bin/bash\nexec rootbridge shell\n' > "$H8/.shortcuts/Ubuntu >_"
printf '#!/bin/bash\nexec rootbridge attach\n' > "$H8/.shortcuts/Claude Code"
cp "$ICONS/legacy/ubuntu.png" "$H8/.shortcuts/icons/Ubuntu >_.png"
runinstall_uninstall "$H8"
check "uninstall: fremdes Skript 'Claude' bleibt"      ja "$(has "$H8/.shortcuts/Claude")"
check "uninstall: 'Ubuntu >_' (unseres) ist weg"       nein "$(has "$H8/.shortcuts/Ubuntu >_")"
check "uninstall: 'Claude Code' (unseres) ist weg"     nein "$(has "$H8/.shortcuts/Claude Code")"
check "uninstall: Standard-Icon der >_-Generation weg" nein "$(has "$H8/.shortcuts/icons/Ubuntu >_.png")"

# ----------------------------------------------------------------------------- 7. the icons
for n in widget legacy/claude legacy/ubuntu; do
    info="$(python3 -I - "$ICONS/$n.png" <<'PY'
import struct, sys
d = open(sys.argv[1], "rb").read()
ok = d[:8] == b"\x89PNG\r\n\x1a\n" and d[12:16] == b"IHDR"
w, h, depth, ctype = struct.unpack(">IIBB", d[16:26])
print(ok, w, h, depth, ctype, d.endswith(b"IEND\xaeB`\x82"))
PY
)"
    check "Icon $n.png: gültiges PNG, 192x192, 8 Bit RGBA" "True 192 192 8 6 True" "$info"
done
check "Das neue Icon unterscheidet sich von den früheren" 0 "$(cmp -s "$ICONS/widget.png" "$ICONS/legacy/claude.png" && echo 1 || echo 0)"

check "Test hat nie das echte rootbridge/tmux/pkill gestartet" 0 "$(grep -c '^tmux\|^pkill' "$STUB_LOG")"

echo
echo "Ergebnis: $PASS bestanden, $FAIL fehlgeschlagen"
[ "$FAIL" -eq 0 ]
