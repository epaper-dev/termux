#!/usr/bin/env bash
# uninstall.sh - remove termux-root-bridge v2 (run in a Termux shell).
# Keeps ~/.rootbridge (audit log, backups) and ~/.config/termux-root-bridge.
#   bash uninstall.sh [--no-guest]
set -eu

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
BEGIN='# >>> termux-root-bridge >>>'
END='# <<< termux-root-bridge <<<'
DO_GUEST=1
[ "${1:-}" = "--no-guest" ] && DO_GUEST=0

say() { printf '%s\n' "$*"; }

if command -v rootbridge >/dev/null 2>&1; then rootbridge stop 2>/dev/null || true; fi

if [ "$DO_GUEST" = 1 ] && command -v proot-distro >/dev/null 2>&1; then
    CFG="$HOME/.config/termux-root-bridge/config"
    DISTRO="$(sed -n 's/^DISTRO=//p' "$CFG" 2>/dev/null | tail -n 1)"; DISTRO="${DISTRO:-ubuntu}"
    for c in "$PREFIX/var/lib/proot-distro/containers/$DISTRO/rootfs" \
             "$PREFIX/var/lib/proot-distro/installed-rootfs/$DISTRO"; do
        if [ -d "$c" ]; then
            STAGE="$c/var/tmp/termux-root-bridge-install"
            rm -rf "$STAGE"; mkdir -p "$STAGE"; cp -r "$REPO/guest/." "$STAGE/"
            proot-distro login "$DISTRO" -- bash /var/tmp/termux-root-bridge-install/install-guest.sh \
                --src /var/tmp/termux-root-bridge-install --uninstall || true
            rm -rf "$STAGE"
            break
        fi
    done
fi

for f in "$HOME/.bashrc" "$HOME/.tmux.conf" "$HOME/.termux/termux.properties"; do
    [ -f "$f" ] || continue
    python3 -I - "$f" "$BEGIN" "$END" <<'PYEOF'
import sys
path, begin, end = sys.argv[1:4]
res, skip = [], False
for line in open(path, encoding="utf-8").read().split("\n"):
    if line.strip() == begin:
        skip = True
        continue
    if skip:
        if line.strip() == end:
            skip = False
        continue
    res.append(line)
open(path, "w", encoding="utf-8").write("\n".join(res).rstrip("\n") + "\n")
PYEOF
    say "Block entfernt: $f"
done

rm -f "$PREFIX/bin/rootbridge" "$PREFIX/bin/rootbridge-daemon"
rm -rf "$PREFIX/lib/termux-root-bridge"
rm -f "$HOME/.termux/boot/10-rootbridge.sh"
# widgets, under every name this project has used: "Claude"/"Ubuntu" are generic, so only remove a script
# that really is ours (it calls rootbridge)
for n in "Claude" "Ubuntu" "Claude >_" "Ubuntu >_" "Claude Code" "Ubuntu Shell"; do
    if [ -f "$HOME/.shortcuts/$n" ] && grep -q 'rootbridge' "$HOME/.shortcuts/$n" 2>/dev/null; then
        rm -f "$HOME/.shortcuts/$n"
    fi
done
# icons: only the default ones this project installed (an icon you chose stays)
for name in "Claude" "Claude >_" "Ubuntu" "Ubuntu >_"; do
    icon="$HOME/.shortcuts/icons/$name.png"
    [ -f "$icon" ] || continue
    for default in "$REPO/termux/shortcuts/icons/widget.png" "$REPO"/termux/shortcuts/icons/legacy/*.png; do
        if cmp -s "$default" "$icon" 2>/dev/null; then rm -f "$icon"; break; fi
    done
done
say "Programme, Widgets und Boot-Skript entfernt."
say "Bleibt erhalten: ~/.rootbridge (Audit-Log, Sicherungen), ~/.config/termux-root-bridge,"
# shellcheck disable=SC2088  # the tilde is meant literally (message text)
say "~/.termux/colors-light.properties (Sicherungen früherer Farbdateien liegen als colors.properties.bak-*) und das Claude-Code-Theme."
