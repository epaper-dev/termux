#!/usr/bin/env bash
# Test: Remote Control name (install.sh --remote-name / guest install-guest.sh --remote-name).
#   1. guest installer against a staging root (--root)
#   2. install.sh with a fake HOME/PREFIX; `proot-distro` is replaced by a stub that runs the
#      real guest installer against a staging root, so the whole path
#      Termux config -> install.sh -> guest config -> claude() can be checked,
#      including "guest is fresh, Termux config stays".
# Nothing real is touched: no real HOME, no real proot, no pkill/tmux (--no-migrate).
#   bash tests/test_remote_name.sh
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

# ------------------------------------------------------------ 1. guest installer
gconf() { printf '%s' "$1/etc/termux-root-bridge.conf"; }
gline() { grep '^CLAUDE_ARGS=' "$(gconf "$1")" 2>/dev/null || true; }
gcount() { grep -c '^CLAUDE_ARGS=' "$(gconf "$1")" 2>/dev/null || true; }
ginstall() {  # ginstall <stage> [args...]  (quiet)
    local stage="$1"; shift
    bash "$GUEST" --root "$stage" --autonomous no "$@" > "$T/guest.log" 2>&1
}
# pre <stage> <conf line>: stage a guest root that already has a config line
pre() { mkdir -p "$1/etc"; printf '%s\n' "WORKDIR=/srv/mine" "$2" > "$(gconf "$1")"; }

S="$T/g1"
ginstall "$S" --remote-name android
check "Gast neu: Installer läuft"                     0 "$?"
check "Gast neu: CLAUDE_ARGS mit Name und --continue" 'CLAUDE_ARGS="--remote-control android --continue"' "$(gline "$S")"
check "Gast neu: genau eine CLAUDE_ARGS-Zeile"        1 "$(gcount "$S")"

before="$(cksum < "$(gconf "$S")")"
baks() { find "$S/etc" -name 'termux-root-bridge.conf.bak-*' | wc -l | tr -d ' '; }
b0="$(baks)"
ginstall "$S" --remote-name android
check "Gast zweiter Lauf: Konfig unverändert"         "$before" "$(cksum < "$(gconf "$S")")"
check "Gast zweiter Lauf: keine neue Sicherung"       "$b0" "$(baks)"

ginstall "$S" --remote-name pixel
check "Gast Name wechseln"                            'CLAUDE_ARGS="--remote-control pixel --continue"' "$(gline "$S")"
check "Gast Name wechseln: weiter eine Zeile"         1 "$(gcount "$S")"

ginstall "$S"
check "Gast ohne Option: Zeile bleibt"                'CLAUDE_ARGS="--remote-control pixel --continue"' "$(gline "$S")"

S="$T/g2"; pre "$S" 'CLAUDE_ARGS="--remote-control old --verbose"'
ginstall "$S" --remote-name android
check "Andere Argumente bleiben, Name ersetzt"        'CLAUDE_ARGS="--remote-control android --verbose"' "$(gline "$S")"
check "Andere Schlüssel bleiben (WORKDIR)"            "WORKDIR=/srv/mine" "$(grep '^WORKDIR=' "$(gconf "$S")")"

S="$T/g3"; pre "$S" 'CLAUDE_ARGS=--continue'
ginstall "$S" --remote-name android
check "Zeile ohne Name und ohne Anführungszeichen"    'CLAUDE_ARGS="--remote-control android --continue"' "$(gline "$S")"

S="$T/g4"; pre "$S" 'CLAUDE_ARGS="--remote-control --continue"'
ginstall "$S" --remote-name android
check "--remote-control ohne Namen wird ersetzt"      'CLAUDE_ARGS="--remote-control android --continue"' "$(gline "$S")"

S="$T/g5"; pre "$S" 'CLAUDE_ARGS="--remote-control=old --continue"'
ginstall "$S" --remote-name android
check "--remote-control=name wird ersetzt"            'CLAUDE_ARGS="--remote-control android --continue"' "$(gline "$S")"

S="$T/g6"; pre "$S" 'CLAUDE_ARGS="--continue --model opus"'
ginstall "$S"
check "Ohne --remote-name bleibt die Zeile"           'CLAUDE_ARGS="--continue --model opus"' "$(gline "$S")"

