#!/usr/bin/env bash
# Test: Codex next to Claude Code (and Claude Code or Codex alone).
#   1. guest installer (staging root): Codex hook in the managed settings, scripts, config keys, bashrc block;
#      --codex no, --claude no (Codex only), both off, --codex-update, a second run changes nothing, uninstall
#   2. rootbridge-update with stub claude / codex: what runs, in which order, the stamps, the modes, tools that
#      are off or missing, a failing step never stops the rest, two runs at once do the work once
#   3. rootbridge-codex with stubs: apt and the update come before Codex, working directory, CODEX_ARGS, exit
#   4. rootbridge-claude hands the update to rootbridge-update and passes the emergency switch on
#   5. the rootbridge command (stub tmux / proot-distro): windows, default tool, codex-login, codex-off / codex-on,
#      status
#   6. install.sh (stub proot-distro, fake HOME/PREFIX): --no-claude / --no-codex / --codex-update, the choice is
#      stored, the Codex widget, switching a tool off removes its widget
# The hook script itself is tested in test_codex_precommit.py. Nothing real is touched: never the real claude or
# codex (their paths are set through ROOTBRIDGE_*_BIN and the PATH of the stubs holds only symlinks to basic tools).
#   bash tests/test_codex.sh
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GUEST="$ROOT/guest/install-guest.sh"
UPDATE="$ROOT/guest/bin/rootbridge-update"
CODEXBIN="$ROOT/guest/bin/rootbridge-codex"
CLAUDEBIN="$ROOT/guest/bin/rootbridge-claude"
INSTALL="$ROOT/install.sh"
UNINSTALL="$ROOT/uninstall.sh"

T="$(mktemp -d)"
cleanup() {
    local p
    p="$(cat "$T/bridge/.lock/pid" 2>/dev/null)"
    [ -n "$p" ] && kill "$p" 2>/dev/null
    rm -rf "$T"
}
trap cleanup EXIT
export ROOTBRIDGE_GUEST_HOME=/home/tester

PASS=0; FAIL=0
check() {   # check <name> <expected> <actual>
    if [ "$2" = "$3" ]; then PASS=$((PASS + 1)); printf 'ok    %s\n' "$1"
    else FAIL=$((FAIL + 1)); printf 'FAIL  %s\n      erwartet: %s\n      erhalten: %s\n' "$1" "$2" "$3"; fi
}
count() { local n; n="$(grep -c -- "$2" "$1" 2>/dev/null)"; echo "${n:-0}"; }   # count <file> <text>: lines containing it (0 if the file is gone)
has() { [ -e "$1" ] && echo ja || echo nein; }

for f in "$UPDATE" "$CODEXBIN" "$CLAUDEBIN" "$GUEST" "$INSTALL" "$ROOT/termux/bin/rootbridge" "$ROOT/termux/shortcuts/codex"; do
    bash -n "$f" 2>/dev/null
    check "Syntax in Ordnung: ${f#"$ROOT"/}" 0 "$?"
done

# =========================================================================== 1. guest installer
ginstall() {   # ginstall <stage> [args...]
    local stage="$1"; shift
    bash "$GUEST" --root "$stage" --autonomous no "$@" > "$T/guest.log" 2>&1
}
gconf() { printf '%s' "$1/etc/termux-rootbridge.conf"; }
gval() { sed -n "s/^$2=//p" "$(gconf "$1")" | tail -n 1; }
msum() {   # one line about the managed settings of a stage
    python3 -I - "$1/etc/claude-code/managed-settings.json" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except OSError:
    print("keine Datei")
    sys.exit()
pre = d.get("hooks", {}).get("PreToolUse", [])
cmds = [h for e in pre for h in e.get("hooks", [])]
codex = [h for h in cmds if "codex-precommit-review.py" in h.get("command", "")]
guard = [h for h in cmds if "android-root-guard.py" in h.get("command", "")]
print("pre=%d codex=%d guard=%d post=%d timeout=%s onFailure=%s" % (
    len(pre), len(codex), len(guard), len(d.get("hooks", {}).get("PostToolUse", [])),
    codex[0].get("timeout") if codex else "-", codex[0].get("onFailure") if codex else "-"))
PY
}
bashrc() { printf '%s' "$1/home/tester/.bashrc"; }

S="$T/g1"
ginstall "$S"
check "Gast ohne Option: Installer läuft"                  0 "$?"
check "Gast: TOOL_CLAUDE=on"                               on "$(gval "$S" TOOL_CLAUDE)"
check "Gast: TOOL_CODEX=on"                                on "$(gval "$S" TOOL_CODEX)"
check "Gast: CODEX_UPDATE=6h als Standard"                 6h "$(gval "$S" CODEX_UPDATE)"
check "Gast: Hooks der Managed Settings"                   "pre=2 codex=1 guard=1 post=1 timeout=900 onFailure=block" "$(msum "$S")"
for f in usr/local/bin/rootbridge-codex usr/local/bin/rootbridge-update usr/local/bin/rootbridge-claude \
         usr/local/lib/termux-rootbridge/codex-precommit-review.py usr/local/lib/termux-rootbridge/android-root-guard.py; do
    check "Gast: $f installiert"                           ja "$(has "$S/$f")"
done
check "Gast: Unterhaltungsprüfung installiert" ja "$(has "$S/usr/local/lib/termux-rootbridge/claude-conversation.py")"
check "Gast: rootbridge-codex hat den Gast-Shebang"        "#!/bin/bash" "$(head -n 1 "$S/usr/local/bin/rootbridge-codex")"
# put() rewrites only the shebang line for the guest: the rest is the script of the repo, byte for byte
check "Gast: Hook-Skript ist das aus dem Repo (ab Zeile 2)" 0 "$(cmp -s <(tail -n +2 "$ROOT/guest/claude/codex-precommit-review.py") <(tail -n +2 "$S/usr/local/lib/termux-rootbridge/codex-precommit-review.py"); echo $?)"
check "Gast: bashrc hat claude()"                          1 "$(count "$(bashrc "$S")" '^claude() {')"
check "Gast: bashrc hat codex()"                           1 "$(count "$(bashrc "$S")" '^codex() { BROWSER=')"
check "Gast: Hook-Befehl hat den Marker (Deinstallation findet ihn)" 1 "$(count "$S/etc/claude-code/managed-settings.json" 'termux-rootbridge/codex-precommit-review.py')"

