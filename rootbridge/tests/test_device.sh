#!/usr/bin/env bash
# Test: install.sh finds the device file (devices/<manufacturer>-<model>.conf, from the vendor partition), asks once whether
# to use it, installs its valid lines as device.conf, keeps the questions about the keys (and leaves out a key the file does
# not describe), suggests the Remote Control name from it, and suggests no for reading aloud on a device that is too weak.
# Nothing real is touched: fake HOME/PREFIX, a getprop stub, made-up /proc and /sys, no guest, no setup (no root).
#   bash tests/test_device.sh
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib.sh
. "$ROOT/tests/lib.sh"
INSTALL="$ROOT/install.sh"
make_tmp

P="$T/prefix"; mkdir -p "$P/bin" "$T/stubs"
# getprop: the properties of $STUB_PROPS (name=value lines)
printf '#!/bin/sh\nsed -n "s/^$1=//p" "$STUB_PROPS"\n' > "$T/stubs/getprop"
printf '#!/bin/bash\nexit 0\n' > "$T/stubs/termux-reload-settings"
# PulseAudio: never the real one of the device
printf '#!/bin/bash\n[ "$1" = --check ] && exit 1\nexit 0\n' > "$T/stubs/pulseaudio"
printf '#!/bin/bash\nexit 1\n' > "$T/stubs/pactl"
printf '#!/bin/bash\ncase "$*" in *pulseaudio*) exit 1 ;; esac\nexec %s "$@"\n' "$(command -v pgrep || echo false)" > "$T/stubs/pgrep"
chmod +x "$T/stubs"/*

# the Hisense A9 with its GSI: the system says QUALCOMM, the vendor partition Hisense
a9_props() {
    printf '%s\n' ro.product.manufacturer=QUALCOMM ro.product.model=HLTE556N ro.product.brand=Crosscall \
        ro.product.vendor.manufacturer=Hisense ro.product.vendor.model=HLTE556N > "$T/props"
}
# a device: 8 cores, 6 GB with 2.3 GB available (enough for reading aloud), or a weak one
strong() {
    rm -rf "$T/sys" "$T/proc"; mkdir -p "$T/sys/devices/system/cpu" "$T/proc"
    echo 0-7 > "$T/sys/devices/system/cpu/online"
    printf 'MemTotal: 6291456 kB\nMemAvailable: 2435216 kB\n' > "$T/proc/meminfo"; : > "$T/proc/cpuinfo"
}
weak() { strong; echo 0 > "$T/sys/devices/system/cpu/online"; printf 'MemTotal: 1048576 kB\nMemAvailable: 204800 kB\n' > "$T/proc/meminfo"; }

# dinst <answers> [args]: install.sh with the answers on stdin, as on a terminal; asked: the device, reading aloud and the keys
dinst() {
    local answers="$1"; shift
    printf '%s' "$answers" | env HOME="$H" PREFIX="$P" PATH="$T/stubs:$PATH" ROOTBRIDGE_ALLOW_GUEST=1 BRIDGE_DIR="$H/.rootbridge" \
        ROOTBRIDGE_FORCE_INTERACTIVE=1 RB_BACKUP_DIR="$T/nobackup" STUB_PROPS="$T/props" \
        RB_SYS_DIR="$T/sys" RB_PROC_DIR="$T/proc" RB_PERF_SCORE=140 \
        bash "${INSTALLER:-$INSTALL}" --no-guest --no-setup --no-deps-check --no-migrate --no-boot --no-extra-keys --no-colors \
        --no-widgets --claude --no-codex --no-opencode --phantom-killer-on --language de --voice --remote-name x "$@" > "$T/install.log" 2>&1
    IRC=$?
}
cget() { sed -n "s/^$1=//p" "$H/.config/termux-rootbridge/config" | tail -n 1; }
count() { grep -c -- "$1" "$T/install.log"; }
DEV="$T/home/.config/termux-rootbridge/device.conf"

# --- the A9: found by the vendor partition, used (Enter), the keys asked as before
H="$T/home"; mkdir -p "$H"; a9_props; strong
dinst $'\n\nn\nn\nn\n'   # device: Enter, reading aloud: Enter, side key n, Home n, headset n
check "A9: Installer läuft"                          0 "$IRC"
check "A9: erkannt über die Vendor-Partition"        1 "$(count 'Hisense A9 erkannt (Hisense HLTE556N): Gerätedatei devices/hisense-hlte556n.conf verwenden')"
check "A9: Wahl gespeichert"                         hisense-hlte556n "$(cget DEVICE)"
check "A9: device.conf mit den Tasten des A9"        "SIDEKEY_CODE=766 HEADSET_DEVICE_NAME=Button Jack" \
      "$(grep '^SIDEKEY_CODE=' "$DEV") $(grep '^HEADSET_DEVICE_NAME=' "$DEV")"
check "A9: Seitentaste mit Gerätename gefragt"       1 "$(count 'Seitentaste des Hisense A9 als Push to Talk')"
check "A9: Home und Headset weiter gefragt"          "1 1" "$(count 'Langer Druck auf Home') $(count 'Kabel-Headsets')"
check "A9: Antworten gespeichert"                    "off off off" "$(cget SIDEKEY) $(cget HOMEKEY) $(cget HEADSET)"
check "A9: Leistung genannt"                         1 "$(count 'Leistung: 8 Kerne')"
check "A9: Vorlesen ohne Einwand"                    "0 on" "$(count 'Vorlesen auf diesem Gerät') $(cget SPEAK)"

before="$(cksum < "$DEV")"
dinst ''
check "Zweiter Lauf: keine Gerätefrage"              0 "$(count 'erkannt (')"
check "Zweiter Lauf: device.conf unverändert"        "$before" "$(cksum < "$DEV")"

dinst '' --device none
check "--device none: gespeichert"                   none "$(cget DEVICE)"
check "--device none: device.conf entfernt"          nein "$([ -e "$DEV" ] && echo ja || echo nein)"
check "--device none: Seitentaste wie früher"        0 "$(count 'Seitentaste des')"
dinst '' --device hisense-hlte556n
check "--device ID: wieder da"                       "hisense-hlte556n ja" "$(cget DEVICE) $([ -e "$DEV" ] && echo ja || echo nein)"

# --- n: no device file, the questions as before
H="$T/home-n"; mkdir -p "$H"
dinst $'n\n\nn\nn\nn\n'
check "Nein: DEVICE=none, keine device.conf"         "none nein" "$(cget DEVICE) $([ -e "$H/.config/termux-rootbridge/device.conf" ] && echo ja || echo nein)"
check "Nein: Seitentaste mit dem alten Text"         1 "$(count 'Seitentaste als Push to Talk (halten = sprechen; nur Hisense A9')"

# --- without a terminal: nothing chosen, a note
H="$T/home-pipe"; mkdir -p "$H"
env HOME="$H" PREFIX="$P" PATH="$T/stubs:$PATH" ROOTBRIDGE_ALLOW_GUEST=1 BRIDGE_DIR="$H/.rootbridge" STUB_PROPS="$T/props" \
    RB_BACKUP_DIR="$T/nobackup" RB_SYS_DIR="$T/sys" RB_PROC_DIR="$T/proc" RB_PERF_SCORE=140 \
    bash "$INSTALL" --no-guest --no-setup --no-deps-check --no-migrate --no-boot --no-extra-keys --no-colors --no-widgets \
    --claude --no-codex --phantom-killer-on --language de --no-voice --remote-name x > "$T/install.log" 2>&1 < /dev/null
check "Ohne Terminal: Hinweis, nichts gespeichert"   "1 " "$(count 'verwenden mit --device hisense-hlte556n') $(cget DEVICE)"

# --- a device without a file: the name of the file to make
H="$T/home-boox"; mkdir -p "$H"
printf '%s\n' ro.product.manufacturer=Onyx ro.product.model="MaxLumi 2" > "$T/props"
dinst $'\nn\nn\nn\n'
check "Unbekannt: Hinweis auf die Datei"             1 "$(count 'Gerät: Onyx MaxLumi 2 (keine Gerätedatei; eigene anlegen: devices/onyx-maxlumi-2.conf')"
check "Unbekannt: nichts gespeichert"                "" "$(cget DEVICE)"

# --- a device file that lacks keys, and a line that does not fit (a copy of the repository with a device file of its own)
cp -r "$ROOT" "$T/repo"
printf '%s\n' 'LABEL="Acme E1"' 'NAME=acme' 'HOMEKEY_METHOD=none' 'SIDEKEY_CODE=$(reboot)' > "$T/repo/devices/acme-e1.conf"
printf '%s\n' ro.product.vendor.manufacturer=ACME ro.product.vendor.model=E1 > "$T/props"
H="$T/home-acme"; mkdir -p "$H"
INSTALLER="$T/repo/install.sh" dinst $'\n\n'   # device: Enter, reading aloud: Enter; no key is asked
check "Ohne Tasten: Installer läuft"                 0 "$IRC"
check "Ohne Tasten: keine Tastenfrage"               "0 0 0" "$(count 'Push to Talk (') $(count 'Langer Druck auf Home') $(count 'Kabel-Headsets')"
check "Ohne Tasten: Hinweise statt Fragen"           "1 1 1" "$(count 'Seitentaste: Acme E1 hat laut Gerätedatei keine') $(count 'Home-Taste: bei Acme E1') $(count 'Headset-Taste: Acme E1 hat laut Gerätedatei keine')"
check "Ohne Tasten: ungültige Zeile übergangen"      "1 0" "$(count 'Zeile 4 übergangen') $(grep -c 'SIDEKEY_CODE' "$H/.config/termux-rootbridge/device.conf")"

# --- a weak device: reading aloud is suggested as no
H="$T/home-weak"; mkdir -p "$H"; a9_props; weak
dinst $'\n\nn\nn\nn\n'
check "Schwach: Grund genannt"                       1 "$(count 'Vorlesen auf diesem Gerät: nicht geeignet: 1 Kerne')"
check "Schwach: Enter heißt nein"                    "off 1" "$(cget SPEAK) $(count 'Antworten vorlesen lassen (Piper, auf Wunsch mit deiner eigenen Stimme)? \[j/N\]')"
strong

# --- the suggested Remote Control name (asked only on a real terminal)
ptyinst() {   # ptyinst <answers> [args]: install.sh on a pseudo-terminal, its output in $T/install.log
    python3 -I - "$INSTALL" "$H" "$P" "$T/stubs:$PATH" "$T/install.log" "$1" "${@:2}" <<'PYTEST'
import errno, os, pty, select, signal, sys, time
installer, home, prefix, path, log, answers, *options = sys.argv[1:]
pid, master = pty.fork()
if pid == 0:
    env = dict(os.environ, HOME=home, PREFIX=prefix, PATH=path, ROOTBRIDGE_ALLOW_GUEST="1", BRIDGE_DIR=home + "/.rootbridge")
    os.execvpe("bash", ["bash", installer, "--no-guest", "--no-setup", "--no-deps-check", "--no-migrate", "--no-boot",
               "--no-extra-keys", "--no-colors", "--no-widgets", "--claude", "--no-codex", "--no-opencode", "--phantom-killer-on",
               "--language", "de", "--no-voice", "--speak", *options], env)
os.write(master, answers.encode())
output, deadline = bytearray(), time.monotonic() + 60
while True:
    if time.monotonic() > deadline:
        os.kill(pid, signal.SIGKILL); os.waitpid(pid, 0)
        raise SystemExit("Installer did not finish in pseudo-terminal")
    if select.select([master], [], [], 0.2)[0]:
        try:
            data = os.read(master, 65536)
        except OSError as e:
            if e.errno == errno.EIO:
                break
            raise
        if not data:
            break
        output.extend(data)
_, status = os.waitpid(pid, 0)
with open(log, "wb") as fh:
    fh.write(output.replace(b"\r\n", b"\n"))
sys.exit(os.waitstatus_to_exitcode(status))
PYTEST
}
export STUB_PROPS="$T/props" RB_BACKUP_DIR="$T/nobackup" RB_SYS_DIR="$T/sys" RB_PROC_DIR="$T/proc" RB_PERF_SCORE=140
H="$T/home-name"; mkdir -p "$H"; a9_props
ptyinst $'\n\n'   # device: Enter, name: Enter
check "Name: NAME der Gerätedatei vorgeschlagen"     "1 hisense-a9" "$(count 'Gerätename \[hisense-a9\]') $(cget REMOTE_NAME)"
H="$T/home-name2"; mkdir -p "$H"
printf '%s\n' ro.product.manufacturer=Onyx ro.product.model=MaxLumi > "$T/props"
ptyinst $'\n'   # no device file: name: Enter
check "Name: ohne Gerätedatei die Kennung"           "1 onyx-maxlumi" "$(count 'Gerätename \[onyx-maxlumi\]') $(cget REMOTE_NAME)"

# --- an option for a device file that does not exist: nothing written
H="$T/home-bad"; mkdir -p "$H"
env HOME="$H" PREFIX="$P" PATH="$T/stubs:$PATH" ROOTBRIDGE_ALLOW_GUEST=1 bash "$INSTALL" --no-deps-check --device ../etc > /dev/null 2>&1
check "--device ungültig: Abbruch mit 2, nichts geschrieben" "2 nein" "$? $([ -e "$H/.config" ] && echo ja || echo nein)"

echo
finish
