#!/usr/bin/env bash
# Test: --autonomous, --model and the working directory (install.sh / guest install-guest.sh).
# Default yes: skipDangerousModePermissionPrompt is set and bypass mode is the start mode
# (permissions.defaultMode, only if there is none yet); no: neither is (an earlier value stays);
# ask without a terminal: no; other values are rejected (exit 2). Default model "opusplan" (only if there
# is none yet; --model writes it, --model none leaves it). /root/work is created (or the WORKDIR of the config).
# Nothing real is touched: staging root for the guest, fake HOME/PREFIX and a stub proot-distro for install.sh.
#   bash tests/test_autonomous.sh
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GUEST="$ROOT/guest/install-guest.sh"
INSTALL="$ROOT/install.sh"

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
export ROOTBRIDGE_GUEST_HOME=/home/tester

PASS=0; FAIL=0
check() {   # check <name> <expected> <actual>
    if [ "$2" = "$3" ]; then PASS=$((PASS + 1)); printf 'ok    %s\n' "$1"
    else FAIL=$((FAIL + 1)); printf 'FAIL  %s\n      erwartet: %s\n      erhalten: %s\n' "$1" "$2" "$3"; fi
}
flag() {   # flag <stage>: value of the key in the staged settings.json, "-" when it is not there
    python3 -I -c '
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except OSError:
    print("-"); raise SystemExit
print(d.get("skipDangerousModePermissionPrompt", "-"))' "$1/home/tester/.claude/settings.json"
}
ginstall() { local s="$1"; shift; bash "$GUEST" --root "$s" "$@" < /dev/null > "$T/guest.log" 2>&1; }
sget() {   # sget <stage> <dotted.key>: value from the staged settings.json, "-" when it is not there
    python3 -I -c '
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except OSError:
    print("-"); raise SystemExit
for k in sys.argv[2].split("."):
    if not isinstance(d, dict) or k not in d:
        print("-"); raise SystemExit
    d = d[k]
print(d)' "$1/home/tester/.claude/settings.json" "$2"
}
baks() { find "$1/home/tester/.claude" -name 'settings.json.bak-*' 2>/dev/null | wc -l | tr -d ' '; }
isdir() { if [ -d "$1" ]; then echo yes; else echo no; fi; }

# ------------------------------------------------------------ guest installer
S="$T/g1"; ginstall "$S"
check "Gast ohne Option: läuft"                          0 "$?"
check "Gast ohne Option: Bypass-Schalter gesetzt"        True "$(flag "$S")"

S="$T/g2"; ginstall "$S" --autonomous yes
check "Gast yes: Schalter gesetzt"                       True "$(flag "$S")"

S="$T/g3"; ginstall "$S" --autonomous no
check "Gast no: läuft"                                   0 "$?"
check "Gast no: Schalter nicht gesetzt"                  - "$(flag "$S")"

S="$T/g4"; ginstall "$S" --autonomous ask
check "Gast ask ohne Terminal: Schalter nicht gesetzt"   - "$(flag "$S")"

S="$T/g5"; ginstall "$S" --autonomous yes; ginstall "$S" --autonomous no
check "Gast: no entfernt einen früheren Wert nicht"      True "$(flag "$S")"

S="$T/g6"; ginstall "$S" --autonomous maybe
check "Gast: ungültiger Wert wird abgelehnt (Code 2)"    2 "$?"
check "Gast: ungültiger Wert: nichts installiert"        - "$(flag "$S")"

# ------------------------------------------------------------ start mode, model, working directory (guest)
S="$T/s1"; ginstall "$S"
check "Standard: Startmodus bypassPermissions"            bypassPermissions "$(sget "$S" permissions.defaultMode)"
check "Standard: Modell opusplan"                         opusplan "$(sget "$S" model)"
check "Standard: Bypass-Schalter weiter gesetzt"          True "$(sget "$S" skipDangerousModePermissionPrompt)"
check "Standard: /root/work angelegt"                     yes "$(isdir "$S/root/work")"
check "Standard: kein altes /root/workspace"              no "$(isdir "$S/root/workspace")"
check "Standard: Konfiguration enthält WORKDIR=/root/work" 1 "$(grep -c '^WORKDIR=/root/work$' "$S/etc/termux-rootbridge.conf")"
check "Standard: ein Schreibvorgang, keine Sicherung"     0 "$(baks "$S")"
ginstall "$S"
check "Zweiter Lauf: Startmodus unverändert"              bypassPermissions "$(sget "$S" permissions.defaultMode)"
check "Zweiter Lauf: keine Sicherung"                     0 "$(baks "$S")"

