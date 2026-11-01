#!/data/data/com.termux/files/usr/bin/bash
# Start/Stop-Toggle für die proot-distro Ubuntu-Umgebung (persistent via tmux)

source "$(dirname "$0")/bridge-lib.sh"

SESSION="$BRIDGE_SESSION"

if tmux has-session -t "$SESSION" 2>/dev/null; then
    echo "Ubuntu läuft – wird gestoppt..."
    tmux kill-session -t "$SESSION"
    echo "Ubuntu gestoppt."
else
    echo "Ubuntu wird gestartet..."
    ensure_bridge
    tmux select-window -t "$SESSION:0" 2>/dev/null
    # Direkt anhängen, wenn wir ein echtes Terminal haben (normaler Termux-Aufruf).
    # Vom Widget aus (kein tty) schlägt das harmlos fehl - Session läuft trotzdem weiter im Hintergrund.
    tmux attach -t "$SESSION" 2>/dev/null || echo "Läuft im Hintergrund. Verbinden mit: tmux attach -t $SESSION"
fi
