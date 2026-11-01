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

Danach eine neue Termux-Sitzung öffnen. Sie startet den Daemon, zählt 3 s herunter (Taste = in Termux bleiben),
führt `claude update` aus und startet Claude Code. Claude **startet weiter im Plan-Modus** (aus deiner
`settings.json`); mit **Umschalt+Tab** wechselst du in *bypass permissions*.

Optionen: `--no-guest`, `--no-boot`, `--no-migrate`, `--autonomous yes|no|ask`. Der Installer ist idempotent, sichert
Geändertes und migriert die alte v1-Popup-Bridge.

## Bedienung

| Befehl (Termux) | Wirkung |
|---|---|
| `rootbridge start` | Daemon + Session (läuft beim Öffnen von Termux automatisch) |
| `rootbridge attach` / Alias `ubuntu` | an die Claude-Code-Session anhängen |
| `rootbridge shell` | zusätzliches Fenster mit normaler Ubuntu-Shell |
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
Autostart und Logins* darüber: [bd-loser/claude-code-termux](https://github.com/bd-loser/claude-code-termux),
[ferrumclaudepilgrim/claude-code-android](https://github.com/ferrumclaudepilgrim/claude-code-android),
[Crypt0Shmipt0/root-aicli](https://github.com/Crypt0Shmipt0/root-aicli). Details: [docs/COMPARISON.md](docs/COMPARISON.md).
Nicht mit Anthropic verbunden.

## Lizenz

Noch nicht festgelegt – die Maintainer:in ergänzt vor dem ersten Release eine `LICENSE`-Datei.