S="$T/s2"; ginstall "$S" --autonomous no
check "no: kein Startmodus"                               - "$(sget "$S" permissions.defaultMode)"
check "no: Modell kommt trotzdem (unabhängig)"            opusplan "$(sget "$S" model)"

S="$T/s3"; mkdir -p "$S/home/tester/.claude"
printf '%s\n' '{"model":"sonnet","theme":"dark","permissions":{"defaultMode":"plan","allow":["Bash(ls)"]}}' \
    > "$S/home/tester/.claude/settings.json"
ginstall "$S"
check "Eigene Werte: Startmodus plan bleibt"              plan "$(sget "$S" permissions.defaultMode)"
check "Eigene Werte: Modell sonnet bleibt"                sonnet "$(sget "$S" model)"
check "Eigene Werte: permissions.allow bleibt"            "['Bash(ls)']" "$(sget "$S" permissions.allow)"
check "Eigene Werte: theme bleibt"                        dark "$(sget "$S" theme)"
check "Eigene Werte: Bypass-Schalter kommt dazu"          True "$(sget "$S" skipDangerousModePermissionPrompt)"
ginstall "$S" --model opus
check "--model schreibt immer"                            opus "$(sget "$S" model)"

S="$T/s4"; ginstall "$S" --model none
check "--model none: läuft"                               0 "$?"
check "--model none: kein Modell"                         - "$(sget "$S" model)"
check "--model none: Startmodus trotzdem"                 bypassPermissions "$(sget "$S" permissions.defaultMode)"

S="$T/s5"; ginstall "$S" --model "bad name"
check "--model ungültig: Code 2"                          2 "$?"
check "--model ungültig: nichts installiert"              no "$(isdir "$S/etc")"

S="$T/s6"; mkdir -p "$S/etc"; printf 'WORKDIR=/root/custom\n' > "$S/etc/termux-rootbridge.conf"
ginstall "$S"
check "Eigener WORKDIR wird angelegt"                     yes "$(isdir "$S/root/custom")"
check "Eigener WORKDIR: /root/work nicht zusätzlich"      no "$(isdir "$S/root/work")"

S="$T/s7"; mkdir -p "$S/etc"; printf 'WORKDIR=/root/../tmp/x\n' > "$S/etc/termux-rootbridge.conf"
ginstall "$S"
check "WORKDIR mit '..': Rückfall auf /root/work"         yes "$(isdir "$S/root/work")"
check "WORKDIR mit '..': nichts außerhalb angelegt"       no "$(isdir "$S/tmp/x")"

S="$T/s8"; mkdir -p "$S/home/tester/.claude"; printf '{kaputt' > "$S/home/tester/.claude/settings.json"
before="$(cksum < "$S/home/tester/.claude/settings.json")"
ginstall "$S"
check "Kaputte settings.json: Installer läuft"            0 "$?"
check "Kaputte settings.json: Datei unberührt"            "$before" "$(cksum < "$S/home/tester/.claude/settings.json")"
check "Kaputte settings.json: genau eine Warnung"         1 "$(grep -c 'kein gültiges JSON' "$T/guest.log")"
check "Kaputte settings.json: keine Sicherung"            0 "$(baks "$S")"

