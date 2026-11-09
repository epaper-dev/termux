#!/usr/bin/env bash
# Test: `claude update` at the start of the Claude Code session runs at most once a day (CLAUDE_UPDATE).
#   1. update_claude() from guest/bin/rootbridge-update (with the helpers it uses) and a stub `claude`
#      (the main part of the script never runs: it would start the real `claude update`; the functions are
#      cut out of it). rootbridge-claude only calls rootbridge-update, after rootbridge-apt.
#   2. guest installer: config key, --claude-update, uninstall
#   3. install.sh with a fake HOME/PREFIX and a stub proot-distro: --claude-update / --no-claude-update,
#      stored in the Termux config
#   bash tests/test_claude_update.sh
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/guest/bin/rootbridge-update"
CLAUDEBIN="$ROOT/guest/bin/rootbridge-claude"
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

bash -n "$SCRIPT" 2>/dev/null
check "rootbridge-update: Syntax in Ordnung" 0 "$?"
bash -n "$CLAUDEBIN" 2>/dev/null
check "rootbridge-claude: Syntax in Ordnung" 0 "$?"

# ------------------------------------------------ 1. update_claude() with a stub claude
FUNCS="$(sed -n '/^conf_get() {/,/^}/p;/^limit_nofile() {/,/^}/p;/^update_due() {/,/^}/p;/^stamp_success() {/,/^}/p;/^state_dir() /p;/^update_claude() {/,/^}/p' "$SCRIPT")"
export FUNCS
for fn in conf_get limit_nofile update_due stamp_success state_dir update_claude; do
    case "$FUNCS" in
        *"$fn() {"*) ;;
        *) echo "ABBRUCH: $fn() nicht in $SCRIPT gefunden." >&2; exit 1 ;;
    esac
done

cat > "$T/claude-stub" <<'EOF'
#!/bin/bash
echo "claude $* hard=$(ulimit -Hn)" >> "$STUB_LOG"
echo "stub claude: $*"
exit "${STUB_UPDATE_RC:-0}"
EOF
chmod +x "$T/claude-stub"
# start from 8192, or from the hard limit if that is lower (a session started by rootbridge-claude
# already runs with NOFILE_LIMIT, and a hard limit cannot be raised again)
HARD="$(ulimit -Hn)"
case "$HARD" in
    unlimited) START=8192 ;;
    ''|*[!0-9]*) echo "ABBRUCH: ulimit -Hn liefert '$HARD'." >&2; exit 1 ;;
    *) START=$(( HARD < 8192 ? HARD : 8192 )) ;;
esac
w() { if [ "$START" -gt "$1" ]; then echo "$1"; else echo "$START"; fi; }   # limits are only ever lowered
if ! bash -c "ulimit -n $START" 2>/dev/null; then
    echo "ABBRUCH: ulimit -n $START ist hier nicht setzbar." >&2
    exit 1
fi

STATE="$T/state"; STAMPF="$STATE/claude-update-last-success"
export STUB_LOG="$T/stub.log" ROOTBRIDGE_STATE_DIR="$STATE"
CONFFILE="$T/test.conf"
mkconf() { printf '%s\n' "$@" > "$CONFFILE"; }
reset_state() { rm -rf "$STATE"; : > "$STUB_LOG"; unset STUB_UPDATE_RC; }
calls() { grep -c '^claude update' "$STUB_LOG" || true; }
stamp_exists() { [ -s "$STAMPF" ] && echo ja || echo nein; }
out_has() { printf '%s\n' "$OUT" | grep -c -- "$1" || true; }
run_update() {   # sets OUT (stdout+stderr incl. rc=N); conf comes from $CONFFILE
    OUT="$(bash -c 'ulimit -n '"$START"'; CONF="$1"; claude_bin="$2"; eval "$FUNCS"; update_claude; echo "rc=$?"' _ "$CONFFILE" "$T/claude-stub" 2>&1)"
}
set_stamp() { mkdir -p "$STATE"; printf '%s\n' "$1" > "$STAMPF"; }
now="$(date +%s)"