for bad in "" "-x" "--evil" "a b" 'x;y' 'a$(id)' "$(printf 'a%.0s' $(seq 1 65))"; do
    S="$T/bad"; rm -rf "$S"
    bash "$GUEST" --root "$S" --autonomous no --remote-name "$bad" > /dev/null 2>&1
    code=$?
    check "ungültiger Name '${bad:0:12}': Abbruch mit 2"  2 "$code"
    check "ungültiger Name '${bad:0:12}': nichts installiert" nein "$([ -e "$S" ] && echo ja || echo nein)"
done
bash "$GUEST" --root "$T/bad" --remote-name > /dev/null 2>&1
check "--remote-name ohne Wert: Abbruch mit 2"        2 "$?"

# wrapper picks the name up (stubbed `command`/`claude`, the real Claude Code can not start)
S="$T/g1"; BLOCK="$(sed -n '/# >>> termux-root-bridge >>>/,/# <<< termux-root-bridge <<</p' "$S$ROOTBRIDGE_GUEST_HOME/.bashrc" 2>/dev/null)"; export BLOCK
if [ -z "$BLOCK" ]; then echo "ABBRUCH: kein claude()-Block im Staging-.bashrc" >&2; exit 1; fi
ginstall "$S" --remote-name android
got="$(ROOTBRIDGE_CONF="$(gconf "$S")" bash -c 'command() { printf "%s" "$*"; }; claude() { printf "BLOCK-FEHLT"; }; eval "$BLOCK"; claude' _)"
check "claude() nutzt den installierten Namen"        "claude --allow-dangerously-skip-permissions --remote-control android" "$got"

# --------------------------------------------------- 2. install.sh (fake Termux)
H="$T/home"; P="$T/prefix"; GROOT="$T/groot"; GUEST_ROOT="$T/guestroot"
CFG="$H/.config/termux-root-bridge/config"
mkdir -p "$H" "$P/bin" "$GROOT/var/tmp" "$T/stubs" "$P/var/lib/proot-distro/containers/ubuntu"
ln -s "$GROOT" "$P/var/lib/proot-distro/containers/ubuntu/rootfs"
cat > "$T/stubs/proot-distro" <<'EOF'
#!/bin/bash
# fake proot-distro: logs the call and runs the guest installer against a staging root
echo "$*" >> "$STUB_LOG"
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
# install.sh reloads the Termux settings after writing colors.properties: never the real one
printf '#!/bin/bash\nexit 0\n' > "$T/stubs/termux-reload-settings"
chmod +x "$T/stubs/proot-distro" "$T/stubs/termux-reload-settings"
export STUB_LOG="$T/proot.log" STUB_GROOT="$GROOT" STUB_GUEST_ROOT="$GUEST_ROOT"
: > "$STUB_LOG"
[ -x "$T/stubs/proot-distro" ] && [ -d "$P/bin" ] || { echo "ABBRUCH: Testumgebung unvollständig" >&2; exit 1; }

rinstall() {  # rinstall [args...]  (fake HOME/PREFIX, stub proot-distro, no migration, no deps check)
    HOME="$H" PREFIX="$P" PATH="$T/stubs:$PATH" ROOTBRIDGE_ALLOW_GUEST=1 BRIDGE_DIR="$H/.rootbridge" \
        bash "$INSTALL" --no-boot --no-migrate --no-deps-check --autonomous no "$@" > "$T/install.log" 2>&1
}
tcount() { grep -c '^REMOTE_NAME=' "$CFG" 2>/dev/null || true; }
gline2() { grep '^CLAUDE_ARGS=' "$GUEST_ROOT/etc/termux-root-bridge.conf" 2>/dev/null || true; }

rinstall --remote-name android
check "install.sh --remote-name: läuft durch"         0 "$?"
check "Name steht in der Termux-Konfig"               "REMOTE_NAME=android" "$(grep '^REMOTE_NAME=' "$CFG")"
check "Termux-Konfig: genau eine Zeile"               1 "$(tcount)"
check "Gast-Installer bekam --remote-name"            1 "$(grep -c -- '--remote-name android' "$STUB_LOG")"
check "Gast-Konfig: CLAUDE_ARGS gesetzt"              'CLAUDE_ARGS="--remote-control android --continue"' "$(gline2)"