# old default WORKDIR=/root/workspace (never created) moves to /root/work; a folder that exists stays
S="$T/m1"; mkdir -p "$S/etc"; printf 'DISTRO=ubuntu\nWORKDIR=/root/workspace\nSESSION=ubuntu\n' > "$S/etc/termux-rootbridge.conf"
ginstall "$S"
check "Altes WORKDIR ohne Ordner: wird /root/work"          1 "$(grep -c '^WORKDIR=/root/work$' "$S/etc/termux-rootbridge.conf")"
check "Altes WORKDIR ohne Ordner: /root/work angelegt"      yes "$(isdir "$S/root/work")"
check "Altes WORKDIR ohne Ordner: kein /root/workspace"     no "$(isdir "$S/root/workspace")"
check "Altes WORKDIR ohne Ordner: Meldung"                  1 "$(grep -c 'WORKDIR: /root/workspace -> /root/work' "$T/guest.log")"
check "Altes WORKDIR ohne Ordner: andere Zeilen bleiben"    1 "$(grep -c '^SESSION=ubuntu$' "$S/etc/termux-rootbridge.conf")"
ginstall "$S"
check "Zweiter Lauf: keine erneute Umstellung"              0 "$(grep -c 'WORKDIR: /root/workspace' "$T/guest.log")"

S="$T/m2"; mkdir -p "$S/etc" "$S/root/workspace"; printf 'WORKDIR=/root/workspace\n' > "$S/etc/termux-rootbridge.conf"
ginstall "$S"
check "Vorhandenes /root/workspace: WORKDIR bleibt"         1 "$(grep -c '^WORKDIR=/root/workspace$' "$S/etc/termux-rootbridge.conf")"
check "Vorhandenes /root/workspace: kein /root/work"        no "$(isdir "$S/root/work")"