before="$(cksum < "$(gconf "$S")")$(cksum < "$S/etc/claude-code/managed-settings.json")"
ginstall "$S"
check "Gast zweiter Lauf: Konfig und Managed Settings unverändert" "$before" "$(cksum < "$(gconf "$S")")$(cksum < "$S/etc/claude-code/managed-settings.json")"
check "Gast zweiter Lauf: Hook genau einmal"               "pre=2 codex=1 guard=1 post=1 timeout=900 onFailure=block" "$(msum "$S")"

# --- --codex no
ginstall "$S" --codex no
check "Gast --codex no: Installer läuft"                   0 "$?"
check "Gast --codex no: TOOL_CODEX=off"                    off "$(gval "$S" TOOL_CODEX)"
check "Gast --codex no: kein Codex-Hook, Guard bleibt"     "pre=1 codex=0 guard=1 post=1 timeout=- onFailure=-" "$(msum "$S")"
check "Gast --codex no: rootbridge-codex entfernt"         nein "$(has "$S/usr/local/bin/rootbridge-codex")"
check "Gast --codex no: Hook-Skript entfernt"              nein "$(has "$S/usr/local/lib/termux-rootbridge/codex-precommit-review.py")"
check "Gast --codex no: kein codex() in der bashrc"        0 "$(count "$(bashrc "$S")" '^codex()')"
check "Gast --codex no: claude() bleibt"                   1 "$(count "$(bashrc "$S")" '^claude() {')"
ginstall "$S"
check "Gast ohne Option danach: die Wahl bleibt (aus)"     off "$(gval "$S" TOOL_CODEX)"
check "Gast ohne Option danach: weiter kein Codex-Hook"    "pre=1 codex=0 guard=1 post=1 timeout=- onFailure=-" "$(msum "$S")"
ginstall "$S" --codex yes
check "Gast --codex yes: Hook wieder da"                   "pre=2 codex=1 guard=1 post=1 timeout=900 onFailure=block" "$(msum "$S")"
check "Gast --codex yes: TOOL_CODEX=on"                    on "$(gval "$S" TOOL_CODEX)"

# --- Codex only
S2="$T/g2"
ginstall "$S2" --autonomous yes --claude no
check "Gast --claude no: Installer läuft"                  0 "$?"
check "Gast --claude no: TOOL_CLAUDE=off"                  off "$(gval "$S2" TOOL_CLAUDE)"
check "Gast --claude no: Codex bleibt"                     on "$(gval "$S2" TOOL_CODEX)"
check "Gast --claude no: keine Managed Settings"           "keine Datei" "$(msum "$S2")"
check "Gast --claude no: kein rootbridge-claude"           nein "$(has "$S2/usr/local/bin/rootbridge-claude")"
check "Gast --claude no: kein Guard, kein Login-Hook, kein Codex-Hook" "nein nein nein" \
      "$(has "$S2/usr/local/lib/termux-rootbridge/android-root-guard.py") $(has "$S2/usr/local/lib/termux-rootbridge/auth-url-hook.py") $(has "$S2/usr/local/lib/termux-rootbridge/codex-precommit-review.py")"
check "Gast --claude no: rootbridge-codex und -update da"  "ja ja" "$(has "$S2/usr/local/bin/rootbridge-codex") $(has "$S2/usr/local/bin/rootbridge-update")"
check "Gast --claude no: keine Claude-Einstellungen"       nein "$(has "$S2/home/tester/.claude/settings.json")"
check "Gast --claude no: bashrc nur mit codex()"           "0 1" "$(count "$(bashrc "$S2")" '^claude()') $(count "$(bashrc "$S2")" '^codex()')"
check "Gast --claude no: PATH-Zeile in der bashrc"         1 "$(count "$(bashrc "$S2")" '^case ":\$PATH:" in .*local/bin')"
check "Gast --claude no: keine CLAUDE_ARGS"                0 "$(count "$(gconf "$S2")" '^CLAUDE_ARGS=')"
check "Gast --claude no: Arbeitsordner trotzdem da"        ja "$(has "$S2/root/work")"
ginstall "$S2" --claude yes
check "Gast --claude yes danach: Managed Settings mit beiden Hooks" "pre=2 codex=1 guard=1 post=1 timeout=900 onFailure=block" "$(msum "$S2")"

# --- both off, option values
ginstall "$T/g3" --claude no --codex no
check "Gast beides aus: Code 2"                            2 "$?"
check "Gast beides aus: Meldung"                           1 "$(count "$T/guest.log" 'Mindestens eines')"
ginstall "$T/g3" --codex maybe
check "Gast --codex maybe: Code 2"                         2 "$?"
ginstall "$T/g4" --codex-update daily
check "Gast --codex-update daily: CODEX_UPDATE=daily"      daily "$(gval "$T/g4" CODEX_UPDATE)"
ginstall "$T/g4" --codex-update bogus
check "Gast --codex-update bogus: Code 2"                  2 "$?"
ginstall "$T/g4"
check "Gast ohne Option: CODEX_UPDATE bleibt"              daily "$(gval "$T/g4" CODEX_UPDATE)"

# --- uninstall
bash "$GUEST" --root "$S" --uninstall > "$T/guest.log" 2>&1
check "Gast Deinstallation: läuft"                         0 "$?"
check "Gast Deinstallation: rootbridge-codex und -update weg" "nein nein" "$(has "$S/usr/local/bin/rootbridge-codex") $(has "$S/usr/local/bin/rootbridge-update")"
check "Gast Deinstallation: kein Codex-Hook mehr"          0 "$(count "$S/etc/claude-code/managed-settings.json" 'codex-precommit-review')"
check "Gast Deinstallation: Hook-Skript weg"               nein "$(has "$S/usr/local/lib/termux-rootbridge/codex-precommit-review.py")"

# =========================================================================== 2. rootbridge-update
UB="$T/ubin"; mkdir -p "$UB"
for c in bash sed date head tail flock mkdir dirname cat tr sleep env rm; do
    r="$(command -v "$c")" && ln -sf "$r" "$UB/$c"
done
cat > "$UB/timeout" <<'EOF'
#!/bin/bash
shift
exec "$@"
EOF
chmod +x "$UB/timeout"
cat > "$UB/claude" <<'EOF'
#!/bin/bash
echo "claude $*" >> "$STUB_LOG"
case "$*" in
    update) [ -z "${STUB_CLAUDE_FAIL:-}" ] || exit 1 ;;
    *) exit 99 ;;
