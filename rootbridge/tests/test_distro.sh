#!/usr/bin/env bash
# Test: install.sh offers Ubuntu or Debian as the guest (asked once when there is none, --distro), stores DISTRO once the
# guest is there, names the widget and the alias after it, and switches an installed guest: the old one stays, a backup of
# it is restored into the new one, the work folder comes along into an empty one.
# Nothing real is touched: fake HOME/PREFIX; proot-distro is a stub, and so is every call of rootbridge (backup, restore,
# stop, voice: through the bash of the fake PREFIX, the interpreter of the installed rootbridge).
#   bash tests/test_distro.sh
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib.sh
. "$ROOT/tests/lib.sh"
INSTALL="$ROOT/install.sh"
make_tmp

P="$T/prefix"; LOG="$T/calls.log"
mkdir -p "$P/bin" "$T/stubs" "$T/storage"
cat > "$T/stubs/proot-distro" <<'EOF'
#!/bin/bash
echo "proot-distro $*" >> "$STUB_LOG"
case "$1" in
    install) mkdir -p "$PREFIX/var/lib/proot-distro/containers/$2/rootfs/root" ;;
    login) case "$*" in *setup-guest.sh*) [ -z "${STUB_SETUP_FAIL:-}" ] || exit 1 ;; esac ;;
esac
exit 0
EOF
cat > "$P/bin/bash" <<EOF
#!$(command -v bash)
# the installed rootbridge runs here: its commands are logged, the rest is the real bash
case "\${2:-}" in
    backup) echo "rootbridge \$2 \${3:-}" >> "\$STUB_LOG"; [ -z "\${STUB_BACKUP_FAIL:-}" ] ;;
    restore) echo "rootbridge \$2 \${3:-} guest=\${RB_GUEST_ROOT:-}" >> "\$STUB_LOG"
        # like a restore of the other guest's config
        [ -z "\${STUB_RESTORE_WORKDIR:-}" ] || echo "WORKDIR=\$STUB_RESTORE_WORKDIR" >> "\$RB_GUEST_ROOT/etc/termux-rootbridge.conf"
        [ -z "\${STUB_RESTORE_FAIL:-}" ] ;;
    stop|daemon-start|daemon-stop|voice|phantom-killer) echo "rootbridge \$2 \${3:-}" >> "\$STUB_LOG"; exit 0 ;;
    *) exec $(command -v bash) "\$@" ;;
