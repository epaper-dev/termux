#!/data/data/com.termux/files/usr/bin/bash
# Switch für die proot-distro Ubuntu-Umgebung (persistent via tmux).
# Anders als ein Toggle: killt NIE eine laufende Session, sondern
# springt nur hinein (oder erstellt sie, falls sie fehlt).
# Stellt bei jedem Aufruf über ensure_bridge() sicher, dass der Root-Bridge-
# Wächter läuft - auch wenn die Session schon vorher bestand.

source "$(dirname "$0")/bridge-lib.sh"

SESSION="$BRIDGE_SESSION"

if tmux has-session -t "$SESSION" 2>/dev/null; then
    echo "Ubuntu läuft bereits – wechsle hinein..."
else
    echo "Ubuntu wird gestartet..."
fi

ensure_bridge
tmux select-window -t "$SESSION:0" 2>/dev/null

if [ -n "$TMUX" ]; then
    tmux switch-client -t "$SESSION"
else
    tmux attach -t "$SESSION" 2>/dev/null || echo "Läuft im Hintergrund. Verbinden mit: tmux attach -t $SESSION"
fi
