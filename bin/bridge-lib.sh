#!/data/data/com.termux/files/usr/bin/bash
# bridge-lib.sh — gemeinsame Helper für die Root-Bridge.
# Wird von ubuntu-switch.sh, ubuntu-toggle.sh, dem optionalen Boot-Script sowie
# root-bridge-watch.sh und root-bridge-confirm.sh gesourced (nicht direkt ausführen).

BRIDGE_DIR="${BRIDGE_DIR:-$HOME/.rootbridge}"
BRIDGE_SESSION="${BRIDGE_SESSION:-ubuntu}"
BRIDGE_WINDOW="${BRIDGE_WINDOW:-bridge}"
BRIDGE_DISTRO="${BRIDGE_DISTRO:-ubuntu}"

# Muss zum Poll-Timeout in androidsu passen (70 * 1s). Requests, die älter sind,
# hat der Client (androidsu) bereits selbst aufgegeben und weggeworfen.
BRIDGE_STALE_TIMEOUT="${BRIDGE_STALE_TIMEOUT:-70}"
# Wie lange das Bestätigungs-Popup auf 'y' wartet (unverändert ggü. Ursprungsversion).
BRIDGE_ANSWER_TIMEOUT="${BRIDGE_ANSWER_TIMEOUT:-10}"

mkdir -p "$BRIDGE_DIR"

# Schreibt eine Zeile ins Audit-Log: Zeitstempel, Entscheidung, Exitcode, Befehl.
log_audit() {
    local decision="$1" code="$2" cmd="$3"
    printf '%s\t%s\t%s\t%s\n' "$(date -Is)" "$decision" "$code" "$cmd" >> "$BRIDGE_DIR/audit.log"
}

# True, wenn irgendwo ein root-bridge-watch.sh-Prozess läuft.
bridge_watcher_alive() {
    pgrep -f 'root-bridge-watch\.sh' >/dev/null 2>&1
}

# Stellt sicher, dass die tmux-Session + der Root-Bridge-Wächter laufen.
# Idempotent: mehrfacher Aufruf (z. B. bei jedem ubuntu-switch) ist sicher.
ensure_bridge() {
    if ! tmux has-session -t "$BRIDGE_SESSION" 2>/dev/null; then
        tmux new-session -d -s "$BRIDGE_SESSION" "proot-distro login $BRIDGE_DISTRO"
    fi

    if bridge_watcher_alive; then
        return 0
    fi

    # Wächter tot, aber evtl. noch ein leeres/totes Fenster übrig - sauber ersetzen.
    if tmux list-windows -t "$BRIDGE_SESSION" -F '#{window_name}' 2>/dev/null | grep -qx "$BRIDGE_WINDOW"; then
        tmux kill-window -t "$BRIDGE_SESSION:$BRIDGE_WINDOW" 2>/dev/null
    fi
    tmux new-window -t "$BRIDGE_SESSION" -n "$BRIDGE_WINDOW" "$HOME/bin/root-bridge-watch.sh"
}