# --- default: daily, no stamp yet
reset_state; mkconf "CLAUDE_UPDATE=daily"
run_update
check "daily ohne Stempel: Exit 0"                    "rc=0" "$(printf '%s\n' "$OUT" | tail -n 1)"
check "daily ohne Stempel: claude update läuft"       1 "$(calls)"
check "daily ohne Stempel: Kopfzeile"                 1 "$(out_has '^== claude update$')"
check "daily ohne Stempel: Stempel geschrieben"       ja "$(stamp_exists)"
check "Stempel ist eine Zahl"                         1 "$([[ "$(cat "$STAMPF")" =~ ^[0-9]{9,12}$ ]] && echo 1 || echo 0)"

# --- daily with a fresh stamp: nothing runs
set_stamp "$((now - 3600))"; : > "$STUB_LOG"
run_update
check "daily, Stempel 1 h alt: Exit 0"                "rc=0" "$(printf '%s\n' "$OUT" | tail -n 1)"
check "daily, Stempel 1 h alt: kein claude update"    0 "$(calls)"
check "daily, Stempel 1 h alt: Hinweis 'übersprungen'" 1 "$(out_has 'übersprungen (CLAUDE_UPDATE=daily)')"
check "daily, Stempel 1 h alt: 'vor 1 h'"             1 "$(out_has 'vor 1 h erfolgreich')"
check "daily, Stempel 1 h alt: keine Kopfzeile"       0 "$(out_has '^== claude update$')"
check "daily, Stempel 1 h alt: Stempel unverändert"   "$((now - 3600))" "$(cat "$STAMPF")"
set_stamp "$((now - 86300))"; : > "$STUB_LOG"; run_update
check "daily, Stempel knapp unter 24 h: übersprungen" 0 "$(calls)"

# --- daily with an old / future / broken stamp: runs
for s in "$((now - 90000))" "$((now + 3600))" "abc" "" "99999999999999" "12345678"; do
    set_stamp "$s"; : > "$STUB_LOG"; run_update
    check "daily, Stempel '${s:0:14}': läuft"          1 "$(calls)"
done

# --- always ignores the stamp
set_stamp "$((now - 60))"; : > "$STUB_LOG"; mkconf "CLAUDE_UPDATE=always"; run_update
check "always, frischer Stempel: läuft trotzdem"      1 "$(calls)"
check "always: Stempel wird erneuert"                 1 "$([ "$(cat "$STAMPF")" -ge "$now" ] && echo 1 || echo 0)"

# --- off does nothing at all
reset_state; mkconf "CLAUDE_UPDATE=off"; run_update
check "off: Exit 0"                                   "rc=0" "$(printf '%s\n' "$OUT" | tail -n 1)"
check "off: kein claude update"                       0 "$(calls)"
check "off: kein Stempel"                             nein "$(stamp_exists)"
check "off: keine Ausgabe außer rc"                   "rc=0" "$OUT"

# --- unknown value: skipped with a hint, never fatal
reset_state; mkconf "CLAUDE_UPDATE=banana"; run_update
check "unbekannter Wert: Exit 0"                      "rc=0" "$(printf '%s\n' "$OUT" | tail -n 1)"
check "unbekannter Wert: kein claude update"          0 "$(calls)"
check "unbekannter Wert: Hinweis"                     1 "$(out_has 'unbekannter Wert CLAUDE_UPDATE=banana')"
check "unbekannter Wert: kein Stempel"                nein "$(stamp_exists)"

# --- missing key / empty value / missing file: default 6h
reset_state; mkconf "WORKDIR=/root/workspace"; run_update
check "ohne CLAUDE_UPDATE-Zeile: Standard 6h, läuft"   1 "$(calls)"
reset_state; mkconf "CLAUDE_UPDATE="; run_update
check "leerer Wert: Standard 6h, läuft"               1 "$(calls)"
reset_state; CONFFILE="$T/gibt-es-nicht.conf"; run_update
check "ohne Konfig-Datei: Standard 6h, läuft"         1 "$(calls)"
set_stamp "$((now - 60))"; : > "$STUB_LOG"; run_update
check "ohne Konfig-Datei: frischer Stempel gilt"      0 "$(calls)"
CONFFILE="$T/test.conf"

