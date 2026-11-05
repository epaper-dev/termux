#!/usr/bin/env bash
# Test: the automatic setup of install.sh (fresh device) and guest/setup-guest.sh.
#   A. install.sh end to end: the missing Termux packages (pkg), the guest (proot-distro install),
#      setup-guest.sh and install-guest.sh in this order; a second run changes nothing; with --no-setup (or
#      --no-deps-check for the packages) nothing is installed and the old hints stay; --setup is still
#      accepted; failures stop early with a message.
#   B. setup-guest.sh: python3 / curl / certificates through apt-get, Claude Code through the official
#      installer, nothing when it is all there, failures of apt-get / curl / the installer.
#   C. the guest ~/.bashrc block puts ~/.local/bin on the PATH (where the Claude Code installer puts claude).
# Nothing real is touched: fake HOME/PREFIX, and pkg, proot-distro, apt-get, curl, tmux are stubs. Commands
# that must count as "missing" are left out of a PATH made of symlinks (the shim), so the result does not
# depend on what the machine has installed.
#   bash tests/test_setup.sh
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL="$ROOT/install.sh"
SETUP_GUEST="$ROOT/guest/setup-guest.sh"
GUEST="$ROOT/guest/install-guest.sh"

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
ORIG_PATH="$PATH"

PASS=0; FAIL=0
check() {   # check <name> <expected> <actual>
    if [ "$2" = "$3" ]; then PASS=$((PASS + 1)); printf 'ok    %s\n' "$1"
    else FAIL=$((FAIL + 1)); printf 'FAIL  %s\n      erwartet: %s\n      erhalten: %s\n' "$1" "$2" "$3"; fi
}
count() { grep -c -- "$2" "$1" 2>/dev/null || true; }          # count <file> <fixed text>
lineno() { grep -n -m1 -- "$2" "$1" 2>/dev/null | cut -d: -f1; }   # first line number of a text

real() { PATH="$ORIG_PATH" command -v "$1" 2>/dev/null || true; }
REAL_PYTHON="$(real python3)"; REAL_SETSID="$(real setsid)"
[ -n "$REAL_PYTHON" ] || { echo "ABBRUCH: python3 fehlt für den Test" >&2; exit 1; }

# ----------------------------------------------------------------------------------- stubs
AV="$T/avail"; mkdir -p "$AV"
# Everything the "install" of a stub package makes appear; pkg / apt-get copy from here into the env's stubs.
printf '#!/bin/bash\nexit 0\n' > "$AV/tmux"
printf '#!/bin/bash\nexit 0\n' > "$AV/termux-open-url"
cat > "$AV/proot-distro" <<'EOF'
#!/bin/bash
# fake proot-distro: logs the call. `install X` makes the guest root, `login X -- bash <script>` only
# notes whether the script is staged inside the guest (setup-guest.sh / install-guest.sh).
echo "proot-distro $*" >> "$STUB_LOG"
case "$1" in
    install)
        [ -z "${STUB_PROOT_INSTALL_FAIL:-}" ] || exit 1
        mkdir -p "$STUB_PREFIX/var/lib/proot-distro/containers/$2/rootfs/var/tmp" ;;
    login)
        script="$STUB_PREFIX/var/lib/proot-distro/containers/$2/rootfs$5"
        if [ -f "$script" ]; then echo "staged ${5##*/}" >> "$STUB_LOG"; else echo "NOT-staged ${5##*/}" >> "$STUB_LOG"; fi
        case "$5" in *setup-guest.sh) [ -z "${STUB_SETUP_FAIL:-}" ] || exit 1 ;; esac ;;
