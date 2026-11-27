#!/usr/bin/env bash
# Test: OpenCode as the third tool, and who reviews the commits of Claude Code (REVIEWERS).
#   1. guest installer (staging root): --opencode (window script, config keys, PATH and opencode() in the bashrc block,
#      the guidelines in ~/.config/opencode/AGENTS.md), --reviewers (the review hook, the Codex plugin only with Codex,
#      only tools of the installation review), --opencode no, --opencode-update, uninstall
#   2. rootbridge-update with a stub opencode: `opencode upgrade` only when OpenCode is part of the installation
#   3. rootbridge-opencode with stubs: apt and the update come before OpenCode, working directory, OPENCODE_ARGS
#   4. the rootbridge command (stub tmux / proot-distro): attach opencode, the default tool, stop, status
#   5. install.sh (stub proot-distro, fake HOME/PREFIX): --opencode, --reviewers, the widget, the choice is stored
# The review itself (OpenCode as a reviewer, both) is tested in test_codex_precommit.py. Nothing real is touched.
#   bash tests/test_opencode.sh
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib.sh
. "$ROOT/tests/lib.sh"
GUEST="$ROOT/guest/install-guest.sh"
UPDATE="$ROOT/guest/bin/rootbridge-update"
OCBIN="$ROOT/guest/bin/rootbridge-opencode"
INSTALL="$ROOT/install.sh"

T="$(mktemp -d)"
cleanup() {
    local p
    p="$(cat "$T/bridge/.lock/pid" 2>/dev/null)"
    [ -n "$p" ] && kill "$p" 2>/dev/null
    rm -rf "$T"
}
trap cleanup EXIT
export ROOTBRIDGE_GUEST_HOME=/home/tester

count() { local n; n="$(grep -c -- "$2" "$1" 2>/dev/null)"; echo "${n:-0}"; }
has() { [ -e "$1" ] && echo ja || echo nein; }

for f in "$OCBIN" "$ROOT/termux/shortcuts/opencode"; do
    bash -n "$f" 2>/dev/null
    check "Syntax in Ordnung: ${f#"$ROOT"/}" 0 "$?"
done