# --- interval: 6h is the default, <N>h sets the distance, daily = 24 h
H=3600
ran() { calls; }   # 1 = claude update ran, 0 = skipped
reset_state; mkconf "CLAUDE_UPDATE=6h"
set_stamp "$((now - 5 * H))"; : > "$STUB_LOG"; run_update
check "6h, Stempel 5 h alt: übersprungen"             0 "$(ran)"
check "6h, Stempel 5 h alt: Hinweis nennt 6h"         1 "$(out_has 'übersprungen (CLAUDE_UPDATE=6h)')"
check "6h, Stempel 5 h alt: 'vor 5 h'"                1 "$(out_has 'vor 5 h erfolgreich')"
set_stamp "$((now - 7 * H))"; : > "$STUB_LOG"; run_update
check "6h, Stempel 7 h alt: läuft"                    1 "$(ran)"
check "6h, Stempel 7 h alt: neuer Stempel"            1 "$([ "$(cat "$STAMPF")" -ge "$now" ] && echo 1 || echo 0)"
mkconf "WORKDIR=/x"
set_stamp "$((now - 5 * H))"; : > "$STUB_LOG"; run_update
check "Standard ohne Zeile = 6h: Stempel 5 h alt übersprungen" 0 "$(ran)"
set_stamp "$((now - 7 * H))"; : > "$STUB_LOG"; run_update
check "Standard ohne Zeile = 6h: Stempel 7 h alt läuft" 1 "$(ran)"
mkconf "CLAUDE_UPDATE=daily"
set_stamp "$((now - 23 * H))"; : > "$STUB_LOG"; run_update
check "daily, Stempel 23 h alt: übersprungen"         0 "$(ran)"
set_stamp "$((now - 25 * H))"; : > "$STUB_LOG"; run_update
check "daily, Stempel 25 h alt: läuft"                1 "$(ran)"
mkconf "CLAUDE_UPDATE=12h"
set_stamp "$((now - 11 * H))"; : > "$STUB_LOG"; run_update
check "12h, Stempel 11 h alt: übersprungen"           0 "$(ran)"
set_stamp "$((now - 13 * H))"; : > "$STUB_LOG"; run_update
check "12h, Stempel 13 h alt: läuft"                  1 "$(ran)"
mkconf "CLAUDE_UPDATE=1h"
set_stamp "$((now - 1800))"; : > "$STUB_LOG"; run_update
check "1h, Stempel 30 min alt: übersprungen"          0 "$(ran)"
set_stamp "$((now - 2 * H))"; : > "$STUB_LOG"; run_update
check "1h, Stempel 2 h alt: läuft"                    1 "$(ran)"
mkconf "CLAUDE_UPDATE=6h"
set_stamp "$((now + 99999))"; : > "$STUB_LOG"; run_update
check "6h, Stempel in der Zukunft: läuft"             1 "$(ran)"
set_stamp "abc"; : > "$STUB_LOG"; run_update
check "6h, kaputter Stempel: läuft"                   1 "$(ran)"
reset_state; run_update
check "6h, ohne Stempel: läuft"                       1 "$(ran)"
for bad in 0h 6 h 1000h 6H 06h "6 h" -6h; do
    reset_state; mkconf "CLAUDE_UPDATE=$bad"; run_update
    check "ungültig '$bad': kein claude update, kein Stempel" "0 nein" "$(ran) $(stamp_exists)"
    check "ungültig '$bad': Warnung"                  1 "$(out_has 'unbekannter Wert CLAUDE_UPDATE=')"
    check "ungültig '$bad': Exit 0"                   "rc=0" "$(printf '%s\n' "$OUT" | tail -n 1)"
done

# --- quotes and several lines
reset_state; set_stamp "$((now - 60))"; mkconf 'CLAUDE_UPDATE="daily"'; run_update
check "\"daily\" in Anführungszeichen: übersprungen"  0 "$(calls)"
mkconf "CLAUDE_UPDATE='always'"; run_update
check "'always' in Anführungszeichen: läuft"          1 "$(calls)"
reset_state; set_stamp "$((now - 60))"; mkconf 'CLAUDE_UPDATE=off' 'CLAUDE_UPDATE=always'; run_update
check "mehrere Zeilen: die letzte gilt"               1 "$(calls)"

