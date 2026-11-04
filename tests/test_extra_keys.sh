#!/usr/bin/env bash
# Test: the Termux extra keys row (install.sh / uninstall.sh): S-TAB = Shift+Tab, KEYBOARD toggles the soft
# keyboard. A phone keyboard has no Shift+Tab, and Claude Code switches its permission mode with it.
#   1. the layout in termux/extra-keys.snippet parses (own mini parser): 2 rows of 6, S-TAB sends SHIFT TAB,
#      KEYBOARD is there, PGUP/PGDN are not
#   2. install.sh: marked block at the end of ~/.termux/termux.properties, mode 600, reload only on a change,
#      idempotent, the rest of the file untouched, backup of the old file
#   3. a row of the user's own (single or multi line) is never replaced; a commented sample line is not "own"
#   4. an older version of our block is brought up to date; --no-extra-keys; uninstall.sh removes only our block
# Nothing real is touched: fake HOME/PREFIX/BRIDGE_DIR; `termux-reload-settings`, `rootbridge` (uninstall.sh
# calls `rootbridge stop`!), `tmux`, `pkill` and `pgrep` are logging stubs; --no-guest --no-migrate --no-colors.
#   bash tests/test_extra_keys.sh
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL="$ROOT/install.sh"
UNINSTALL="$ROOT/uninstall.sh"
SNIP="$ROOT/termux/extra-keys.snippet"
BEGIN='# >>> termux-root-bridge >>>'
END='# <<< termux-root-bridge <<<'

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

PASS=0; FAIL=0
check() {   # check <name> <expected> <actual>
    if [ "$2" = "$3" ]; then PASS=$((PASS + 1)); printf 'ok    %s\n' "$1"
    else FAIL=$((FAIL + 1)); printf 'FAIL  %s\n      erwartet: %s\n      erhalten: %s\n' "$1" "$2" "$3"; fi
}

P="$T/prefix"; mkdir -p "$P/bin" "$T/stubs"
for s in rootbridge tmux pkill pgrep; do
    printf '#!/bin/bash\necho "%s $*" >> "$STUB_LOG"\nexit 1\n' "$s" > "$T/stubs/$s"