esac
exit 0
EOF
cat > "$UB/codex" <<'EOF'
#!/bin/bash
echo "codex $*" >> "$STUB_LOG"
[ -z "${STUB_SLEEP:-}" ] || sleep "$STUB_SLEEP"
[ -z "${STUB_CODEX_FAIL:-}" ] || exit 1
exit 0
EOF
chmod +x "$UB/claude" "$UB/codex"
USTATE="$T/ustate"; UCONF="$T/u.conf"; ULOG="$T/u.log"
mkdir -p "$T/update-home"
ureset() { rm -rf "$USTATE"; : > "$ULOG"; printf '%s\n' "$@" > "$UCONF"; }
urun() {   # urun [VAR=value ...]: one run of the real rootbridge-update with the stubs; output in $T/u.out
    env -i HOME="$T/update-home" PATH="$UB" ROOTBRIDGE_UPDATE_KEEP_PATH=1 ROOTBRIDGE_CONF="$UCONF" ROOTBRIDGE_STATE_DIR="$USTATE" \
        ROOTBRIDGE_CLAUDE_BIN="$UB/claude" ROOTBRIDGE_CODEX_BIN="$UB/codex" STUB_LOG="$ULOG" "$@" \
        "$(command -v bash)" "$UPDATE" > "$T/u.out" 2>&1
    URC=$?
}
stamps() { ( cd "$USTATE" 2>/dev/null && ls *-update-last-success 2>/dev/null | sed 's/-update-last-success//' | tr '\n' ' ' ); }
runs() { count "$ULOG" "^$1"; }

ureset ""
urun
check "update: Exit 0"                                     0 "$URC"
check "update: claude update läuft"                        1 "$(runs 'claude update$')"
check "update: codex update läuft"                         1 "$(runs 'codex update$')"
check "update: keine Plugin-Befehle beim Start"             0 "$(runs 'claude plugin ')"
check "update: Reihenfolge claude, codex"                   "claude update|codex update" "$(paste -sd'|' "$ULOG")"
check "update: zwei Stempel"                               "claude codex " "$(stamps)"
check "update: kein Plugin-Update-Log"                      nein "$(has "$USTATE/codex-plugin-update.log")"
: > "$ULOG"; urun
check "update zweiter Lauf: nichts läuft"                  0 "$(wc -l < "$ULOG" | tr -d ' ')"
check "update zweiter Lauf: zwei Hinweise 'übersprungen'"  2 "$(count "$T/u.out" 'übersprungen')"

# Each CLI keeps its own six-hour window.
for tool in claude codex; do
    for age in 21540 21660; do
        ureset ""; urun
        printf '%s\n' "$(( $(date +%s) - age ))" > "$USTATE/$tool-update-last-success"
        : > "$ULOG"; urun
        expected=0; [ "$age" -lt 21600 ] || expected=1
        check "$tool nach $age Sekunden: Sechs-Stunden-Fenster" "$expected" "$(runs "$tool update$")"
        check "$tool nach $age Sekunden: nur fälliges Update" "$expected" "$(wc -l < "$ULOG" | tr -d ' ')"
    done
done

# Existing installations may retain a plugin stamp; it must not trigger plugin management even in always mode.
for age in 0 21660; do
    ureset "CLAUDE_UPDATE=always" "CODEX_UPDATE=always"
    mkdir -p "$USTATE"
    old_stamp="$(( $(date +%s) - age ))"
    printf '%s\n' "$old_stamp" > "$USTATE/codex-plugin-update-last-success"
    urun
    check "Alter Plugin-Stempel ($age Sekunden): nur CLI-Updates" "claude update|codex update" "$(paste -sd'|' "$ULOG")"
    check "Alter Plugin-Stempel ($age Sekunden): unverändert" "$old_stamp" "$(cat "$USTATE/codex-plugin-update-last-success")"
    check "Alter Plugin-Stempel ($age Sekunden): kein Plugin-Log" nein "$(has "$USTATE/codex-plugin-update.log")"
done

ureset "CODEX_UPDATE=off"; urun
check "update CODEX_UPDATE=off: nur claude update"         "claude update" "$(paste -sd'|' "$ULOG")"
ureset "CLAUDE_UPDATE=off" "CODEX_UPDATE=always"; urun
check "update CLAUDE_UPDATE=off: nur codex update"           "codex update" "$(paste -sd'|' "$ULOG")"
: > "$ULOG"; urun
check "update CODEX_UPDATE=always: läuft jedes Mal"        1 "$(wc -l < "$ULOG" | tr -d ' ')"
ureset "TOOL_CODEX=off"; urun
check "update TOOL_CODEX=off: nur claude update, kein Plugin" "claude update" "$(paste -sd'|' "$ULOG")"
ureset "TOOL_CLAUDE=off"; urun
check "update TOOL_CLAUDE=off: nur codex update, kein Plugin" "codex update" "$(paste -sd'|' "$ULOG")"
ureset "CODEX_UPDATE=3h"; urun
check "update CODEX_UPDATE=3h: läuft"                      2 "$(count "$ULOG" '^claude\|^codex')"
ureset "CODEX_UPDATE=bogus"; urun
check "update CODEX_UPDATE=bogus: Hinweis, claude läuft"   "claude update" "$(paste -sd'|' "$ULOG")"
check "update CODEX_UPDATE=bogus: Meldung"                 1 "$(count "$T/u.out" 'unbekannter Wert CODEX_UPDATE=bogus')"
check "update CODEX_UPDATE=bogus: Exit 0"                  0 "$URC"

ureset ""; urun STUB_CODEX_FAIL=1
check "update codex schlägt fehl: Exit 0, Rest läuft"      "0 2" "$URC $(wc -l < "$ULOG" | tr -d ' ')"
check "update codex schlägt fehl: kein Stempel für codex"  "claude " "$(stamps)"
check "update codex schlägt fehl: Meldung"                 1 "$(count "$T/u.out" 'Update fehlgeschlagen')"
ureset ""; urun STUB_CLAUDE_FAIL=1
check "update claude schlägt fehl: codex läuft trotzdem"   1 "$(runs 'codex update$')"
check "update claude schlägt fehl: kein claude-Stempel"    "codex " "$(stamps)"

mv "$UB/codex" "$UB/codex.off"
ureset ""; urun
check "update ohne codex-Programm: nur claude update"      "claude update" "$(paste -sd'|' "$ULOG")"
mv "$UB/codex.off" "$UB/codex"; mv "$UB/claude" "$UB/claude.off"
ureset ""; urun
check "update ohne claude-Programm: nur codex update"      "codex update" "$(paste -sd'|' "$ULOG")"
mv "$UB/claude.off" "$UB/claude"