esac
exit 0
EOF
cat > "$AV/pkg" <<'EOF'
#!/bin/bash
# fake pkg: logs the call and lets the commands of the named packages appear in the stubs dir
echo "pkg $* [DEBIAN_FRONTEND=${DEBIAN_FRONTEND:-}]" >> "$STUB_LOG"
[ -z "${STUB_PKG_FAIL:-}" ] || exit 1
for a in "$@"; do
    case "$a" in
        tmux|proot-distro) cp "$STUB_AV/$a" "$STUB_BIN/$a" ;;
        termux-api) cp "$STUB_AV/termux-open-url" "$STUB_BIN/termux-open-url" ;;
        python) ln -sf "$STUB_REAL_PYTHON" "$STUB_BIN/python3" ;;
        coreutils) for c in stat timeout sha256sum; do
                       r="$(PATH="$STUB_ORIG_PATH" command -v "$c")"; [ -n "$r" ] && ln -sf "$r" "$STUB_BIN/$c"
                   done ;;
        util-linux) if [ -n "$STUB_REAL_SETSID" ]; then ln -sf "$STUB_REAL_SETSID" "$STUB_BIN/setsid"
                    else printf '#!/bin/bash\nexec "$@"\n' > "$STUB_BIN/setsid"; fi ;;
    esac