# --- failures never stop the start and leave no (new) stamp
for rc in 1 124; do
    reset_state; mkconf "CLAUDE_UPDATE=daily"; export STUB_UPDATE_RC=$rc; run_update
    check "Exit $rc von claude update: Exit 0"         "rc=0" "$(printf '%s\n' "$OUT" | tail -n 1)"
    check "Exit $rc: Hinweis, Start geht weiter"       1 "$(out_has 'Update fehlgeschlagen oder abgebrochen')"
    check "Exit $rc: kein Stempel"                     nein "$(stamp_exists)"
done
reset_state; set_stamp "$((now - 90000))"; export STUB_UPDATE_RC=1; mkconf "CLAUDE_UPDATE=daily"; run_update
check "Fehler: alter Stempel bleibt, nächster Start versucht es erneut" "$((now - 90000))" "$(cat "$STAMPF")"
unset STUB_UPDATE_RC

# --- state directory not writable: the update still ran, the start is not affected
reset_state; mkconf "CLAUDE_UPDATE=daily"
OUT="$(ROOTBRIDGE_STATE_DIR=/proc/gibt-es-nicht/x bash -c 'CONF="$1"; claude_bin="$2"; eval "$FUNCS"; update_claude; echo "rc=$?"' _ "$CONFFILE" "$T/claude-stub" 2>&1)"
check "Stempel-Ordner nicht anlegbar: Exit 0"         "rc=0" "$(printf '%s\n' "$OUT" | tail -n 1)"
check "Stempel-Ordner nicht anlegbar: Update lief"    1 "$(calls)"

# --- the fd limit still applies to `claude update`
reset_state; mkconf "CLAUDE_UPDATE=always"; run_update
check "claude update läuft mit Limit 2048"            1 "$(grep -c "hard=$(w 2048)\$" "$STUB_LOG")"
reset_state; mkconf "CLAUDE_UPDATE=always" "NOFILE_LIMIT=1024"; run_update
check "claude update mit NOFILE_LIMIT=1024"           1 "$(grep -c "hard=$(w 1024)\$" "$STUB_LOG")"

# --- how the script uses it
check "genau eine Kopfzeile 'claude update'"          1 "$(grep -c '^    echo "== claude update"$' "$SCRIPT")"
check "update_claude wird genau einmal aufgerufen"    1 "$(grep -c '&& update_claude$' "$SCRIPT")"
rc_apt="$(grep -n 'rootbridge-apt ||' "$CLAUDEBIN" | head -n 1 | cut -d: -f1)"
rc_upd="$(grep -n 'rootbridge-update ||' "$CLAUDEBIN" | head -n 1 | cut -d: -f1)"
check "apt läuft vor claude update (rootbridge-claude)" 1 "$([ -n "$rc_apt" ] && [ -n "$rc_upd" ] && [ "$rc_apt" -lt "$rc_upd" ] && echo 1 || echo 0)"
check "kein ungeschützter claude update-Aufruf mehr"  1 "$(grep -c '"\$claude_bin" update ); then' "$SCRIPT")"

# ------------------------------------------------------ 2. guest installer
gconf() { printf '%s' "$1/etc/termux-rootbridge.conf"; }
gval() { grep "^$2=" "$(gconf "$1")" 2>/dev/null || true; }
gcount() { grep -c "^$2=" "$(gconf "$1")" 2>/dev/null || true; }
ginstall() {  # ginstall <stage> [args...]
    local stage="$1"; shift
    bash "$GUEST" --root "$stage" --autonomous no "$@" > "$T/guest.log" 2>&1
}
cbak() { find "$1/etc" -name 'termux-rootbridge.conf.bak-*' 2>/dev/null | wc -l | tr -d ' '; }

S="$T/g1"
ginstall "$S"
check "Gast ohne Option: Installer läuft"             0 "$?"
check "Gast: CLAUDE_UPDATE=6h als Standard"           "CLAUDE_UPDATE=6h" "$(gval "$S" CLAUDE_UPDATE)"
check "Gast: genau eine Zeile"                        1 "$(gcount "$S" CLAUDE_UPDATE)"
check "Gast: rootbridge-update installiert"           ja "$([ -x "$S/usr/local/bin/rootbridge-update" ] && echo ja || echo nein)"
check "Gast: rootbridge-claude ruft rootbridge-update" 1 "$(grep -c 'rootbridge-update || true' "$S/usr/local/bin/rootbridge-claude")"

