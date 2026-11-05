# termux-root-bridge

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
  el invitado (`curl -fsSL https://claude.ai/install.sh | bash`)
* Un `su` que funcione (Magisk, KernelSU, ...); sin él, solo funcionan las funciones de inicio de sesión
* Paquetes de Termux: `tmux proot-distro python coreutils util-linux`; opcional `termux-api` (+ la app Termux:API)
  para el portapapeles
* Paquetes del invitado: `python3` (hooks), coreutils con `sha256sum`, `od`, `timeout`
* Claude Code ≥ 2.1.295 (`onFailure: "block"` para los hooks)

## Instalación

En una shell de **Termux** (no dentro de proot):

```bash
pkg install git tmux proot-distro python coreutils util-linux termux-api
git clone https://github.com/hisense-a9/termux-root-bridge
cd termux-root-bridge
bash install.sh            # hace una pregunta sobre el modo autónomo
```

**En un dispositivo nuevo** (Termux recién instalado, sin Ubuntu) deja que el instalador prepare todo lo necesario:

```bash
pkg install -y git
git clone https://github.com/hisense-a9/termux-root-bridge
cd termux-root-bridge
bash install.sh --setup --autonomous no
```

`--setup` instala los paquetes de Termux que faltan (`pkg install`), el invitado Ubuntu si no hay ninguno (`proot-distro
install`, una descarga de unos cientos de MB), `python3`, `curl` y los certificados en el invitado, y Claude Code con el
instalador oficial. No hace preguntas (la del modo autónomo la responde `--autonomous`) y se puede repetir tras un fallo.
Sigue siendo manual: la autorización de root para Termux (tu gestor de root pregunta en la primera petición), abrir
Termux:Boot una vez, poner el widget **Claude** en la pantalla de inicio y el inicio de sesión de Claude (`/login`; el
navegador se abre solo). Sin `--setup` el instalador no cambia nada de esto y solo indica lo que falta.

Después inicia Claude Code con el widget **Claude**, o escribe `ubuntu` (alias de `rootbridge attach`) en una shell de
Termux. El primer arranque crea la sesión: inicia el daemon, actualiza los paquetes del invitado (`apt-get update` +
`upgrade`, como máximo una vez al día, ver abajo), ejecuta `claude update` (también como máximo una vez al día) e
inicia Claude Code; los arranques posteriores solo se conectan a ella.
**Las ventanas normales de Termux siguen siendo shells simples** (con los colores cargados): nada se inicia solo. Con
Termux:Boot la sesión se crea en segundo plano tras un reinicio (`rootbridge start --no-attach`). Claude sigue
**arrancando en modo plan** (según tu `settings.json`); pulsa **Shift+Tab** para cambiar a *bypass permissions* (en un
teléfono, con la tecla **S-TAB** que el instalador añade a la fila de teclas extra de Termux, ver abajo).

Opciones: `--setup`, `--no-guest`, `--no-boot`, `--no-migrate`, `--no-colors`, `--no-widgets`, `--no-extra-keys`, `--autonomous yes|no|ask`,
`--remote-name NAME`, `--apt-upgrade daily|always|off`, `--no-apt-upgrade`, `--claude-update daily|always|off`,
`--no-claude-update`. El instalador es idempotente, hace copia de seguridad de lo que modifica y migra el antiguo puente
con ventana emergente de la v1 si lo encuentra.