done
printf '#!/bin/bash\necho reload >> "$RB_LOG"\n' > "$T/stubs/termux-reload-settings"
chmod +x "$T/stubs"/*
export STUB_LOG="$T/stub.log" RB_LOG="$T/rb.log"; : > "$STUB_LOG"; : > "$RB_LOG"

rinstall() {  # rinstall <home> [args...]
    local home="$1"; shift
    HOME="$home" PREFIX="$P" PATH="$T/stubs:$PATH" ROOTBRIDGE_ALLOW_GUEST=1 BRIDGE_DIR="$home/.rootbridge" \
        bash "$INSTALL" --no-guest --no-migrate --no-colors --no-deps-check "$@" > "$T/install.log" 2>&1
}
rununinstall() {  # rununinstall <home>
    HOME="$1" PREFIX="$P" PATH="$T/stubs:$PATH" bash "$UNINSTALL" --no-guest > "$T/uninstall.log" 2>&1
}
reloads() { grep -c '^reload$' "$RB_LOG" || true; }
baks() { find "$1/.termux" -name 'termux.properties.bak-*' 2>/dev/null | wc -l | tr -d ' '; }
blocks() { grep -c -F -x "$BEGIN" "$1" || true; }
# the text of our block (between the markers)
inner() { sed -n "/^$(printf '%s' "$BEGIN" | sed 's/[][\.*^$/]/\\&/g')\$/,/^$(printf '%s' "$END" | sed 's/[][\.*^$/]/\\&/g')\$/p" "$1" | sed '1d;$d'; }
# the file without our block
outer() { python3 -I - "$1" "$BEGIN" "$END" <<'PYEOF'
import sys
path, begin, end = sys.argv[1:4]
skip = False
out = []
for line in open(path, encoding="utf-8").read().split("\n"):
    if line.strip() == begin:
        skip = True
        continue
    if skip:
        if line.strip() == end:
            skip = False
        continue
    out.append(line)
sys.stdout.write("\n".join(out).rstrip("\n") + "\n")
PYEOF
}

# ------------------------------------------------ 1. the layout itself
LAYOUT="$(python3 -I - "$SNIP" <<'PYEOF'
import re, sys
text = open(sys.argv[1], encoding="utf-8").read()
m = re.search(r"^extra-keys\s*=\s*(.*)$", text, re.M)
if not m:
    print("NOLINE"); sys.exit(0)
src = m.group(1)
pos = 0
def ws():
    global pos
    while pos < len(src) and src[pos] in " \t":
        pos += 1
def word():
    global pos
    ws()
    if src[pos] in "'\"":
        q = src[pos]; pos += 1; start = pos
        while src[pos] != q:
            pos += 1
        w = src[start:pos]; pos += 1
        return w
    start = pos
    while pos < len(src) and src[pos] not in ",:]} \t":
        pos += 1
    return src[start:pos]
def parse():
    global pos
    ws()
    c = src[pos]
    if c == "[":
        pos += 1; out = []
        while True:
            ws()
            if src[pos] == "]":
                pos += 1; return out
            out.append(parse()); ws()
            if src[pos] == ",":
                pos += 1
    if c == "{":
        pos += 1; out = {}
        while True:
            ws()
            if src[pos] == "}":
                pos += 1; return out
            k = word(); ws()
            assert src[pos] == ":", "':' expected at %d" % pos
            pos += 1
            out[k] = parse(); ws()
            if src[pos] == ",":
                pos += 1
    return word()
try:
    rows = parse()
    ws()
    assert pos == len(src), "text after the closing bracket"
except Exception as e:
    print("PARSEERROR", e); sys.exit(0)
names = []
for row in rows:
    for k in row:
        if isinstance(k, dict):
            names.append(("macro:" + k["macro"]) if "macro" in k else k.get("key", "?"))
        else:
            names.append(k)
print("rows=%d" % len(rows))
print("lens=" + ",".join(str(len(r)) for r in rows))
print("names=|" + "|".join(names) + "|")
pops = []
for row in rows:
    for k in row:
        if isinstance(k, dict) and "popup" in k:
            p = k["popup"]
            pops.append(p if isinstance(p, str) else ("macro:" + p["macro"] if "macro" in p else p.get("key", "?")))
print("popups=" + " ".join(pops))
PYEOF
)"
line() { printf '%s\n' "$LAYOUT" | sed -n "s/^$1=//p"; }
check "Vorlage: genau eine extra-keys-Zeile"          1 "$(grep -c '^extra-keys *=' "$SNIP")"
check "Vorlage: Syntax lesbar (kein Parserfehler)"    "" "$(printf '%s\n' "$LAYOUT" | grep -E '^(PARSEERROR|NOLINE)')"
check "Vorlage: zwei Zeilen"                          2 "$(line rows)"
check "Vorlage: je sechs Tasten"                      "6,6" "$(line lens)"
names="$(line names)"
for want in ESC DEL UP ENTER CTRL ALT LEFT DOWN RIGHT KEYBOARD '/' 'macro:SHIFT TAB'; do
    case "$names" in *"|$want|"*) r=ja ;; *) r=nein ;; esac
    check "Vorlage: Taste $want vorhanden"            ja "$r"
done
for gone in PGUP PGDN TAB HOME END; do
    case "$names" in *"|$gone|"*) r=ja ;; *) r=nein ;; esac
    check "Vorlage: keine eigene Taste $gone"         nein "$r"
done
check "Vorlage: Wisch nach oben liefert -, TAB, HOME, END" "- macro:TAB HOME END" "$(line popups)"
check "Vorlage: Reihenfolge der Tasten"               "|ESC|/|macro:SHIFT TAB|DEL|UP|ENTER|KEYBOARD|CTRL|ALT|LEFT|DOWN|RIGHT|" "$names"
check "Vorlage: S-TAB beschriftet"                    1 "$(grep -c 'display: "S-TAB"' "$SNIP")"
check "Vorlage: keine Zeilenfortsetzung mit Backslash" 0 "$(grep -c '\\$' "$SNIP")"

# ------------------------------------------------ 2. fresh device (no termux.properties yet)
H1="$T/h1"; mkdir -p "$H1"; TP1="$H1/.termux/termux.properties"
rinstall "$H1"
check "frisch: Installer läuft"                       0 "$?"
check "frisch: termux.properties angelegt"            ja "$([ -f "$TP1" ] && echo ja || echo nein)"
check "frisch: Modus 600"                             600 "$(stat -c %a "$TP1")"
check "frisch: Block genau einmal"                    1 "$(blocks "$TP1")"
check "frisch: Blockinhalt = Vorlage"                 0 "$(inner "$TP1" | cmp -s - "$SNIP"; echo $?)"
check "frisch: Endmarke genau einmal"                 1 "$(grep -c -F -x "$END" "$TP1")"
check "frisch: genau eine aktive extra-keys-Zeile"    1 "$(grep -c '^extra-keys *=' "$TP1")"
check "frisch: Reload genau einmal"                   1 "$(reloads)"
check "frisch: keine Sicherung (nichts zu sichern)"   0 "$(baks "$H1")"
check "frisch: Hinweis am Ende"                       1 "$(grep -c '^Zusatztasten: S-TAB' "$T/install.log")"

# ------------------------------------------------ idempotence
sum1="$(cksum < "$TP1")"
rinstall "$H1"
check "zweiter Lauf: läuft durch"                     0 "$?"
check "zweiter Lauf: Datei unverändert"               "$sum1" "$(cksum < "$TP1")"
check "zweiter Lauf: Block weiter genau einmal"       1 "$(blocks "$TP1")"
check "zweiter Lauf: kein weiterer Reload"            1 "$(reloads)"
check "zweiter Lauf: keine Sicherung"                 0 "$(baks "$H1")"

# ------------------------------------------------ an older version of our block is updated
python3 -I - "$TP1" <<'PYEOF'
import sys
p = sys.argv[1]
t = open(p, encoding="utf-8").read()
lines = t.split("\n")
out = []
for l in lines:
    out.append("extra-keys = [['ESC','TAB','PGUP']]" if l.startswith("extra-keys") else l)
open(p, "w", encoding="utf-8").write("\n".join(out))
PYEOF
check "alter Block: Vorbereitung (alte Zeile steht)"  1 "$(grep -c "PGUP" "$TP1")"
rinstall "$H1"
check "alter Block: Installer läuft"                  0 "$?"
check "alter Block: auf die Vorlage gebracht"         0 "$(inner "$TP1" | cmp -s - "$SNIP"; echo $?)"
check "alter Block: weiter genau einmal"              1 "$(blocks "$TP1")"
check "alter Block: eine Sicherung"                   1 "$(baks "$H1")"
check "alter Block: Sicherung hat die alte Zeile"     1 "$(grep -c "PGUP" "$H1"/.termux/termux.properties.bak-*)"
check "alter Block: Reload erneut"                    2 "$(reloads)"
check "alter Block: Modus bleibt 600"                 600 "$(stat -c %a "$TP1")"

# ------------------------------------------------ 3. existing file of the user
H2="$T/h2"; mkdir -p "$H2/.termux"; TP2="$H2/.termux/termux.properties"
cat > "$TP2" <<'EOF'
### sample file of Termux
### Default extra-key configuration
# extra-keys = [[ESC, TAB, CTRL, ALT, {key: '-', popup: '|'}, DOWN, UP]]

# use-black-ui = true
allow-external-apps=true
EOF
chmod 600 "$TP2"; cp "$TP2" "$T/h2.orig"
: > "$RB_LOG"
rinstall "$H2"
check "Beispieldatei: Installer läuft"                0 "$?"
check "Beispieldatei: Block am Ende"                  "$END" "$(tail -n 1 "$TP2")"
check "Beispieldatei: übriger Inhalt unverändert"     0 "$(outer "$TP2" | cmp -s - "$T/h2.orig"; echo $?)"
check "Beispieldatei: auskommentierte Zeile zählt nicht als eigene" 1 "$(grep -c '^extra-keys *=' "$TP2")"
check "Beispieldatei: eine Sicherung mit altem Inhalt" "1 0" "$(baks "$H2") $(cmp -s "$T/h2.orig" "$H2"/.termux/termux.properties.bak-*; echo $?)"
check "Beispieldatei: Modus 600"                      600 "$(stat -c %a "$TP2")"
check "Beispieldatei: Reload einmal"                  1 "$(reloads)"

# ------------------------------------------------ a row of the user's own stays
for variant in single multi spaced; do
    H3="$T/h3-$variant"; mkdir -p "$H3/.termux"; TP3="$H3/.termux/termux.properties"
    case "$variant" in
        single) printf '%s\n' "extra-keys = [['ESC','TAB']]" "allow-external-apps=true" > "$TP3" ;;
        multi)  printf '%s\n' "extra-keys = [['ESC','/','-'], \\" "              ['TAB','CTRL','ALT']]" > "$TP3" ;;
        spaced) printf '%s\n' "  extra-keys=[[ESC]]" > "$TP3" ;;
    esac
    chmod 600 "$TP3"; sum3="$(cksum < "$TP3")"; : > "$RB_LOG"
    rinstall "$H3"
    check "eigene Zeile ($variant): Installer läuft"      0 "$?"
    check "eigene Zeile ($variant): Datei unverändert"    "$sum3" "$(cksum < "$TP3")"
    check "eigene Zeile ($variant): kein Block"           0 "$(blocks "$TP3")"
    check "eigene Zeile ($variant): Hinweis ausgegeben"   1 "$(grep -c 'eigene extra-keys-Zeile' "$T/install.log")"
    check "eigene Zeile ($variant): kein Reload"          0 "$(reloads)"
    check "eigene Zeile ($variant): keine Sicherung"      0 "$(baks "$H3")"
done

# ------------------------------------------------ 4. --no-extra-keys
H4="$T/h4"; mkdir -p "$H4"; : > "$RB_LOG"
rinstall "$H4" --no-extra-keys
check "--no-extra-keys: Installer läuft"              0 "$?"
check "--no-extra-keys: keine termux.properties"      nein "$([ -e "$H4/.termux/termux.properties" ] && echo ja || echo nein)"
check "--no-extra-keys: kein Reload"                  0 "$(reloads)"
check "--no-extra-keys: Hinweis ausgegeben"           1 "$(grep -c 'Zusatztasten übersprungen' "$T/install.log")"
check "--no-extra-keys: Abschlusshinweis fehlt"       0 "$(grep -c '^Zusatztasten: S-TAB' "$T/install.log")"

# ------------------------------------------------ uninstall removes only our block
H5="$T/h5"; mkdir -p "$H5/.termux"; TP5="$H5/.termux/termux.properties"
printf '%s\n' "allow-external-apps=true" "# use-black-ui = true" > "$TP5"; chmod 600 "$TP5"; cp "$TP5" "$T/h5.orig"
rinstall "$H5"
check "Deinstallation: Vorbereitung (Block steht)"    1 "$(blocks "$TP5")"
rununinstall "$H5"
check "Deinstallation: läuft durch"                   0 "$?"
check "Deinstallation: Block entfernt"                0 "$(blocks "$TP5")"
check "Deinstallation: übriger Inhalt wie vorher"     0 "$(cmp -s "$T/h5.orig" "$TP5"; echo $?)"
check "Deinstallation: Modus bleibt 600"              600 "$(stat -c %a "$TP5")"
# the user's own row survives an uninstall (it was never ours)
H6="$T/h6"; mkdir -p "$H6/.termux"; printf '%s\n' "extra-keys = [['ESC']]" > "$H6/.termux/termux.properties"
rununinstall "$H6"
check "Deinstallation: eigene Zeile bleibt"           1 "$(grep -c '^extra-keys' "$H6/.termux/termux.properties")"

# ------------------------------------------------ help text, nothing real started
help_out="$(bash "$INSTALL" --help 2>&1)"
check "--help nennt [--no-extra-keys]"                1 "$(printf '%s\n' "$help_out" | grep -c -- '\[--no-extra-keys\]')"
check "--help beschreibt S-TAB und KEYBOARD"          1 "$(printf '%s\n' "$help_out" | grep -c 'S-TAB = Shift+Tab, KEYBOARD')"
check "--help zeigt den ganzen Kopf (Schritt 5)"      1 "$(printf '%s\n' "$help_out" | grep -c 'stored as CLAUDE_UPDATE')"
check "--help läuft nicht in den Code hinein"         0 "$(printf '%s\n' "$help_out" | grep -c '^set -eu')"
check "Test hat nie das echte rootbridge/tmux/pkill gestartet" 0 "$(grep -vc '^rootbridge stop' "$STUB_LOG")"

echo
echo "Ergebnis: $PASS bestanden, $FAIL fehlgeschlagen"
[ "$FAIL" -eq 0 ]
