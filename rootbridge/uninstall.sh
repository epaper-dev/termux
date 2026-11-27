#!/usr/bin/env bash
# uninstall.sh - remove termux-rootbridge v2 (run in a Termux shell).
# Keeps ~/.rootbridge (audit log, backups) and ~/.config/termux-rootbridge.
#   bash uninstall.sh [--no-guest]
set -eu

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
BEGIN='# >>> termux-rootbridge >>>'
END='# <<< termux-rootbridge <<<'
DO_GUEST=1
[ "${1:-}" = "--no-guest" ] && DO_GUEST=0

say() { printf '%s\n' "$*"; }

if command -v rootbridge >/dev/null 2>&1; then rootbridge stop 2>/dev/null || true; fi

if [ "$DO_GUEST" = 1 ] && command -v proot-distro >/dev/null 2>&1; then
    CFG="$HOME/.config/termux-rootbridge/config"
    DISTRO="$(sed -n 's/^DISTRO=//p' "$CFG" 2>/dev/null | tail -n 1)"; DISTRO="${DISTRO:-ubuntu}"
    for c in "$PREFIX/var/lib/proot-distro/containers/$DISTRO/rootfs" \
             "$PREFIX/var/lib/proot-distro/installed-rootfs/$DISTRO"; do
        if [ -d "$c" ]; then
            STAGE="$c/var/tmp/termux-rootbridge-install"
            rm -rf "$STAGE"; mkdir -p "$STAGE"; cp -r "$REPO/guest/." "$STAGE/"
            proot-distro login "$DISTRO" -- bash /var/tmp/termux-rootbridge-install/install-guest.sh \
                --src /var/tmp/termux-rootbridge-install --uninstall || true
            rm -rf "$STAGE"
            break
        fi
    done
fi

for f in "$HOME/.bashrc" "$HOME/.tmux.conf" "$HOME/.termux/termux.properties"; do
    [ -f "$f" ] || continue
    python3 -I "$REPO/guest/lib/rbfile.py" drop "$f" "$BEGIN" "$END"
    say "Block entfernt: $f"
done

# the key readers and our PulseAudio configuration (a default.pa of the user, without our marker, stays)
for reader in sidekey-ptt headset-ptt; do
    if [ -f "$PREFIX/bin/$reader" ] && grep -q "$reader" "$PREFIX/bin/$reader" 2>/dev/null; then
        pkill -f "$reader" 2>/dev/null || true
        rm -f "$PREFIX/bin/$reader"
    fi
done
# our PulseAudio (the listener for the guest, maybe with module loading shut for reading aloud only) ends first, while
# rootbridge is still there; a PulseAudio started later has none of it
if grep -qs 'termux-rootbridge voice' "$HOME/.config/pulse/default.pa" "$HOME/.config/pulse/daemon.conf"; then
    if [ -x "$PREFIX/bin/rootbridge" ] && ! "$PREFIX/bin/rootbridge" voice stop >/dev/null 2>&1; then
        say "Hinweis: PulseAudio läuft noch; beenden mit:  pulseaudio --kill"
    fi
fi
rm -f "$HOME/.cache/rootbridge-pulse-playback-only"
if grep -qs 'termux-rootbridge voice' "$HOME/.config/pulse/default.pa"; then
    rm -f "$HOME/.config/pulse/default.pa"
    say "PulseAudio-Konfiguration entfernt: ~/.config/pulse/default.pa"
fi
# daemon.conf: our pair goes (the marker and the allow-module-loading = no right after it); lines of your own stay, with a backup
dc="$HOME/.config/pulse/daemon.conf"
if grep -qs 'termux-rootbridge voice' "$dc"; then
    rc=0
    # our pair only: the marker and the setting right after it (a setting of your own stays)
    rest="$(awk '/^# termux-rootbridge voice/ { ours = 1; next } ours && $0 == "allow-module-loading = no" { ours = 0; next }
                 { ours = 0; print }' "$dc")" || rc=2
    if [ "$rc" -gt 1 ]; then   # it could not be read: the file stays as it is
        say "Hinweis: ~/.config/pulse/daemon.conf ließ sich nicht lesen und bleibt (darin: allow-module-loading = no)"
    elif grep -q '[^[:space:]]' <<< "$rest"; then
        # with a backup, and written atomically: a failure leaves the file as it was
        if cp -p "$dc" "$dc.bak-$(date +%Y%m%d%H%M%S)" && printf '%s\n' "$rest" > "$dc.new.$$" && mv -f "$dc.new.$$" "$dc"; then
            say "PulseAudio: die Sperre für nur Vorlesen aus ~/.config/pulse/daemon.conf entfernt, deine Zeilen bleiben"
        else
            rm -f "$dc.new.$$"
            say "Hinweis: ~/.config/pulse/daemon.conf ließ sich nicht ändern und bleibt (darin: allow-module-loading = no)"
        fi
    else
        rm -f "$dc"
        say "PulseAudio-Konfiguration entfernt: ~/.config/pulse/daemon.conf"
    fi