cfg_before="$(cksum < "$CFG")"
rinstall
check "Zweiter Lauf ohne Option: läuft durch"         0 "$?"
check "Zweiter Lauf: Termux-Konfig unverändert"       "$cfg_before" "$(cksum < "$CFG")"
check "Zweiter Lauf: Name aus der Konfig übernommen"  2 "$(grep -c -- '--remote-name android' "$STUB_LOG")"

# the point of it all: guest is gone/fresh, Termux config stays -> name is back
rm -rf "$GUEST_ROOT"
rinstall
check "Frischer Gast: Name kommt aus der Termux-Konfig zurück" 'CLAUDE_ARGS="--remote-control android --continue"' "$(gline2)"

rinstall --remote-name pixel
check "Name ändern: Termux-Konfig"                    "REMOTE_NAME=pixel" "$(grep '^REMOTE_NAME=' "$CFG")"
check "Name ändern: weiter eine Zeile"                1 "$(tcount)"
check "Name ändern: Gast-Konfig"                      'CLAUDE_ARGS="--remote-control pixel --continue"' "$(gline2)"

# hand-edited config: invalid value is ignored, nothing passed on
sed -i 's|^REMOTE_NAME=.*|REMOTE_NAME="bad name"|' "$CFG"
: > "$STUB_LOG"
rinstall
check "Ungültiger Wert in der Konfig wird ignoriert"  0 "$(grep -c -- '--remote-name' "$STUB_LOG")"

# no config, no option: nothing is passed on and no REMOTE_NAME is invented
H2="$T/home2"; mkdir -p "$H2"
: > "$STUB_LOG"; rm -rf "$GUEST_ROOT"
HOME="$H2" PREFIX="$P" PATH="$T/stubs:$PATH" ROOTBRIDGE_ALLOW_GUEST=1 BRIDGE_DIR="$H2/.rootbridge" \
    bash "$INSTALL" --no-boot --no-migrate --no-deps-check --autonomous no > "$T/install.log" 2>&1
check "Ohne Name: Installer läuft"                    0 "$?"
check "Ohne Name: nichts an den Gast übergeben"       0 "$(grep -c -- '--remote-name' "$STUB_LOG")"
check "Ohne Name: keine REMOTE_NAME-Zeile"            0 "$(grep -c '^REMOTE_NAME=' "$H2/.config/termux-root-bridge/config")"
check "Ohne Name: keine CLAUDE_ARGS im Gast"          0 "$(grep -c '^CLAUDE_ARGS=' "$GUEST_ROOT/etc/termux-root-bridge.conf")"

# invalid option value: abort before anything is written
H3="$T/home3"; mkdir -p "$H3"
HOME="$H3" PREFIX="$P" PATH="$T/stubs:$PATH" ROOTBRIDGE_ALLOW_GUEST=1 bash "$INSTALL" --no-deps-check --remote-name '--evil' > /dev/null 2>&1
check "install.sh: ungültiger Name bricht mit 2 ab"   2 "$?"
check "install.sh: dabei nichts geschrieben"          nein "$([ -e "$H3/.config" ] && echo ja || echo nein)"

# --no-guest: name is stored, guest installer not called
H4="$T/home4"; mkdir -p "$H4"; : > "$STUB_LOG"
HOME="$H4" PREFIX="$P" PATH="$T/stubs:$PATH" ROOTBRIDGE_ALLOW_GUEST=1 BRIDGE_DIR="$H4/.rootbridge" \
    bash "$INSTALL" --no-boot --no-migrate --no-deps-check --no-guest --remote-name android > /dev/null 2>&1
check "--no-guest: Name gespeichert"                  "REMOTE_NAME=android" "$(grep '^REMOTE_NAME=' "$H4/.config/termux-root-bridge/config")"
check "--no-guest: Gast-Installer nicht aufgerufen"   0 "$(wc -l < "$STUB_LOG" | tr -d ' ')"

echo
echo "Ergebnis: $PASS bestanden, $FAIL fehlgeschlagen"
[ "$FAIL" -eq 0 ]
