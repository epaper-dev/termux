#!/usr/bin/env bash
# Test: automatic apt-get update + upgrade at the start of the Claude Code session.
#   1. guest/bin/rootbridge-apt with stub apt-get/apt-mark/dpkg/dpkg-query/timeout (real apt is
#      never started: the stubs stay in front of PATH, ROOTBRIDGE_APT_KEEP_PATH)
#   2. guest installer: script, config keys, --apt-upgrade, uninstall
#   3. install.sh with a fake HOME/PREFIX: --apt-upgrade / --no-apt-upgrade, stored in the Termux config
#   bash tests/test_apt_upgrade.sh
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APT="$ROOT/guest/bin/rootbridge-apt"
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

# ------------------------------------------------ 1. rootbridge-apt with stubs
mkdir -p "$T/stubs" "$T/state"
cat > "$T/stubs/apt-get" <<'EOF'
#!/bin/bash
echo "apt-get $*" >> "$STUB_LOG"
echo "env DEBIAN_FRONTEND=${DEBIAN_FRONTEND:-} LISTCHANGES=${APT_LISTCHANGES_FRONTEND:-}" >> "$STUB_LOG"
echo "stub apt-get: $*"
for a in "$@"; do
    case "$a" in
        update) exit "${STUB_UPDATE_RC:-0}" ;;
        upgrade) exit "${STUB_UPGRADE_RC:-0}" ;;
    esac
done
exit 0
EOF
cat > "$T/stubs/apt-mark" <<'EOF'
#!/bin/bash
echo "apt-mark $*" >> "$STUB_LOG"
case "$1" in
    showhold) cat "$STUB_HOLDS" 2>/dev/null ;;
    hold) echo "$2" >> "$STUB_HOLDS" ;;
