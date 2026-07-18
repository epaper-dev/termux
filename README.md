# termux-root-bridge

Ermöglicht einer persistenten Ubuntu-Umgebung (proot-distro, läuft in Termux auf
einem Hisense A9 / Android 14 GSI) echten Android-Root anzufragen — mit
manueller Bestätigung pro Befehl. Direkte `su`-Aufrufe *innerhalb* von
proot-distro scheitern, weil sich proots Syscall-Interception und Magisks
Daemon-Kommunikation gegenseitig blockieren ("zwei ptrace-artige Schichten
kollidieren"). Diese Bridge umgeht das, indem sie den Root-Aufruf in einen
zweiten, echten Termux-Kontext auslagert.

## Architektur

Zwei getrennte Kontexte:

- **Innerhalb proot (Ubuntu):** `androidsu <befehl>` schreibt eine Anfrage
  nach `~/.rootbridge/req-<id>.txt` und wartet bis zu 70 Sekunden auf eine
  Antwort (`res-<id>.txt`). Führt selbst nie etwas Privilegiertes aus.
- **Außerhalb proot (normales Termux):** `root-bridge-watch.sh` läuft als
  Hintergrund-Dauerschleife in einem eigenen tmux-Fenster (`bridge`),
  entdeckt neue Requests und öffnet pro Anfrage ein `tmux display-popup`
  mit `root-bridge-confirm.sh <id>`. Das Popup zeigt den Befehl und verlangt
  `y` + Enter innerhalb von 10 Sekunden. Nur bei explizitem `y` wird
  `su -c "<befehl>"` ausgeführt; alles andere (Enter, Timeout, andere
  Eingabe) ist eine Ablehnung.

```
proot Ubuntu                      Termux (außerhalb proot)
─────────────                     ─────────────────────────
androidsu "id"                    root-bridge-watch.sh (Dauerschleife)
   │  schreibt req-<id>.txt   ───▶   │  entdeckt req-*.txt
   │                                  │  öffnet Popup:
   │                                  ▼
   │                           root-bridge-confirm.sh <id>
   │                                  │  zeigt Befehl, read -t 10 auf 'y'
   │                                  │  bei 'y': su -c "id"
   │                                  │  schreibt res-<id>.txt (atomar)
   │  liest res-<id>.txt      ◀───────┘  loggt Entscheidung in audit.log
   ▼
Ausgabe + Exitcode
```

## Dateien

| Datei | Kontext | Zweck |
|---|---|---|
| `bin/androidsu` | proot | Client: Request schreiben, auf Antwort warten |
| `bin/root-bridge-watch.sh` | Termux | Wächter-Dauerschleife, öffnet Popups |
| `bin/root-bridge-confirm.sh` | Termux | Popup-Inhalt: Bestätigung + `su -c` + Audit-Log |
| `bin/bridge-lib.sh` | Termux | gemeinsame Helper (Konfig, Locking, `ensure_bridge`, Audit) |
| `bin/ubuntu-switch.sh` | Termux | in die Ubuntu-Session wechseln/erstellen, Wächter sicherstellen |
| `bin/ubuntu-toggle.sh` | Termux | Ubuntu-Session starten/stoppen (Alias `ubuntu`) |
| `.termux/boot/10-ubuntu-bridge.sh` | Termux | optionaler Autostart beim Geräteboot |
| `~/.rootbridge/audit.log` | Termux | Protokoll aller Root-Anfragen und Entscheidungen |

## Installation

1. Alle Dateien aus `bin/` nach `~/bin/` (Termux-Home, **nicht** proot) legen,
   ausführbar machen: `chmod 700 ~/bin/*.sh ~/bin/androidsu`.
2. `androidsu` zusätzlich innerhalb der proot-Ubuntu-Umgebung im PATH
   verfügbar machen (z. B. gleiche Datei dort ablegen oder Bind-Mount —
   je nach proot-distro-Konfiguration).
3. In `~/.bashrc` (Termux) existiert bereits: `alias ubuntu=~/bin/ubuntu-toggle.sh`.

## Nutzung

Aus der proot-Ubuntu-Umgebung heraus:

```sh
androidsu id
androidsu "pm list packages | grep magisk"
```

Ein Popup erscheint im Termux/tmux-Fenster. Mit `y` + Enter bestätigen (10s
Zeitfenster) — danach liefert `androidsu` Ausgabe und Exitcode des über `su`
ausgeführten Befehls zurück. Alles außer `y` (auch reines Enter oder
Timeout) lehnt ab.

Ubuntu-Session wechseln/starten: `ubuntu` (Toggle) oder `~/bin/ubuntu-switch.sh`
(wechselt hinein, killt nie eine laufende Session). Beide stellen bei jedem
Aufruf sicher, dass der Wächter läuft (`ensure_bridge` in `bridge-lib.sh`) —
auch wenn die Session schon vorher bestand.

## Autostart

- **Ohne Geräteboot-Integration:** reicht bereits, weil `ubuntu-switch.sh`
  und `ubuntu-toggle.sh` den Wächter bei jedem Aufruf selbst heilen, falls er
  fehlt (z. B. nach Absturz oder manuellem Kill des `bridge`-Fensters).
- **Mit Geräteboot-Autostart:** erfordert die App **Termux:Boot** (separat aus
  F-Droid/Play installieren — das kann dieses Setup nicht automatisieren).
  Ist sie installiert, führt Termux beim Geräteboot automatisch alle Skripte
  in `~/.termux/boot/` aus, darunter `10-ubuntu-bridge.sh`, welches Session
  und Wächter startet.

## Sicherheitsmodell

- Jede Root-Anfrage verlangt eine **explizite, manuelle** Bestätigung (`y` +
  Enter) innerhalb von 10 Sekunden. Kein Eingreifen = Ablehnung.
- Anfragen, die älter als das Client-Timeout (70s) sind, werden ohne Popup
  automatisch abgelehnt (`STALE`) — der anfragende Client hat ohnehin
  längst aufgegeben.
- Jede Entscheidung wird in `~/.rootbridge/audit.log` protokolliert:
  Zeitstempel, Entscheidung (`ALLOW`/`DENY`/`STALE`/`NO-SU`/`EMPTY`),
  Exitcode, Befehl.
- **Grenze:** Wer innerhalb der proot-Umgebung (oder sonstwo mit
  Schreibzugriff auf `~/.rootbridge/`) eine `req-*.txt` anlegen kann, kann
  eine Root-Anfrage stellen. Die Bridge schützt nicht vor einem bereits
  kompromittierten proot-Kontext — sie stellt sicher, dass *keine* Anfrage
  ohne manuelle Zustimmung ausgeführt wird. Wer physischen/interaktiven
  Zugriff auf das Gerät hat, um `y` zu bestätigen, autorisiert den Befehl.
- Nur eine Wächter-Instanz läuft gleichzeitig (Lock in
  `~/.rootbridge/.lock`) — verhindert doppelte Popups pro Anfrage.

## Troubleshooting

- **`androidsu` hängt ~70s und bricht dann mit „keine Antwort vom
  Root-Bridge-Wächter (Timeout, läuft er?)“ ab:** Der Wächter läuft nicht.
  `~/bin/ubuntu-switch.sh` (oder `ubuntu`) erneut aufrufen — startet ihn via
  `ensure_bridge` neu, ohne die laufende Session zu killen.
- **Popup erscheint nicht:** prüfen, ob die tmux-Session `ubuntu` existiert
  (`tmux has-session -t ubuntu`) und ob ein `root-bridge-watch.sh`-Prozess
  läuft (`pgrep -f root-bridge-watch.sh`).
- **`su nicht gefunden` in der Antwort:** Magisk/Root auf dem Gerät prüfen;
  die Bridge selbst benötigt kein Root, nur der Zielbefehl.
- **Audit-Log einsehen:** `tail -f ~/.rootbridge/audit.log`.