**Widgets.** Con la app Termux:Widget tienes dos accesos directos: **Claude** (conectarse a la sesión de Claude Code) y
**Ubuntu** (una shell Ubuntu simple). El instalador los coloca en `~/.shortcuts` junto con iconos neutros `>_`
(`~/.shortcuts/icons/<nombre>.png`, sin logotipos; se regeneran con `tools/make-shortcut-icons.py`). Un icono que ya
existe nunca se reemplaza, así que puedes poner allí tu propio PNG; con los nombres anteriores («Claude Code» /
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
`rootbridge-apt` ejecuta `apt-get update` y `apt-get -y upgrade`, como máximo una vez cada 24 h tras un éxito
(`APT_UPGRADE=daily`), y nunca bloquea el arranque (sin red, un error o un tiempo de espera agotado solo muestran un
aviso y Claude Code arranca; el siguiente arranque lo intenta de nuevo). Dos salvaguardas importan en proot-distro con
Ubuntu 26.04: dpkg recibe `-o DPkg::Path` incluyendo `/usr/local/bin`, porque los coreutils de uutils necesitan allí los
enlaces simbólicos con nombres GNU (si no, los scripts de mantenimiento abortan con «Security violation»), y los
paquetes de coreutils (`APT_HOLD`) se mantienen retenidos, porque actualizar el propio binario multicall rompe el
invitado. Registro: `/var/log/termux-root-bridge-apt.log` en el invitado; cada ejecución termina con una línea
`Ende: ok` (o el motivo), y una ejecución sin ella fue interrumpida; paquetes retenidos: `apt-mark showhold`. Se
desactiva con `bash install.sh --no-apt-upgrade` (se guarda en la configuración de Termux como `APT_UPGRADE`, de modo
que las instalaciones posteriores lo conservan, también con un invitado nuevo), o se ejecuta en cada arranque con
`--apt-upgrade always`. A mano: `rootbridge-apt` en el invitado.

**`claude update`.** Mismas reglas que las actualizaciones de paquetes (`CLAUDE_UPDATE=daily|always|off`, por defecto
`daily`): el inicio de la sesión ejecuta `claude update` como máximo una vez cada 24 h tras un éxito (marca
`/var/lib/termux-root-bridge/claude-update-last-success` en el invitado). Una actualización fallida o interrumpida no
deja marca, muestra un aviso y Claude Code arranca igualmente; el siguiente arranque lo intenta de nuevo. Con `daily`,
Claude Code puede ir hasta un día por detrás de la última versión. `bash install.sh --no-claude-update` lo desactiva y
`--claude-update always` lo ejecuta en cada arranque (se guarda en la configuración de Termux como `CLAUDE_UPDATE`, de
modo que las instalaciones posteriores lo conservan, también con un invitado nuevo). Un `claude update` que ejecutes a
mano no crea la marca.

**Colores y tema.** Salvo que pases `--no-colors`, el instalador escribe un esquema de colores claro en
`~/.termux/colors.properties` (tu archivo anterior se conserva como `colors.properties.bak-<marca de tiempo>`) y fija
`"theme": "light-ansi"` en el `~/.claude/settings.json` del invitado (las demás claves se mantienen). La variante ANSI
dibuja con los 16 colores de ese archivo en lugar de valores RGB fijos, lo que se lee mucho mejor en Termux que
`light`; cámbialo cuando quieras con `/theme`. Cada nueva shell interactiva de Termux ejecuta
`termux-reload-settings`, y también los accesos directos de Termux:Widget antes de conectarse, de modo que los colores
están cargados antes de que arranquen `claude update` y Claude Code. Para cambiar el aspecto, edita
`termux/colors.properties` y vuelve a ejecutar `install.sh`.

**Nombre fijo en la vista Remote Control** (claude.ai/code): `bash install.sh --remote-name android`. **En un
dispositivo nuevo** (o tras borrar Termux) pasa la opción en la primera instalación, porque aún no hay una
configuración de Termux que pueda recordar el nombre. Después queda guardado allí (`REMOTE_NAME`), así que cada
instalación posterior lo reutiliza sin la opción (también con un invitado nuevo o tras `uninstall.sh`), y el instalador
del invitado escribe `CLAUDE_ARGS="--remote-control android --continue"`. El nombre pertenece a la *sesión*: una sesión
nueva lo recibe del flag, y `--continue` conserva esa sesión (y su nombre) entre reinicios. Una sesión que ya existe
con otro nombre no se renombra con el flag; renómbrala una vez con `/rename android`.

## Uso diario

| Comando (Termux) | Qué hace |
|---|---|
| `rootbridge start` | daemon + sesión; `--no-attach` la crea en segundo plano (Termux:Boot lo ejecuta tras un reinicio) |
| `rootbridge attach` / alias `ubuntu` | conectarse a la sesión de Claude Code |
| `rootbridge shell` | shell Ubuntu simple en este terminal (inicia el daemon para `androidsu`, pero no Claude Code ni una sesión de tmux; widget «Ubuntu») |
| `rootbridge status` | daemon, sesión, instalación en el invitado, últimas líneas de auditoría |
| `rootbridge login <server>` | `claude mcp login <server>` con traspaso al navegador |
| `rootbridge stop` | detener sesión y daemon |
| `rootbridge guard-off` / `guard-on` | interruptor de emergencia para los hooks |

Dentro de Claude Code no cambia nada: pide lo que quieras. Cuando Claude necesita root, ejecuta
`androidsu '<comando>'` y aparece una confirmación que muestra exactamente ese comando. Cada decisión queda en
`~/.rootbridge/audit.log`.

## Inicios de sesión y enlaces MCP

Versión corta (detalles y solución de problemas: [docs/LOGIN.md](docs/LOGIN.md)):

* En un cuadro de inicio de sesión pulsa **`c`**: Claude Code copia el enlace al portapapeles de Android (necesita los
  ajustes de tmux que añade el instalador).
* `/login`, `/mcp` y `claude mcp login` **abren el navegador por sí solos**.
* Para los conectores de claude.ai (herramientas `authenticate`), un hook abre el enlace y Claude imprime una nota de
  una línea en lugar de la URL larga. `AUTH_OPEN=copy` solo copia, `AUTH_OPEN=off` lo desactiva.

## Configuración

Termux: `~/.config/termux-root-bridge/config` (se interpreta como datos, nunca se ejecuta): `DISTRO`, `WORKDIR`,
`SESSION`, `TICKET_TTL`, `SU_ARGS` (`-c` o `-mm -c`), `AUTOSTART_DELAY`, `REMOTE_NAME`, `APT_UPGRADE` y `CLAUDE_UPDATE`
(todos los lee `install.sh`).
Invitado: `/etc/termux-root-bridge.conf`: `BRIDGE_DIR`, `TICKET_TTL`, `WORKDIR`, `AUTH_OPEN`, `AUTH_REPLACE_OUTPUT`,
`TTY_CONFIRM`, `PROTECTED_PATHS`, `CLAUDE_ARGS`, `APT_UPGRADE` (`daily`, `always`, `off`), `APT_TIMEOUT` (segundos para
la actualización, por defecto 600), `APT_HOLD` (paquetes retenidos en la actualización), `CLAUDE_UPDATE` (`daily`,
`always`, `off`), `NOFILE_LIMIT` (ver abajo).

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

## Proyectos relacionados y créditos

Otras formas de llevar Claude Code a Android: resuelven la *instalación*, este proyecto resuelve la *confirmación de
root, el arranque y los inicios de sesión* por encima de ella:
[bd-loser/claude-code-termux](https://github.com/bd-loser/claude-code-termux),
[ferrumclaudepilgrim/claude-code-android](https://github.com/ferrumclaudepilgrim/claude-code-android),
[Crypt0Shmipt0/root-aicli](https://github.com/Crypt0Shmipt0/root-aicli). Detalles en
[docs/COMPARISON.md](docs/COMPARISON.md). Sin afiliación con Anthropic.

## Licencia

[MIT](LICENSE).