esac
exit 0
EOF
cat > "$T/stubs/dpkg-query" <<'EOF'
#!/bin/bash
pkg="${*: -1}"
case " ${STUB_INSTALLED:-} " in *" $pkg "*) printf 'ii ' ;; *) exit 1 ;; esac
EOF
cat > "$T/stubs/dpkg" <<'EOF'
#!/bin/bash
echo "dpkg $*" >> "$STUB_LOG"
[ "$1" = --audit ] && [ -n "${STUB_AUDIT:-}" ] && echo "$STUB_AUDIT"
exit 0
EOF
cat > "$T/stubs/timeout" <<'EOF'
#!/bin/bash
echo "timeout $1" >> "$STUB_LOG"
shift
exec "$@"
EOF
chmod +x "$T"/stubs/*
export STUB_LOG="$T/stub.log" STUB_HOLDS="$T/holds"
ALL_PKGS="rust-coreutils gnu-coreutils coreutils-from-uutils coreutils"
CONF="$T/conf"

mkconf() { printf '%s\n' "$@" > "$CONF"; }   # mkconf KEY=VALUE...
run_apt() {   # run_apt [VAR=value ...]: one run of rootbridge-apt; exit code in $RC, output in $T/out.txt
    : > "$STUB_LOG"
    env PATH="$T/stubs:$PATH" ROOTBRIDGE_APT_KEEP_PATH=1 ROOTBRIDGE_APT_ALLOW_NONROOT=1 \
        ROOTBRIDGE_CONF="$CONF" ROOTBRIDGE_APT_STATE_DIR="$T/state" ROOTBRIDGE_APT_LOG="$T/apt.log" \
        STUB_INSTALLED="$ALL_PKGS" "$@" bash "$APT" > "$T/out.txt" 2>&1
    RC=$?
}
reset_state() { rm -rf "$T/state" "$T/apt.log" "$STUB_HOLDS"; mkdir -p "$T/state"; }
calls() { grep -c "$1" "$STUB_LOG" || true; }          # number of log lines matching a pattern
out_has() { grep -c "$1" "$T/out.txt" || true; }
stamp_exists() { [ -s "$T/state/apt-last-success" ] && echo ja || echo nein; }
line_of() { grep -n "$1" "$STUB_LOG" | head -n 1 | cut -d: -f1; }

# --- default: daily, no stamp yet
reset_state; mkconf "APT_UPGRADE=daily"
run_apt
check "daily ohne Stempel: Exit 0"                    0 "$RC"
check "update genau einmal"                           1 "$(calls 'apt-get .* update$')"
check "upgrade genau einmal"                          1 "$(calls 'apt-get .* upgrade$')"
check "update kommt vor upgrade"                      1 "$([ "$(line_of 'apt-get .* update$')" -lt "$(line_of 'apt-get .* upgrade$')" ] && echo 1 || echo 0)"
check "upgrade mit -y"                                1 "$(calls 'apt-get -y .* upgrade$')"
check "upgrade mit DPkg::Path inkl. /usr/local/bin"   1 "$(calls 'apt-get .*DPkg::Path=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin .* upgrade$')"
check "upgrade mit --force-confold"                   1 "$(calls 'apt-get .*--force-confold .* upgrade$')"
check "noninteractive gesetzt"                        2 "$(calls '^env DEBIAN_FRONTEND=noninteractive LISTCHANGES=none')"
check "Netz-Timeouts beim update"                     1 "$(calls 'apt-get .*Acquire::http::Timeout=15 .* update$')"
check "Timeouts: 120 s update, 600 s upgrade"         "timeout 120|timeout 600" "$(grep '^timeout ' "$STUB_LOG" | tr '\n' '|' | sed 's/|$//')"
check "vier coreutils-Pakete auf hold"                4 "$(calls '^apt-mark hold ')"
check "hold: rust-coreutils"                          1 "$(calls '^apt-mark hold rust-coreutils$')"
check "Stempel geschrieben"                           ja "$(stamp_exists)"
check "Stempel ist eine Zahl"                         1 "$([[ "$(cat "$T/state/apt-last-success")" =~ ^[0-9]{9,12}$ ]] && echo 1 || echo 0)"
check "Log enthält Lauf-Kopf und apt-Ausgabe"         2 "$(grep -c '^=== \|^stub apt-get: .*update$' "$T/apt.log")"
check "Ausgabe endet mit 'fertig'"                    1 "$(out_has 'apt: fertig')"

# --- daily with a fresh stamp: nothing runs
now="$(date +%s)"
printf '%s\n' "$((now - 3600))" > "$T/state/apt-last-success"
run_apt
check "daily, Stempel 1 h alt: Exit 0"                0 "$RC"
check "daily, Stempel 1 h alt: kein apt-get"          0 "$(calls '^apt-get ')"
check "daily, Stempel 1 h alt: Hinweis 'übersprungen'" 1 "$(out_has 'übersprungen')"

# --- daily with an old / future / broken stamp: runs
for s in "$((now - 90000))" "$((now + 99999))" "abc" ""; do
    printf '%s\n' "$s" > "$T/state/apt-last-success"
    run_apt
    check "daily, Stempel '${s:0:10}': läuft"         "1 1" "$(calls 'apt-get .* update$') $(calls 'apt-get .* upgrade$')"
done

# --- always ignores the stamp
printf '%s\n' "$((now - 60))" > "$T/state/apt-last-success"
mkconf "APT_UPGRADE=always"
run_apt
check "always, frischer Stempel: läuft trotzdem"      "1 1" "$(calls 'apt-get .* update$') $(calls 'apt-get .* upgrade$')"

# --- off / unknown / missing mode
reset_state; mkconf "APT_UPGRADE=off"
run_apt
check "off: Exit 0"                                   0 "$RC"
check "off: kein apt-get"                             0 "$(calls '^apt-get ')"
check "off: keine Ausgabe"                            0 "$(wc -c < "$T/out.txt" | tr -d ' ')"
check "off: kein Stempel"                             nein "$(stamp_exists)"

mkconf "APT_UPGRADE=banana"
run_apt
check "unbekannter Wert: Exit 0"                      0 "$RC"
check "unbekannter Wert: kein apt-get"                0 "$(calls '^apt-get ')"
check "unbekannter Wert: Warnung"                     1 "$(out_has 'unbekannter Wert APT_UPGRADE=banana')"

mkconf "WORKDIR=/x"
run_apt
check "ohne APT_UPGRADE-Zeile: Standard daily, läuft" "1 1" "$(calls 'apt-get .* update$') $(calls 'apt-get .* upgrade$')"
reset_state; rm -f "$CONF"
run_apt
check "ohne Konfig-Datei: Standard daily, läuft"      "1 1" "$(calls 'apt-get .* update$') $(calls 'apt-get .* upgrade$')"

# --- failures never stop the start and leave no stamp
reset_state; mkconf "APT_UPGRADE=daily"
run_apt STUB_UPDATE_RC=100
check "update schlägt fehl: Exit 0"                   0 "$RC"
check "update schlägt fehl: kein upgrade"             0 "$(calls 'apt-get .* upgrade$')"
check "update schlägt fehl: kein Stempel"             nein "$(stamp_exists)"
check "update schlägt fehl: Meldung"                  1 "$(out_has 'update fehlgeschlagen')"
check "update schlägt fehl: kein apt-mark hold"       0 "$(calls '^apt-mark hold')"

run_apt STUB_UPGRADE_RC=100
check "upgrade schlägt fehl: Exit 0"                  0 "$RC"
check "upgrade schlägt fehl: kein Stempel"            nein "$(stamp_exists)"
check "upgrade schlägt fehl: Meldung nennt das Log"   1 "$(out_has 'upgrade fehlgeschlagen')"

run_apt "STUB_AUDIT=iF  foo  1.0  broken"
check "dpkg --audit meldet etwas: Exit 0"             0 "$RC"
check "dpkg --audit meldet etwas: kein Stempel"       nein "$(stamp_exists)"
check "dpkg --audit meldet etwas: Warnung"            1 "$(out_has 'WARNUNG')"

# --- holds
reset_state; mkconf "APT_UPGRADE=daily"
run_apt "STUB_INSTALLED=rust-coreutils coreutils"
check "nur installierte Pakete werden gehalten"       2 "$(calls '^apt-mark hold ')"
check "nicht installiert: kein hold für gnu-coreutils" 0 "$(calls '^apt-mark hold gnu-coreutils$')"

reset_state; printf '%s\n' rust-coreutils > "$STUB_HOLDS"
run_apt
check "schon auf hold: nicht doppelt gesetzt"         0 "$(calls '^apt-mark hold rust-coreutils$')"
check "schon auf hold: die anderen drei schon"        3 "$(calls '^apt-mark hold ')"

reset_state; mkconf "APT_UPGRADE=daily" "APT_HOLD="
run_apt
check "APT_HOLD leer: kein hold"                      0 "$(calls '^apt-mark hold')"
check "APT_HOLD leer: upgrade läuft"                  1 "$(calls 'apt-get .* upgrade$')"

reset_state; mkconf "APT_UPGRADE=daily" 'APT_HOLD="foo bar"'
run_apt "STUB_INSTALLED=foo rust-coreutils"
check "APT_HOLD eigene Liste: nur foo (installiert)"  "apt-mark hold foo" "$(grep '^apt-mark hold ' "$STUB_LOG")"

reset_state; mkconf "APT_UPGRADE=daily" 'APT_HOLD=a;b $(id)'
run_apt
check "APT_HOLD mit Sonderzeichen: Standardliste"     4 "$(calls '^apt-mark hold ')"

# --- APT_TIMEOUT
for pair in "900:900" "60:60" "3600:3600" "5:600" "99999:600" "abc:600" "-1:600"; do
    reset_state; mkconf "APT_UPGRADE=daily" "APT_TIMEOUT=${pair%%:*}"
    run_apt
    check "APT_TIMEOUT=${pair%%:*} -> ${pair##*:} s"  "timeout 120|timeout ${pair##*:}" "$(grep '^timeout ' "$STUB_LOG" | tr '\n' '|' | sed 's/|$//')"
done

# --- log stays small
reset_state; mkconf "APT_UPGRADE=daily"
awk 'BEGIN { for (i = 0; i < 5000; i++) print "old log line " i " with some padding to make the file big enough, 0123456789" }' > "$T/apt.log"
size_before="$(wc -c < "$T/apt.log" | tr -d ' ')"
run_apt
check "Log > 256 KiB wird gekürzt"                    1 "$([ "$(wc -c < "$T/apt.log")" -lt "$size_before" ] && echo 1 || echo 0)"
check "Log: neuer Lauf steht drin"                    1 "$(grep -c '^=== ' "$T/apt.log")"

# --- not root (only checkable when the tests do not run as root)
if [ "$(id -u)" -ne 0 ]; then
    reset_state; mkconf "APT_UPGRADE=daily"; : > "$STUB_LOG"
    env PATH="$T/stubs:$PATH" ROOTBRIDGE_APT_KEEP_PATH=1 ROOTBRIDGE_CONF="$CONF" \
        ROOTBRIDGE_APT_STATE_DIR="$T/state" ROOTBRIDGE_APT_LOG="$T/apt.log" bash "$APT" > "$T/out.txt" 2>&1
    check "ohne root: Exit 0"                         0 "$?"
    check "ohne root: kein apt-get"                   0 "$(calls '^apt-get ')"
    check "ohne root: Hinweis"                        1 "$(out_has 'braucht root')"
fi

# --- rootbridge-claude calls it before `claude update`, and never lets it stop the start
rc_apt="$(grep -n 'rootbridge-apt ||' "$ROOT/guest/bin/rootbridge-claude" | head -n 1 | cut -d: -f1)"
rc_upd="$(grep -n 'echo "== claude update"' "$ROOT/guest/bin/rootbridge-claude" | head -n 1 | cut -d: -f1)"
check "rootbridge-claude: apt vor claude update"      1 "$([ -n "$rc_apt" ] && [ -n "$rc_upd" ] && [ "$rc_apt" -lt "$rc_upd" ] && echo 1 || echo 0)"
check "rootbridge-claude: Fehler von apt egal (|| true)" 1 "$(grep -c 'rootbridge-apt || true' "$ROOT/guest/bin/rootbridge-claude")"

# ------------------------------------------------------ 2. guest installer
gconf() { printf '%s' "$1/etc/termux-root-bridge.conf"; }
gval() { grep "^$2=" "$(gconf "$1")" 2>/dev/null || true; }
gcount() { grep -c "^$2=" "$(gconf "$1")" 2>/dev/null || true; }
ginstall() {  # ginstall <stage> [args...]
    local stage="$1"; shift
    bash "$GUEST" --root "$stage" --autonomous no "$@" > "$T/guest.log" 2>&1
}
cbak() { find "$1/etc" -name 'termux-root-bridge.conf.bak-*' 2>/dev/null | wc -l | tr -d ' '; }

S="$T/g1"
ginstall "$S"
check "Gast ohne Option: Installer läuft"             0 "$?"
check "Gast: APT_UPGRADE=daily als Standard"          "APT_UPGRADE=daily" "$(gval "$S" APT_UPGRADE)"
check "Gast: APT_TIMEOUT=600"                         "APT_TIMEOUT=600" "$(gval "$S" APT_TIMEOUT)"
check "Gast: APT_HOLD mit den coreutils-Paketen"      "APT_HOLD=rust-coreutils gnu-coreutils coreutils-from-uutils coreutils" "$(gval "$S" APT_HOLD)"
check "Gast: rootbridge-apt installiert"              ja "$([ -x "$S/usr/local/bin/rootbridge-apt" ] && echo ja || echo nein)"
check "Gast: rootbridge-apt hat Gast-Shebang"         "#!/bin/bash" "$(head -n 1 "$S/usr/local/bin/rootbridge-apt")"
check "Gast: rootbridge-claude hat den apt-Aufruf"    1 "$(grep -c 'rootbridge-apt || true' "$S/usr/local/bin/rootbridge-claude")"

before="$(cksum < "$(gconf "$S")")"; b0="$(cbak "$S")"
ginstall "$S"
check "Gast zweiter Lauf: Konfig unverändert"         "$before" "$(cksum < "$(gconf "$S")")"
check "Gast zweiter Lauf: keine neue Sicherung"       "$b0" "$(cbak "$S")"

ginstall "$S" --apt-upgrade off
check "Gast --apt-upgrade off"                        "APT_UPGRADE=off" "$(gval "$S" APT_UPGRADE)"
check "Gast --apt-upgrade off: genau eine Zeile"      1 "$(gcount "$S" APT_UPGRADE)"
check "Gast --apt-upgrade off: WORKDIR bleibt"        "WORKDIR=/root/workspace" "$(gval "$S" WORKDIR)"
before="$(cksum < "$(gconf "$S")")"; b0="$(cbak "$S")"
ginstall "$S" --apt-upgrade off
check "Gast --apt-upgrade off wiederholt: unverändert" "$before" "$(cksum < "$(gconf "$S")")"
check "Gast --apt-upgrade off wiederholt: keine Sicherung" "$b0" "$(cbak "$S")"
ginstall "$S"
check "Gast ohne Option: off bleibt"                  "APT_UPGRADE=off" "$(gval "$S" APT_UPGRADE)"
ginstall "$S" --apt-upgrade always
check "Gast --apt-upgrade always"                     "APT_UPGRADE=always" "$(gval "$S" APT_UPGRADE)"
ginstall "$S" --apt-upgrade daily
check "Gast --apt-upgrade daily"                      "APT_UPGRADE=daily" "$(gval "$S" APT_UPGRADE)"

S="$T/g2"; mkdir -p "$S/etc"; printf '%s\n' "WORKDIR=/srv/mine" "APT_UPGRADE=always" "APT_TIMEOUT=900" > "$(gconf "$S")"
ginstall "$S"
check "Eigene Werte bleiben: APT_UPGRADE"             "APT_UPGRADE=always" "$(gval "$S" APT_UPGRADE)"
check "Eigene Werte bleiben: APT_TIMEOUT"             "APT_TIMEOUT=900" "$(gval "$S" APT_TIMEOUT)"
check "Eigene Werte bleiben: WORKDIR"                 "WORKDIR=/srv/mine" "$(gval "$S" WORKDIR)"

for bad in "" Daily banana "on" "daily;id" "-x"; do
    S="$T/bad"; rm -rf "$S"
    bash "$GUEST" --root "$S" --autonomous no --apt-upgrade "$bad" > /dev/null 2>&1
    code=$?
    check "ungültiger Modus '${bad:0:8}': Abbruch mit 2"  2 "$code"
    check "ungültiger Modus '${bad:0:8}': nichts geschrieben" nein "$([ -e "$S" ] && echo ja || echo nein)"
done
bash "$GUEST" --root "$T/bad" --apt-upgrade > /dev/null 2>&1
check "--apt-upgrade ohne Wert: Abbruch mit 2"        2 "$?"

S="$T/g3"; ginstall "$S"; mkdir -p "$S/var/lib/termux-root-bridge"; echo 1 > "$S/var/lib/termux-root-bridge/apt-last-success"
bash "$GUEST" --root "$S" --uninstall > "$T/guest.log" 2>&1
check "Deinstallation: rootbridge-apt entfernt"       nein "$([ -e "$S/usr/local/bin/rootbridge-apt" ] && echo ja || echo nein)"
check "Deinstallation: Stempel-Ordner entfernt"       nein "$([ -e "$S/var/lib/termux-root-bridge" ] && echo ja || echo nein)"

# ----------------------------------------------- 3. install.sh (fake Termux)
H="$T/home"; P="$T/prefix"; GROOT="$T/groot"; GUEST_ROOT="$T/guestroot"
mkdir -p "$H" "$P/bin" "$GROOT/var/tmp" "$P/var/lib/proot-distro/containers/ubuntu"
ln -s "$GROOT" "$P/var/lib/proot-distro/containers/ubuntu/rootfs"
cat > "$T/stubs/proot-distro" <<'EOF'
#!/bin/bash
# fake proot-distro: logs the call and runs the guest installer against a staging root
echo "$*" >> "$PROOT_LOG"
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
printf '#!/bin/bash\nexit 0\n' > "$T/stubs/termux-reload-settings"
chmod +x "$T/stubs/proot-distro" "$T/stubs/termux-reload-settings"
export PROOT_LOG="$T/proot.log" STUB_GROOT="$GROOT" STUB_GUEST_ROOT="$GUEST_ROOT"
: > "$PROOT_LOG"
[ -x "$T/stubs/proot-distro" ] && [ -d "$P/bin" ] || { echo "ABBRUCH: Testumgebung unvollständig" >&2; exit 1; }

rinstall() {  # rinstall <home> [args...]  (fake HOME/PREFIX, stub proot-distro, no migration, no deps check)
    local home="$1"; shift
    HOME="$home" PREFIX="$P" PATH="$T/stubs:$PATH" ROOTBRIDGE_ALLOW_GUEST=1 BRIDGE_DIR="$home/.rootbridge" \
        bash "$INSTALL" --no-boot --no-migrate --no-deps-check --autonomous no "$@" > "$T/install.log" 2>&1
}
CFG="$H/.config/termux-root-bridge/config"
tval() { grep '^APT_UPGRADE=' "$CFG" 2>/dev/null || true; }
tcount() { grep -c '^APT_UPGRADE=' "$CFG" 2>/dev/null || true; }
gv() { grep '^APT_UPGRADE=' "$GUEST_ROOT/etc/termux-root-bridge.conf" 2>/dev/null || true; }
passed() { grep -c -- "--apt-upgrade $1" "$PROOT_LOG" || true; }

rinstall "$H" --no-apt-upgrade
check "install.sh --no-apt-upgrade: läuft durch"      0 "$?"
check "Termux-Konfig: APT_UPGRADE=off"                "APT_UPGRADE=off" "$(tval)"
check "Termux-Konfig: genau eine Zeile"               1 "$(tcount)"
check "Gast-Installer bekam --apt-upgrade off"        1 "$(passed off)"
check "Gast-Konfig: APT_UPGRADE=off"                  "APT_UPGRADE=off" "$(gv)"

cfg_before="$(cksum < "$CFG")"
rinstall "$H"
check "Zweiter Lauf ohne Option: läuft durch"         0 "$?"
check "Zweiter Lauf: Termux-Konfig unverändert"       "$cfg_before" "$(cksum < "$CFG")"
check "Zweiter Lauf: off aus der Konfig übernommen"   2 "$(passed off)"

rm -rf "$GUEST_ROOT"
rinstall "$H"
check "Frischer Gast: off kommt aus der Termux-Konfig" "APT_UPGRADE=off" "$(gv)"

rinstall "$H" --apt-upgrade always
check "--apt-upgrade always: Termux-Konfig"           "APT_UPGRADE=always" "$(tval)"
check "--apt-upgrade always: weiter eine Zeile"       1 "$(tcount)"
check "--apt-upgrade always: Gast-Konfig"             "APT_UPGRADE=always" "$(gv)"

rinstall "$H" --no-apt-upgrade --apt-upgrade daily
check "Letzte Option gewinnt (daily)"                 "APT_UPGRADE=daily" "$(tval)"

# hand-edited invalid value in the Termux config: ignored, nothing passed on
sed -i 's|^APT_UPGRADE=.*|APT_UPGRADE=banana|' "$CFG"
: > "$PROOT_LOG"
rinstall "$H"
check "Ungültiger Wert in der Konfig wird ignoriert"  0 "$(grep -c -- '--apt-upgrade' "$PROOT_LOG")"

# no config, no option: nothing passed on, the guest falls back to its default
H2="$T/home2"; mkdir -p "$H2"; : > "$PROOT_LOG"; rm -rf "$GUEST_ROOT"
rinstall "$H2"
check "Ohne Option und Konfig: Installer läuft"       0 "$?"
check "Ohne Option und Konfig: nichts an den Gast"    0 "$(grep -c -- '--apt-upgrade' "$PROOT_LOG")"
check "Ohne Option und Konfig: keine Zeile in Termux" 0 "$(grep -c '^APT_UPGRADE=' "$H2/.config/termux-root-bridge/config")"
check "Ohne Option und Konfig: Gast-Standard daily"   "APT_UPGRADE=daily" "$(gv)"

# invalid option values: abort with 2 before anything is written
for bad in banana Daily "" "-x"; do
    H3="$T/home3"; rm -rf "$H3"; mkdir -p "$H3"
    HOME="$H3" PREFIX="$P" PATH="$T/stubs:$PATH" ROOTBRIDGE_ALLOW_GUEST=1 bash "$INSTALL" --no-deps-check --apt-upgrade "$bad" > /dev/null 2>&1
    check "install.sh --apt-upgrade '$bad': Abbruch mit 2" 2 "$?"
    check "install.sh --apt-upgrade '$bad': nichts geschrieben" nein "$([ -e "$H3/.config" ] && echo ja || echo nein)"
done
HOME="$H3" PREFIX="$P" PATH="$T/stubs:$PATH" ROOTBRIDGE_ALLOW_GUEST=1 bash "$INSTALL" --no-deps-check --apt-upgrade > /dev/null 2>&1
check "install.sh --apt-upgrade ohne Wert: Abbruch mit 2" 2 "$?"

# --no-guest: mode is stored, guest installer not called
H4="$T/home4"; mkdir -p "$H4"; : > "$PROOT_LOG"
rinstall "$H4" --no-guest --no-apt-upgrade
check "--no-guest: Modus gespeichert"                 "APT_UPGRADE=off" "$(grep '^APT_UPGRADE=' "$H4/.config/termux-root-bridge/config")"
check "--no-guest: Gast-Installer nicht aufgerufen"   0 "$(wc -l < "$PROOT_LOG" | tr -d ' ')"

# --help mentions the options
help_out="$(bash "$INSTALL" --help 2>&1)"
check "--help nennt --no-apt-upgrade"                 1 "$(printf '%s\n' "$help_out" | grep -c -- '--no-apt-upgrade\]')"

echo
echo "Ergebnis: $PASS bestanden, $FAIL fehlgeschlagen"
[ "$FAIL" -eq 0 ]
