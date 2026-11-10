# termux-rootbridge

**Claude Code auf Android (Termux + proot-distro) – jede echte Root-Aktion wird direkt in Claude Code bestätigt, und Logins funktionieren ohne Kopierärger.**

[English](README.md) · [Español](README.es.md) · [Vergleich mit anderen Projekten](docs/COMPARISON.md) · [Login & MCP](docs/LOGIN.md) · [Sicherheit](SECURITY.md)

> **Stand: v2.0.0-dev.** Unit- und Integrationstests laufen (Guard-Hook, Login-Hook, Daemon, Installer).
> Auf einem Gerät bestätigt (Hisense A9): die Root-Rückfrage auch im Bypass-Modus, ein vollständiger Login mit
> automatischem `localhost`-Redirect, Browser-Öffnen aus dem Gast und Kopieren von Links in die Android-Zwischenablage
> (über den Daemon und mit der Taste `c` durch tmux). Noch zu prüfen: das genaue `tool_response`-Format der
> MCP-Login-Tools. Siehe [Was geprüft ist](#was-geprüft-ist).

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

* Android mit Termux (F-Droid/GitHub-Build), `proot-distro` mit Ubuntu-Gast, Claude Code im Gast installiert (`install.sh` richtet fehlende Teile davon und die Pakete unten selbst ein)
* funktionierendes `su` (Magisk, KernelSU ...) – ohne `su` gehen nur die Login-Funktionen
* Termux-Pakete: `tmux proot-distro python coreutils util-linux`, optional `termux-api` (+ Termux:API-App) für die Zwischenablage
* Gast: `python3`, coreutils mit `sha256sum`, `od`, `timeout`
* Claude Code ≥ 2.1.295
* Codex (standardmäßig an, `--no-codex` lässt es weg): `install.sh` installiert es mit dem offiziellen Installer; das
  Claude-Code-Plugin und die Pre-Commit-Review brauchen außerdem `git` und `nodejs` (≥ 18.18) im Gast, die er per `apt` einrichtet

## Installation

In einer **Termux**-Shell (nicht in proot):

```bash
pkg install -y git
git clone --depth 1 --filter=blob:none --sparse https://github.com/epaper-dev/termux
cd termux
git sparse-checkout set rootbridge
cd rootbridge
bash install.sh
```

`epaper-dev/termux` enthält auch die Termux-Apps (`termux-app/`, `termux-float/` und weitere, etwa 110 MB). Der
Sparse-Checkout holt nur `rootbridge/` (etwa 1,5 MB); mehr braucht der Installer nicht. Zum Aktualisieren später
`git pull` in `~/termux` und `bash install.sh` noch einmal ausführen. Ein einfaches
`git clone --depth 1 https://github.com/epaper-dev/termux` geht ebenfalls und lädt das ganze Repository.

Der Installer richtet selbst und ohne Rückfrage ein, was fehlt: die Termux-Pakete (`pkg install`), den Ubuntu-Gast
(`proot-distro install`, ein Download von einigen hundert MB), `python3`, `curl` und die Zertifikate im Gast sowie Claude Code
mit dem offiziellen Installer. Hat das Gerät schon alles, läuft nur die normale Installation. Nach einem Fehler einfach noch
einmal starten. Weiter von Hand: die Root-Freigabe für Termux (dein Root-Manager fragt bei der ersten Anfrage), Termux:Boot
einmal öffnen, das Widget **Claude** auf den Homescreen legen und die Claude-Anmeldung (`/login`; der Browser öffnet sich
von selbst). `--no-setup` ändert nichts davon und nennt nur, was fehlt (`--no-deps-check` überspringt den Paketteil,
`--no-guest` den Gastteil). `--setup`, die Option früherer Versionen, wird weiter angenommen und tut nichts Zusätzliches.

**Der autonome Modus ist standardmäßig an** (`--autonomous yes`): Der Installer setzt `skipDangerousModePermissionPrompt` in der
`~/.claude/settings.json` des Gasts, Claude Code zeigt dann keinen Warndialog für den Bypass-Modus, und `permissions.defaultMode`
auf `bypassPermissions` (nur, wenn du noch keinen Standardmodus gesetzt hast), sodass Claude Code **im Bypass-Modus startet**.
Der Bypass-Modus läuft im proot-Gast, und jeder Android-Root-Befehl fragt weiter nach (auch im Bypass-Modus). `--autonomous no`
lässt beide Einstellungen unberührt (ein früher gesetzter Wert bleibt), `--autonomous ask` fragt in einem Terminal.

Außerdem setzt der Installer das **Modell** auf `opusplan` (Opus plant, Sonnet arbeitet), ebenfalls nur, wenn die `settings.json`
noch keins enthält. `--model NAME` schreibt das angegebene Modell immer, `--model none` lässt es unberührt. Und er legt den
**Arbeitsordner `/root/work`** im Gast an, in dem Claude Code startet (`WORKDIR` in `/etc/termux-rootbridge.conf`; ein dort
gesetzter Wert bleibt). Vorher wurde der Ordner nie angelegt, sodass eine frische Installation Claude Code in `/root` startete.
Ein alter Standard `WORKDIR=/root/workspace` wird auf `/root/work` umgestellt, wenn der Ordner `/root/workspace` nicht existiert.

Danach Claude Code über das Widget **Claude** starten oder in einer Termux-Shell `ubuntu` eingeben (Alias für
`rootbridge attach`). Der erste Start legt die Sitzung an: Daemon starten, Pakete des Gasts aktualisieren
(`apt-get update` + `upgrade`, höchstens alle 6 Stunden, siehe unten), `claude update` ausführen (ebenfalls höchstens alle 6
Stunden) und Claude Code starten; spätere Starts hängen sich nur an. **Normale Termux-Fenster bleiben reine Shells** (mit geladenen Farben),
nichts startet von selbst. Mit Termux:Boot wird die Sitzung nach einem Neustart im Hintergrund angelegt
(`rootbridge start --no-attach`). Claude **startet im Bypass-Modus** (mit `--autonomous no`: im Modus deiner
`settings.json`); mit **Umschalt+Tab** wechselst du den Modus (am Handy mit der Taste **S-TAB**, die der Installer der
Termux-Zusatztastenleiste hinzufügt, siehe unten).

Optionen: `--no-setup`, `--no-guest`, `--no-boot`, `--no-migrate`, `--no-colors`, `--no-widgets`, `--no-extra-keys`, `--autonomous yes|no|ask`, `--model NAME|none`, `--remote-name NAME`,
`--apt-upgrade 6h|<N>h|daily|always|off`, `--no-apt-upgrade`, `--claude-update 6h|<N>h|daily|always|off`, `--no-claude-update`, `--codex-update 6h|<N>h|daily|always|off`, `--no-codex-update`, `--no-claude`, `--no-codex` (`--claude` / `--codex` schalten ein Programm wieder an, siehe [Codex neben Claude Code](#codex-neben-claude-code)). Der Installer ist idempotent, sichert Geändertes und migriert die
alte v1-Popup-Bridge.

**Widgets.** Mit der App Termux:Widget gibt es drei Verknüpfungen: **Claude** (an die Claude-Code-Sitzung anhängen), **Codex** (das Codex-Fenster, siehe
[Codex neben Claude Code](#codex-neben-claude-code)) und **Ubuntu** (normale Ubuntu-Shell). Der Installer legt sie zusammen
mit dem Widget-Icon in `~/.shortcuts` ab (`termux/shortcuts/icons/widget.png`, kopiert nach `~/.shortcuts/icons/<Name>.png`,
für alle dasselbe; `tools/make-widget-icon.py` erzeugt es aus dem Logo `termux/shortcuts/icons/logo.png`). Das bunte Icon der
vorigen Version (`icons/legacy/widget-colour.png`) wird ebenfalls dadurch ersetzt. Die neutralen
`>_`-Icons früherer Versionen (`termux/shortcuts/icons/legacy`) werden dadurch ersetzt, jedes andere vorhandene Icon wird
nie ersetzt, du kannst also ein eigenes PNG dorthin legen; bei früheren Namen („Claude Code“ / „Ubuntu Shell“, „Claude >_“ / „Ubuntu >_“) wandert ein vorhandenes Icon auf den neuen Namen, und die alten Skripte werden entfernt. Sicherungen von
Widget- und Boot-Skripten landen in `~/.rootbridge/backups` (Termux:Widget listet jede Datei in `~/.shortcuts`,
Termux:Boot führt jede Datei in `~/.termux/boot` aus). `--no-widgets` überspringt das Ganze.

**Zusatztasten.** Eine Handy-Tastatur hat kein Umschalt+Tab, und Claude Code wechselt damit den Berechtigungsmodus (Plan,
Auto, Bypass). Der Installer setzt deshalb die Zusatztastenleiste von Termux in `~/.termux/termux.properties` (in einem
markierten Block, die Datei wird vorher gesichert, danach lädt Termux seine Einstellungen neu): zwei Zeilen mit je sechs Tasten,
`ESC` `CTRL` `S-TAB` `BKSP` `↑` `ENTER` und `KEYBOARD` `/` `TAB` `←` `↓` `→`. **S-TAB** sendet Umschalt+Tab, **TAB**
vervollständigt Slash-Befehle und `@`-Dateien. **KEYBOARD** blendet die Bildschirmtastatur ein oder aus (eine
ausgeblendete Tastatur kommt nicht von selbst zurück; `ENTER`, die Pfeile, `ESC` und `S-TAB` beantworten weiter Rückfragen
und Menüs). Wisch nach oben auf `←` ergibt `HOME`, auf `→` `END`. Eine eigene Leiste (eine `extra-keys`-Zeile
außerhalb unseres Blocks) wird nie ersetzt, der Installer nennt dann nur die Taste, die du selbst ergänzen kannst (Vorlage:
`termux/extra-keys.snippet`). `--no-extra-keys` überspringt das Ganze, `uninstall.sh` entfernt den Block. Die Farben der
Leiste legt Termux fest, sie lassen sich von hier aus nicht ändern.

**Ende der Sitzung.** `/exit` (oder Strg+C) in Claude Code beendet alles: Das tmux-Fenster und die tmux-Sitzung schließen sich,
`rootbridge attach` kehrt zurück, und das über das Widget **Claude** geöffnete Termux-Fenster schließt sich mit. Du landest nicht in der
Ubuntu-Shell. Nur wenn Claude Code mit einem Fehlercode endet, bleibt die Gast-Shell mit einem Hinweis offen, damit die Meldung lesbar bleibt (ebenso, wenn `claude` nicht installiert ist).

**Paket-Updates im Gast.** Standardmäßig an: Beim Start der Claude-Code-Sitzung führt `rootbridge-apt`
`apt-get update` und `apt-get -y upgrade` aus, höchstens einmal in 6 h nach einem Erfolg (`APT_UPGRADE=6h`; `12h` usw. ändern den Abstand, `daily` = 24 h), und
blockiert den Start nie (kein Netz, ein Fehler oder ein Timeout geben nur einen Hinweis aus, Claude Code startet, der
nächste Start versucht es erneut). Zwei Schutzmaßnahmen sind unter proot-distro mit Ubuntu 26.04 wichtig: dpkg bekommt
`-o DPkg::Path` mit `/usr/local/bin`, weil die uutils-coreutils dort die GNU-benannten Symlinks brauchen (sonst brechen
Maintainer-Skripte mit „Security violation“ ab), und die coreutils-Pakete (`APT_HOLD`) werden zurückgehalten, weil ein
Upgrade des Multicall-Binarys den Gast kaputt macht. Log: `/var/log/termux-rootbridge-apt.log` im Gast – jeder Lauf
endet mit einer Zeile `Ende: ok` (oder dem Grund), ein Lauf ohne sie wurde abgebrochen; gehaltene Pakete:
`apt-mark showhold`. Abschalten mit `bash install.sh --no-apt-upgrade` (wird in der Termux-Konfig als
`APT_UPGRADE` gespeichert, spätere Installationen behalten es, auch mit frischem Gast), bei jedem Start mit
`--apt-upgrade always`. Von Hand: `rootbridge-apt` im Gast. Alles, was per `apt` installiert ist, ist abgedeckt, auch `nodejs` und `npm`, falls du
sie nachinstallierst; globale Pakete aus `npm -g` nicht. Claude Code selbst ist ein natives Programm, das `claude update`
ohne npm ersetzt. Ein Wert, der schon in `/etc/termux-rootbridge.conf` steht, bleibt beim Installieren ohne Option
erhalten; ein älteres `daily` stellst du einmal mit `bash install.sh --apt-upgrade 6h --claude-update 6h` um.

**`claude update`.** Gleiche Regeln wie bei den Paket-Updates (`CLAUDE_UPDATE=6h|<N>h|daily|always|off`, Standard `6h`): Der
Sitzungsstart führt `claude update` höchstens einmal in 6 h nach einem Erfolg aus (Stempel
`/var/lib/termux-rootbridge/claude-update-last-success` im Gast). Ein fehlgeschlagenes oder abgebrochenes Update hinterlässt
keinen Stempel, meldet es kurz und Claude Code startet trotzdem; der nächste Start versucht es erneut. Mit dem Standard kann
Claude Code bis zu 6 Stunden hinter der neuesten Version liegen. Abschalten mit `bash install.sh --no-claude-update`, bei
jedem Start mit `--claude-update always` (wird in der Termux-Konfig als `CLAUDE_UPDATE` gespeichert, spätere
Installationen behalten es, auch mit frischem Gast). Ein von Hand gestartetes `claude update` setzt den Stempel nicht.

**Startzeit von Hooks und Tools.** Claude Code schließt nach jedem Prozessstart alle Dateideskriptoren bis zum
Limit (`ulimit -n`), und unter proot ist jedes `close()` ein abgefangener Syscall: Androids Standard von 32768 kostete
2,5 bis 4 s pro gestartetem Prozess, jeder Hook und jeder Tool-Aufruf brauchte 4 bis 9 s statt unter einer Sekunde.
`rootbridge-claude` und die Funktion `claude()` starten Claude Code deshalb mit `NOFILE_LIMIT` (Standard 2048, `0` =
nicht ändern; `/etc/termux-rootbridge.conf` im Gast). Das Limit wird nur gesenkt, nie erhöht, und nur für Claude: die
Shell drumherum behält ihres. Wirkt nach `install.sh` und einem Neustart der Claude-Code-Sitzung.

**Farben und Theme.** Der Installer schreibt keine Farbdatei. Der E-Paper-Build von Termux (`epaper-dev/termux`) bringt ein
helles und ein dunkles Schema mit und folgt dem Hell/Dunkel-Modus des Telefons: Das Terminal ist im Hellmodus hell und im
Dunkelmodus dunkel, ganz ohne Datei; `~/.termux/colors-light.properties`, `colors-dark.properties` und `colors.properties`
überschreiben das nur. Farbdateien, die frühere Versionen installiert haben (`colors.properties` mit der hellen Palette,
`colors-light.properties`), werden entfernt, solange sie noch genau so sind wie installiert, weil sie das eingebaute Schema
überdecken würden; eine Datei, die du geändert hast, bleibt. `--no-colors` lässt Farbdateien und das Claude-Code-Theme in
Ruhe. Außerdem setzt der Installer `"theme": "custom:epaper"` in der `~/.claude/settings.json` des Gasts (andere
Schlüssel bleiben) und legt das Theme **Auto epaper** an (`~/.claude/themes/epaper.json`, Basis `light-ansi`: die 16 Farben des Termux-Schemas, die dem Schwellwert von
„Text mit hohem Kontrast“ ausweichen; eine
eigene Datei bleibt). Claude Codes eigenes `auto` wählt nur `light` oder `dark`, deshalb meldet Termux einen Wechsel
zwischen hell und dunkel (DECSET 2031) an tmux, dessen Hooks `client-light-theme` / `client-dark-theme` dann
`rootbridge theme light|dark` aufrufen: Es stellt die Basis zwischen `light-ansi` und `dark-ansi` um (bzw.
`light-daltonized`/`dark-daltonized`, `light`/`dark`, wenn du das einträgst). Eine laufende
Claude-Code-Sitzung übernimmt die geänderte Theme-Datei und wechselt die Farben live (auf dem Gerät bestätigt, ohne
Neustart). `THEME_RESTART=on` in `~/.config/termux-rootbridge/config` ist nur eine Notlösung für eine Version, die das
nicht tut: Es startet Claude Code mit `--continue` neu (eine laufende Antwort bricht ab). `THEME_FOLLOW=off` schaltet die
Hooks ab. Ein anderes
Theme jederzeit mit `/theme`. Jede neue interaktive Termux-Shell führt
`termux-reload-settings` aus, ebenso die Termux:Widget-Verknüpfungen vor dem Anhängen. Andere Termux-Builds haben kein
eingebautes helles Schema; dort ein Schema nach `~/.termux/colors.properties` kopieren.

**Fester Name in der Remote-Control-Ansicht** (claude.ai/code): Standard ist `android`, ein einfaches `bash install.sh`
setzt ihn also. Anderer Name: `bash install.sh --remote-name NAME`. Dieser Name steht danach in der Termux-Konfig
(`REMOTE_NAME`) und wird bei jeder späteren Installation ohne Option wiederverwendet, auch bei frischem Gast oder nach
`uninstall.sh`; der Gast-Installer schreibt `CLAUDE_ARGS="--remote-control android --continue"`.
`--remote-control NAME` schaltet Remote Control ein und betitelt die Sitzung in der Remote-Control-Ansicht. Diese
Remote-Control-Sitzung wird über Neustarts und `/clear` wiederverwendet und behält ihren Namen, auch einen per
`/rename` vergebenen. Für einen anderen Namen genügt ein einmaliges `/rename NAME`. Ein `--name` gibt es bewusst nicht:
Es würde den Namen zusätzlich im Rahmen des Eingabefelds im Claude-Code-Fenster anzeigen.

## Codex neben Claude Code

`install.sh` richtet standardmäßig **Codex** (OpenAIs Coding-Agent) neben Claude Code ein. `--no-codex` lässt es weg,
`--no-claude` gibt dir Codex allein: kein Claude Code, keine Managed Settings, keine Hooks, kein Plugin (Guard, Plugin und
Pre-Commit-Review leben alle in Claude Code); eines der beiden Programme bleibt immer. Die Wahl steht in der Termux-Konfig
(`TOOL_CLAUDE` / `TOOL_CODEX`) und gilt für jede spätere Installation; mit `--claude` / `--codex` schaltest du ein Programm
wieder an.

* **Installation.** Im Gast: `git` und `nodejs` per `apt` (das Plugin braucht Node.js 18.18 oder neuer), Codex mit dem
  offiziellen Standalone-Installer (`chatgpt.com/codex/install.sh`, nicht interaktiv, nach `~/.local/bin`; er bringt seine
  eigene `bwrap`-Sandbox mit) und das Codex-Plugin für Claude Code (`codex@openai-codex` aus `openai/codex-plugin-cc`).
  Jeder Schritt läuft nur, wenn er fehlt, ein zweiter Lauf fasst das Netz also nicht an.
* **Widget „Codex“** und `rootbridge attach codex`: ein zweites Fenster in derselben tmux-Sitzung. Codex startet mit seinen
  eigenen Standardwerten (Sandbox und Rückfragen), **nicht** in einem Bypass-Modus; `CODEX_ARGS` in
  `/etc/termux-rootbridge.conf` fügt Optionen hinzu. Der Hook `android-root-guard` schützt nur Claude Code; `androidsu`
  verweigert ohne Ticket weiterhin, und Tickets stellt nur dieser Hook aus.
* **Anmeldung.** `rootbridge codex-login` führt `codex login` mit der Browser-Übergabe aus (`--device-auth`, wenn es keinen
  Browser gibt). `rootbridge status` zeigt, ob Codex, seine Anmeldung, das Plugin und der Hook da sind.
* **Beide bleiben aktuell.** Der Start eines der beiden Fenster ruft `rootbridge-apt` und danach `rootbridge-update` auf:
  `claude update`, `codex update` und das Plugin-Update, jeweils höchstens alle 6 h nach einem Erfolg (`CLAUDE_UPDATE` /
  `CODEX_UPDATE` = `6h|<N>h|daily|always|off`, Stempel in `/var/lib/termux-rootbridge/`; `--codex-update M`,
  `--no-codex-update`). Starten zwei Sitzungen gleichzeitig, kommen sie nacheinander dran (Sperre), und ein fehlgeschlagener
  Schritt hält den Start nie auf. `nodejs` und `git` sind `apt`-Pakete, `rootbridge-apt` hält sie also aktuell. Ein
  Plugin-Update gilt nach einem Neustart von Claude Code.
* **Pre-Commit-Review.** Mit beiden Programmen lässt ein Hook in den Managed Settings (`codex-precommit-review.py`, Timeout
  900 s, `onFailure: "block"`) Codex jeden `git commit` von Claude Code prüfen. Eine erste Zeile `ALLOW` lässt den Commit
  durch; `BLOCK` oder keine klare Antwort hält ihn an und gibt Codex' Befunde an Claude, das sie behebt und erneut committet.
  Es ist eine strikte Schleife: Nach einem `BLOCK` kommt derselbe Diff nie durch, nur ein geänderter Diff, den Codex danach
  freigibt; ein freigegebener Diff wird gemerkt. Fail-closed: Ohne Codex-Anmeldung, Plugin oder `node`, oder wenn Codex oder `git`
  scheitert, wird der Commit blockiert. Notausgang, nur für dich: `rootbridge codex-off` / `codex-on` (Claude Code neu
  starten) oder `CODEX_PRECOMMIT=off` in der Umgebung, mit der Claude Code startet. **Bis du dich bei Codex angemeldet hast,
  ist jeder Commit von Claude Code blockiert.** Der Hook zerlegt den Befehl wie eine Shell und prüft ein `git commit`, das ausgeführt wird (auch nach `cd`, mit
  `git -C`, hinter `sudo` / `env` / `time`, in `bash -c '…'` und `$(…)`); Text in Anführungszeichen oder Heredocs zählt nicht.
  Git-Aliase (`git ci`) und Skripte, die committen, erkennt er nicht, und die Prüfung betrachtet den ganzen Arbeitsbaum
  (staged und unstaged, Binäränderungen eingeschlossen) sowie, wenn derselbe Befehl `git add` ausführt, die noch nicht
  verfolgten Dateien, die dabei dazukommen können (sie stehen in keinem Diff).
  Codex blockiert nur bei hoher Schwere (ein Bug, der etwas kaputt macht, eine Sicherheitslücke, ein Secret, Datenverlust,
  ein verschluckter Fehler); Kleineres kommt als Hinweis hinter `ALLOW`. Die Prüfung sieht den Arbeitsbaum, wie er beim
  Start des Befehls ist: Was derselbe Befehl vor dem Commit noch ändert (`sed -i … && git commit -a`, ein Build-Skript),
  ist nicht erfasst.
* **Daten.** Der Diff und alles, was Codex im Arbeitsbaum liest, gehen an OpenAI, unter dem Konto, mit dem du dich angemeldet
  hast. Die Sandbox von Codex beschränkt das Schreiben, nicht das Lesen: Es kann mehr vom Gast lesen als das Repository.

## Bedienung

| Befehl (Termux) | Wirkung |
|---|---|
| `rootbridge start` | Daemon + Session; mit `--no-attach` im Hintergrund (Termux:Boot ruft das nach einem Neustart auf) |
| `rootbridge attach` / Alias `ubuntu` | an die Claude-Code-Session anhängen |
| `rootbridge attach codex` | an das Codex-Fenster anhängen (Widget **Codex**; die Session wird angelegt, wenn sie fehlt) |
| `rootbridge shell` | normale Ubuntu-Shell in diesem Terminal (startet den Daemon für `androidsu`, aber weder Claude Code noch eine tmux-Sitzung; Widget „Ubuntu“) |
| `rootbridge status` | Daemon, Session, Gast-Installation, letzte Audit-Zeilen |
| `rootbridge login <server>` | `claude mcp login <server>` mit Browser-Übergabe |
| `rootbridge codex-login` | `codex login` mit Browser-Übergabe (`--device-auth` ohne Browser) |
| `rootbridge stop` | Session und Daemon stoppen |
| `rootbridge guard-off` / `guard-on` | Notschalter für die Hooks |
| `rootbridge codex-off` / `codex-on` | Notschalter für die Codex-Pre-Commit-Review (Claude Code neu starten) |
| `ptt start` / `stop` / `toggle` / `status` | Push-to-Talk: drückt im Claude-Code-Fenster eine Taste für `/voice` (siehe unten) |

In Claude Code ändert sich nichts: Du sagst, was du willst. Braucht Claude Root, ruft es `androidsu '<befehl>'`
auf, und du siehst eine Rückfrage mit genau diesem Befehl. Jede Entscheidung steht in `~/.rootbridge/audit.log`.

### Push-to-Talk für `/voice`

`/voice` von Claude Code braucht eine gehaltene Taste, und das geht mit einer Bildschirmtastatur nicht. `ptt` ist die Taste dafür,
damit etwas anderes sie halten kann: eine Seitentaste, ein Widget, ein Skript. Einmal einrichten:

1. `~/.claude/keybindings.json`: `{"bindings": [{"context": "Chat", "bindings": {"meta+k": "voice:pushToTalk"}}]}`
2. In Claude Code `/voice hold`.
3. `ptt start` startet die Aufnahme (es wiederholt Alt+K alle 50 ms, wie eine gehaltene Taste), `ptt stop` beendet sie, und der Text
   landet im Eingabefeld. Ohne Stopp enden die Wiederholungen nach `PTT_MAX` Sekunden (120).

`ptt` drückt nur eine Taste in einem tmux-Fenster (`PTT_TARGET`, Standard `ubuntu:claude`; `PTT_KEY`, Standard `M-k`) und passt damit
zu jedem Programm, das auf eine Taste hört. Das Mikrofon selbst braucht `sox` im Gast, einen PulseAudio-Server in Termux mit
Mikrofonquelle und die Mikrofon-Berechtigung von Android für Termux; das ist Geräte-Einrichtung, nicht Teil des Installers.

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
| Guard-Entscheidungen (43 Tests): Ticketbindung, indirekte Aufrufe, Manipulationsschutz, fail-closed | `tool_response`-Form der MCP-Login-Tools; `updatedToolOutput` |
| Daemon: Ticket einmalig/Ablauf/Hash, lange Befehle, URL-Prüfung (49 Checks) | — |
| Login-Hook (19 Tests: Antwortformen, URL-Regeln, Modi) | — |
| Installer: Staging-Root, Idempotenz, v1-Migration, Deinstallation | — |
| Codex neben Claude Code: Installationsoptionen und gespeicherte Wahl, Update-Schritte mit Stempeln und Sperre, tmux-Fenster, `codex-login` / `codex-off` / `status`, die Pre-Commit-Schleife (Stub-`node`) | `codex-login` und das Widget **Codex** auf einem Gerät; `claude plugin update`, `codex update` und `onFailure: "block"` nach einem Absturz des Hooks; `bwrap` auf anderen Geräten |

Auf einem Gerät bestätigt (Hisense A9, 04.11.2026): Installer, Farben und Theme, apt-Upgrade, `claude update`, das
Dateideskriptor-Limit, Widgets, Sitzungsende mit `/exit`, die Root-Rückfrage im Bypass-Modus (der Hook fragte in Claude Code, `androidsu` lief erst nach
der Antwort), ein vollständiger `/login` mit automatischem `localhost`-Redirect (ohne Code einzufügen), Browser-Öffnen aus dem Gast und Kopieren von Links in die
Android-Zwischenablage (`--copy-only` über den Daemon und die Taste `c` durch tmux).

Tests starten: `python3 -I -m unittest discover -s tests && bash tests/test_daemon.sh`.

## Grenzen

Das Projekt schützt vor **unbeabsichtigten** Aktionen, nicht vor einem feindlichen Agenten: Root im Gast teilt sich das
Termux-Home mit dem Daemon. Die ehrliche Liste steht in [SECURITY.md](SECURITY.md).

## Deinstallation

```bash
bash uninstall.sh      # behält ~/.rootbridge (Audit-Log, Sicherungen) und die Konfiguration
```

Er entfernt die Widgets (auch **Codex**), die Programme und die Hooks, die Codex-Pre-Commit-Review eingeschlossen. Codex selbst,
seine Anmeldung (`~/.codex`) und das Plugin bleiben im Gast.

## Verwandte Projekte

Andere Wege, Claude Code auf Android zu bringen, lösen die *Installation*; dieses Projekt löst *Root-Bestätigung,
Start und Logins* darüber: [bd-loser/claude-code-termux](https://github.com/bd-loser/claude-code-termux),
[ferrumclaudepilgrim/claude-code-android](https://github.com/ferrumclaudepilgrim/claude-code-android),
[Crypt0Shmipt0/root-aicli](https://github.com/Crypt0Shmipt0/root-aicli). Details: [docs/COMPARISON.md](docs/COMPARISON.md).
Nicht mit Anthropic verbunden.

## Lizenz

[MIT](LICENSE).