# two sessions start at once (both widgets): the work is done once, the second one waits for the first
ureset ""
( urun STUB_SLEEP=2 ) & p1=$!
sleep 0.5
URC2=0; env -i PATH="$UB" ROOTBRIDGE_UPDATE_KEEP_PATH=1 ROOTBRIDGE_CONF="$UCONF" ROOTBRIDGE_STATE_DIR="$USTATE" \
    ROOTBRIDGE_CLAUDE_BIN="$UB/claude" ROOTBRIDGE_CODEX_BIN="$UB/codex" STUB_LOG="$ULOG" \
    "$(command -v bash)" "$UPDATE" > "$T/u2.out" 2>&1 || URC2=$?
wait "$p1"
check "update gleichzeitig: Exit 0 beider"                 0 "$URC2"
check "update gleichzeitig: codex update nur einmal"       1 "$(runs 'codex update$')"
check "update gleichzeitig: claude update nur einmal"      1 "$(runs 'claude update$')"
check "update gleichzeitig: der zweite wartet"             1 "$(count "$T/u2.out" 'Warte auf ein laufendes Update')"

# the functions stay cut-out-able for tests (the main part does not run when sourced)
check "update: Funktionen ohne Hauptteil ladbar"           ok "$(bash -c '. "$1"; type update_due update_claude update_codex >/dev/null 2>&1 && echo ok' _ "$UPDATE")"

# An expired lock wait must not start a second updater without the lock.
mv "$UB/flock" "$UB/flock.real"
printf '#!/bin/bash\nexit 1\n' > "$UB/flock"; chmod +x "$UB/flock"
ureset ""; urun
check "update Sperre bleibt belegt: Exit 0" 0 "$URC"
check "update Sperre bleibt belegt: keine Tool-Updates" 0 "$(wc -l < "$ULOG" | tr -d ' ')"
check "update Sperre bleibt belegt: Hinweis" 1 "$(count "$T/u.out" 'Update-Sperre weiterhin belegt')"
mv -f "$UB/flock.real" "$UB/flock"

# =========================================================================== 3. rootbridge-codex
CB="$T/cbin"; mkdir -p "$CB" "$T/cwork"
for c in bash sed tail cat env; do r="$(command -v "$c")" && ln -sf "$r" "$CB/$c"; done
printf '#!/bin/bash\necho "apt" >> "$STUB_LOG"\nexit "${STUB_APT_RC:-0}"\n' > "$CB/rootbridge-apt"
printf '#!/bin/bash\necho "update" >> "$STUB_LOG"\nexit "${STUB_UPD_RC:-0}"\n' > "$CB/rootbridge-update"
cat > "$CB/codex" <<'EOF'
#!/bin/bash
echo "codex $* | cwd=$PWD | BROWSER=${BROWSER:-}" >> "$STUB_LOG"
exit "${STUB_CODEX_RC:-0}"
EOF
printf '#!/bin/bash\necho "bash $*" >> "$STUB_LOG"\nexit 0\n' > "$CB/bashstub"   # `exec bash -l` after an error
chmod +x "$CB/rootbridge-apt" "$CB/rootbridge-update" "$CB/codex" "$CB/bashstub"
mkdir -p "$T/cpath"; ln -sf "$CB/bashstub" "$T/cpath/bash"
CLOG="$T/c.log"; CCONF="$T/c.conf"
crun() {   # crun [VAR=value ...]
    : > "$CLOG"
    env -i PATH="$T/cpath:$CB" ROOTBRIDGE_CODEX_KEEP_PATH=1 ROOTBRIDGE_CONF="$CCONF" ROOTBRIDGE_CODEX_BIN="$CB/codex" STUB_LOG="$CLOG" "$@" \
        "$(command -v bash)" "$CODEXBIN" > "$T/c.out" 2>&1
    CRC=$?
}
printf 'WORKDIR=%s\nCODEX_ARGS="--model gpt-test"\n' "$T/cwork" > "$CCONF"
crun
check "rootbridge-codex: Exit 0 nach sauberem Ende"        0 "$CRC"
check "rootbridge-codex: Reihenfolge apt, update, codex"   "apt|update|codex --model gpt-test | cwd=$T/cwork | BROWSER=/usr/local/bin/rootbridge-open" "$(paste -sd'|' "$CLOG")"
check "rootbridge-codex: kein 'bash -l' nach sauberem Ende" 0 "$(count "$CLOG" '^bash')"
crun STUB_CODEX_RC=130
check "rootbridge-codex: Ctrl+C beendet das Fenster"       "0 0" "$CRC $(count "$CLOG" '^bash')"
crun STUB_CODEX_RC=3
check "rootbridge-codex: Fehler lässt die Shell offen"     "1" "$(count "$CLOG" '^bash -l')"
crun STUB_APT_RC=1 STUB_UPD_RC=1
check "rootbridge-codex: Fehler von apt/update egal, Codex startet" 1 "$(count "$CLOG" '^codex')"
# the fallback is the guest's /root; a CI runner has none, or one it may not enter
if [ -d /root ] && [ -x /root ]; then
    printf 'WORKDIR=/gibt/es/nicht\n' > "$CCONF"; crun
    check "rootbridge-codex: fehlender Arbeitsordner: Rückfall auf /root" "ja" "$(grep -q '^codex' "$CLOG" && echo ja || echo nein)"
fi
printf 'WORKDIR=%s\n' "$T/cwork" > "$CCONF"
check "rootbridge-codex: Codex-Argumente leer ohne CODEX_ARGS" "codex  | cwd=$T/cwork | BROWSER=/usr/local/bin/rootbridge-open" "$(crun; grep '^codex' "$CLOG")"
mv "$CB/codex" "$CB/codex.off"; crun ROOTBRIDGE_CODEX_BIN="$CB/gibt-es-nicht"
check "rootbridge-codex ohne codex: Hinweis und Shell"     "1 1" "$(count "$T/c.out" 'codex nicht gefunden') $(count "$CLOG" '^bash -l')"
mv "$CB/codex.off" "$CB/codex"

