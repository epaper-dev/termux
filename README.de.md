# termux-root-bridge

**Claude Code auf Android (Termux + proot-distro) – jede echte Root-Aktion wird direkt in Claude Code bestätigt, und Logins funktionieren ohne Kopierärger.**

[English](README.md) · [Vergleich mit anderen Projekten](docs/COMPARISON.md) · [Login & MCP](docs/LOGIN.md) · [Sicherheit](SECURITY.md)

> **Stand: v2.0.0-dev.** Unit- und Integrationstests laufen (Guard-Hook, Login-Hook, Daemon, Installer).
> Noch nicht auf einem Gerät bestätigt: Zwischenablage (OSC 52 durch tmux nach Android), Browser-Öffnen aus dem
> Gast und das genaue `tool_response`-Format der MCP-Login-Tools. Siehe [Was geprüft ist](#was-geprüft-ist).

## Welches Problem löst es?

Wer Claude Code in einem Ubuntu-Gast (proot-distro) in Termux betreibt, stößt auf drei Dinge:

1. **Echter Android-Root ist unerreichbar.** `su` in proot kollidiert mit Magisk. Ein kleiner Daemon *außerhalb*
   von proot führt `su -c` für den Gast aus, aber nur für bestätigte Befehle.
2. **Claude soll autonom arbeiten, aber nie ungefragt am System ändern.** Ein Hook macht aus jedem root-fähigen
   Befehl (`androidsu`, `adb`, `fastboot`, `su`, `magisk` ...) eine normale Rückfrage *in Claude Code* – auch im
   Bypass-Modus.
3. **Logins sind am Handy mühsam.** Der OAuth-/MCP-Link ist hunderte Zeichen lang, bricht über viele Zeilen um und
   bekommt beim Kopieren Leerzeichen. Der Link wird jetzt im Android-Browser geöffnet oder mit einer Taste sauber kopiert.

Es gibt kein zweites Terminal-Fenster und kein Popup mehr (v1 brauchte beides).

## Funktionsweise

```
Claude Code (Ubuntu-Gast, root)                   Termux (außerhalb proot)
───────────────────────────────                   ────────────────────────
Bash: androidsu 'id'
 └─ PreToolUse-Hook (android-root-guard.py)
     • wörtlicher Befehl? → Einmal-Ticket, gebunden an sha256("id")
     • fragt: „⚠ ANDROID-ROOT: id“   ← Ja / Nein direkt in Claude Code
androidsu ── Anfrage + Ticket ─────────────────▶  rootbridge-daemon (ohne Fenster)
                                                  gültiges Ticket? → su -c 'id'
                         ◀──────── Ergebnis ───   kein Ticket?     → abgelehnt (Exit 99)
```

* **Kein Ticket, kein Root.** Wird die Rückfrage abgelehnt, läuft der Befehl nie. Es gibt keinen Popup-Fallback.
* **Autonom alles andere.** Was nicht root-relevant ist (auch `/sdcard`), läuft ohne Rückfrage.
* **Login-Links.** `/login`, `/mcp` und `claude mcp login <server>` öffnen den Browser über `BROWSER`/`xdg-open`.
  Ergebnisse von `mcp__*__authenticate` werden abgefangen: Der lange Link wird geöffnet und kopiert statt ausgegeben.

## Voraussetzungen

* Android mit Termux (F-Droid/GitHub-Build), `proot-distro` mit Ubuntu-Gast, Claude Code im Gast installiert
* funktionierendes `su` (Magisk, KernelSU ...) – ohne `su` gehen nur die Login-Funktionen
* Termux-Pakete: `tmux proot-distro python coreutils util-linux`, optional `termux-api` (+ Termux:API-App) für die Zwischenablage
* Gast: `python3`, coreutils mit `sha256sum`, `od`, `timeout`
* Claude Code ≥ 2.1.295

## Installation

In einer **Termux**-Shell (nicht in proot):

```bash
pkg install git tmux proot-distro python coreutils util-linux termux-api
git clone https://github.com/hisense-a9/termux-root-bridge
cd termux-root-bridge
bash install.sh            # stellt eine Frage zum autonomen Modus
```

Danach Claude Code über das Widget **Claude** starten oder in einer Termux-Shell `ubuntu` eingeben (Alias für
`rootbridge attach`). Der erste Start legt die Sitzung an: Daemon starten, Pakete des Gasts aktualisieren
(`apt-get update` + `upgrade`, höchstens einmal am Tag, siehe unten), `claude update` ausführen (ebenfalls höchstens einmal am
Tag) und Claude Code starten; spätere Starts hängen sich nur an. **Normale Termux-Fenster bleiben reine Shells** (mit geladenen Farben),
nichts startet von selbst. Mit Termux:Boot wird die Sitzung nach einem Neustart im Hintergrund angelegt
(`rootbridge start --no-attach`). Claude **startet weiter im Plan-Modus** (aus deiner `settings.json`); mit
**Umschalt+Tab** wechselst du in *bypass permissions*.

Optionen: `--no-guest`, `--no-boot`, `--no-migrate`, `--no-colors`, `--no-widgets`, `--autonomous yes|no|ask`, `--remote-name NAME`,
`--apt-upgrade daily|always|off`, `--no-apt-upgrade`, `--claude-update daily|always|off`, `--no-claude-update`. Der Installer ist idempotent, sichert Geändertes und migriert die
alte v1-Popup-Bridge.

**Widgets.** Mit der App Termux:Widget gibt es zwei Verknüpfungen: **Claude** (an die Claude-Code-Sitzung anhängen)
und **Ubuntu** (normale Ubuntu-Shell). Der Installer legt sie zusammen mit neutralen `>_`-Icons in `~/.shortcuts`
ab (`~/.shortcuts/icons/<Name>.png`, keine Logos; neu erzeugen mit `tools/make-shortcut-icons.py`). Ein schon
vorhandenes Icon wird nie ersetzt, du kannst also ein eigenes PNG dorthin legen; bei früheren Namen („Claude Code“ / „Ubuntu Shell“, „Claude >_“ / „Ubuntu >_“) wandert ein vorhandenes Icon auf den neuen Namen, und die alten Skripte werden entfernt. Sicherungen von
Widget- und Boot-Skripten landen in `~/.rootbridge/backups` (Termux:Widget listet jede Datei in `~/.shortcuts`,
Termux:Boot führt jede Datei in `~/.termux/boot` aus). `--no-widgets` überspringt das Ganze.

**Ende der Sitzung.** `/exit` (oder Strg+C) in Claude Code beendet alles: Das tmux-Fenster und die tmux-Sitzung schließen sich,
`rootbridge attach` kehrt zurück, und das über das Widget **Claude** geöffnete Termux-Fenster schließt sich mit. Du landest nicht in der
Ubuntu-Shell. Nur wenn Claude Code mit einem Fehlercode endet, bleibt die Gast-Shell mit einem Hinweis offen, damit die Meldung lesbar bleibt (ebenso, wenn `claude` nicht installiert ist).

**Paket-Updates im Gast.** Standardmäßig an: Beim Start der Claude-Code-Sitzung führt `rootbridge-apt`
`apt-get update` und `apt-get -y upgrade` aus, höchstens einmal in 24 h nach einem Erfolg (`APT_UPGRADE=daily`), und
blockiert den Start nie (kein Netz, ein Fehler oder ein Timeout geben nur einen Hinweis aus, Claude Code startet, der
nächste Start versucht es erneut). Zwei Schutzmaßnahmen sind unter proot-distro mit Ubuntu 26.04 wichtig: dpkg bekommt
`-o DPkg::Path` mit `/usr/local/bin`, weil die uutils-coreutils dort die GNU-benannten Symlinks brauchen (sonst brechen
Maintainer-Skripte mit „Security violation“ ab), und die coreutils-Pakete (`APT_HOLD`) werden zurückgehalten, weil ein
Upgrade des Multicall-Binarys den Gast kaputt macht. Log: `/var/log/termux-root-bridge-apt.log` im Gast – jeder Lauf
endet mit einer Zeile `Ende: ok` (oder dem Grund), ein Lauf ohne sie wurde abgebrochen; gehaltene Pakete:
`apt-mark showhold`. Abschalten mit `bash install.sh --no-apt-upgrade` (wird in der Termux-Konfig als
`APT_UPGRADE` gespeichert, spätere Installationen behalten es, auch mit frischem Gast), bei jedem Start mit
`--apt-upgrade always`. Von Hand: `rootbridge-apt` im Gast.

**`claude update`.** Gleiche Regeln wie bei den Paket-Updates (`CLAUDE_UPDATE=daily|always|off`, Standard `daily`): Der
Sitzungsstart führt `claude update` höchstens einmal in 24 h nach einem Erfolg aus (Stempel
`/var/lib/termux-root-bridge/claude-update-last-success` im Gast). Ein fehlgeschlagenes oder abgebrochenes Update hinterlässt
keinen Stempel, meldet es kurz und Claude Code startet trotzdem; der nächste Start versucht es erneut. Mit `daily` kann
Claude Code bis zu einen Tag hinter der neuesten Version liegen. Abschalten mit `bash install.sh --no-claude-update`, bei
jedem Start mit `--claude-update always` (wird in der Termux-Konfig als `CLAUDE_UPDATE` gespeichert, spätere
Installationen behalten es, auch mit frischem Gast). Ein von Hand gestartetes `claude update` setzt den Stempel nicht.

**Startzeit von Hooks und Tools.** Claude Code schließt nach jedem Prozessstart alle Dateideskriptoren bis zum
Limit (`ulimit -n`), und unter proot ist jedes `close()` ein abgefangener Syscall: Androids Standard von 32768 kostete
2,5 bis 4 s pro gestartetem Prozess, jeder Hook und jeder Tool-Aufruf brauchte 4 bis 9 s statt unter einer Sekunde.
`rootbridge-claude` und die Funktion `claude()` starten Claude Code deshalb mit `NOFILE_LIMIT` (Standard 2048, `0` =
nicht ändern; `/etc/termux-root-bridge.conf` im Gast). Das Limit wird nur gesenkt, nie erhöht, und nur für Claude: die
Shell drumherum behält ihres. Wirkt nach `install.sh` und einem Neustart der Claude-Code-Sitzung.

**Farben und Theme.** Ohne `--no-colors` schreibt der Installer ein helles Farbschema nach
`~/.termux/colors.properties` (deine bisherige Datei bleibt als `colors.properties.bak-<Zeitstempel>` erhalten) und
setzt `"theme": "light-ansi"` in der `~/.claude/settings.json` des Gasts (andere Schlüssel bleiben). Die ANSI-Variante
zeichnet mit den 16 Farben dieser Datei statt mit festen RGB-Werten und ist in Termux deutlich besser lesbar als
`light`; jederzeit mit `/theme` umstellbar. Jede neue interaktive
Termux-Shell führt `termux-reload-settings` aus, ebenso die Termux:Widget-Verknüpfungen vor dem Anhängen; die Farben
sind also geladen, bevor `claude update` und Claude Code starten. Zum Ändern `termux/colors.properties` bearbeiten und
`install.sh` erneut ausführen.

**Fester Name in der Remote-Control-Ansicht** (claude.ai/code): `bash install.sh --remote-name android`. **Auf einem
neuen Gerät** (oder nach einem Zurücksetzen von Termux) die Option bei der ersten Installation angeben, denn es gibt
noch keine Termux-Konfig, die sich den Namen merken könnte. Danach steht er dort (`REMOTE_NAME`) und wird bei jeder
späteren Installation ohne Option wiederverwendet, auch bei frischem Gast oder nach `uninstall.sh`; der Gast-Installer
schreibt `CLAUDE_ARGS="--remote-control android --continue"`.
Der Name gehört zur *Sitzung*: eine neue Sitzung bekommt ihn über das Flag, `--continue` behält Sitzung und Namen beim
Neustart. Eine bestehende Sitzung mit anderem Namen benennt das Flag nicht um; einmal `/rename android` eingeben.

## Bedienung

| Befehl (Termux) | Wirkung |
|---|---|
| `rootbridge start` | Daemon + Session; mit `--no-attach` im Hintergrund (Termux:Boot ruft das nach einem Neustart auf) |
| `rootbridge attach` / Alias `ubuntu` | an die Claude-Code-Session anhängen |
| `rootbridge shell` | normale Ubuntu-Shell in diesem Terminal (startet den Daemon für `androidsu`, aber weder Claude Code noch eine tmux-Sitzung; Widget „Ubuntu“) |
| `rootbridge status` | Daemon, Session, Gast-Installation, letzte Audit-Zeilen |
| `rootbridge login <server>` | `claude mcp login <server>` mit Browser-Übergabe |
| `rootbridge stop` | Session und Daemon stoppen |
| `rootbridge guard-off` / `guard-on` | Notschalter für die Hooks |

In Claude Code ändert sich nichts: Du sagst, was du willst. Braucht Claude Root, ruft es `androidsu '<befehl>'`
auf, und du siehst eine Rückfrage mit genau diesem Befehl. Jede Entscheidung steht in `~/.rootbridge/audit.log`.

## Logins und MCP-Links

Kurzfassung (Details: [docs/LOGIN.md](docs/LOGIN.md)):

* Im Login-Dialog **`c`** drücken – Claude Code kopiert den Link in die Android-Zwischenablage (braucht die
  tmux-Einstellungen, die der Installer setzt).
* `/login`, `/mcp` und `claude mcp login` **öffnen den Browser selbst**.
* Bei claude.ai-Connectors (`authenticate`-Tools) öffnet ein Hook den Link, und Claude schreibt eine
  Kurzmeldung statt der langen URL. `AUTH_OPEN=copy` kopiert nur, `AUTH_OPEN=off` schaltet es ab.

## Was geprüft ist

| Durch automatische Tests belegt | Auf einem echten Gerät noch zu prüfen |
|---|---|
| Guard-Entscheidungen (43 Tests): Ticketbindung, indirekte Aufrufe, Manipulationsschutz, fail-closed | Rückfrage des Hooks auch im Bypass-Modus (`tests/headless-proof.sh`) |
| Daemon: Ticket einmalig/Ablauf/Hash, lange Befehle, URL-Prüfung (49 Checks) | OSC 52-Zwischenablage durch tmux nach Android |
| Login-Hook (19 Tests: Antwortformen, URL-Regeln, Modi) | Browser-Öffnen aus dem Gast, `localhost`-Redirect |
| Installer: Staging-Root, Idempotenz, v1-Migration, Deinstallation | `tool_response`-Form der MCP-Login-Tools; `updatedToolOutput` |

Tests starten: `python3 -I -m unittest discover -s tests && bash tests/test_daemon.sh`.

## Grenzen

Das Projekt schützt vor **unbeabsichtigten** Aktionen, nicht vor einem feindlichen Agenten: Root im Gast teilt sich das
Termux-Home mit dem Daemon. Die ehrliche Liste steht in [SECURITY.md](SECURITY.md).

## Deinstallation

```bash
bash uninstall.sh      # behält ~/.rootbridge (Audit-Log, Sicherungen) und die Konfiguration
```

## Verwandte Projekte

Andere Wege, Claude Code auf Android zu bringen, lösen die *Installation*; dieses Projekt löst *Root-Bestätigung,
Start und Logins* darüber: [bd-loser/claude-code-termux](https://github.com/bd-loser/claude-code-termux),
[ferrumclaudepilgrim/claude-code-android](https://github.com/ferrumclaudepilgrim/claude-code-android),
[Crypt0Shmipt0/root-aicli](https://github.com/Crypt0Shmipt0/root-aicli). Details: [docs/COMPARISON.md](docs/COMPARISON.md).
Nicht mit Anthropic verbunden.

## Lizenz

Noch nicht festgelegt – die Maintainer:in ergänzt vor dem ersten Release eine `LICENSE`-Datei.