fi
# the long press on Home: Termux gives the assistant role back before ptt goes, or Home calls a missing command. Asked
# whenever the installer ever handled the key (HOMEKEY in the config, on or off: an earlier removal may have failed); on a
# terminal the real role decides (root). Without one the hint is the plain su command: rootbridge is gone afterwards.
if grep -qs '^HOMEKEY=' "$HOME/.config/termux-rootbridge/config"; then
    if [ -t 0 ] && [ -x "$PREFIX/bin/rootbridge" ] && role="$("$PREFIX/bin/rootbridge" voice assistant status 2>/dev/null)" \
            && [[ "$role" != *'Termux push to talk'* ]]; then
        :   # the role could be read, and Termux does not hold it
    elif ! { [ -t 0 ] && [ -x "$PREFIX/bin/rootbridge" ] && "$PREFIX/bin/rootbridge" voice assistant off; }; then
        say "Hinweis: Termux ist noch der digitale Assistent (langer Druck auf Home). Zurücknehmen (Root):"
        say "  su -c 'cmd role remove-role-holder --user 0 android.app.role.ASSISTANT com.termux'"
    fi
fi
# Android's phantom process killer: switched off by rootbridge phantom-killer off (from the installer or by hand), which
# leaves the marker phantom-killer-off before it changes anything and removes it once Android's defaults are back. A choice
# that was only stored (no terminal, --no-setup) changed nothing, so the marker alone counts. Android's defaults come back before rootbridge goes, also the sync of device_config, which is off for
# the whole phone. Without a terminal, or when root is refused, the commands to do it by hand.
# (next to the config, as rootbridge-lib.sh finds it: ROOTBRIDGE_CONFIG or the default)
if [ -e "$(dirname "${ROOTBRIDGE_CONFIG:-$HOME/.config/termux-rootbridge/config}")/phantom-killer-off" ]; then
    if ! { [ -t 0 ] && [ -x "$PREFIX/bin/rootbridge" ] && "$PREFIX/bin/rootbridge" phantom-killer on; }; then
        say "Hinweis: Der Phantom Process Killer ist noch aus, und Android lädt keine Systemeinstellungen nach. Zurück (Root):"
        say "  su -c 'settings delete global settings_enable_monitor_phantom_procs; device_config delete activity_manager max_phantom_processes; device_config set_sync_disabled_for_tests none'"
        say "  Prüfen: su -c 'device_config get_sync_disabled_for_tests'   (none = Android lädt Einstellungen wieder nach)"
    fi
fi
rm -f "$PREFIX/bin/rootbridge" "$PREFIX/bin/rootbridge-daemon" "$PREFIX/bin/ptt"
rm -rf "$PREFIX/lib/termux-rootbridge"
rm -f "$HOME/.termux/boot/10-rootbridge.sh"
# widgets, under every name this project has used: "Claude"/"Ubuntu" are generic, so only remove a script
# that really is ours (it calls rootbridge)
for n in "Claude" "Claude Neu" "Codex" "Ubuntu" "Debian" "Claude >_" "Ubuntu >_" "Claude Code" "Ubuntu Shell"; do
    if [ -f "$HOME/.shortcuts/$n" ] && grep -q 'rootbridge' "$HOME/.shortcuts/$n" 2>/dev/null; then
        rm -f "$HOME/.shortcuts/$n"
    fi
done
for n in "Vorlesen" "Stopp"; do
    if [ -f "$HOME/.shortcuts/tasks/$n" ] && grep -q 'rootbridge voice speak' "$HOME/.shortcuts/tasks/$n" 2>/dev/null; then
        rm -f "$HOME/.shortcuts/tasks/$n"
    fi
done
# icons: only the default ones this project installed (an icon you chose stays)
for name in "Claude" "Claude Neu" "Codex" "Claude >_" "Ubuntu" "Debian" "Ubuntu >_"; do
    icon="$HOME/.shortcuts/icons/$name.png"
    [ -f "$icon" ] || continue
    for default in "$REPO/termux/shortcuts/icons/widget.png" "$REPO"/termux/shortcuts/icons/legacy/*.png; do
        if cmp -s "$default" "$icon" 2>/dev/null; then rm -f "$icon"; break; fi
    done
done
say "Programme, Widgets und Boot-Skript entfernt."
say "Bleibt erhalten: ~/.rootbridge (Audit-Log, Sicherungen), ~/.config/termux-rootbridge,"
# shellcheck disable=SC2088  # the tilde is meant literally (message text)
say "Farbdateien in ~/.termux (der Installer schreibt keine mehr; Sicherungen früherer Versionen liegen als colors*.properties.bak-*) und das Claude-Code-Theme."