# =========================================================================== 4. rootbridge-claude
check "rootbridge-claude ruft rootbridge-update (nach apt)" 1 "$(count "$CLAUDEBIN" '^    rootbridge-update || true$')"
ra="$(grep -n 'rootbridge-apt ||' "$CLAUDEBIN" | head -n 1 | cut -d: -f1)"; ru="$(grep -n 'rootbridge-update ||' "$CLAUDEBIN" | head -n 1 | cut -d: -f1)"
rl="$(grep -n 'exec "\$claude_bin" --allow-dangerously-skip-permissions' "$CLAUDEBIN" | head -n 1 | cut -d: -f1)"
check "rootbridge-claude: apt < update < Start von Claude" ja "$([ -n "$ra" ] && [ -n "$ru" ] && [ -n "$rl" ] && [ "$ra" -lt "$ru" ] && [ "$ru" -lt "$rl" ] && echo ja || echo nein)"
check "rootbridge-claude: update_claude steckt nicht mehr darin" 0 "$(count "$CLAUDEBIN" '^update_claude')"
FUNCS="$(sed -n '/^conf_get() {/,/^}/p' "$CLAUDEBIN")"; EXPORT_LINE="$(grep 'export CODEX_PRECOMMIT=off' "$CLAUDEBIN")"
printf 'CODEX_PRECOMMIT=off\n' > "$T/cl.conf"
check "rootbridge-claude: CODEX_PRECOMMIT=off aus der Konfig kommt im Hook an" off \
      "$(env -u CODEX_PRECOMMIT bash -c 'CONF="$1"; eval "$2"; eval "$3"; echo "${CODEX_PRECOMMIT:-leer}"' _ "$T/cl.conf" "$FUNCS" "$EXPORT_LINE")"
printf 'CODEX_PRECOMMIT=on\n' > "$T/cl.conf"
check "rootbridge-claude: ein anderer Wert wird nicht weitergegeben" leer \
      "$(env -u CODEX_PRECOMMIT bash -c 'CONF="$1"; eval "$2"; eval "$3"; echo "${CODEX_PRECOMMIT:-leer}"' _ "$T/cl.conf" "$FUNCS" "$EXPORT_LINE")"
: > "$T/cl.conf"
check "rootbridge-claude: ohne Eintrag bleibt die Variable leer" leer \
      "$(env -u CODEX_PRECOMMIT bash -c 'CONF="$1"; eval "$2"; eval "$3"; echo "${CODEX_PRECOMMIT:-leer}"' _ "$T/cl.conf" "$FUNCS" "$EXPORT_LINE")"

# =========================================================================== 5. the rootbridge command
mkdir -p "$T/bin" "$T/lib/termux-rootbridge" "$T/stubs" "$T/home/.config/termux-rootbridge" "$T/prefix/bin"
sed "1s|^#!.*|#!$(command -v bash)|" "$ROOT/termux/bin/rootbridge" > "$T/bin/rootbridge"
cp "$ROOT/termux/lib/rootbridge-lib.sh" "$T/lib/termux-rootbridge/rootbridge-lib.sh"
cat > "$T/bin/rootbridge-daemon" <<'EOF'
#!/bin/bash
echo "daemon-start" >> "$STUB_LOG"
mkdir -p "$BRIDGE_DIR/.lock"
echo $$ > "$BRIDGE_DIR/.lock/pid"
touch "$BRIDGE_DIR/.alive"
sleep 60
EOF
cat > "$T/stubs/tmux" <<'EOF'
#!/bin/bash
echo "tmux $*" >> "$STUB_LOG"
[ "$1" = has-session ] && exit "${STUB_HAS_SESSION:-1}"
[ "$1" = list-windows ] && { printf '%s\n' ${STUB_WINDOWS:-}; exit 0; }
exit 0
EOF
cat > "$T/stubs/proot-distro" <<'EOF'
#!/bin/bash
echo "proot-distro $*" >> "$STUB_LOG"
exit 0
EOF
chmod +x "$T/bin/rootbridge" "$T/bin/rootbridge-daemon" "$T/stubs/tmux" "$T/stubs/proot-distro"
export STUB_LOG="$T/stub.log" BRIDGE_DIR="$T/bridge"
RBC="$T/home/.config/termux-rootbridge/config"
rb() {   # rb [env VAR=..] <args...>: the copied rootbridge; exit code in $RC
    : > "$STUB_LOG"
    env HOME="$T/home" PREFIX="$T/prefix" PATH="$T/stubs:$PATH" "$@" > "$T/out.txt" 2>&1
    RC=$?
}
calls() { grep -c -- "$1" "$STUB_LOG" || true; }
: > "$RBC"

rb bash "$T/bin/rootbridge" attach
check "attach (beide Tools): Standard ist Claude Code"     1 "$(calls '^tmux new-session -d -s ubuntu -n claude proot-distro login ubuntu -- /usr/local/bin/rootbridge-claude$')"
rb bash "$T/bin/rootbridge" attach codex
check "attach codex ohne Sitzung: erstes Fenster ist Codex" 1 "$(calls '^tmux new-session -d -s ubuntu -n codex proot-distro login ubuntu -- /usr/local/bin/rootbridge-codex$')"
check "attach codex ohne Sitzung: hängt sich an"           1 "$(calls '^tmux attach -t ubuntu$')"
rb env STUB_HAS_SESSION=0 STUB_WINDOWS=claude bash "$T/bin/rootbridge" attach codex
check "attach codex bei laufender Sitzung: neues Fenster"  1 "$(calls '^tmux new-window -d -t ubuntu: -n codex proot-distro login ubuntu -- /usr/local/bin/rootbridge-codex$')"
check "attach codex bei laufender Sitzung: keine neue Sitzung" 0 "$(calls '^tmux new-session')"
check "attach codex bei laufender Sitzung: Fenster wird gewählt" 1 "$(calls '^tmux select-window -t ubuntu:codex$')"
rb env STUB_HAS_SESSION=0 STUB_WINDOWS="claude codex" bash "$T/bin/rootbridge" attach codex
check "attach codex: Fenster da, kein zweites"             0 "$(calls '^tmux new-window')"
rb env STUB_HAS_SESSION=0 STUB_WINDOWS=codex bash "$T/bin/rootbridge" attach claude
check "attach claude: fehlendes Claude-Fenster kommt dazu" 1 "$(calls '^tmux new-window -d -t ubuntu: -n claude proot-distro login ubuntu -- /usr/local/bin/rootbridge-claude$')"
rb bash "$T/bin/rootbridge" attach vim
check "attach vim: Fehler"                                 1 "$RC"
check "attach vim: Meldung"                                1 "$(grep -c 'unbekanntes Programm' "$T/out.txt")"
rb bash "$T/bin/rootbridge" start --no-attach codex
check "start --no-attach codex: Sitzung mit Codex"         1 "$(calls '^tmux new-session -d -s ubuntu -n codex ')"

