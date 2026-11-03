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

for f in "$HOME/.bashrc" "$HOME/.tmux.conf"; do
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
rm -f "$HOME/.shortcuts/Claude Code" "$HOME/.shortcuts/Ubuntu Shell" "$HOME/.termux/boot/10-rootbridge.sh"
say "Programme, Widgets und Boot-Skript entfernt."
say "Bleibt erhalten: ~/.rootbridge (Audit-Log, Sicherungen), ~/.config/termux-root-bridge,"
say "~/.termux/colors.properties (die vorherige Version liegt als colors.properties.bak-*) und das Claude-Code-Theme."