esac
EOF
printf '#!/bin/bash\nexit 0\n' > "$T/stubs/termux-reload-settings"
chmod +x "$T/stubs"/* "$P/bin/bash"
ROOTFS="$P/var/lib/proot-distro/containers"

# dinst <answers> [args]: install.sh with real setup (the guest is installed), answers on stdin as on a terminal
dinst() {
    local answers="$1"; shift
    : > "$LOG"
    printf '%s' "$answers" | env HOME="$H" PREFIX="$P" PATH="$T/stubs:$PATH" ROOTBRIDGE_ALLOW_GUEST=1 BRIDGE_DIR="$H/.rootbridge" \
        ROOTBRIDGE_FORCE_INTERACTIVE="${TTY-1}" STUB_LOG="$LOG" RB_BACKUP_DIR="$T/backup" RB_STORAGE_CHECK="$T/storage" \
        bash "$INSTALL" --no-deps-check --no-migrate --no-boot --no-extra-keys --no-colors --autonomous no \
        --claude --no-codex --phantom-killer-on --language de --no-voice --no-speak --remote-name x "$@" > "$T/install.log" 2>&1
    IRC=$?
}
cget() { sed -n "s/^$1=//p" "$H/.config/termux-rootbridge/config" | tail -n 1; }
calls() { grep -c -- "$1" "$LOG"; }
line_of() { grep -n -- "$1" "$LOG" | head -n 1 | cut -d: -f1; }
has() { [ -e "$1" ] && echo ja || echo nein; }

# --- a fresh device: the question, d is Debian
H="$T/home-d"; mkdir -p "$H"
dinst $'d\n'
check "Neu, d: Installer läuft"                     0 "$IRC"
check "Neu, d: gefragt"                             1 "$(grep -c 'Gastsystem: Ubuntu oder Debian' "$T/install.log")"
check "Neu, d: Debian installiert und gespeichert"  "1 debian" "$(calls '^proot-distro install debian$') $(cget DISTRO)"
check "Neu, d: Widget Debian, kein Ubuntu"          "ja nein" "$(has "$H/.shortcuts/Debian") $(has "$H/.shortcuts/Ubuntu")"
check "Neu, d: Alias debian"                        1 "$(grep -c "^alias debian='rootbridge shell'$" "$H/.bashrc")"
dinst ''
check "Zweiter Lauf: keine Frage, keine Installation" "0 0" "$(grep -c 'Gastsystem:' "$T/install.log") $(calls 'proot-distro install')"
rm -rf "$ROOTFS"

# --- Debian installed, its setup failed: the next run without an option goes on with Debian
H="$T/home-retry"; mkdir -p "$H"
STUB_SETUP_FAIL=1 dinst $'d\n'
check "Einrichtung scheitert: nichts gespeichert"   "1 " "$IRC $(cget DISTRO)"
dinst ''
check "Neuer Versuch: weiter mit Debian"            "0 0 debian" "$IRC $(calls 'proot-distro install') $(cget DISTRO)"
rm -rf "$ROOTFS"

# --- a fresh device, Enter: Ubuntu
H="$T/home-u"; mkdir -p "$H"
dinst $'\n'
check "Neu, Enter: Ubuntu"                          "1 ubuntu ja" "$(calls '^proot-distro install ubuntu$') $(cget DISTRO) $(has "$H/.shortcuts/Ubuntu")"

# --- the switch: Ubuntu -> Debian, with backup, restore and the work folder (the old guest's own WORKDIR)
mkdir -p "$ROOTFS/ubuntu/rootfs/root/src/proj" "$ROOTFS/ubuntu/rootfs/etc"
echo hallo > "$ROOTFS/ubuntu/rootfs/root/src/proj/a.txt"
echo 'WORKDIR=/root/src' > "$ROOTFS/ubuntu/rootfs/etc/termux-rootbridge.conf"
echo mine > "$H/.shortcuts/icons/Ubuntu.png"
# a setup of the new guest that fails: DISTRO stays, the next run switches again
STUB_SETUP_FAIL=1 dinst $'n\nn\n' --distro debian
check "Einrichtung scheitert: Gast und Widget bleiben Ubuntu" "1 ubuntu ja nein" \
      "$IRC $(cget DISTRO) $(has "$H/.shortcuts/Ubuntu") $(has "$H/.shortcuts/Debian")"
dinst $'\n\n' --distro debian   # backup: Enter (yes), work folder: Enter (yes)
check "Wechsel: Installer läuft"                    0 "$IRC"
check "Wechsel: Sitzungen beendet, Sicherung des alten Gasts" "1 1" "$(calls '^rootbridge stop') $(calls "^rootbridge backup $T/backup-ubuntu$")"
check "Wechsel: Debian schon da, keine zweite Installation; zurück in den neuen Gast" "0 1" \
      "$(calls 'proot-distro install') $(calls "^rootbridge restore $T/backup-ubuntu guest=$ROOTFS/debian/rootfs$")"
check "Wechsel: Sicherung vor der Wiederherstellung" ja \
      "$(b="$(line_of 'rootbridge backup')"; r="$(line_of 'rootbridge restore')"
         [ -n "$b" ] && [ -n "$r" ] && [ "$b" -lt "$r" ] && echo ja || echo nein)"
check "Wechsel: DISTRO=debian"                      debian "$(cget DISTRO)"
check "Wechsel: Arbeitsordner kopiert"              hallo "$(cat "$ROOTFS/debian/rootfs/root/work/proj/a.txt" 2>/dev/null)"
check "Wechsel: alter Gast bleibt"                  ja "$(has "$ROOTFS/ubuntu/rootfs/root/src/proj/a.txt")"
check "Wechsel: Widget Debian mit dem Icon, Ubuntu weg" "ja nein mine" \
      "$(has "$H/.shortcuts/Debian") $(has "$H/.shortcuts/Ubuntu") $(cat "$H/.shortcuts/icons/Debian.png" 2>/dev/null)"
check "Wechsel: Hinweis zum alten Gast"             1 "$(grep -c 'proot-distro remove ubuntu' "$T/install.log")"

# --- back to Ubuntu, nothing along: no installation, nothing copied over the work folder
echo anders > "$ROOTFS/debian/rootfs/root/work/proj/a.txt"
dinst $'n\nn\n' --distro ubuntu
check "Zurück: keine Installation, keine Sicherung" "0 0 0" "$(calls 'proot-distro install') $(calls 'rootbridge backup') $(calls 'rootbridge restore')"
check "Zurück: DISTRO=ubuntu, Widget Ubuntu"        "ubuntu ja nein" "$(cget DISTRO) $(has "$H/.shortcuts/Ubuntu") $(has "$H/.shortcuts/Debian")"
check "Zurück: Arbeitsordner unberührt"             hallo "$(cat "$ROOTFS/ubuntu/rootfs/root/src/proj/a.txt")"

# --- into a guest whose work folder is not empty: nothing is overwritten
dinst $'n\n\n' --distro debian
check "Voller Arbeitsordner: nicht überschrieben"   "anders 1" "$(cat "$ROOTFS/debian/rootfs/root/work/proj/a.txt") $(grep -c 'ist nicht leer, nicht kopiert' "$T/install.log")"

# --- back into a guest with its own work folder: the restore of the other guest's config does not move it
mkdir -p "$ROOTFS/ubuntu/rootfs/etc"; echo 'WORKDIR=/root/src' > "$ROOTFS/ubuntu/rootfs/etc/termux-rootbridge.conf"
STUB_RESTORE_WORKDIR=/root/work dinst $'\n\n' --distro ubuntu
check "Zurück mit Sicherung: WORKDIR des Ziels bleibt" "0 WORKDIR=/root/src" \
      "$IRC $(grep '^WORKDIR=' "$ROOTFS/ubuntu/rootfs/etc/termux-rootbridge.conf" | tail -n 1)"
check "Zurück mit Sicherung: Arbeitsordner nicht überschrieben" "hallo 1" \
      "$(cat "$ROOTFS/ubuntu/rootfs/root/src/proj/a.txt") $(grep -c 'ist nicht leer, nicht kopiert' "$T/install.log")"
dinst $'n\nn\n' --distro debian

# --- a failed backup: nothing is switched
STUB_BACKUP_FAIL=1 dinst $'\nn\n' --distro ubuntu
check "Sicherung scheitert: Abbruch, Gast und Widget bleiben Debian" "1 debian 0 ja nein" \
      "$IRC $(cget DISTRO) $(calls 'rootbridge restore') $(has "$H/.shortcuts/Debian") $(has "$H/.shortcuts/Ubuntu")"

# --- a failed restore (a wrong password): nothing is switched
STUB_RESTORE_FAIL=1 dinst $'\nn\n' --distro ubuntu
check "Wiederherstellung scheitert: Abbruch, Gast bleibt Debian" "1 debian 1" \
      "$IRC $(cget DISTRO) $(grep -c 'der Gast bleibt debian' "$T/install.log")"

# --- without a terminal: the switch takes nothing along
TTY="" dinst '' --distro ubuntu
check "Ohne Terminal: Wechsel ohne Sicherung"       "0 ubuntu 0" "$IRC $(cget DISTRO) $(calls 'rootbridge backup')"
check "Ohne Terminal: Hinweis"                      1 "$(grep -c 'ohne Terminal: nichts mitgenommen' "$T/install.log")"

# --- --no-guest: the option changes nothing
dinst '' --no-guest --distro debian
check "--no-guest: Gast bleibt"                     "ubuntu 1" "$(cget DISTRO) $(grep -c 'gilt nur mit dem Gast' "$T/install.log")"

# --- a link on the way to the work folder of the old guest: nothing is copied (it could lead into Termux)
H="$T/home-link"; mkdir -p "$H"; rm -rf "$ROOTFS"
mkdir -p "$ROOTFS/ubuntu/rootfs/root"; echo geheim > "$H/private.txt"
ln -s "$H" "$ROOTFS/ubuntu/rootfs/root/work"
dinst $'n\n' --distro ubuntu
dinst $'n\n\n' --distro debian
check "Link: nichts kopiert"                        "nein 1" \
      "$(has "$ROOTFS/debian/rootfs/root/work/private.txt") $(grep -c 'liegt ein Link, nicht kopiert' "$T/install.log")"

# --- an invalid value
env HOME="$T/home-bad" PREFIX="$P" bash "$INSTALL" --distro arch > /dev/null 2>&1
check "--distro arch: Abbruch mit 2"                2 "$?"

echo
finish
