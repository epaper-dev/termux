#!/data/data/com.termux/files/usr/bin/bash
# Termux:Boot-Autostart — startet beim Geräteboot die persistente
# Ubuntu-tmux-Session headless und stellt sicher, dass der Root-Bridge-
# Wächter läuft. Wird nur ausgeführt, wenn die Termux:Boot-App installiert
# ist (Scripte in ~/.termux/boot/ werden sonst schlicht nie aufgerufen).

source "$HOME/bin/bridge-lib.sh"

if ! tmux has-session -t "$BRIDGE_SESSION" 2>/dev/null; then
    tmux new-session -d -s "$BRIDGE_SESSION" "proot-distro login $BRIDGE_DISTRO"
fi
ensure_bridge
