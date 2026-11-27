#!/usr/bin/env bash
# Test: the automatic effort (EFFORT_AUTO, effort-router as a pinned plugin of the managed settings).
#   1. guest installer (staging root): --effort-auto effort-router declares the plugin and its inline marketplace (pinned to
#      one commit, fetched over https: the guest knows no SSH host key of github.com), next to the Codex plugin; off and --claude no take only ours out; a declaration of yours stays;
#      the choice is stored; a wrong value is refused
#   2. install.sh (stub proot-distro, fake HOME/PREFIX): the option goes to the guest and is stored, off by default
#   3. rootbridge status names it
#   bash tests/test_effort.sh
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib.sh
. "$ROOT/tests/lib.sh"
GUEST="$ROOT/guest/install-guest.sh"
INSTALL="$ROOT/install.sh"
make_tmp
export ROOTBRIDGE_GUEST_HOME=/home/tester
SHA=bd3496ca18b7000930679b890662c7bb8a947412

# =========================================================================== 1. guest installer
ginstall() {   # ginstall <stage> [args...]
    local stage="$1"; shift
    bash "$GUEST" --root "$stage" --autonomous no "$@" > "$T/guest.log" 2>&1
    GRC=$?
}
gval() { sed -n "s/^$2=//p" "$1/etc/termux-rootbridge.conf" | tail -n 1; }
plugins() {   # plugins <stage>: the enabled plugins, the marketplaces and the pin of effort-router
    python3 -I - "$1/etc/claude-code/managed-settings.json" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except OSError:
    print("keine Datei")
    sys.exit()
markets = d.get("extraKnownMarketplaces", {})
pin = "-"
source = markets.get("rootbridge-effort", {}).get("source", {})
if source:
    entry = source["plugins"][0]["source"]
    pin = "%s %s %s %s" % (source["source"], source["name"], entry["url"], entry["sha"])
print("%s | %s | %s" % (" ".join(sorted(d.get("enabledPlugins", {}))), " ".join(sorted(markets)), pin))
PY
}
S="$T/stage"
ginstall "$S"
check "Gast ohne Option: aus"                              "0 off" "$GRC $(gval "$S" EFFORT_AUTO)"
check "Gast ohne Option: nur das Codex-Plugin"             "codex@openai-codex | openai-codex | -" "$(plugins "$S")"
ginstall "$S" --effort-auto effort-router
check "Gast --effort-auto effort-router: gespeichert"      effort-router "$(gval "$S" EFFORT_AUTO)"
check "Gast --effort-auto effort-router: Plugin fest auf einen Commit" \
      "codex@openai-codex effort-router@rootbridge-effort | openai-codex rootbridge-effort | settings rootbridge-effort https://github.com/cfitzgerald-pd/effort-router.git $SHA" "$(plugins "$S")"
check "Gast --effort-auto effort-router: Meldung"          1 "$(grep -c 'Effort-Wahl: Claude Code lädt effort-router' "$T/guest.log")"
ginstall "$S"
check "Gast danach ohne Option: bleibt an"                 "effort-router 1" "$(gval "$S" EFFORT_AUTO) $(plugins "$S" | grep -c rootbridge-effort)"
# a plugin of yours in the managed settings stays when ours goes
python3 -I - "$S/etc/claude-code/managed-settings.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
d["enabledPlugins"]["mine@elsewhere"] = True
json.dump(d, open(sys.argv[1], "w"))
PY
ginstall "$S" --effort-auto off
check "Gast --effort-auto off: nur unseres geht"           "codex@openai-codex mine@elsewhere | openai-codex | -" "$(plugins "$S")"
check "Gast --effort-auto off: gespeichert"                off "$(gval "$S" EFFORT_AUTO)"
ginstall "$S" --effort-auto effort-router --codex no
check "Gast ohne Codex: effort-router bleibt allein"       "effort-router@rootbridge-effort mine@elsewhere | rootbridge-effort | settings rootbridge-effort https://github.com/cfitzgerald-pd/effort-router.git $SHA" "$(plugins "$S")"
ginstall "$S" --uninstall
check "Gast --uninstall: unser Plugin weg, deines bleibt"  "mine@elsewhere |  | -" "$(plugins "$S")"
ginstall "$S" --effort-auto immer
check "Gast --effort-auto immer: abgelehnt"                2 "$GRC"

# =========================================================================== 2. install.sh
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
iget() { sed -n "s/^$1=//p" "$H/.config/termux-rootbridge/config" 2>/dev/null | tail -n 1; }
guestargs() { grep 'install-guest.sh' "$ILOG" | tail -n 1; }
irun
check "install.sh ohne Option: aus, nichts gespeichert"    "0 1 " "$IRC $(guestargs | grep -c -- '--effort-auto off') $(iget EFFORT_AUTO)"
irun --effort-auto effort-router
check "install.sh --effort-auto effort-router: an den Gast" 1 "$(guestargs | grep -c -- '--effort-auto effort-router')"
check "install.sh --effort-auto effort-router: gespeichert" effort-router "$(iget EFFORT_AUTO)"
check "install.sh --effort-auto: Gast hat das Plugin"      1 "$(plugins "$T/iguest" | grep -c 'effort-router@rootbridge-effort')"
irun
check "install.sh danach ohne Option: bleibt an"           1 "$(guestargs | grep -c -- '--effort-auto effort-router')"
irun --no-effort-auto
check "install.sh --no-effort-auto: aus und gespeichert"   "1 off" "$(guestargs | grep -c -- '--effort-auto off') $(iget EFFORT_AUTO)"
irun --effort-auto immer
check "install.sh --effort-auto immer: abgelehnt"          2 "$IRC"

# =========================================================================== 3. rootbridge status
mkdir -p "$T/bin" "$T/lib/termux-rootbridge" "$T/stubs" "$T/home/.config/termux-rootbridge"
sed "1s|^#!.*|#!$(command -v bash)|" "$ROOT/termux/bin/rootbridge" > "$T/bin/rootbridge"
cp "$ROOT/termux/lib/rootbridge-lib.sh" "$T/lib/termux-rootbridge/rootbridge-lib.sh"
for c in tmux pulseaudio pgrep pkill; do printf '#!/bin/bash\nexit 1\n' > "$T/stubs/$c"; done
chmod +x "$T/bin/rootbridge" "$T/stubs"/*
G="$T/prefix/var/lib/proot-distro/containers/ubuntu/rootfs"
mkdir -p "$G/etc"
: > "$T/home/.config/termux-rootbridge/config"
printf 'EFFORT_AUTO=effort-router\n' > "$G/etc/termux-rootbridge.conf"
env HOME="$T/home" PREFIX="$T/prefix" PATH="$T/stubs:$PATH" BRIDGE_DIR="$T/bridge" RB_STORAGE_DIR="$T/no-storage" \
    bash "$T/bin/rootbridge" status > "$T/out.txt" 2>&1
check "status: nennt effort-router"                        1 "$(grep -c 'Effort-Wahl: *effort-router' "$T/out.txt")"

finish
