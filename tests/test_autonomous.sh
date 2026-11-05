#!/usr/bin/env bash
# Test: --autonomous (install.sh / guest install-guest.sh). Default yes: skipDangerousModePermissionPrompt is set;
# no: it is not (an earlier value stays); ask without a terminal: no; other values are rejected (exit 2).
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
        bash "$INSTALL" --no-boot --no-migrate --no-deps-check --no-extra-keys --no-colors "$@" > "$T/install.log" 2>&1
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
    bash "$INSTALL" --no-boot --no-migrate --no-deps-check --no-extra-keys --no-colors --autonomous maybe > "$T/install.log" 2>&1
check "install.sh: ungültiger Wert wird abgelehnt (Code 2)" 2 "$?"
check "install.sh: ungültiger Wert: Gast nicht angefasst" 0 "$(wc -c < "$STUB_LOG" | tr -d ' ')"

echo
echo "Ergebnis: $PASS bestanden, $FAIL fehlgeschlagen"
[ "$FAIL" -eq 0 ]