before="$(cksum < "$(gconf "$S")")"; b0="$(cbak "$S")"
ginstall "$S"
check "Gast zweiter Lauf: Konfig unverändert"         "$before" "$(cksum < "$(gconf "$S")")"
check "Gast zweiter Lauf: keine neue Sicherung"       "$b0" "$(cbak "$S")"

ginstall "$S" --claude-update off
check "Gast --claude-update off"                      "CLAUDE_UPDATE=off" "$(gval "$S" CLAUDE_UPDATE)"
check "Gast --claude-update off: genau eine Zeile"    1 "$(gcount "$S" CLAUDE_UPDATE)"
check "Gast --claude-update off: APT_UPGRADE bleibt"  "APT_UPGRADE=6h" "$(gval "$S" APT_UPGRADE)"
check "Gast --claude-update off: WORKDIR bleibt"      "WORKDIR=/root/work" "$(gval "$S" WORKDIR)"
before="$(cksum < "$(gconf "$S")")"; b0="$(cbak "$S")"
ginstall "$S" --claude-update off
check "Gast --claude-update off wiederholt: unverändert" "$before" "$(cksum < "$(gconf "$S")")"
check "Gast --claude-update off wiederholt: keine Sicherung" "$b0" "$(cbak "$S")"
ginstall "$S"
check "Gast ohne Option: off bleibt"                  "CLAUDE_UPDATE=off" "$(gval "$S" CLAUDE_UPDATE)"
ginstall "$S" --claude-update always
check "Gast --claude-update always"                   "CLAUDE_UPDATE=always" "$(gval "$S" CLAUDE_UPDATE)"
ginstall "$S" --claude-update daily
check "Gast --claude-update daily"                    "CLAUDE_UPDATE=daily" "$(gval "$S" CLAUDE_UPDATE)"
ginstall "$S" --claude-update 12h
check "Gast --claude-update 12h"                      "CLAUDE_UPDATE=12h" "$(gval "$S" CLAUDE_UPDATE)"
ginstall "$S" --claude-update 6h
check "Gast --claude-update 6h"                       "CLAUDE_UPDATE=6h" "$(gval "$S" CLAUDE_UPDATE)"
check "Gast --claude-update 6h: genau eine Zeile"     1 "$(gcount "$S" CLAUDE_UPDATE)"
ginstall "$S" --apt-upgrade off --claude-update always
check "beide Optionen: APT_UPGRADE=off"               "APT_UPGRADE=off" "$(gval "$S" APT_UPGRADE)"
check "beide Optionen: CLAUDE_UPDATE=always"          "CLAUDE_UPDATE=always" "$(gval "$S" CLAUDE_UPDATE)"
ginstall "$S" --apt-upgrade daily
check "--apt-upgrade ändert CLAUDE_UPDATE nicht"      "CLAUDE_UPDATE=always" "$(gval "$S" CLAUDE_UPDATE)"

S="$T/g2"; mkdir -p "$S/etc"; printf '%s\n' "WORKDIR=/srv/mine" "CLAUDE_UPDATE=always" "APT_UPGRADE=off" > "$(gconf "$S")"
ginstall "$S"
check "Eigene Werte bleiben: CLAUDE_UPDATE"           "CLAUDE_UPDATE=always" "$(gval "$S" CLAUDE_UPDATE)"
check "Eigene Werte bleiben: APT_UPGRADE"             "APT_UPGRADE=off" "$(gval "$S" APT_UPGRADE)"
check "Eigene Werte bleiben: WORKDIR"                 "WORKDIR=/srv/mine" "$(gval "$S" WORKDIR)"

S="$T/g2b"; mkdir -p "$S/etc"; printf '%s\n' "WORKDIR=/srv/mine" "APT_UPGRADE=always" > "$(gconf "$S")"
ginstall "$S"
check "Konfig ohne Schlüssel: CLAUDE_UPDATE=6h ergänzt" "CLAUDE_UPDATE=6h" "$(gval "$S" CLAUDE_UPDATE)"

