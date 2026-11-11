# termux-rootbridge

**Ejecuta Claude Code en Android (Termux + proot-distro) con cada acción de root real confirmada dentro de Claude Code, y con inicios de sesión que simplemente funcionan.**

[English](README.md) · [Deutsch](README.de.md) · [Comparación con otros proyectos](docs/COMPARISON.md) · [Inicio de sesión y MCP](docs/LOGIN.md) · [Seguridad](SECURITY.md)

> **Estado: v2.0.0-dev.** Las pruebas unitarias y de integración pasan (hook de guardia, hook de inicio de sesión,
> daemon, instaladores). Confirmado en un dispositivo (Hisense A9): la confirmación de root también en modo bypass, un
> inicio de sesión completo con la redirección automática a `localhost`, la apertura del navegador desde el invitado y
> la copia de enlaces al portapapeles de Android (mediante el daemon y con la tecla `c` a través de tmux). Pendiente de
> comprobar: el formato exacto de `tool_response` de las herramientas de inicio de sesión MCP. Consulta
> [qué está verificado](#qué-está-verificado).

## ¿Qué problema resuelve?

Si ejecutas Claude Code dentro de un invitado Ubuntu (proot-distro) en Termux, te encuentras con tres obstáculos:

1. **El root real de Android queda fuera de alcance.** `su` dentro de proot choca con Magisk. Este proyecto ejecuta un
   pequeño daemon *fuera* de proot que lanza `su -c` para el invitado, pero solo para los comandos que hayas confirmado.
2. **Quieres que Claude trabaje de forma autónoma** (sin preguntar por cada `ls`) **pero que nunca toque el sistema del
   teléfono sin preguntar.** Un hook convierte cada comando capaz de usar root (`androidsu`, `adb`, `fastboot`, `su`,
   `magisk`, ...) en una confirmación normal *dentro de Claude Code*, también en el modo bypass-permissions.
3. **Iniciar sesión es incómodo en un teléfono.** El enlace OAuth/MCP tiene cientos de caracteres, se parte en muchas
   líneas y al copiarlo se le cuelan espacios. Ahora el enlace se abre por ti en el navegador de Android, o se copia
   limpio con una sola tecla.

Ya no hay una segunda ventana de terminal ni ventana emergente (la v1 necesitaba ambas).

## Cómo funciona

```
Claude Code (invitado Ubuntu, root)               Termux (fuera de proot)
───────────────────────────────────               ───────────────────────
Bash: androidsu 'id'
 └─ hook PreToolUse (android-root-guard.py)
     • ¿comando literal? → ticket de un solo uso, ligado a sha256("id")
     • pregunta: "⚠ ANDROID-ROOT: id"   ← respondes Sí / No en Claude Code
androidsu ── solicitud + ticket ───────────────▶  rootbridge-daemon (sin ventana)
                                                  ¿ticket válido? → su -c 'id'
                         ◀──────── resultado ──   ¿sin ticket?    → rechazado (exit 99)
```

* **Sin ticket, no hay root.** Si rechazas la confirmación, el comando nunca se ejecuta. No hay alternativa con ventana
  emergente.
* **Autonomía para todo lo demás.** Lo que no tiene que ver con root (incluido `/sdcard`) se ejecuta sin preguntas.
* **Enlaces de inicio de sesión.** `/login`, `/mcp` y `claude mcp login <server>` abren el navegador mediante
  `BROWSER`/`xdg-open`; los resultados de `mcp__*__authenticate` se interceptan para que el enlace largo se abra y se
  copie en lugar de imprimirse.

## Requisitos

* Android con Termux (compilación de F-Droid/GitHub), `proot-distro` con un invitado Ubuntu y Claude Code instalado en
  el invitado (`curl -fsSL https://claude.ai/install.sh | bash`); `install.sh` prepara lo que falte de esto y de los paquetes de abajo
* Un `su` que funcione (Magisk, KernelSU, ...); sin él, solo funcionan las funciones de inicio de sesión
* Paquetes de Termux: `tmux proot-distro python coreutils util-linux`; opcional `termux-api` (+ la app Termux:API)
  para el portapapeles
* Paquetes del invitado: `python3` (hooks), coreutils con `sha256sum`, `od`, `timeout`
* Claude Code ≥ 2.1.295 (`onFailure: "block"` para los hooks)
* Codex (activado por defecto, `--no-codex` lo omite): `install.sh` lo instala con el instalador oficial; el plugin de
  Claude Code y la revisión previa al commit necesitan además `git` y `nodejs` (≥ 18.18) en el invitado, y Codex necesita
  `bubblewrap` (`bwrap`). El instalador configura estos paquetes con `apt`.

## Instalación

En una shell de **Termux** (no dentro de proot):

```bash
pkg install -y git
git clone --depth 1 --filter=blob:none --sparse https://github.com/epaper-dev/termux
cd termux
git sparse-checkout set rootbridge
cd rootbridge
bash install.sh
```

`epaper-dev/termux` también incluye las apps de Termux (`termux-app/`, `termux-float/` y otras, unos 110 MB). La descarga «sparse» solo descarga `rootbridge/` (unos 1,5 MB); el instalador no necesita nada más. Para actualizar más adelante, ejecuta de nuevo `git pull` en `~/termux` y luego `bash install.sh`. También puedes usar un simple `git clone --depth 1 https://github.com/epaper-dev/termux`, que descargará todo el repositorio.

El instalador prepara por sí solo y sin preguntar lo que falte: los paquetes de Termux (`pkg install`), el invitado Ubuntu
(`proot-distro install`, una descarga de unos cientos de MB), `python3`, `curl` y los certificados en el invitado, y Claude Code
con el instalador oficial. Si el dispositivo ya lo tiene todo, solo se ejecuta la instalación normal. Tras un fallo, vuelve a
ejecutarlo. Sigue siendo manual: la autorización de root para Termux (tu gestor de root pregunta en la primera petición), abrir
Termux:Boot una vez, poner el widget **Claude** en la pantalla de inicio y el inicio de sesión de Claude (`/login`; el navegador
se abre solo). `--no-setup` no cambia nada de esto y solo indica lo que falta (`--no-deps-check` omite la parte de paquetes,
`--no-guest` la del invitado). `--setup`, la opción de versiones anteriores, se sigue aceptando y no hace nada adicional.

**El modo autónomo está activado por defecto** (`--autonomous yes`): el instalador pone `skipDangerousModePermissionPrompt` en el
`~/.claude/settings.json` del invitado, así que Claude Code no muestra el diálogo de aviso al pasar al modo bypass con
Shift+Tab. No cambia nada más. Claude sigue arrancando en el modo de tu configuración, el modo bypass se ejecuta dentro del
invitado proot y cada comando de root de Android sigue pidiendo confirmación (también en modo bypass). `--autonomous no` deja el
ajuste como está (un valor anterior se mantiene), `--autonomous ask` pregunta en un terminal.

Después inicia Claude Code con el widget **Claude**, o escribe `claude` (alias de `rootbridge attach claude`) en una shell de
Termux. `codex` abre la sesión de Codex y `ubuntu` abre una shell Ubuntu simple. Tras la instalación, ejecuta
`source ~/.bashrc` o abre una nueva ventana de Termux para cargar los atajos.
El primer arranque de Claude crea la sesión: inicia el daemon, actualiza los paquetes del invitado (`apt-get update` +
`upgrade`, como máximo una vez cada 6 h, ver abajo), ejecuta `claude update` (también como máximo una vez cada 6 h) e
inicia Claude Code; los arranques posteriores solo se conectan a ella.
**Las ventanas normales de Termux siguen siendo shells simples** (con los colores cargados): nada se inicia solo. Con
Termux:Boot la sesión se crea en segundo plano tras un reinicio (`rootbridge start --no-attach`). Claude sigue
**arrancando en modo plan** (según tu `settings.json`); pulsa **Shift+Tab** para cambiar a *bypass permissions* (en un
teléfono, con la tecla **S-TAB** que el instalador añade a la fila de teclas extra de Termux, ver abajo).

Opciones: `--no-setup`, `--no-guest`, `--no-boot`, `--no-migrate`, `--no-colors`, `--no-widgets`, `--no-extra-keys`, `--autonomous yes|no|ask`,
`--remote-name NAME`, `--apt-upgrade 6h|<N>h|daily|always|off`, `--no-apt-upgrade`, `--claude-update 6h|<N>h|daily|always|off`,
`--no-claude-update`, `--codex-update 6h|<N>h|daily|always|off`, `--no-codex-update`, `--no-claude`, `--no-codex` (`--claude` / `--codex` vuelven a activar una herramienta, ver [Codex junto a Claude Code](#codex-junto-a-claude-code)). El instalador es idempotente, hace copia de seguridad de lo que modifica y migra el antiguo puente
con ventana emergente de la v1 si lo encuentra.

**Widgets.** Con la app Termux:Widget tienes tres accesos directos: **Claude** (conectarse a la sesión de Claude Code), **Codex** (la ventana de Codex, ver
[Codex junto a Claude Code](#codex-junto-a-claude-code)) y **Ubuntu** (una shell Ubuntu simple). El instalador los coloca en
`~/.shortcuts` junto con el icono del widget (`termux/shortcuts/icons/widget.png`, copiado a `~/.shortcuts/icons/<nombre>.png`,
el mismo para todos; `tools/make-widget-icon.py` lo genera a partir del logotipo `termux/shortcuts/icons/logo.png`). El icono
de colores de la versión anterior (`icons/legacy/widget-colour.png`) también se reemplaza por él. Los iconos
neutros `>_` de versiones anteriores (`termux/shortcuts/icons/legacy`) se reemplazan por él; cualquier otro icono que ya
exista nunca se reemplaza, así que puedes poner allí tu propio PNG; con los nombres anteriores («Claude Code» /
«Ubuntu Shell», «Claude >_» / «Ubuntu >_») un icono existente pasa al nombre nuevo y se eliminan los scripts antiguos.
Las copias de seguridad de los scripts de widgets y de arranque van a `~/.rootbridge/backups` (Termux:Widget lista cada
archivo de `~/.shortcuts` y Termux:Boot ejecuta cada archivo de `~/.termux/boot`). `--no-widgets` omite todo esto.

**Teclas extra.** El teclado de un teléfono no tiene Shift+Tab, y Claude Code cambia con él su modo de permisos (plan,
auto, bypass). Por eso el instalador configura la fila de teclas extra de Termux en `~/.termux/termux.properties` (dentro de
un bloque marcado; antes se hace una copia del archivo y después Termux recarga su configuración): dos filas de seis teclas,
`ESC` `CTRL` `S-TAB` `BKSP` `↑` `ENTER` y `KEYBOARD` `/` `TAB` `←` `↓` `→`. **S-TAB** envía Shift+Tab; **TAB** completa
comandos slash y archivos `@`. **KEYBOARD** muestra u oculta el teclado en pantalla (un teclado
oculto no vuelve a aparecer por sí solo; `ENTER`, las flechas, `ESC` y `S-TAB` siguen respondiendo a preguntas y menús).
Deslizar hacia arriba sobre `←` da `HOME` y sobre `→` da `END`. Una fila propia (una línea `extra-keys` fuera de
nuestro bloque) nunca se sustituye; el instalador solo indica qué tecla añadir a mano (plantilla:
`termux/extra-keys.snippet`). `--no-extra-keys` omite todo esto y `uninstall.sh` elimina el bloque. Los colores de la fila
los fija Termux y no se pueden cambiar desde aquí.

**Fin de la sesión.** `/exit` (o Ctrl+C) en Claude Code lo termina todo: la ventana y la sesión de tmux se cierran,
`rootbridge attach` vuelve, y la ventana de Termux abierta por el widget **Claude** se cierra con ellas. No terminas en
la shell de Ubuntu. Solo si Claude Code termina con un código de error, la shell del invitado se queda abierta con un
aviso, para que el mensaje siga siendo legible (también cuando `claude` no está instalado).

**Actualizaciones de paquetes en el invitado.** Activadas por defecto: al iniciar la sesión de Claude Code,
`rootbridge-apt` ejecuta `apt-get update` y `apt-get -y upgrade`, como máximo una vez cada 6 h tras un éxito
(`APT_UPGRADE=6h`; p. ej. `12h` cambia el intervalo, `daily` = 24 h), y nunca bloquea el arranque (sin red, un error o un tiempo de espera agotado solo muestran un
aviso y Claude Code arranca; el siguiente arranque lo intenta de nuevo). Dos salvaguardas importan en proot-distro con
Ubuntu 26.04: dpkg recibe `-o DPkg::Path` incluyendo `/usr/local/bin`, porque los coreutils de uutils necesitan allí los
enlaces simbólicos con nombres GNU (si no, los scripts de mantenimiento abortan con «Security violation»), y los
paquetes de coreutils (`APT_HOLD`) se mantienen retenidos, porque actualizar el propio binario multicall rompe el
invitado. Registro: `/var/log/termux-rootbridge-apt.log` en el invitado; cada ejecución termina con una línea
`Ende: ok` (o el motivo), y una ejecución sin ella fue interrumpida; paquetes retenidos: `apt-mark showhold`. Se
desactiva con `bash install.sh --no-apt-upgrade` (se guarda en la configuración de Termux como `APT_UPGRADE`, de modo
que las instalaciones posteriores lo conservan, también con un invitado nuevo), o se ejecuta en cada arranque con
`--apt-upgrade always`. A mano: `rootbridge-apt` en el invitado. Todo lo instalado con `apt` queda cubierto, también `nodejs` y `npm` si los
añades; los paquetes globales de `npm -g` no. Claude Code es un binario nativo que `claude update` sustituye sin npm. Un
valor que ya está en `/etc/termux-rootbridge.conf` se conserva al instalar sin la opción; cambia un `daily` anterior una
vez con `bash install.sh --apt-upgrade 6h --claude-update 6h`.

**`claude update`.** Mismas reglas que las actualizaciones de paquetes (`CLAUDE_UPDATE=6h|<N>h|daily|always|off`, por defecto
`6h`): el inicio de la sesión ejecuta `claude update` como máximo una vez cada 6 h tras un éxito (marca
`/var/lib/termux-rootbridge/claude-update-last-success` en el invitado). Una actualización fallida o interrumpida no
deja marca, muestra un aviso y Claude Code arranca igualmente; el siguiente arranque lo intenta de nuevo. Con el valor por defecto,
Claude Code puede ir hasta 6 horas por detrás de la última versión. `bash install.sh --no-claude-update` lo desactiva y
`--claude-update always` lo ejecuta en cada arranque (se guarda en la configuración de Termux como `CLAUDE_UPDATE`, de
modo que las instalaciones posteriores lo conservan, también con un invitado nuevo). Un `claude update` que ejecutes a
mano no crea la marca.

**Colores y tema.** El instalador no escribe ningún archivo de colores. La compilación E-Paper de Termux
(`epaper-dev/termux`) trae un esquema claro y uno oscuro y sigue el modo claro/oscuro del teléfono, así que el terminal es
claro en modo claro y oscuro en modo oscuro sin ningún archivo; `~/.termux/colors-light.properties`, `colors-dark.properties`
y `colors.properties` solo lo sobrescriben. Los archivos de colores que instalaron versiones anteriores (`colors.properties`
con la paleta clara, `colors-light.properties`) se eliminan si siguen exactamente como se instalaron, porque taparían el
esquema integrado; un archivo que hayas cambiado se conserva. `--no-colors` no toca los archivos de colores ni el tema de
Claude Code. El instalador configura `"theme": "custom:epaper"` en el archivo `~/.claude/settings.json` del invitado (las
demás claves se mantienen) y crea el tema **Auto epaper** (`~/.claude/themes/epaper.json`, basado en `light-ansi`, los 16 colores del esquema de Termux;
tu propio archivo se mantiene). La opción `auto` de Claude Code solo elige entre `light` o `dark`, así que Termux notifica
un cambio entre claro y oscuro (DECSET 2031) a tmux, cuyos hooks `client-light-theme` / `client-dark-theme` ejecutan
`rootbridge theme light|dark`: esto cambia el tema base entre `light-ansi` y `dark-ansi` (o
`light-daltonized`/`dark-daltonized`, `light`/`dark` si lo has configurado así). Una sesión
de Claude Code en marcha recoge el archivo de tema modificado y cambia los colores en directo (confirmado en el
dispositivo, sin reiniciar). `THEME_RESTART=on` en `~/.config/termux-rootbridge/config` es solo un recurso para una
versión que no lo haga: reinicia Claude Code con `--continue` (se interrumpe cualquier respuesta en curso).
`THEME_FOLLOW=off` desactiva los hooks. Puedes elegir otro tema en cualquier momento con `/theme`. Cada nueva shell interactiva de Termux ejecuta `termux-reload-settings`, y
también los accesos directos de Termux:Widget antes de conectarse. Otras compilaciones de Termux no traen un esquema claro;
allí copia un esquema a `~/.termux/colors.properties`.

**Nombre fijo en la vista Remote Control** (claude.ai/code): `bash install.sh --remote-name android`. **En un
dispositivo nuevo** (o tras borrar Termux) pasa la opción en la primera instalación, porque aún no hay una
configuración de Termux que pueda recordar el nombre. Después queda guardado allí (`REMOTE_NAME`), así que cada
instalación posterior lo reutiliza sin la opción (también con un invitado nuevo o tras `uninstall.sh`), y el instalador
del invitado escribe `CLAUDE_ARGS="--remote-control android --continue"`. `--remote-control NOMBRE` activa Remote
Control y titula la sesión en la vista Remote Control. Esa sesión de Remote Control se reutiliza tras reinicios y
`/clear` y conserva su nombre, también uno puesto con `/rename`. Para otro nombre basta un único `/rename NOMBRE`.
A propósito no hay `--name`: mostraría el nombre además en el marco del campo de entrada de la ventana de Claude Code.

## Codex junto a Claude Code

`install.sh` instala por defecto **Codex** (el agente de programación de OpenAI) junto a Claude Code. `--no-codex` lo
omite solo en esa ejecución. Una ejecución posterior sin esa opción restaura Codex, su acceso directo de Termux, su widget
y, con Claude Code, el hook de revisión, aunque estuviera guardado `TOOL_CODEX=off`.
`--no-claude` te deja solo Codex: sin Claude Code, sin Managed Settings, sin hooks, sin plugin (la guardia, el plugin
y la revisión previa al commit viven dentro de Claude Code); siempre queda al menos una de las dos herramientas.
La elección de Claude se conserva para instalaciones posteriores (`TOOL_CLAUDE`, se reactiva con `--claude`). `TOOL_CODEX`
guarda la selección actual para los lanzadores. Para restaurar una instalación existente ahora, ejecuta
`bash install.sh --codex` y después `source ~/.bashrc` en Termux o abre una ventana nueva.

* **Instalación.** En el invitado: `git`, `bubblewrap` (`bwrap`) y, con ambas herramientas, `nodejs` con `apt` (el plugin
  necesita Node.js 18.18 o superior), Codex con el instalador autónomo oficial (`chatgpt.com/codex/install.sh`, no
  interactivo, en `~/.local/bin`). El instalador escribe los hooks y declara el plugin en los Managed Settings
  (`extraKnownMarketplaces` con la fuente HTTPS y `enabledPlugins`), sin ejecutar `claude plugin …`.
  Claude Code descarga `codex@openai-codex` al arrancar; necesita red. Si aún no está activo, consulta `/plugin` y ejecuta
  `/reload-plugins` o reinicia Claude Code. El hook previo al commit bloquea los commits hasta que el plugin esté listo.
  Una segunda ejecución no usa la red si ya están los requisitos; instala `bwrap` si falta aunque Codex ya esté instalado.
  `--no-codex`, `--no-claude` y la desinstalación eliminan esta declaración y conservan las de otros plugins.
* **Widget «Codex»** y `rootbridge attach codex`: una segunda ventana en la misma sesión de tmux. Codex arranca con sus
  valores por defecto (su sandbox y sus preguntas de aprobación), **no** en un modo bypass; `CODEX_ARGS` en
  `/etc/termux-rootbridge.conf` añade opciones. El hook `android-root-guard` solo protege a Claude Code; `androidsu` sigue
  negándose sin ticket, y los tickets solo los emite ese hook.
* **Inicio de sesión.** `rootbridge codex-login` ejecuta `codex login` con el traspaso al navegador (`--device-auth` si no
  hay navegador). `rootbridge status` muestra si Codex, su inicio de sesión, el plugin y el hook están en su sitio.
* **Ambos se mantienen al día.** Al arrancar cualquiera de las dos ventanas se ejecuta `rootbridge-apt` y luego
  `rootbridge-update`: `claude update` y `codex update`, cada uno como mucho una vez cada 6 h
  tras un éxito (`CLAUDE_UPDATE` / `CODEX_UPDATE` = `6h|<N>h|daily|always|off`, marcas en `/var/lib/termux-rootbridge/`;
  `--codex-update M`, `--no-codex-update`). Si dos sesiones arrancan a la vez, esperan su turno (bloqueo), y un paso fallido
  nunca detiene el arranque. `nodejs` y `git` son paquetes de `apt`, así que `rootbridge-apt` los mantiene al día.
* **Actualizar el plugin manualmente.** El arranque no actualiza automáticamente el marketplace ni el plugin. Cuando sea
  necesario, ejecuta `/root/.local/bin/claude plugin marketplace update openai-codex` y después
  `/root/.local/bin/claude plugin update codex@openai-codex` en Ubuntu y reinicia Claude Code.
* **Revisión antes del commit.** Con ambas herramientas, un hook de los Managed Settings (`codex-precommit-review.py`,
  tiempo límite 1560 s, `onFailure: "block"`) hace que Codex revise cada `git commit` de Claude Code. Una primera línea `ALLOW`
  deja pasar el commit; `BLOCK`, o ninguna respuesta clara, lo detiene y entrega los hallazgos de Codex a Claude, que los
  corrige y vuelve a hacer commit. Es un bucle estricto: tras un `BLOCK` el mismo diff nunca pasa, solo un diff modificado
  que Codex apruebe después; un diff aprobado se recuerda. Falla cerrado: sin inicio de sesión de Codex, plugin o `node`, o
  si Codex o `git` falla, el commit se bloquea. Interruptor de emergencia, solo para ti: `rootbridge codex-off` / `codex-on`
  (reinicia Claude Code) o `CODEX_PRECOMMIT=off` en el entorno con el que arranca Claude Code. **Mientras no hayas iniciado
  sesión en Codex, todos los commits de Claude Code quedan bloqueados.** El hook descompone el comando como una shell y revisa un `git commit` que se ejecuta (también tras `cd`, con
  `git -C`, tras `sudo` / `env` / `time`, dentro de `bash -c '…'` y `$(…)`); el texto entre comillas o en heredocs no cuenta.
  No reconoce alias de git (`git ci`) ni scripts que hacen commit, y la revisión mira todo el árbol de trabajo
  (staged y unstaged, cambios binarios incluidos) y, si el mismo comando ejecuta `git add`, los archivos sin seguimiento
  que puede incorporar (no aparecen en ningún diff).
  Codex solo bloquea por gravedad alta (un fallo que rompe algo, una vulnerabilidad, un secreto, pérdida de datos, un
  error silenciado); lo menor llega como notas tras `ALLOW`. La revisión ve el árbol de trabajo tal como está al empezar
  el comando: lo que el mismo comando cambia antes del commit (`sed -i … && git commit -a`, un script de compilación) no
  queda cubierto.
  Codex revisa con esfuerzo `high` dentro de un presupuesto de 1500 s desde el inicio del hook (el tiempo límite del hook,
  1560 s, queda por encima, porque el corte propio de Claude Code termina un hook sin veredicto). Cada llamada a `git` tiene
  un límite de tiempo y de tamaño, el registro es privado (0600), se rota y no contiene argumentos de comandos, y lo que
  llega a Claude se limpia de caracteres de control, se acorta y se marca como texto ajeno. Por dispositivo, el entorno con
  el que arranca Claude Code puede fijar `CODEX_PRECOMMIT_TIMEOUT_S` (60-3000), `CODEX_PRECOMMIT_ATTEMPTS` (1-5),
  `CODEX_PRECOMMIT_GIT_TIMEOUT_S` (1-300) y `CODEX_PRECOMMIT_EFFORT` (`none` a `xhigh`); sube el tiempo límite del hook en
  los Managed Settings junto con el presupuesto.
* **Datos.** El diff y lo que Codex lea en el árbol de trabajo van a OpenAI, con la cuenta con la que iniciaste sesión. El
  sandbox de Codex restringe la escritura, no la lectura: puede leer más del invitado que el repositorio.

## Uso diario

| Comando (Termux) | Qué hace |
|---|---|
| `rootbridge start` | daemon + sesión; `--no-attach` la crea en segundo plano (Termux:Boot lo ejecuta tras un reinicio) |
| `claude` / `rootbridge attach claude` | abrir la sesión de Claude Code o conectarse a la sesión activa (widget **Claude**) |
| `claude -n` / `claude --new` | iniciar una conversación nueva de Claude en una ventana separada |
| `codex` / `rootbridge attach codex` | conectarse a la ventana de Codex (widget **Codex**; la sesión se crea si falta) |
| `ubuntu` / `rootbridge shell` | shell Ubuntu simple en este terminal (inicia el daemon para `androidsu`, pero no Claude Code ni una sesión de tmux; widget «Ubuntu») |
| `rootbridge attach` | abrir la herramienta predeterminada: Claude Code, o Codex si Claude Code no está instalado |
| `rootbridge status` | daemon, sesión, instalación en el invitado, últimas líneas de auditoría |
| `rootbridge login <server>` | `claude mcp login <server>` con traspaso al navegador |
| `rootbridge codex-login` | `codex login` con traspaso al navegador (`--device-auth` sin navegador) |
| `rootbridge stop` | detener sesión y daemon |
| `rootbridge guard-off` / `guard-on` | interruptor de emergencia para los hooks |
| `rootbridge codex-off` / `codex-on` | interruptor de emergencia de la revisión previa al commit de Codex (reinicia Claude Code) |
| `ptt start` / `stop` / `toggle` / `status` | pulsar para hablar: pulsa una tecla en la ventana de Claude Code para `/voice` (ver abajo) |
| `rootbridge voice start\|stop\|status\|grant` | PulseAudio y micrófono para `/voice`; `grant` da a Termux el permiso de micrófono de Android (root) |

Dentro de Claude Code no cambia nada: pide lo que quieras. Cuando Claude necesita root, ejecuta
`androidsu '<comando>'` y aparece una confirmación que muestra exactamente ese comando. Cada decisión queda en
`~/.rootbridge/audit.log`.

### Dictado por voz (`/voice`) y pulsar para hablar

Activado por defecto; `--no-voice` lo omite (se guarda como `VOICE`, una reinstalación conserva la elección). Necesita Claude Code. El instalador prepara:

* **`sox`** en el invitado (`rec`, con el que graba Claude Code) y **PulseAudio** en Termux. PulseAudio escucha solo en `127.0.0.1`, admite un cliente solo con su cookie
  (privada de Termux; el invitado recibe `PULSE_COOKIE`) y lleva el micrófono del teléfono (`~/.config/pulse/default.pa`: el archivo propio de Termux más la fuente del micrófono y 200 % de ganancia, porque la
  fuente «reconocimiento de voz» de Android suena baja). Arranca con la sesión (`rootbridge start` / `attach`); un `default.pa` propio se conserva.
* **Ajustes de Claude Code**: `~/.claude/keybindings.json` recibe `meta+k` = `voice:pushToTalk` y `~/.claude/settings.json` recibe
  `"voice": {"enabled": true, "mode": "hold"}`. Ambos solo donde aún no has decidido nada (una asignación existente de la acción o un valor `voice` se conservan).
* **`ptt`**: `ptt start` pulsa la tecla por ti, `ptt stop` la suelta. En el modo `hold` (por defecto) repite Alt+K cada 50 ms, como una tecla
  mantenida, de modo que solo tu propio `stop` termina la grabación (un teclado en pantalla no puede mantener una tecla). Sin parada, las
  repeticiones terminan tras `PTT_MAX` segundos (120). `ptt` solo pulsa una tecla en una ventana de tmux (`PTT_TARGET`, por defecto
  `ubuntu:claude`; `PTT_KEY`, por defecto `M-k`) y sirve para cualquier programa que escuche una tecla.
* **Permiso de micrófono de Android** para Termux (un permiso en tiempo de ejecución: desaparece con cada nueva instalación de la app; las apps de Termux comparten
  un id de usuario y solo la **app Termux:API** declara `RECORD_AUDIO`, así que debe estar instalada). Necesita root:
  en un terminal el instalador lo pide (el gestor de root pregunta) y lo omite si el micrófono ya funciona; en una ejecución por script solo muestra
  el aviso. `rootbridge voice grant` lo concede en cualquier momento, `rootbridge voice status` muestra PulseAudio y el micrófono,
  `rootbridge voice start|stop` controlan el servidor de audio a mano.

**Tecla lateral del Hisense A9** (`--sidekey`, desactivada por defecto, se guarda como `SIDEKEY`): mantener la tecla lateral = grabar, soltar = parar. El instalador coloca
`sidekey-ptt` en `$PREFIX/bin`; mantiene un `cat` de root sobre `/dev/input/event2` (la tecla, código 766) y llama a `ptt start` / `ptt stop`.
La pulsación corta y la doble siguen con la app E-Ink; ajusta su pulsación larga a «Nothing». `rootbridge start|attach` arrancan el lector (una instancia),
`--no-sidekey` lo elimina. Es un puente hasta que la app E-Ink y la app de Termux lo hagan por sí mismas.

## Inicios de sesión y enlaces MCP

Versión corta (detalles y solución de problemas: [docs/LOGIN.md](docs/LOGIN.md)):

* En un cuadro de inicio de sesión pulsa **`c`**: Claude Code copia el enlace al portapapeles de Android (necesita los
  ajustes de tmux que añade el instalador).
* `/login`, `/mcp` y `claude mcp login` **abren el navegador por sí solos**.
* Para los conectores de claude.ai (herramientas `authenticate`), un hook abre el enlace y Claude imprime una nota de
  una línea en lugar de la URL larga. `AUTH_OPEN=copy` solo copia, `AUTH_OPEN=off` lo desactiva.

## Configuración

Termux: `~/.config/termux-rootbridge/config` (se interpreta como datos, nunca se ejecuta): `DISTRO`, `WORKDIR`,
`SESSION`, `TICKET_TTL`, `SU_ARGS` (`-c` o `-mm -c`), `AUTOSTART_DELAY`, `REMOTE_NAME`, `APT_UPGRADE`, `CLAUDE_UPDATE`, `CODEX_UPDATE`, `TOOL_CLAUDE` y `TOOL_CODEX`
(todos los lee `install.sh`).
Invitado: `/etc/termux-rootbridge.conf`: `BRIDGE_DIR`, `TICKET_TTL`, `WORKDIR`, `AUTH_OPEN`, `AUTH_REPLACE_OUTPUT`,
`TTY_CONFIRM`, `PROTECTED_PATHS`, `CLAUDE_ARGS`, `APT_UPGRADE` (`6h`, `<N>h`, `daily`, `always`, `off`), `APT_TIMEOUT` (segundos para
la actualización, por defecto 1800), `APT_HOLD` (paquetes retenidos en la actualización), `CLAUDE_UPDATE` (`6h`, `<N>h`,
`daily`, `always`, `off`), `CODEX_UPDATE` (mismos valores), `CODEX_ARGS` (argumentos adicionales para Codex), `CODEX_PRECOMMIT` (`off` = sin revisión previa al commit, lo pone `rootbridge codex-off`), `TOOL_CLAUDE` / `TOOL_CODEX` (`on` / `off`), `NOFILE_LIMIT` (ver abajo). `VOICE` / `SIDEKEY` (`on` / `off`). Solo en la configuración de Termux: `PTT_TARGET`, `PTT_KEY`, `PTT_MODE` (`hold` / `tap`), `PTT_INTERVAL` (ms), `PTT_MAX` (s), ver `ptt help`.

`NOFILE_LIMIT` (por defecto `2048`, `0` = dejar el límite como está) es el límite de descriptores de archivo con el que
se inicia Claude Code. Claude Code cierra todos los descriptores hasta ese límite tras cada fork, y bajo proot cada
`close()` es una llamada al sistema interceptada, así que el valor por defecto de Android (32768) añadía de 2,5 a 4 s a
cada proceso iniciado: cada hook y cada llamada a una herramienta tardaba de 4 a 9 s en lugar de bastante menos de un
segundo. `rootbridge-claude` y la función `claude()` lo reducen solo para Claude (nunca lo aumentan); la shell que lo
rodea conserva el suyo.

`CLAUDE_ARGS` en el archivo del invitado contiene argumentos adicionales para el inicio de la sesión
(`rootbridge-claude`), p. ej. `CLAUDE_ARGS="--remote-control android --continue"` para mostrar la sesión como
«android» en la vista Remote Control y reanudar la última sesión (`install.sh --remote-name` escribe y actualiza esta
línea; los demás argumentos que contenga se mantienen). La función de shell `claude()` solo lee de ella el nombre de
Remote Control (nunca `--continue`) y lo omite para `-p`, `--version` y `--help`.

## Qué está verificado

| Verificado con pruebas automáticas | Pendiente de comprobar en un dispositivo real |
|---|---|
| Decisiones de la guardia (43 pruebas): vínculo del ticket, llamadas indirectas, protección contra manipulación, fail-closed | Forma de `tool_response` de las herramientas de inicio de sesión MCP; `updatedToolOutput` |
| Daemon: ticket de un solo uso/caducidad/hash, comandos largos, validación de URL (49 comprobaciones) | — |
| Hook de inicio de sesión (19 pruebas: formas de respuesta, reglas de URL, modos) | — |
| Instaladores: raíz de staging, idempotencia, migración de la v1, desinstalación | — |
| Codex junto a Claude Code: opciones de instalación y la elección guardada, pasos de actualización con marcas y bloqueo, ventanas de tmux, `codex-login` / `codex-off` / `status`, el bucle de revisión previa al commit (`node` simulado) | `codex-login` y el widget **Codex** en un dispositivo; `claude plugin update`, `codex update` y `onFailure: "block"` tras un fallo del hook; `bwrap` en otros dispositivos |
| Voz y tecla lateral: opciones del instalador y la elección guardada, `default.pa` (la nuestra, la tuya, actualización con copia), `rootbridge voice`, ajustes y asignación de teclas en el invitado sin sobrescribir las tuyas, `sox` solo con Claude Code, desinstalación (stubs de `pulseaudio` / `pactl` / `su` / `pkg`) | el micrófono con hardware real, `pm grant` con root real (aviso de Magisk), `sidekey-ptt` con la tecla real, el permiso de micrófono tras una nueva instalación de Termux |

Confirmado en un dispositivo (Hisense A9, 04/11/2026): instalador, colores y tema, actualización de apt,
`claude update`, límite de descriptores de archivo, widgets, fin de la sesión con `/exit`, la confirmación de root en modo bypass (el hook preguntó en Claude Code y `androidsu` solo
se ejecutó tras la respuesta), un `/login` completo con la redirección automática a `localhost` (sin código que pegar), apertura del navegador desde
el invitado y copia de enlaces al portapapeles de Android (`--copy-only` mediante el daemon y la tecla `c` a través de
tmux).

Ejecutar las pruebas: `python3 -I -m unittest discover -s tests && bash tests/test_daemon.sh`.

## Límites

Esto protege contra acciones **involuntarias**, no contra un agente hostil: el root del invitado comparte el home de
Termux con el daemon. Consulta [SECURITY.md](SECURITY.md) para la lista honesta.

## Desinstalación

```bash
bash uninstall.sh      # conserva ~/.rootbridge (registro de auditoría, copias de seguridad) y la configuración
```

Elimina los widgets (también **Codex**), los programas y los hooks, la revisión previa al commit de Codex incluida. Codex
en sí, su inicio de sesión (`~/.codex`) y el plugin permanecen en el invitado.

## Proyectos relacionados y créditos

Otras formas de llevar Claude Code a Android: resuelven la *instalación*, este proyecto resuelve la *confirmación de
root, el arranque y los inicios de sesión* por encima de ella:
[bd-loser/claude-code-termux](https://github.com/bd-loser/claude-code-termux),
[ferrumclaudepilgrim/claude-code-android](https://github.com/ferrumclaudepilgrim/claude-code-android),
[Crypt0Shmipt0/root-aicli](https://github.com/Crypt0Shmipt0/root-aicli). Detalles en
[docs/COMPARISON.md](docs/COMPARISON.md). Sin afiliación con Anthropic.

## Licencia

[MIT](LICENSE).
