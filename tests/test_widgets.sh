#!/usr/bin/env bash
# Test: Termux:Widget shortcuts "Claude >_" / "Ubuntu >_" and their icons (install.sh / uninstall.sh).
#   - installed under the new names, with default icons (neutral, no logos) only where no icon exists
#   - upgrade from the old names "Claude Code" / "Ubuntu Shell": the user's icons are carried over, our old
#     scripts and their *.bak-* files leave the widget list (Termux:Widget lists EVERY file there)
#   - backups of ~/.shortcuts and ~/.termux/boot files go to $BRIDGE_DIR/backups (Termux:Boot runs EVERY file)
#   - --no-widgets, idempotence, uninstall keeps an icon the user chose
#   - the committed PNGs are valid and match tools/make-shortcut-icons.py
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

W1="Claude >_"; W2="Ubuntu >_"
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
        bash "$INSTALL" --no-guest --no-migrate --no-colors --no-deps-check "$@" > "$T/install.log" 2>&1
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
check "frisch: Icon '$W1.png' angelegt"                0 "$(cmp -s "$ICONS/claude.png" "$SC/icons/$W1.png"; echo $?)"
check "frisch: Icon '$W2.png' angelegt"                0 "$(cmp -s "$ICONS/ubuntu.png" "$SC/icons/$W2.png"; echo $?)"
check "frisch: keine alten Namen"                      nein "$(has "$SC/Claude Code")"

before="$(files "$H1")"
rinstall "$H1"
check "zweiter Lauf: Dateien unverändert"              "$before" "$(files "$H1")"
check "zweiter Lauf: Icon bleibt"                      0 "$(cmp -s "$ICONS/claude.png" "$SC/icons/$W1.png"; echo $?)"

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
check "fehlendes Icon (Ubuntu) kommt als Standard"     0 "$(cmp -s "$ICONS/ubuntu.png" "$H4/.shortcuts/icons/$W2.png"; echo $?)"

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

# ----------------------------------------------------------------------------- 7. the icons
for n in claude ubuntu; do
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

# the committed PNGs are what the generator produces (compare the decoded pixels: the compressed bytes
# may differ between zlib builds)
mkdir -p "$T/regen"
python3 -I "$ROOT/tools/make-shortcut-icons.py" "$T/regen" > /dev/null
for n in claude ubuntu; do
    same="$(python3 -I - "$ICONS/$n.png" "$T/regen/$n.png" <<'PY'
import struct, sys, zlib
def pixels(path):
    d = open(path, "rb").read()
    pos, idat = 8, b""
    while pos < len(d):
        n, kind = struct.unpack(">I4s", d[pos:pos + 8])
        if kind == b"IDAT":
            idat += d[pos + 8:pos + 8 + n]
        pos += 12 + n
    return zlib.decompress(idat)
print(pixels(sys.argv[1]) == pixels(sys.argv[2]))
PY
)"
    check "Icon $n.png entspricht tools/make-shortcut-icons.py" True "$same"
done

check "Test hat nie das echte rootbridge/tmux/pkill gestartet" 0 "$(grep -c '^tmux\|^pkill' "$STUB_LOG")"

echo
echo "Ergebnis: $PASS bestanden, $FAIL fehlgeschlagen"
[ "$FAIL" -eq 0 ]
