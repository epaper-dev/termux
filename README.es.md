# termux-root-bridge

[English](README.md) · [Deutsch](README.de.md) · [Español](README.es.md)

Ejecuta un Ubuntu persistente (mediante [proot-distro](https://github.com/termux/proot-distro)) en Termux en el Hisense A9, inícialo y detenlo con un widget, y solicita **comandos reales de root de Android** desde esa sesión de Ubuntu con una confirmación manual consciente para cada solicitud.

Está pensado para todo lo que se desarrolla o ejecuta en un entorno Termux/proot (por ejemplo, agentes de programación con IA como Claude Code) y que ocasionalmente necesita acceso root real al dispositivo (ajustes del sistema, nodos `/sys`, etc.).

## ¿Por qué no usar simplemente `su` desde proot-distro?

No funciona de forma fiable. `proot` intercepta las llamadas al sistema mediante `ptrace`, mientras que el `su` de Magisk se comunica con el demonio `magiskd` mediante su propio mecanismo RPC/socket. Dos capas similares a ptrace entran en conflicto (`write failed: Broken pipe` en una prueba directa). Es una limitación arquitectónica de proot, no un problema de configuración.

## Arquitectura

```
Sesión Ubuntu (proot-distro)           Fuera de proot (Termux normal)
────────────────────────────           ───────────────────────────────
androidsu "<comando>"                  root-bridge-watch.sh (bucle de fondo)
  escribe una solicitud en               detecta una solicitud nueva
  ~/.rootbridge/req-<id>.txt              │
  espera la respuesta                     ▼
                                        tmux display-popup
                                          → root-bridge-confirm.sh <id>
                                             muestra el comando, read -t 10 "y"?
                                             sí  → su -c "<comando>" (root real)
                                             no/tiempo agotado → rechazado
                                             escribe el resultado en
                                             ~/.rootbridge/res-<id>.txt
  lee la respuesta y devuelve
  el código de salida y la salida
```

`su` se ejecuta exclusivamente fuera de proot, nunca dentro. El cliente (`androidsu`, que se ejecuta en proot) no realiza ninguna operación privilegiada; solo maneja archivos. Toda la elevación de privilegios ocurre en un proceso que nunca está bajo la capa ptrace de proot.

**¿Por qué usar `tmux display-popup` en lugar de una segunda ventana de tmux?** Si el único acceso es un interruptor de widget en la pantalla de inicio (sin una forma práctica de cambiar de ventana dentro de tmux), la confirmación aparece como una superposición **directamente sobre la ventana visible**; no hace falta cambiar de ventana.

## Modelo de seguridad

No se crea una nueva frontera de confianza: todo lo que se ejecuta en la sesión de Ubuntu ya tiene permisos completos de la aplicación Termux. La nueva capacidad es poder solicitar acciones reales de root de Android con confirmación manual para cada comando. Cada solicitud muestra el texto exacto del comando, y solo una entrada deliberada de `y` (no Enter ni una entrada vacía) inicia la ejecución. El tiempo agotado se considera un rechazo.

## Instalación

Requisitos: Termux, `proot-distro` con una distribución Ubuntu instalada, `tmux` (≥ 3.2 para `display-popup`) y acceso root (por ejemplo, Magisk) con Termux autorizado como aplicación superusuario.

```sh
mkdir -p ~/bin ~/.shortcuts
cp scripts/ubuntu-toggle.sh scripts/androidsu scripts/root-bridge-watch.sh scripts/root-bridge-confirm.sh ~/bin/
chmod 700 ~/bin/ubuntu-toggle.sh ~/bin/androidsu ~/bin/root-bridge-watch.sh ~/bin/root-bridge-confirm.sh
cp ~/bin/ubuntu-toggle.sh "~/.shortcuts/Ubuntu Toggle"   # para Termux:Widget
```

Añade `androidsu` al PATH dentro de la distribución de proot-distro (el `~/.bashrc` del contenedor, no el de Termux):

```sh
echo 'export PATH="/data/data/com.termux/files/home/bin:$PATH"' >> ~/.bashrc
```

Instala Termux:Widget (por ejemplo desde [GitHub](https://github.com/termux/termux-widget/releases) o F-Droid; debe coincidir con la familia de firmas de tu instalación de Termux) y coloca el widget `Ubuntu Toggle` en la pantalla de inicio.

**Nota:** Los permisos de archivo y el contexto SELinux deben coincidir con el UID de tu aplicación Termux (`id -u` en Termux, categoría SELinux mediante `ls -Z ~`). Los valores exactos varían según la instalación y no están fijados aquí.

## Uso

```sh
# En la pantalla de inicio: toca el widget Ubuntu Toggle (inicia/detiene Ubuntu).
# En la sesión de Ubuntu:
androidsu id
# → Aparece un cuadro emergente; confirma con 'y' + Enter (ventana de 10 segundos)
# → uid=0(root) gid=0(root) ...
```

## Referencia / inspiración

[hisense-a9/PatchingService](https://github.com/hisense-a9/PatchingService) demuestra que la IPC entre proot y un proceso root es posible en principio (allí, un demonio nativo usa un socket Unix abstracto para comandos de control de E Ink). Este proyecto utiliza el sondeo de archivos en lugar de un socket por simplicidad; para un caso de uso ocasional y confirmado manualmente, la diferencia de latencia es irrelevante.