printf 'TOOL_CODEX=off\n' > "$RBC"
rb bash "$T/bin/rootbridge" attach codex
check "TOOL_CODEX=off: attach codex lehnt ab"              1 "$RC"
check "TOOL_CODEX=off: Meldung nennt --no-codex"           1 "$(grep -c -- '--no-codex' "$T/out.txt")"
check "TOOL_CODEX=off: tmux nicht angefasst"               0 "$(calls '^tmux ')"
rb bash "$T/bin/rootbridge" codex-login
check "TOOL_CODEX=off: codex-login lehnt ab"               1 "$RC"
printf 'TOOL_CLAUDE=off\n' > "$RBC"
rb bash "$T/bin/rootbridge" attach
check "TOOL_CLAUDE=off: attach ohne Argument öffnet Codex" 1 "$(calls '^tmux new-session -d -s ubuntu -n codex ')"
rb bash "$T/bin/rootbridge" attach claude
check "TOOL_CLAUDE=off: attach claude lehnt ab"            1 "$RC"
rb bash "$T/bin/rootbridge" start --no-attach
check "TOOL_CLAUDE=off: start startet Codex"               1 "$(calls '^tmux new-session -d -s ubuntu -n codex ')"
: > "$RBC"

rb bash "$T/bin/rootbridge" codex-login
check "codex-login: Exit 0"                                0 "$RC"
check "codex-login: Daemon läuft schon, kein zweiter"       0 "$(calls '^daemon-start$')"
check "codex-login: proot-distro login ... codex login"    1 "$(calls '^proot-distro login ubuntu -- bash -lc .*codex login "\$@" _$')"
check "codex-login: Browser-Übergabe gesetzt"              1 "$(calls 'BROWSER=/usr/local/bin/rootbridge-open')"
rb bash "$T/bin/rootbridge" codex-login --device-auth
check "codex-login --device-auth: wird weitergereicht"     1 "$(calls 'codex login "\$@" _ --device-auth$')"
rb bash "$T/bin/rootbridge" codex-login '; rm -rf /'
check "codex-login: Schrott als Argument wird abgelehnt"   1 "$RC"
check "codex-login: nichts ausgeführt"                     0 "$(calls '^proot-distro ')"

# codex-off / codex-on / status against a fake guest
G="$T/prefix/var/lib/proot-distro/containers/ubuntu/rootfs"
mkdir -p "$G/etc/claude-code" "$G/root/.local/bin" "$G/root/.codex" "$G/root/.claude/plugins/cache/openai-codex/codex/1.0.6" "$G/usr/local/bin"
printf 'WORKDIR=/root/work\nTICKET_TTL=1800\n' > "$G/etc/termux-rootbridge.conf"; chmod 644 "$G/etc/termux-rootbridge.conf"
rb bash "$T/bin/rootbridge" codex-off
check "codex-off: Exit 0"                                  0 "$RC"
check "codex-off: Zeile in der Gast-Konfig"                1 "$(grep -c '^CODEX_PRECOMMIT=off$' "$G/etc/termux-rootbridge.conf")"
check "codex-off: andere Zeilen bleiben"                   2 "$(grep -c '^WORKDIR=\|^TICKET_TTL=' "$G/etc/termux-rootbridge.conf")"
check "codex-off: Dateirechte bleiben"                     644 "$(stat -c '%a' "$G/etc/termux-rootbridge.conf")"
rb bash "$T/bin/rootbridge" codex-off
check "codex-off zweimal: weiter genau eine Zeile"         1 "$(grep -c '^CODEX_PRECOMMIT=' "$G/etc/termux-rootbridge.conf")"
check "codex-off: im Audit-Log"                            1 "$(grep -c 'CODEX-PRECOMMIT-off' "$T/bridge/audit.log" | head -n 1 | sed 's/^2$/1/')"
rb bash "$T/bin/rootbridge" codex-on
check "codex-on: Zeile weg"                                0 "$(grep -c '^CODEX_PRECOMMIT=' "$G/etc/termux-rootbridge.conf")"
check "codex-on: andere Zeilen bleiben"                    2 "$(grep -c '^WORKDIR=\|^TICKET_TTL=' "$G/etc/termux-rootbridge.conf")"

ln -s /root/.codex/packages/standalone/current/bin/codex "$G/root/.local/bin/codex"   # target exists only inside the guest
ln -s /nonexistent "$G/root/.local/bin/claude"
printf '#!/bin/bash\n' > "$G/usr/local/bin/androidsu"; chmod +x "$G/usr/local/bin/androidsu"
rb bash "$T/bin/rootbridge" status
check "status: Codex ok (Link mit Ziel im Gast zählt)"     1 "$(grep -c '^  Codex: *ok' "$T/out.txt")"
check "status: Codex-Login fehlt"                          1 "$(grep -c 'Codex-Login: *FEHLT' "$T/out.txt")"
check "status: Plugin ok"                                  1 "$(grep -c 'Codex-Plugin: *ok' "$T/out.txt")"
check "status: Pre-Commit-Review fehlt ohne Hook"          1 "$(grep -c 'Pre-Commit-Review: *FEHLT' "$T/out.txt")"
echo '{"hooks":{"PreToolUse":[{"hooks":[{"command":"x /usr/local/lib/termux-rootbridge/codex-precommit-review.py"}]}]}}' > "$G/etc/claude-code/managed-settings.json"
echo '{}' > "$G/root/.codex/auth.json"
rb bash "$T/bin/rootbridge" status
check "status: Login ok mit auth.json"                     1 "$(grep -c 'Codex-Login: *ok' "$T/out.txt")"
check "status: Pre-Commit-Review aktiv"                    1 "$(grep -c 'Pre-Commit-Review: *aktiv' "$T/out.txt")"
rb bash "$T/bin/rootbridge" codex-off; rb bash "$T/bin/rootbridge" status
check "status nach codex-off: AUSGESCHALTET"               1 "$(grep -c 'Pre-Commit-Review: *AUSGESCHALTET (codex-off)' "$T/out.txt")"
mv "$G/etc/claude-code/managed-settings.json" "$G/etc/claude-code/managed-settings.json.off"
rb bash "$T/bin/rootbridge" status
check "status nach guard-off: AUSGESCHALTET (guard-off)"   1 "$(grep -c 'Pre-Commit-Review: *AUSGESCHALTET (guard-off)' "$T/out.txt")"
printf 'TOOL_CODEX=off\n' > "$RBC"; rb bash "$T/bin/rootbridge" status
check "status ohne Codex: nennt --no-codex"                1 "$(grep -c 'Codex: *nicht Teil der Installation (--no-codex)' "$T/out.txt")"
printf 'TOOL_CLAUDE=off\n' > "$RBC"; rb bash "$T/bin/rootbridge" status
check "status ohne Claude Code: nennt --no-claude"         1 "$(grep -c 'Claude Code: *nicht Teil der Installation (--no-claude)' "$T/out.txt")"
check "status ohne Claude Code: keine Plugin-Zeile"        0 "$(grep -c 'Codex-Plugin' "$T/out.txt")"
: > "$RBC"
rb bash "$T/bin/rootbridge" help
check "help: nennt codex-login, codex-off und attach [claude|codex]" 3 "$(grep -c 'codex-login\|codex-off\|attach \[claude|codex\]' "$T/out.txt")"