for bad in "" Daily banana "on" "daily;id" "-x" 0h 6 h 1000h 6H 06h "6 h" -6h; do
    S="$T/bad"; rm -rf "$S"
    bash "$GUEST" --root "$S" --autonomous no --claude-update "$bad" > /dev/null 2>&1
    code=$?
    check "ungültiger Modus '${bad:0:8}': Abbruch mit 2"  2 "$code"
    check "ungültiger Modus '${bad:0:8}': nichts geschrieben" nein "$([ -e "$S" ] && echo ja || echo nein)"
done
bash "$GUEST" --root "$T/bad" --claude-update > /dev/null 2>&1
check "--claude-update ohne Wert: Abbruch mit 2"      2 "$?"

S="$T/g3"; ginstall "$S"; mkdir -p "$S/var/lib/termux-rootbridge"; echo 1 > "$S/var/lib/termux-rootbridge/claude-update-last-success"
bash "$GUEST" --root "$S" --uninstall > "$T/guest.log" 2>&1
check "Deinstallation: Stempel-Ordner entfernt"       nein "$([ -e "$S/var/lib/termux-rootbridge" ] && echo ja || echo nein)"
check "Deinstallation: rootbridge-claude entfernt"    nein "$([ -e "$S/usr/local/bin/rootbridge-claude" ] && echo ja || echo nein)"

# ----------------------------------------------- 3. install.sh (fake Termux)
H="$T/home"; P="$T/prefix"; GROOT="$T/groot"; GUEST_ROOT="$T/guestroot"
mkdir -p "$H" "$P/bin" "$GROOT/var/tmp" "$P/var/lib/proot-distro/containers/ubuntu" "$T/stubs"
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
        bash "$INSTALL" --no-boot --no-migrate --no-deps-check --no-extra-keys --no-setup --autonomous no "$@" > "$T/install.log" 2>&1
}
CFG="$H/.config/termux-rootbridge/config"
tval() { grep '^CLAUDE_UPDATE=' "$CFG" 2>/dev/null || true; }
tcount() { grep -c '^CLAUDE_UPDATE=' "$CFG" 2>/dev/null || true; }
gv() { grep '^CLAUDE_UPDATE=' "$GUEST_ROOT/etc/termux-rootbridge.conf" 2>/dev/null || true; }
passed() { grep -c -- "--claude-update $1" "$PROOT_LOG" || true; }

rinstall "$H" --no-claude-update
check "install.sh --no-claude-update: läuft durch"    0 "$?"
check "Termux-Konfig: CLAUDE_UPDATE=off"              "CLAUDE_UPDATE=off" "$(tval)"
check "Termux-Konfig: genau eine Zeile"               1 "$(tcount)"
check "Gast-Installer bekam --claude-update off"      1 "$(passed off)"
check "Gast-Konfig: CLAUDE_UPDATE=off"                "CLAUDE_UPDATE=off" "$(gv)"

cfg_before="$(cksum < "$CFG")"
rinstall "$H"
check "Zweiter Lauf ohne Option: läuft durch"         0 "$?"
check "Zweiter Lauf: Termux-Konfig unverändert"       "$cfg_before" "$(cksum < "$CFG")"
check "Zweiter Lauf: off aus der Konfig übernommen"   2 "$(passed off)"

rm -rf "$GUEST_ROOT"
rinstall "$H"
check "Frischer Gast: off kommt aus der Termux-Konfig" "CLAUDE_UPDATE=off" "$(gv)"

rinstall "$H" --claude-update always
check "--claude-update always: Termux-Konfig"         "CLAUDE_UPDATE=always" "$(tval)"
check "--claude-update always: weiter eine Zeile"     1 "$(tcount)"
check "--claude-update always: Gast-Konfig"           "CLAUDE_UPDATE=always" "$(gv)"

rinstall "$H" --no-claude-update --claude-update daily
check "Letzte Option gewinnt (daily)"                 "CLAUDE_UPDATE=daily" "$(tval)"