done
chmod +x "$STUB_BIN"/* 2>/dev/null
exit 0
EOF
cat > "$AV/apt-get" <<'EOF'
#!/bin/bash
# fake apt-get: logs the call; `install` lets python3 / curl / the certificate bundle appear
echo "apt-get $* [DEBIAN_FRONTEND=${DEBIAN_FRONTEND:-}]" >> "$STUB_LOG"
case "${1:-}" in
    update)  [ "${STUB_APT_FAIL:-}" != update ] || exit 100 ;;
    install)
        [ "${STUB_APT_FAIL:-}" != install ] || exit 100
        for a in "$@"; do
            case "$a" in
                python3) ln -sf "$STUB_REAL_PYTHON" "$STUB_BIN/python3" ;;
                curl) cp "$STUB_AV/curl" "$STUB_BIN/curl" ;;
                ca-certificates) mkdir -p "$(dirname "$ROOTBRIDGE_CA_BUNDLE")"; echo cert > "$ROOTBRIDGE_CA_BUNDLE" ;;
            esac
        done ;;
esac
chmod +x "$STUB_BIN"/* 2>/dev/null
exit 0
EOF
cat > "$AV/curl" <<'EOF'
#!/bin/bash
# fake curl: writes a fake Claude Code installer to the -o target
echo "curl $*" >> "$STUB_LOG"
[ -z "${STUB_CURL_FAIL:-}" ] || exit 22
out=""
while [ $# -gt 0 ]; do [ "$1" = -o ] && out="$2"; shift; done
if [ -n "${STUB_INSTALLER_FAIL:-}" ]; then
    printf '#!/bin/bash\necho "installer: boom" >&2\nexit 1\n' > "$out"
elif [ -n "${STUB_INSTALLER_NOBINARY:-}" ]; then
    printf '#!/bin/bash\necho "installer: ran" >> "$STUB_LOG"\nexit 0\n' > "$out"
else
    printf '#!/bin/bash\necho "installer: ran with HOME=$HOME" >> "$STUB_LOG"\nmkdir -p "$HOME/.local/bin"\nprintf "#!/bin/bash\\nexit 0\\n" > "$HOME/.local/bin/claude"\nchmod +x "$HOME/.local/bin/claude"\n' > "$out"
fi
exit 0
EOF
chmod +x "$AV"/*

# The shim: symlinks to everything on the machine's PATH except tmux, proot-distro, termux-open-url, python3,
# setsid, curl, claude, apt-get, pkg (those are "missing" until a stub package brings them). Built once,
# with few forks: one `ln -s -t` per batch of files.
SHIM="$T/shim"; mkdir -p "$SHIM"
{
    IFS=:
    for d in $ORIG_PATH; do
        [ -d "$d" ] || continue
        find "$d" -maxdepth 1 \( -type f -o -type l \) -perm -u+x -print0 2>/dev/null
    done
} | tr '\0' '\n' | awk -F/ '
    { n = $NF }
    n ~ /^(tmux|proot-distro|termux-open-url|python3|setsid|curl|claude|apt-get|pkg)$/ { next }
    !(n in seen) { seen[n] = 1; print }' | tr '\n' '\0' | xargs -0 ln -s -t "$SHIM" 2>/dev/null
[ -e "$SHIM/bash" ] && [ -e "$SHIM/sed" ] || { echo "ABBRUCH: Shim-PATH unvollständig" >&2; exit 1; }

# newenv <name> [command ...]: a fresh fake device. Commands named as arguments are available right away.
# HIDE="stat timeout" in the environment of the call takes those commands out of this device's PATH.
newenv() {
    E="$T/$1"; shift
    rm -rf "$E"; mkdir -p "$E/bin" "$E/home" "$E/prefix/bin"
    SHIMDIR="$SHIM"
    if [ -n "${HIDE:-}" ]; then
        SHIMDIR="$E/shim"; cp -a "$SHIM" "$SHIMDIR"
        for h in $HIDE; do rm -f "$SHIMDIR/$h"; done
    fi
    cp "$AV/pkg" "$AV/apt-get" "$E/bin/"
    local c
    for c in "$@"; do
        case "$c" in
            python3) ln -sf "$REAL_PYTHON" "$E/bin/python3" ;;
            setsid) if [ -n "$REAL_SETSID" ]; then ln -sf "$REAL_SETSID" "$E/bin/setsid"; else printf '#!/bin/bash\nexec "$@"\n' > "$E/bin/setsid"; fi ;;
            *) cp "$AV/$c" "$E/bin/$c" ;;
        esac
    done
    chmod +x "$E/bin"/*
    LOG="$E/stub.log"; : > "$LOG"
}
# envrun <args...>: runs the command with the environment of the current fake device
envrun() {
    env -i HOME="$E/home" PREFIX="$E/prefix" PATH="$E/bin:$SHIMDIR" STUB_LOG="$LOG" STUB_PREFIX="$E/prefix" \
        STUB_AV="$AV" STUB_BIN="$E/bin" STUB_REAL_PYTHON="$REAL_PYTHON" STUB_REAL_SETSID="$REAL_SETSID" STUB_ORIG_PATH="$ORIG_PATH" \
        BRIDGE_DIR="$E/home/.rootbridge" ROOTBRIDGE_ALLOW_GUEST=1 \
        ROOTBRIDGE_CA_BUNDLE="$E/ca/ca-certificates.crt" ROOTBRIDGE_GUEST_HOME="${ROOTBRIDGE_GUEST_HOME:-$E/ghome}" \
        "$@"
}
rinstall() { envrun bash "$INSTALL" --no-migrate --no-colors --no-extra-keys --autonomous no "$@" > "$E/out.log" 2>&1; }

ALL_DEPS="tmux proot-distro python3 setsid termux-open-url"

# =========================================================== A. install.sh, fresh device
newenv a1
rinstall
check "A1 frisch: ohne Option läuft die Einrichtung durch"                          0 "$?"
check "A1 genau ein pkg install"                                1 "$(count "$LOG" '^pkg install')"
pk="$(grep '^pkg install' "$LOG")"
check "A1 pkg: -y und nicht interaktiv"                         1 "$(printf '%s' "$pk" | grep -c -- 'pkg install -y .*DEBIAN_FRONTEND=noninteractive')"
for p in tmux proot-distro python termux-api util-linux; do
    check "A1 pkg installiert $p (genau einmal)"                1 "$(printf '%s\n' "$pk" | tr ' ' '\n' | grep -c -x -- "$p")"
done
check "A1 Gast wird angelegt"                                   1 "$(count "$LOG" '^proot-distro install ubuntu$')"
check "A1 setup-guest.sh ist im Gast bereitgestellt"            1 "$(count "$LOG" '^staged setup-guest.sh$')"
check "A1 install-guest.sh ist im Gast bereitgestellt"          1 "$(count "$LOG" '^staged install-guest.sh$')"
a="$(lineno "$LOG" '^pkg install')"; b="$(lineno "$LOG" '^proot-distro install ubuntu$')"
c="$(lineno "$LOG" 'setup-guest.sh$')"; d="$(lineno "$LOG" 'install-guest.sh$')"
check "A1 Reihenfolge: pkg < Gast anlegen < setup-guest < install-guest" ja \
      "$([ "$a" -lt "$b" ] && [ "$b" -lt "$c" ] && [ "$c" -lt "$d" ] && echo ja || echo "nein ($a $b $c $d)")"
check "A1 Hinweis auf die Handarbeit am Ende"                   1 "$(count "$E/out.log" 'Noch von Hand')"
check "A1 Bridge ist eingerichtet (Widget Claude)"              ja "$([ -f "$E/home/.shortcuts/Claude" ] && echo ja || echo nein)"
check "A1 Staging im Gast ist wieder aufgeräumt"                nein "$([ -e "$E/prefix/var/lib/proot-distro/containers/ubuntu/rootfs/var/tmp/termux-root-bridge-install" ] && echo ja || echo nein)"

: > "$LOG"
rinstall
check "A2 zweiter Lauf: läuft durch"                            0 "$?"
check "A2 zweiter Lauf: kein pkg"                               0 "$(count "$LOG" '^pkg ')"
check "A2 zweiter Lauf: Gast wird nicht neu angelegt"           0 "$(count "$LOG" '^proot-distro install')"
check "A2 zweiter Lauf: setup-guest.sh läuft (macht selbst nichts, wenn alles da ist)" 1 "$(count "$LOG" '^staged setup-guest.sh$')"
check "A2 zweiter Lauf: keine Paket-Einrichtung gemeldet"       0 "$(count "$E/out.log" '== 0/5 Einrichtung')"

# the guest holds everything (python3, curl, certificates, claude): setup-guest.sh is not even started
G="$E/prefix/var/lib/proot-distro/containers/ubuntu/rootfs"
mkdir -p "$G/usr/bin" "$G/etc/ssl/certs" "$G/root/.local/bin"
printf '#!/bin/bash\n' > "$G/usr/bin/python3"; printf '#!/bin/bash\n' > "$G/usr/bin/curl"; echo cert > "$G/etc/ssl/certs/ca-certificates.crt"
printf '#!/bin/bash\n' > "$G/root/.local/bin/claude"; chmod +x "$G/root/.local/bin/claude"
: > "$LOG"
ROOTBRIDGE_GUEST_HOME=/root rinstall
check "A2b Gast vollständig: läuft durch"                       0 "$?"
check "A2b Gast vollständig: setup-guest.sh wird nicht gerufen" 0 "$(count "$LOG" 'setup-guest.sh')"
check "A2b Gast vollständig: install-guest.sh läuft"            1 "$(count "$LOG" '^staged install-guest.sh$')"
check "A2b nichts eingerichtet: kein 'Noch von Hand'"           0 "$(count "$E/out.log" 'Noch von Hand')"
rm -f "$G/root/.local/bin/claude"
: > "$LOG"
rinstall
check "A2c claude fehlt im Gast: setup-guest.sh läuft"          1 "$(count "$LOG" '^staged setup-guest.sh$')"
check "A2c claude fehlt im Gast: Hinweis 'Noch von Hand'"       1 "$(count "$E/out.log" 'Noch von Hand')"

# the old option is still accepted and changes nothing
newenv a11
rinstall --setup
check "A11 --setup (Altlast) wird angenommen"                   0 "$?"
check "A11 --setup: dieselbe Einrichtung wie ohne Option"       1 "$(count "$LOG" '^pkg install')"

# a package that is half there: only the missing one is installed
newenv a3 tmux proot-distro python3 setsid
rinstall --no-guest
check "A3 nur termux-api fehlt: läuft durch"                    0 "$?"
check "A3 nur termux-api wird installiert"                      "pkg install -y -o Dpkg::Options::=--force-confold termux-api [DEBIAN_FRONTEND=noninteractive]" "$(grep '^pkg ' "$LOG")"

# stat, timeout and sha256sum all come from coreutils: named once
HIDE="stat timeout sha256sum" newenv a10 tmux proot-distro python3 setsid termux-open-url
rinstall --no-guest
check "A10 coreutils fehlt: läuft durch"                        0 "$?"
check "A10 coreutils wird genau einmal genannt"                 "pkg install -y -o Dpkg::Options::=--force-confold coreutils [DEBIAN_FRONTEND=noninteractive]" "$(grep '^pkg ' "$LOG")"

# --no-guest: packages yes, guest no
newenv a4
rinstall --no-guest
check "A4 --no-guest: läuft durch"                              0 "$?"
check "A4 --no-guest: pkg läuft"                                1 "$(count "$LOG" '^pkg install')"
check "A4 --no-guest: proot-distro wird nie gerufen"            0 "$(count "$LOG" '^proot-distro')"

# --no-setup: nothing is installed, the hints stay
newenv a5
rinstall --no-setup
check "A5 --no-setup: Abbruch bei fehlenden Paketen"            1 "$?"
check "A5 --no-setup: nennt die fehlenden Pakete"               1 "$(count "$E/out.log" 'Fehlende Pakete:')"
check "A5 --no-setup: pkg wird nie gerufen"                     0 "$(count "$LOG" '^pkg ')"

newenv a6 $ALL_DEPS
rinstall --no-setup
check "A6 --no-setup, ohne Gast: Abbruch"                       1 "$?"
check "A6 --no-setup, ohne Gast: nennt --no-setup / --no-guest" 1 "$(count "$E/out.log" 'Ohne --no-setup legt install.sh ihn an')"
check "A6 --no-setup, ohne Gast: kein proot-distro install"     0 "$(count "$LOG" '^proot-distro install')"
check "A6 --no-setup: kein 'Noch von Hand' am Ende"             0 "$(count "$E/out.log" 'Noch von Hand')"

# --no-deps-check also skips the package part; without pkg (not Termux) the old hint stays
newenv a12
rinstall --no-deps-check --no-guest
check "A12 --no-deps-check: pkg wird nie gerufen"               0 "$(count "$LOG" '^pkg ')"
newenv a13
rm -f "$E/bin/pkg"
rinstall
check "A13 ohne pkg: Abbruch mit dem alten Hinweis"             1 "$?"
check "A13 ohne pkg: nennt die fehlenden Pakete"                1 "$(count "$E/out.log" 'Fehlende Pakete:')"

# failures stop early
newenv a7
envrun env STUB_PKG_FAIL=1 bash "$INSTALL" --no-migrate --no-colors --no-extra-keys > "$E/out.log" 2>&1
check "A7 pkg schlägt fehl: Abbruch"                            1 "$?"
check "A7 pkg schlägt fehl: Meldung"                            1 "$(count "$E/out.log" 'ist fehlgeschlagen (Netz? pkg update?)')"
check "A7 pkg schlägt fehl: kein proot-distro"                  0 "$(count "$LOG" '^proot-distro')"

newenv a8 $ALL_DEPS
envrun env STUB_PROOT_INSTALL_FAIL=1 bash "$INSTALL" --no-migrate --no-colors --no-extra-keys > "$E/out.log" 2>&1
check "A8 proot-distro install schlägt fehl: Abbruch"           1 "$?"
check "A8 proot-distro install schlägt fehl: Meldung"           1 "$(count "$E/out.log" 'proot-distro install ubuntu ist fehlgeschlagen')"
check "A8 proot-distro install schlägt fehl: kein Gast-Skript"  0 "$(count "$LOG" 'staged')"

newenv a9 $ALL_DEPS
envrun env STUB_SETUP_FAIL=1 bash "$INSTALL" --no-migrate --no-colors --no-extra-keys > "$E/out.log" 2>&1
check "A9 setup-guest schlägt fehl: Abbruch"                    1 "$?"
check "A9 setup-guest schlägt fehl: install-guest läuft nicht"  0 "$(count "$LOG" 'install-guest.sh')"

# =========================================================== B. setup-guest.sh
gsetup() { envrun bash "$SETUP_GUEST" > "$E/out.log" 2>&1; }

newenv b1
gsetup
check "B1 frisch: läuft durch"                                  0 "$?"
check "B1 apt-get update vor install"                           ja "$([ "$(lineno "$LOG" '^apt-get update')" -lt "$(lineno "$LOG" '^apt-get install')" ] && echo ja || echo nein)"
check "B1 apt-get install: genau die fehlenden Pakete"          "apt-get install -y --no-install-recommends python3 curl ca-certificates [DEBIAN_FRONTEND=noninteractive]" "$(grep '^apt-get install' "$LOG")"
check "B1 apt-get update: nicht interaktiv"                     "apt-get update [DEBIAN_FRONTEND=noninteractive]" "$(grep '^apt-get update' "$LOG")"
check "B1 curl lädt den offiziellen Installer"                  "curl -fsSL https://claude.ai/install.sh -o $(sed -n 's/^curl .* -o //p' "$LOG")" "$(grep '^curl' "$LOG")"
check "B1 Installer lief mit dem Gast-HOME"                     "installer: ran with HOME=$E/ghome" "$(grep '^installer:' "$LOG")"
check "B1 claude liegt in ~/.local/bin und ist ausführbar"      ja "$([ -x "$E/ghome/.local/bin/claude" ] && echo ja || echo nein)"
dl="$(sed -n 's/^curl .* -o //p' "$LOG")"
check "B1 Installer-Datei wird aufgeräumt"                      nein "$([ -n "$dl" ] && [ ! -e "$dl" ] && echo nein || echo ja)"

: > "$LOG"
gsetup
check "B2 zweiter Lauf: läuft durch"                            0 "$?"
check "B2 zweiter Lauf: kein apt-get"                           0 "$(count "$LOG" '^apt-get')"
check "B2 zweiter Lauf: kein curl"                              0 "$(count "$LOG" '^curl')"
check "B2 zweiter Lauf: meldet 'schon installiert'"             1 "$(count "$E/out.log" 'claude ist schon installiert')"

newenv b3 python3
mkdir -p "$E/ca"; echo cert > "$E/ca/ca-certificates.crt"
gsetup
check "B3 nur curl fehlt: läuft durch"                          0 "$?"
check "B3 nur curl fehlt: apt-get installiert nur curl"         "apt-get install -y --no-install-recommends curl [DEBIAN_FRONTEND=noninteractive]" "$(grep '^apt-get install' "$LOG")"

newenv b4 python3 curl
mkdir -p "$E/ca"; echo cert > "$E/ca/ca-certificates.crt"
envrun env CLAUDE_INSTALL_URL=https://example.invalid/i.sh bash "$SETUP_GUEST" > "$E/out.log" 2>&1
check "B4 alles da, nur claude fehlt: läuft durch"              0 "$?"
check "B4 kein apt-get"                                         0 "$(count "$LOG" '^apt-get')"
check "B4 CLAUDE_INSTALL_URL wird benutzt"                      1 "$(count "$LOG" 'curl -fsSL https://example.invalid/i.sh')"

newenv b5 python3 curl
mkdir -p "$E/ca"; echo cert > "$E/ca/ca-certificates.crt"
envrun env STUB_CURL_FAIL=1 bash "$SETUP_GUEST" > "$E/out.log" 2>&1
check "B5 curl schlägt fehl: Abbruch"                           1 "$?"
check "B5 curl schlägt fehl: Meldung mit Hinweis"               1 "$(count "$E/out.log" 'Download von https://claude.ai/install.sh ist fehlgeschlagen')"
check "B5 curl schlägt fehl: kein claude"                       nein "$([ -e "$E/ghome/.local/bin/claude" ] && echo ja || echo nein)"

newenv b6 python3 curl
mkdir -p "$E/ca"; echo cert > "$E/ca/ca-certificates.crt"
envrun env STUB_INSTALLER_FAIL=1 bash "$SETUP_GUEST" > "$E/out.log" 2>&1
check "B6 Installer schlägt fehl: Abbruch"                      1 "$?"
check "B6 Installer schlägt fehl: Meldung"                      1 "$(count "$E/out.log" 'Claude-Code-Installer ist fehlgeschlagen')"

newenv b7 python3 curl
mkdir -p "$E/ca"; echo cert > "$E/ca/ca-certificates.crt"
envrun env STUB_INSTALLER_NOBINARY=1 bash "$SETUP_GUEST" > "$E/out.log" 2>&1
check "B7 Installer ohne claude danach: Abbruch"                1 "$?"
check "B7 Installer ohne claude danach: Meldung"                1 "$(count "$E/out.log" 'es gibt kein claude')"

newenv b8
envrun env STUB_APT_FAIL=update bash "$SETUP_GUEST" > "$E/out.log" 2>&1
check "B8 apt-get update schlägt fehl: Abbruch"                 1 "$?"
check "B8 apt-get update schlägt fehl: kein install, kein curl" 0 "$(count "$LOG" '^apt-get install\|^curl')"

newenv b9
envrun env STUB_APT_FAIL=install bash "$SETUP_GUEST" > "$E/out.log" 2>&1
check "B9 apt-get install schlägt fehl: Abbruch"                1 "$?"
check "B9 apt-get install schlägt fehl: kein curl"              0 "$(count "$LOG" '^curl')"

newenv b10 python3 curl
mkdir -p "$E/ca"; echo cert > "$E/ca/ca-certificates.crt"
printf '#!/bin/bash\nexit 0\n' > "$E/bin/claude"; chmod +x "$E/bin/claude"
gsetup
check "B10 claude liegt im PATH: nichts wird geladen"           0 "$(count "$LOG" '^curl')"

# =========================================================== C. PATH in the guest ~/.bashrc
GS="$T/c1"; mkdir -p "$GS"
ROOTBRIDGE_GUEST_HOME=/home/tester bash "$GUEST" --root "$GS" --autonomous no > "$T/guest.log" 2>&1
check "C1 Gast-Installer läuft"                                 0 "$?"
RC="$GS/home/tester/.bashrc"
check "C1 .bashrc: PATH-Zeile genau einmal"                     1 "$(count "$RC" 'export PATH="$HOME/.local/bin:$PATH"')"
p1="$(env -i HOME=/hh PATH=/usr/bin:/bin bash -c ". '$RC'; printf '%s' \"\$PATH\"")"
check "C1 .bashrc: ~/.local/bin steht vorn im PATH"             "/hh/.local/bin:/usr/bin:/bin" "$p1"
p2="$(env -i HOME=/hh PATH=/usr/bin:/bin bash -c ". '$RC'; . '$RC'; printf '%s' \"\$PATH\"")"
check "C1 .bashrc: zweimal laden verdoppelt nichts"             "/hh/.local/bin:/usr/bin:/bin" "$p2"
ROOTBRIDGE_GUEST_HOME=/home/tester bash "$GUEST" --root "$GS" --autonomous no > "$T/guest.log" 2>&1
check "C1 zweiter Lauf: weiter genau eine PATH-Zeile"           1 "$(count "$RC" 'export PATH="$HOME/.local/bin:$PATH"')"

echo
echo "Ergebnis: $PASS bestanden, $FAIL fehlgeschlagen"
[ "$FAIL" -eq 0 ]