# ------------------------------------------------------------ install.sh -> guest (stub proot-distro)
H="$T/home"; P="$T/prefix"; GROOT="$T/groot"; GUEST_ROOT="$T/guestroot"
mkdir -p "$H" "$P/bin" "$GROOT/var/tmp" "$T/stubs" "$P/var/lib/proot-distro/containers/ubuntu"
ln -s "$GROOT" "$P/var/lib/proot-distro/containers/ubuntu/rootfs"
cat > "$T/stubs/proot-distro" <<'STUB'
#!/bin/bash
# fake proot-distro: runs the guest installer against a staging root and logs its arguments
[ "$1" = login ] || exit 0
shift 3; shift
script="$STUB_GROOT$1"; shift
args=()
while [ $# -gt 0 ]; do
    case "$1" in /var/tmp/*) args+=("$STUB_GROOT$1") ;; *) args+=("$1") ;; esac
    shift
done
echo "${args[*]}" >> "$STUB_LOG"
exec bash "$script" --root "$STUB_GUEST_ROOT" "${args[@]}" < /dev/null
STUB
printf '#!/bin/bash\nexit 0\n' > "$T/stubs/termux-reload-settings"
chmod +x "$T/stubs"/*
export STUB_LOG="$T/proot.log" STUB_GROOT="$GROOT" STUB_GUEST_ROOT="$GUEST_ROOT"
rinstall() {
    rm -rf "$GUEST_ROOT"; : > "$STUB_LOG"
    HOME="$H" PREFIX="$P" PATH="$T/stubs:$PATH" ROOTBRIDGE_ALLOW_GUEST=1 BRIDGE_DIR="$H/.rootbridge" \
        bash "$INSTALL" --no-boot --no-migrate --no-deps-check --no-extra-keys --no-colors --no-setup "$@" > "$T/install.log" 2>&1
}

rinstall
check "install.sh ohne Option: läuft"                    0 "$?"
check "install.sh ohne Option: gibt yes an den Gast"     1 "$(grep -c -- '--autonomous yes' "$STUB_LOG")"
check "install.sh ohne Option: Schalter im Gast"         True "$(flag "$GUEST_ROOT")"

rinstall --autonomous no
check "install.sh no: gibt no an den Gast"               1 "$(grep -c -- '--autonomous no' "$STUB_LOG")"
check "install.sh no: Schalter nicht gesetzt"            - "$(flag "$GUEST_ROOT")"

rm -rf "$GUEST_ROOT"; : > "$STUB_LOG"
HOME="$H" PREFIX="$P" PATH="$T/stubs:$PATH" ROOTBRIDGE_ALLOW_GUEST=1 BRIDGE_DIR="$H/.rootbridge" \
    bash "$INSTALL" --no-boot --no-migrate --no-deps-check --no-extra-keys --no-colors --no-setup --autonomous maybe > "$T/install.log" 2>&1
check "install.sh: ungültiger Wert wird abgelehnt (Code 2)" 2 "$?"
check "install.sh: ungültiger Wert: Gast nicht angefasst" 0 "$(wc -c < "$STUB_LOG" | tr -d ' ')"

rinstall
check "install.sh ohne --model: reicht keins an den Gast" 0 "$(grep -c -- '--model' "$STUB_LOG")"
check "install.sh ohne --model: Standardmodell im Gast"   opusplan "$(sget "$GUEST_ROOT" model)"
check "install.sh: Startmodus bypassPermissions im Gast"  bypassPermissions "$(sget "$GUEST_ROOT" permissions.defaultMode)"
check "install.sh: /root/work im Gast angelegt"           yes "$(isdir "$GUEST_ROOT/root/work")"
check "install.sh: Termux-Konfig WORKDIR=/root/work"      1 "$(grep -c '^WORKDIR=/root/work$' "$H/.config/termux-rootbridge/config")"
check "install.sh: Abschlussmeldung nennt Bypass+work"    1 "$(grep -c 'Bypass-Modus im Ordner /root/work' "$T/install.log")"

# Termux config written by an earlier version: old default is migrated (no folder in the guest), the guest follows
mkdir -p "$H/.config/termux-rootbridge"
printf 'DISTRO=ubuntu\nWORKDIR=/root/workspace\nSESSION=ubuntu\n' > "$H/.config/termux-rootbridge/config"
rinstall
check "install.sh: alte Termux-Konfig wird auf /root/work gestellt" 1 "$(grep -c '^WORKDIR=/root/work$' "$H/.config/termux-rootbridge/config")"
check "install.sh: alte Termux-Konfig: Sicherung angelegt"          1 "$(ls "$H/.config/termux-rootbridge"/config.bak-* 2>/dev/null | wc -l | tr -d ' ')"
check "install.sh: alte Konfig: /root/work im Gast"                 yes "$(isdir "$GUEST_ROOT/root/work")"
printf 'DISTRO=ubuntu\nWORKDIR=/root/workspace\n' > "$H/.config/termux-rootbridge/config"
mkdir -p "$GROOT/root/workspace"
rinstall
check "install.sh: vorhandenes /root/workspace im Gast: bleibt"     1 "$(grep -c '^WORKDIR=/root/workspace$' "$H/.config/termux-rootbridge/config")"
rmdir "$GROOT/root/workspace"

rinstall --model none
check "install.sh --model none: gibt es an den Gast"      1 "$(grep -c -- '--model none' "$STUB_LOG")"
check "install.sh --model none: kein Modell im Gast"      - "$(sget "$GUEST_ROOT" model)"

rinstall --autonomous no
check "install.sh no: kein Startmodus im Gast"            - "$(sget "$GUEST_ROOT" permissions.defaultMode)"
check "install.sh no: Abschlussmeldung ohne Bypass-Satz"  0 "$(grep -c 'Bypass-Modus im Ordner' "$T/install.log")"

rm -rf "$GUEST_ROOT"; : > "$STUB_LOG"
HOME="$H" PREFIX="$P" PATH="$T/stubs:$PATH" ROOTBRIDGE_ALLOW_GUEST=1 BRIDGE_DIR="$H/.rootbridge" \
    bash "$INSTALL" --no-boot --no-migrate --no-deps-check --no-extra-keys --no-colors --no-setup --model "bad name" > "$T/install.log" 2>&1
check "install.sh --model ungültig: Code 2"               2 "$?"
check "install.sh --model ungültig: Gast nicht angefasst" 0 "$(wc -c < "$STUB_LOG" | tr -d ' ')"

echo
echo "Ergebnis: $PASS bestanden, $FAIL fehlgeschlagen"
[ "$FAIL" -eq 0 ]