# =========================================================================== 1. guest installer
ginstall() {   # ginstall <stage> [args...]
    local stage="$1"; shift
    bash "$GUEST" --root "$stage" --autonomous no "$@" > "$T/guest.log" 2>&1
    GRC=$?
}
gval() { sed -n "s/^$2=//p" "$1/etc/termux-rootbridge.conf" | tail -n 1; }
review() {   # review <stage>: "hook=<n> plugin=<yes|no>" from the managed settings
    python3 -I - "$1/etc/claude-code/managed-settings.json" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except OSError:
    print("keine Datei")
    sys.exit()
cmds = [h.get("command", "") for e in d.get("hooks", {}).get("PreToolUse", []) for h in e.get("hooks", [])]
print("hook=%d plugin=%s" % (sum("codex-precommit-review.py" in c for c in cmds),
                             "yes" if "codex@openai-codex" in d.get("enabledPlugins", {}) else "no"))
PY
}
S="$T/stage"
B="$S/home/tester/.bashrc"
ginstall "$S" --opencode yes
check "Gast --opencode yes: läuft"                         0 "$GRC"
check "Gast --opencode yes: rootbridge-opencode"           ja "$(has "$S/usr/local/bin/rootbridge-opencode")"
check "Gast --opencode yes: TOOL_OPENCODE=on"              on "$(gval "$S" TOOL_OPENCODE)"
check "Gast --opencode yes: OPENCODE_UPDATE=6h"            6h "$(gval "$S" OPENCODE_UPDATE)"
check "Gast --opencode yes: Codex prüft (Standard)"        codex "$(gval "$S" REVIEWERS)"
check "Gast --opencode yes: Hook und Codex-Plugin"         "hook=1 plugin=yes" "$(review "$S")"
check "Gast --opencode yes: PATH mit ~/.opencode/bin"      1 "$(count "$B" '\.opencode/bin:\$PATH')"
check "Gast --opencode yes: opencode() mit Browser"        1 "$(count "$B" '^opencode() { BROWSER=/usr/local/bin/rootbridge-open OPENCODE_DISABLE_AUTOUPDATE=1 command opencode')"
check "Gast --opencode yes: Richtlinien für OpenCode"      1 "$(count "$S/home/tester/.config/opencode/AGENTS.md" '^## Code Quality')"
ginstall "$S" --reviewers opencode
check "Gast --reviewers opencode: OpenCode bleibt (aus der Konfig)" on "$(gval "$S" TOOL_OPENCODE)"
check "Gast --reviewers opencode: gespeichert"            opencode "$(gval "$S" REVIEWERS)"
check "Gast --reviewers opencode: Hook, Codex-Plugin bleibt" "hook=1 plugin=yes" "$(review "$S")"
ginstall "$S" --reviewers opencode,codex
check "Gast --reviewers opencode,codex: in fester Reihenfolge" codex,opencode "$(gval "$S" REVIEWERS)"
ginstall "$S" --codex no
check "Gast --codex no: nur OpenCode prüft"                opencode "$(gval "$S" REVIEWERS)"
check "Gast --codex no: Hook ohne Codex-Plugin"            "hook=1 plugin=no" "$(review "$S")"
check "Gast --codex no: Hook-Skript bleibt"                ja "$(has "$S/usr/local/lib/termux-rootbridge/codex-precommit-review.py")"
ginstall "$S" --opencode no
check "Gast --opencode no (ohne Codex): kein Hook"         "hook=0 plugin=no" "$(review "$S")"
check "Gast --opencode no: rootbridge-opencode weg"        nein "$(has "$S/usr/local/bin/rootbridge-opencode")"
check "Gast --opencode no: Hook-Skript weg"                nein "$(has "$S/usr/local/lib/termux-rootbridge/codex-precommit-review.py")"
check "Gast --opencode no: Richtlinien-Block weg"          nein "$(has "$S/home/tester/.config/opencode/AGENTS.md")"
check "Gast --opencode no: kein opencode() mehr"           0 "$(count "$B" '^opencode()')"
ginstall "$S" --codex yes
check "Gast --codex yes: Codex prüft wieder"               "codex hook=1 plugin=yes" "$(gval "$S" REVIEWERS) $(review "$S")"
ginstall "$S" --reviewers gemini
check "Gast --reviewers gemini: abgelehnt"                 2 "$GRC"
ginstall "$S" --opencode yes --opencode-update daily
check "Gast --opencode-update daily"                       daily "$(gval "$S" OPENCODE_UPDATE)"
ginstall "$S" --uninstall
check "Gast --uninstall: rootbridge-opencode weg"          nein "$(has "$S/usr/local/bin/rootbridge-opencode")"
check "Gast --uninstall: Richtlinien für OpenCode weg"     nein "$(has "$S/home/tester/.config/opencode/AGENTS.md")"
S2="$T/stage2"
ginstall "$S2" --claude no --codex no --opencode yes
check "Gast nur OpenCode: läuft"                           0 "$GRC"
check "Gast nur OpenCode: keine Managed Settings"          "keine Datei" "$(review "$S2")"
ginstall "$T/stage3" --claude no --codex no
check "Gast ohne jedes Werkzeug: abgelehnt"                2 "$GRC"

# =========================================================================== 2. rootbridge-update
UB="$T/ubin"; mkdir -p "$UB"
for c in bash sed date head tail flock mkdir dirname cat tr sleep env rm; do
    r="$(command -v "$c")" && ln -sf "$r" "$UB/$c"
done
printf '#!/bin/bash\nshift\nexec "$@"\n' > "$UB/timeout"
for t in claude codex opencode; do
    printf '#!/bin/bash\necho "%s $*" >> "$STUB_LOG"\nexit 0\n' "$t" > "$UB/$t"