# =========================================================================== 6. install.sh
H="$T/ih"; P="$T/ip"; GROOT="$P/var/lib/proot-distro/containers/ubuntu/rootfs"
mkdir -p "$H" "$P/bin" "$GROOT/var/tmp" "$T/istubs"
cat > "$T/istubs/proot-distro" <<'EOF'
#!/bin/bash
# logs the call and runs the guest scripts against a staging root, like test_autonomous.sh
echo "proot-distro $*" >> "$STUB_LOG"
[ "$1" = login ] || exit 0
shift 3; shift
script="$STUB_GROOT$1"; shift
case "$script" in *setup-guest.sh) exit 0 ;; esac
args=()
while [ $# -gt 0 ]; do
    case "$1" in /var/tmp/*) args+=("$STUB_GROOT$1") ;; *) args+=("$1") ;; esac
    shift
done
exec bash "$script" --root "$STUB_GUEST_ROOT" "${args[@]}" < /dev/null
EOF
printf '#!/bin/bash\nexit 0\n' > "$T/istubs/termux-reload-settings"
printf '#!/bin/bash\necho "rootbridge $*" >> "$STUB_LOG"\nexit 1\n' > "$T/istubs/rootbridge"
chmod +x "$T/istubs"/*
export STUB_GROOT="$GROOT" STUB_GUEST_ROOT="$T/iguest"
ILOG="$T/i.log"
irun() {   # irun [args...]; the guest root starts empty every time, HOME/PREFIX stay
    rm -rf "$T/iguest"; : > "$ILOG"
    STUB_LOG="$ILOG" HOME="$H" PREFIX="$P" PATH="$T/istubs:$PATH" ROOTBRIDGE_ALLOW_GUEST=1 BRIDGE_DIR="$H/.rootbridge" \
        bash "$INSTALL" --no-boot --no-migrate --no-deps-check --no-extra-keys --no-colors --no-setup "$@" > "$T/install.log" 2>&1
    IRC=$?
}
ICFG="$H/.config/termux-rootbridge/config"
iget() { sed -n "s/^$1=//p" "$ICFG" 2>/dev/null | tail -n 1; }
guestargs() { grep 'install-guest.sh' "$ILOG" | tail -n 1; }

irun
check "install.sh ohne Option: läuft"                      0 "$IRC"
check "install.sh: Widgets Claude, Codex, Ubuntu"          "ja ja ja" "$(has "$H/.shortcuts/Claude") $(has "$H/.shortcuts/Codex") $(has "$H/.shortcuts/Ubuntu")"
check "install.sh: Codex-Widget startet das Codex-Fenster" 1 "$(count "$H/.shortcuts/Codex" '^exec rootbridge attach codex$')"
check "install.sh: Codex-Widget ist ausführbar"            ja "$([ -x "$H/.shortcuts/Codex" ] && echo ja || echo nein)"
check "install.sh: Codex-Widget hat das Standard-Icon"     0 "$(cmp -s "$ROOT/termux/shortcuts/icons/widget.png" "$H/.shortcuts/icons/Codex.png"; echo $?)"
check "install.sh: gibt --claude yes --codex yes an den Gast" 1 "$(guestargs | grep -c -- '--claude yes --codex yes')"
check "install.sh: Gast hat beide Hooks"                   "pre=2 codex=1 guard=1 post=1 timeout=900 onFailure=block" "$(msum "$T/iguest")"
check "install.sh: Abschlussmeldung nennt rootbridge codex-login" 1 "$(count "$T/install.log" 'rootbridge codex-login')"
for entry in "ubuntu:Ubuntu-Shell" "claude:Claude-Code-Sitzung" "codex:Codex-Sitzung"; do
    check "install.sh: Abschlussmeldung erklärt ${entry%%:*}" 1 "$(count "$T/install.log" "^  ${entry%%:*} .*${entry#*:}")"
done
check "install.sh: ohne Option nichts in der Termux-Konfig gespeichert" "" "$(iget TOOL_CODEX)$(iget TOOL_CLAUDE)"

irun --no-codex
check "install.sh --no-codex: läuft"                       0 "$IRC"
check "install.sh --no-codex: kein Codex-Widget"           nein "$(has "$H/.shortcuts/Codex")"
check "install.sh --no-codex: Claude-Widget bleibt"        ja "$(has "$H/.shortcuts/Claude")"
check "install.sh --no-codex: Gast bekommt --codex no"     1 "$(guestargs | grep -c -- '--claude yes --codex no')"
check "install.sh --no-codex: Wahl in der Termux-Konfig"   off "$(iget TOOL_CODEX)"
check "install.sh --no-codex: kein Codex-Hook im Gast"     "pre=1 codex=0 guard=1 post=1 timeout=- onFailure=-" "$(msum "$T/iguest")"
check "install.sh --no-codex: Abschluss ohne Codex-Login-Satz" 0 "$(count "$T/install.log" 'rootbridge codex-login')"

irun
check "install.sh danach ohne Option: Wahl bleibt (kein Codex)" "nein" "$(has "$H/.shortcuts/Codex")"
check "install.sh danach: Meldung über die gespeicherte Wahl" 1 "$(count "$T/install.log" 'Codex: abgewählt')"
check "install.sh danach: Gast bekommt --codex no"         1 "$(guestargs | grep -c -- '--codex no')"
irun --codex
check "install.sh --codex: Codex-Widget wieder da"         ja "$(has "$H/.shortcuts/Codex")"
check "install.sh --codex: Wahl in der Konfig on"          on "$(iget TOOL_CODEX)"
check "install.sh --codex: Gast bekommt --codex yes"       1 "$(guestargs | grep -c -- '--codex yes')"

irun --no-claude
check "install.sh --no-claude: läuft"                      0 "$IRC"
check "install.sh --no-claude: Claude-Widget entfernt"     nein "$(has "$H/.shortcuts/Claude")"
check "install.sh --no-claude: Kopie des alten Widgets in backups" 1 "$(ls "$H/.rootbridge/backups"/Claude.old-* 2>/dev/null | wc -l | tr -d ' ')"
check "install.sh --no-claude: Codex-Widget und Ubuntu bleiben" "ja ja" "$(has "$H/.shortcuts/Codex") $(has "$H/.shortcuts/Ubuntu")"
check "install.sh --no-claude: Gast bekommt --claude no"   1 "$(guestargs | grep -c -- '--claude no --codex yes')"
check "install.sh --no-claude: keine Managed Settings im Gast" "keine Datei" "$(msum "$T/iguest")"
check "install.sh --no-claude: Wahl in der Konfig off"     off "$(iget TOOL_CLAUDE)"
check "install.sh --no-claude: Abschluss nennt den Bypass-Modus nicht" 0 "$(count "$T/install.log" 'Bypass-Modus im Ordner')"
check "install.sh --no-claude: Abschluss nennt keine Managed Settings" 0 "$(count "$T/install.log" 'Managed Settings gelten')"
irun --claude
check "install.sh --claude: Claude-Widget wieder da"       ja "$(has "$H/.shortcuts/Claude")"

irun --no-claude --no-codex
check "install.sh beides aus: Code 2"                      2 "$IRC"
check "install.sh beides aus: Gast nicht angefasst"        0 "$(wc -c < "$ILOG" | tr -d ' ')"
irun --no-claude
irun --no-codex
check "install.sh gespeichertes --no-claude + neues --no-codex: Fehler" 1 "$IRC"
check "install.sh abgelehnte Kombination: Konfig bleibt (Codex weiter on)" "on off" "$(iget TOOL_CODEX) $(iget TOOL_CLAUDE)"
irun --claude --codex
check "install.sh --claude --codex: zurück auf beide"      0 "$IRC"

irun --codex-update daily
check "install.sh --codex-update daily: an den Gast"       1 "$(guestargs | grep -c -- '--codex-update daily')"
check "install.sh --codex-update daily: gespeichert"       daily "$(iget CODEX_UPDATE)"
check "install.sh --codex-update daily: im Gast"           daily "$(sed -n 's/^CODEX_UPDATE=//p' "$T/iguest/etc/termux-rootbridge.conf")"
irun
check "install.sh danach ohne Option: Modus aus der Konfig" 1 "$(guestargs | grep -c -- '--codex-update daily')"
irun --no-codex-update
check "install.sh --no-codex-update: off"                  off "$(iget CODEX_UPDATE)"
irun --codex-update bogus
check "install.sh --codex-update bogus: Code 2"            2 "$IRC"
check "install.sh --codex-update bogus: Gast nicht angefasst" 0 "$(wc -c < "$ILOG" | tr -d ' ')"

# readiness check of the guest: with Codex and the plugin missing, the setup runs even though Claude Code is there
mkdir -p "$GROOT/usr/bin" "$GROOT/etc/ssl/certs" "$GROOT/root/.local/bin"
for b in python3 curl; do printf '#!/bin/bash\n' > "$GROOT/usr/bin/$b"; done
echo cert > "$GROOT/etc/ssl/certs/ca-certificates.crt"
printf '#!/bin/bash\n' > "$GROOT/root/.local/bin/claude"; chmod +x "$GROOT/root/.local/bin/claude"
rm -f "$H/.config/termux-rootbridge/config"
ROOTBRIDGE_GUEST_HOME=/root irun --no-codex
check "Gast mit Claude Code, --no-codex: setup-guest.sh läuft nicht" 0 "$(grep -c 'setup-guest.sh' "$ILOG" | head -n 1)"
rm -f "$H/.config/termux-rootbridge/config"
ROOTBRIDGE_GUEST_HOME=/root irun --setup
check "Gast mit Claude Code, Codex fehlt: setup-guest.sh läuft" 1 "$(grep -c 'setup-guest.sh' "$ILOG" | head -n 1)"
check "Gast mit Claude Code, Codex fehlt: mit --claude yes --codex yes" 1 "$(grep 'setup-guest.sh' "$ILOG" | grep -c -- '--claude yes --codex yes')"
printf '#!/bin/bash\n' > "$GROOT/usr/bin/git"; printf '#!/bin/bash\n' > "$GROOT/usr/bin/node"
ln -s /root/.codex/packages/standalone/current/bin/codex "$GROOT/root/.local/bin/codex"
rm -f "$H/.config/termux-rootbridge/config"
ROOTBRIDGE_GUEST_HOME=/root irun --setup
check "Gast mit Codex, git, node, aber ohne Plugin: setup-guest.sh läuft" 1 "$(grep -c 'setup-guest.sh' "$ILOG" | head -n 1)"
mkdir -p "$GROOT/root/.claude/plugins/cache/openai-codex/codex/1.0.6"
rm -f "$H/.config/termux-rootbridge/config"
ROOTBRIDGE_GUEST_HOME=/root irun --setup
check "Gast komplett: setup-guest.sh läuft nicht"          0 "$(grep -c 'setup-guest.sh' "$ILOG" | head -n 1)"
rm -rf "${GROOT:?}/usr/bin" "${GROOT:?}/root"

# The new-conversation widget is installed and removed together with Claude.
irun --claude --codex
check "Claude Neu: Widget vorhanden" ja "$(has "$H/.shortcuts/Claude Neu")"
check "Claude Neu: startet explizit neu" 1 "$(grep -c 'rootbridge attach claude --new' "$H/.shortcuts/Claude Neu")"
irun --no-claude
check "Claude Neu: bei --no-claude entfernt" nein "$(has "$H/.shortcuts/Claude Neu")"

# uninstall: the Codex widget and its default icon go (a stub rootbridge: uninstall.sh calls `rootbridge stop`)
irun --claude --codex
check "uninstall: vorher Codex-Widget und Icon da"         "ja ja" "$(has "$H/.shortcuts/Codex") $(has "$H/.shortcuts/icons/Codex.png")"
STUB_LOG="$ILOG" HOME="$H" PREFIX="$P" PATH="$T/istubs:$PATH" bash "$UNINSTALL" --no-guest > "$T/uninstall.log" 2>&1
check "uninstall: läuft"                                   0 "$?"
check "uninstall: Codex-Widget und sein Standard-Icon weg" "nein nein" "$(has "$H/.shortcuts/Codex") $(has "$H/.shortcuts/icons/Codex.png")"

echo
echo "Ergebnis: $PASS bestanden, $FAIL fehlgeschlagen"
[ "$FAIL" -eq 0 ]
