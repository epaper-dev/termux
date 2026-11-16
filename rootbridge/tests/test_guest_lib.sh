#!/usr/bin/env bash
# Test: guest/lib/rootbridge-guest-lib.sh - the helpers the guest scripts share (conf_raw / conf_get, update_interval,
# stamp_age, enter_workdir, run_maintenance, after_tool) - and that every guest script that sources it refuses to run,
# with a clear message, when the library is missing (no silent fallback, least of all in androidsu).
#   bash tests/test_guest_lib.sh
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib.sh
. "$ROOT/tests/lib.sh"
LIB="$ROOTBRIDGE_GUEST_LIB"

make_tmp

# ------------------------------------------------------------------------------------------ library missing: fail closed
for script in androidsu rootbridge-claude rootbridge-codex rootbridge-update rootbridge-apt rootbridge-open; do
    out="$(ROOTBRIDGE_GUEST_LIB="$T/missing.sh" bash "$ROOT/guest/bin/$script" < /dev/null 2>&1)"; rc=$?
    check "$script ohne Lib: Exit 1"      1 "$rc"
    check "$script ohne Lib: klare Meldung" 1 "$(printf '%s\n' "$out" | grep -c 'rootbridge-guest-lib.sh nicht gefunden')"
done

# ------------------------------------------------------------------------------------------ conf_raw / conf_get
printf 'A=1\nB=\nC="quoted"\nD=%ssingle%s\nA=2\n' "'" "'" > "$T/c.conf"
lib() {   # lib <config file> <code>: run code with the library loaded and CONF pointing at the file
    ROOTBRIDGE_CONF="$1" bash -c '. "$1"; eval "$2"' _ "$LIB" "$2"
}
check "conf_get: der letzte Wert gewinnt"              2 "$(lib "$T/c.conf" 'conf_get A')"
check "conf_get: doppelte Anführungszeichen entfernt"  quoted "$(lib "$T/c.conf" 'conf_get C')"
check "conf_get: einfache Anführungszeichen entfernt"  single "$(lib "$T/c.conf" 'conf_get D')"
check "conf_get: leerer Wert scheitert"                "rc=1" "$(lib "$T/c.conf" 'conf_get B; echo "rc=$?"')"
check "conf_raw: leerer Wert ist vorhanden"            "rc=0" "$(lib "$T/c.conf" 'conf_raw B > /dev/null; echo "rc=$?"')"
check "conf_raw: fehlender Schlüssel scheitert"        "rc=1" "$(lib "$T/c.conf" 'conf_raw NOPE; echo "rc=$?"')"
check "conf_get: fehlende Datei scheitert"             "rc=1" "$(lib "$T/none.conf" 'conf_get A; echo "rc=$?"')"
check "CONF-Standard ohne ROOTBRIDGE_CONF"             /etc/termux-rootbridge.conf "$(env -u ROOTBRIDGE_CONF bash -c '. "$1"; echo "$CONF"' _ "$LIB")"

# ------------------------------------------------------------------------------------------ update_interval
ui() { bash -c '. "$1"; update_interval "$2"; echo "rc=$?"' _ "$LIB" "$1" | paste -sd' '; }
check "update_interval 6h"            "21600 rc=0" "$(ui 6h)"
check "update_interval 12h"           "43200 rc=0" "$(ui 12h)"
check "update_interval 999h"          "3596400 rc=0" "$(ui 999h)"
check "update_interval daily"         "86400 rc=0" "$(ui daily)"
check "update_interval always"        "0 rc=0" "$(ui always)"
check "update_interval off"           "rc=1" "$(ui off)"
check "update_interval unbekannt"     "rc=2" "$(ui bogus)"
check "update_interval 0h ungültig"   "rc=2" "$(ui 0h)"
check "update_interval 1000h ungültig" "rc=2" "$(ui 1000h)"

# ------------------------------------------------------------------------------------------ stamp_age
age() { bash -c '. "$1"; a="$(stamp_age "$2")"; echo "rc=$? $a"' _ "$LIB" "$1"; }
now="$(date +%s)"
echo "$((now - 7200))" > "$T/stamp"
a="$(age "$T/stamp" | sed 's/^rc=0 //')"
check "stamp_age: zwei Stunden alt"           ja "$([ "$a" -ge 7200 ] && [ "$a" -le 7205 ] && echo ja || echo nein)"
echo "abc" > "$T/stamp";               check "stamp_age: Müll im Stempel"      "rc=1 " "$(age "$T/stamp")"
echo "$((now + 3600))" > "$T/stamp";   check "stamp_age: Stempel in der Zukunft" "rc=1 " "$(age "$T/stamp")"
check "stamp_age: Datei fehlt"                "rc=1 " "$(age "$T/no-stamp")"

# ------------------------------------------------------------------------------------------ enter_workdir
mkdir -p "$T/work"
printf 'WORKDIR=%s\n' "$T/work" > "$T/w.conf"
check "enter_workdir: WORKDIR aus der Konfig" "$T/work" "$(lib "$T/w.conf" 'enter_workdir; pwd')"

# ------------------------------------------------------------------------------------------ run_maintenance
mkdir -p "$T/bin"
for name in rootbridge-apt rootbridge-update; do
    printf '#!/bin/bash\necho "%s" >> "$MAINT_LOG"\nexit 1\n' "$name" > "$T/bin/$name"; chmod +x "$T/bin/$name"
done
rm -f "$T/maint.log"
rc="$(MAINT_LOG="$T/maint.log" PATH="$T/bin:$PATH" bash -c '. "$1"; run_maintenance; echo $?' _ "$LIB")"
check "run_maintenance: Fehler der Schritte stoppen nichts" 0 "$rc"
check "run_maintenance: erst apt, dann update"              "rootbridge-apt rootbridge-update" "$(paste -sd' ' "$T/maint.log")"
rm -f "$T/maint.log"
rc="$(MAINT_LOG="$T/maint.log" PATH="/usr/bin:/bin" bash -c '. "$1"; run_maintenance; echo $?' _ "$LIB")"
check "run_maintenance: ohne die Skripte kein Fehler"       0 "$rc"

# ------------------------------------------------------------------------------------------ after_tool
at() { bash -c '. "$1"; after_tool Codex codex "$2"; echo "weiter"' _ "$LIB" "$1" < /dev/null 2>&1; echo "rc=$?"; }
out="$(at 0)";   check "after_tool: Ende mit 0 beendet das Skript"    "rc=0" "$out"
out="$(at 130)"; check "after_tool: Ctrl+C (130) beendet das Skript"  "rc=0" "$out"
out="$(at 3)"
check "after_tool: Fehler: Meldung mit Code und Neustartbefehl" 1 "$(printf '%s\n' "$out" | grep -c 'Codex wurde mit Code 3 beendet. Neu starten mit: codex   (Shell bleibt offen)')"
check "after_tool: Fehler: das Skript läuft nicht weiter"       0 "$(printf '%s\n' "$out" | grep -c '^weiter$')"

echo
finish