done
chmod +x "$UB"/*
USTATE="$T/ustate"; UCONF="$T/u.conf"; ULOG="$T/u.log"
mkdir -p "$T/update-home"
urun() {   # urun <config lines...>: one run of the real rootbridge-update with the stubs
    rm -rf "$USTATE"; : > "$ULOG"; printf '%s\n' "$@" > "$UCONF"
    env -i HOME="$T/update-home" PATH="$UB" ROOTBRIDGE_UPDATE_KEEP_PATH=1 ROOTBRIDGE_CONF="$UCONF" ROOTBRIDGE_GUEST_LIB="$ROOTBRIDGE_GUEST_LIB" ROOTBRIDGE_STATE_DIR="$USTATE" \
        ROOTBRIDGE_CLAUDE_BIN="$UB/claude" ROOTBRIDGE_CODEX_BIN="$UB/codex" ROOTBRIDGE_OPENCODE_BIN="$UB/opencode" STUB_LOG="$ULOG" \
        "$(command -v bash)" "$UPDATE" > "$T/u.out" 2>&1
    URC=$?
}
urun ""
check "update ohne TOOL_OPENCODE: kein opencode upgrade"   "0 0" "$URC $(count "$ULOG" '^opencode')"
urun "TOOL_OPENCODE=on"
check "update mit OpenCode: opencode upgrade läuft"        1 "$(count "$ULOG" '^opencode upgrade$')"
check "update mit OpenCode: Zeitstempel"                   ja "$(has "$USTATE/opencode-update-last-success")"
urun "TOOL_OPENCODE=on" "OPENCODE_UPDATE=off"
check "update OPENCODE_UPDATE=off: kein Upgrade"           0 "$(count "$ULOG" '^opencode')"

# =========================================================================== 3. rootbridge-opencode
CB="$T/cbin"; mkdir -p "$CB" "$T/cwork" "$T/cpath"
for c in bash sed tail cat env; do r="$(command -v "$c")" && ln -sf "$r" "$CB/$c"; done
printf '#!/bin/bash\necho "apt" >> "$STUB_LOG"\n' > "$CB/rootbridge-apt"
printf '#!/bin/bash\necho "update" >> "$STUB_LOG"\n' > "$CB/rootbridge-update"
cat > "$CB/opencode" <<'EOF'
#!/bin/bash
echo "opencode $* | cwd=$PWD | BROWSER=${BROWSER:-} | AUTOUPDATE=${OPENCODE_DISABLE_AUTOUPDATE:-}" >> "$STUB_LOG"
exit "${STUB_OC_RC:-0}"
EOF
printf '#!/bin/bash\necho "bash $*" >> "$STUB_LOG"\n' > "$CB/bashstub"
chmod +x "$CB"/*
ln -sf "$CB/bashstub" "$T/cpath/bash"
CLOG="$T/c.log"; CCONF="$T/c.conf"
crun() {   # crun [VAR=value ...]
    : > "$CLOG"
    env -i PATH="$T/cpath:$CB" ROOTBRIDGE_OPENCODE_KEEP_PATH=1 ROOTBRIDGE_CONF="$CCONF" ROOTBRIDGE_GUEST_LIB="$ROOTBRIDGE_GUEST_LIB" \
        ROOTBRIDGE_OPENCODE_BIN="$CB/opencode" STUB_LOG="$CLOG" "$@" "$(command -v bash)" "$OCBIN" > "$T/c.out" 2>&1
    CRC=$?
}
printf 'WORKDIR=%s\nOPENCODE_ARGS="--model anthropic/test"\n' "$T/cwork" > "$CCONF"
crun
check "rootbridge-opencode: apt, update, dann OpenCode"   "apt|update|opencode --model anthropic/test | cwd=$T/cwork | BROWSER=/usr/local/bin/rootbridge-open | AUTOUPDATE=1" "$(paste -sd'|' "$CLOG")"
check "rootbridge-opencode: sauberes Ende ohne Shell"     "0 0" "$CRC $(count "$CLOG" '^bash')"
crun STUB_OC_RC=3
check "rootbridge-opencode: Fehler lässt die Shell offen" 1 "$(count "$CLOG" '^bash -l')"
mv "$CB/opencode" "$CB/opencode.off"; crun ROOTBRIDGE_OPENCODE_BIN="$CB/gibt-es-nicht"
check "rootbridge-opencode ohne opencode: Hinweis und Shell" "1 1" "$(count "$T/c.out" 'opencode nicht gefunden') $(count "$CLOG" '^bash -l')"
mv "$CB/opencode.off" "$CB/opencode"

# =========================================================================== 4. the rootbridge command
mkdir -p "$T/bin" "$T/lib/termux-rootbridge" "$T/stubs" "$T/home/.config/termux-rootbridge" "$T/prefix/bin"
sed "1s|^#!.*|#!$(command -v bash)|" "$ROOT/termux/bin/rootbridge" > "$T/bin/rootbridge"
cp "$ROOT/termux/lib/rootbridge-lib.sh" "$T/lib/termux-rootbridge/rootbridge-lib.sh"
cat > "$T/bin/rootbridge-daemon" <<'EOF'
#!/bin/bash
mkdir -p "$BRIDGE_DIR/.lock"
echo $$ > "$BRIDGE_DIR/.lock/pid"
touch "$BRIDGE_DIR/.alive"
sleep 60
EOF
cat > "$T/stubs/tmux" <<'EOF'
#!/bin/bash
echo "tmux $*" >> "$STUB_LOG"
[ "$1" = has-session ] && exit "${STUB_HAS_SESSION:-1}"
exit 0
EOF
printf '#!/bin/bash\necho "proot-distro $*" >> "$STUB_LOG"\n' > "$T/stubs/proot-distro"
for c in pulseaudio pgrep pkill; do printf '#!/bin/bash\nexit 1\n' > "$T/stubs/$c"; done
chmod +x "$T/bin"/* "$T/stubs"/*
export STUB_LOG="$T/stub.log" BRIDGE_DIR="$T/bridge"
export RB_STORAGE_DIR="$T/no-storage"
RBC="$T/home/.config/termux-rootbridge/config"
rb() {   # rb <args...>: the copied rootbridge; exit code in $RC
    : > "$STUB_LOG"
    env HOME="$T/home" PREFIX="$T/prefix" PATH="$T/stubs:$PATH" "$@" > "$T/out.txt" 2>&1
    RC=$?
}
calls() { grep -c -- "$1" "$STUB_LOG" || true; }
ISO="--isolated --bind $T/bridge:$T/bridge"
: > "$RBC"
rb bash "$T/bin/rootbridge" attach opencode
check "attach opencode ohne OpenCode: abgelehnt"           "1 1" "$RC $(count "$T/out.txt" 'install.sh --opencode')"
printf 'TOOL_OPENCODE=on\n' > "$RBC"
rb bash "$T/bin/rootbridge" attach opencode
check "attach opencode: eigene Sitzung"                    1 "$(calls '^tmux new-session -d -s ubuntu-opencode -n opencode proot-distro login ubuntu '"$ISO"' -- /usr/local/bin/rootbridge-opencode$')"
printf 'TOOL_CLAUDE=off\nTOOL_CODEX=off\nTOOL_OPENCODE=on\n' > "$RBC"
rb bash "$T/bin/rootbridge" attach
check "attach (nur OpenCode): Standard ist OpenCode"       1 "$(calls '^tmux new-session -d -s ubuntu-opencode -n opencode')"
rb env STUB_HAS_SESSION=0 bash "$T/bin/rootbridge" stop
check "stop: beendet auch die OpenCode-Sitzung"            1 "$(calls '^tmux kill-session -t =ubuntu-opencode$')"
G="$T/prefix/var/lib/proot-distro/containers/ubuntu/rootfs"
mkdir -p "$G/root/.opencode/bin" "$G/root/.local/share/opencode" "$G/etc/claude-code" "$G/usr/local/bin"
printf '#!/bin/bash\n' > "$G/root/.opencode/bin/opencode"; chmod +x "$G/root/.opencode/bin/opencode"
printf 'REVIEWERS=opencode\n' > "$G/etc/termux-rootbridge.conf"
echo '{"hooks":{"PreToolUse":[{"hooks":[{"command":"x /usr/local/lib/termux-rootbridge/codex-precommit-review.py"}]}]}}' > "$G/etc/claude-code/managed-settings.json"
printf 'TOOL_CODEX=off\nTOOL_OPENCODE=on\n' > "$RBC"
rb bash "$T/bin/rootbridge" status
check "status: OpenCode ok, Login fehlt"                   "1 1" "$(count "$T/out.txt" 'OpenCode: *ok') $(count "$T/out.txt" 'OpenCode-Login: *FEHLT (im OpenCode-Fenster: /connect)')"
check "status: Pre-Commit-Review nennt OpenCode"           1 "$(count "$T/out.txt" 'Pre-Commit-Review: *aktiv: opencode')"
echo '{}' > "$G/root/.local/share/opencode/auth.json"
rb bash "$T/bin/rootbridge" status
check "status: OpenCode-Login ok mit auth.json"            1 "$(count "$T/out.txt" 'OpenCode-Login: *ok')"

# =========================================================================== 5. install.sh
H="$T/ih"; P="$T/ip"; GROOT="$P/var/lib/proot-distro/containers/ubuntu/rootfs"
mkdir -p "$H" "$P/bin" "$GROOT/var/tmp" "$T/istubs"
cp "$ROOT/tests/stubs/proot-distro-guest-scripts" "$T/istubs/proot-distro"
printf '#!/bin/bash\nexit 0\n' > "$T/istubs/termux-reload-settings"
printf '#!/bin/bash\nexit 1\n' > "$T/istubs/rootbridge"
printf '#!/bin/bash\n[ "$1" = --check ] && exit 1\nexit 0\n' > "$T/istubs/pulseaudio"
printf '#!/bin/bash\nexit 1\n' > "$T/istubs/pactl"
printf '#!/bin/bash\ncase "$*" in *pulseaudio*) exit 1 ;; esac\nexec %s "$@"\n' "$(command -v pgrep || echo false)" > "$T/istubs/pgrep"
chmod +x "$T/istubs"/*
export STUB_GROOT="$GROOT" STUB_GUEST_ROOT="$T/iguest"
ILOG="$T/i.log"
irun() {   # irun [args...]: a fresh guest, HOME/PREFIX stay
    rm -rf "$T/iguest"; : > "$ILOG"
    STUB_LOG="$ILOG" HOME="$H" PREFIX="$P" PATH="$T/istubs:$PATH" ROOTBRIDGE_ALLOW_GUEST=1 BRIDGE_DIR="$H/.rootbridge" \
        bash "$INSTALL" --no-boot --no-migrate --no-deps-check --no-extra-keys --no-colors --no-setup "$@" > "$T/install.log" 2>&1
    IRC=$?
}
ICFG="$H/.config/termux-rootbridge/config"
iget() { sed -n "s/^$1=//p" "$ICFG" 2>/dev/null | tail -n 1; }
guestargs() { grep 'install-guest.sh' "$ILOG" | tail -n 1; }
irun
check "install.sh ohne Option: kein OpenCode"              "0 nein" "$IRC $(has "$H/.shortcuts/OpenCode")"
check "install.sh ohne Option: --opencode no an den Gast"  1 "$(guestargs | grep -c -- '--opencode no')"
irun --opencode --reviewers codex,opencode
check "install.sh --opencode: läuft"                       0 "$IRC"
check "install.sh --opencode: Widget startet OpenCode"     1 "$(count "$H/.shortcuts/OpenCode" '^exec rootbridge attach opencode$')"
check "install.sh --opencode: an den Gast"                 1 "$(guestargs | grep -c -- '--opencode yes .*--reviewers codex,opencode')"
check "install.sh --opencode: gespeichert"                 "on codex,opencode" "$(iget TOOL_OPENCODE) $(iget REVIEWERS)"
check "install.sh --opencode: Alias opencode"              1 "$(count "$H/.bashrc" "^alias opencode='rootbridge attach opencode'$")"
check "install.sh --opencode: nennt /connect"              1 "$(count "$T/install.log" '/connect im OpenCode-Fenster')"
irun
check "install.sh danach ohne Option: OpenCode bleibt"     "ja 1" "$(has "$H/.shortcuts/OpenCode") $(guestargs | grep -c -- '--opencode yes .*--reviewers codex,opencode')"
irun --no-opencode
check "install.sh --no-opencode: Widget weg"               "nein off" "$(has "$H/.shortcuts/OpenCode") $(iget TOOL_OPENCODE)"
irun --reviewers gemini
check "install.sh --reviewers gemini: abgelehnt"           2 "$IRC"

finish