# both choices side by side, neither disturbs the other
rinstall "$H" --no-apt-upgrade --claude-update always
check "mit --no-apt-upgrade: APT_UPGRADE=off"         "APT_UPGRADE=off" "$(grep '^APT_UPGRADE=' "$CFG")"
check "mit --no-apt-upgrade: CLAUDE_UPDATE=always"    "CLAUDE_UPDATE=always" "$(tval)"
check "mit --no-apt-upgrade: Gast CLAUDE_UPDATE"      "CLAUDE_UPDATE=always" "$(gv)"
rinstall "$H" --apt-upgrade daily
check "--apt-upgrade ändert CLAUDE_UPDATE nicht"      "CLAUDE_UPDATE=always" "$(tval)"

# hand-edited invalid value in the Termux config: ignored, nothing passed on
sed -i 's|^CLAUDE_UPDATE=.*|CLAUDE_UPDATE=banana|' "$CFG"
: > "$PROOT_LOG"
rinstall "$H"
check "Ungültiger Wert in der Konfig wird ignoriert"  0 "$(grep -c -- '--claude-update' "$PROOT_LOG")"

# no config, no option: nothing passed on, the guest falls back to its default
H2="$T/home2"; mkdir -p "$H2"; : > "$PROOT_LOG"; rm -rf "$GUEST_ROOT"
rinstall "$H2"
check "Ohne Option und Konfig: Installer läuft"       0 "$?"
check "Ohne Option und Konfig: nichts an den Gast"    0 "$(grep -c -- '--claude-update' "$PROOT_LOG")"
check "Ohne Option und Konfig: keine Zeile in Termux" 0 "$(grep -c '^CLAUDE_UPDATE=' "$H2/.config/termux-rootbridge/config")"
check "Ohne Option und Konfig: Gast-Standard 6h"      "CLAUDE_UPDATE=6h" "$(gv)"
check "Neue Termux-Konfig nennt CLAUDE_UPDATE (Kommentar)" 1 "$(grep -c '^# CLAUDE_UPDATE=6h' "$H2/.config/termux-rootbridge/config")"

# invalid option values: abort with 2 before anything is written
for bad in banana Daily "" "-x" 0h 1000h 6H; do
    H3="$T/home3"; rm -rf "$H3"; mkdir -p "$H3"
    HOME="$H3" PREFIX="$P" PATH="$T/stubs:$PATH" ROOTBRIDGE_ALLOW_GUEST=1 bash "$INSTALL" --no-deps-check --claude-update "$bad" > /dev/null 2>&1
    check "install.sh --claude-update '$bad': Abbruch mit 2" 2 "$?"
    check "install.sh --claude-update '$bad': nichts geschrieben" nein "$([ -e "$H3/.config" ] && echo ja || echo nein)"
done
HOME="$H3" PREFIX="$P" PATH="$T/stubs:$PATH" ROOTBRIDGE_ALLOW_GUEST=1 bash "$INSTALL" --no-deps-check --claude-update > /dev/null 2>&1
check "install.sh --claude-update ohne Wert: Abbruch mit 2" 2 "$?"

# --no-guest: mode is stored, guest installer not called
H4="$T/home4"; mkdir -p "$H4"; : > "$PROOT_LOG"
rinstall "$H4" --no-guest --no-claude-update
check "--no-guest: Modus gespeichert"                 "CLAUDE_UPDATE=off" "$(grep '^CLAUDE_UPDATE=' "$H4/.config/termux-rootbridge/config")"
check "--no-guest: Gast-Installer nicht aufgerufen"   0 "$(wc -l < "$PROOT_LOG" | tr -d ' ')"

# --help mentions the options
help_out="$(bash "$INSTALL" --help 2>&1)"
check "--help nennt --no-claude-update"               1 "$(printf '%s\n' "$help_out" | grep -c -- '--no-claude-update\]')"
check "--help zeigt den ganzen Kopf (Schritt 5)"      1 "$(printf '%s\n' "$help_out" | grep -c 'stored as CLAUDE_UPDATE')"
check "--help läuft nicht in den Code hinein"         0 "$(printf '%s\n' "$help_out" | grep -c '^set -eu')"

echo
echo "Ergebnis: $PASS bestanden, $FAIL fehlgeschlagen"
[ "$FAIL" -eq 0 ]
