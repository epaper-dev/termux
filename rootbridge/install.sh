#!/usr/bin/env bash
# install.sh - termux-rootbridge v2 installer. Run it in a TERMUX shell
# (not inside proot): the daemon needs real `su` outside proot.
#
#   bash install.sh [--no-guest] [--no-boot] [--no-migrate] [--no-colors] [--no-widgets]
#                   [--autonomous yes|no|ask] [--no-deps-check] [--remote-name NAME] [--no-extra-keys]
#                   [--apt-upgrade 6h|<N>h|daily|always|off | --no-apt-upgrade]
#                   [--claude-update 6h|<N>h|daily|always|off | --no-claude-update] [--no-setup]
#                   [--model NAME|none] [--claude | --no-claude] [--codex | --no-codex]
#                   [--codex-update 6h|<N>h|daily|always|off | --no-codex-update] [--codex-bypass | --no-codex-bypass]
#                   [--opencode | --no-opencode] [--opencode-update 6h|<N>h|daily|always|off | --no-opencode-update]
#                   [--reviewers codex|opencode|codex,opencode] [--guidelines | --no-guidelines]
#                   [--voice | --no-voice] [--speak | --no-speak] [--sidekey | --no-sidekey] [--home-key | --no-home-key]
#                   [--headset | --no-headset] [--phantom-killer-off | --phantom-killer-on] [--language de|en]
#                   [--device ID|none] [--distro ubuntu|debian]
#
# Questions: all of them come first, before anything is installed; then the installation runs through. On a terminal each
# one is asked once (Claude Code, Codex, the language, reading aloud, dictation, the device name for Claude Remote Control,
# the keys for push to talk, Android's
# phantom process killer); the answer is stored in the Termux config, and its option changes it later (--remote-name NAME,
# --claude/--no-claude, ...). Enter takes the suggestion. Without a terminal nothing is asked.
# Phone storage: without access to /sdcard the installer runs termux-setup-storage first (Android asks). A backup in
# /sdcard/backup/termux (rootbridge backup) on a fresh installation is offered with the questions and restored at the end
# by rootbridge restore.
# Missing components are installed automatically: the Termux packages
#   (pkg install), the Ubuntu guest (proot-distro install, a download of a few hundred MB),
#   python3/curl/certificates in the guest and Claude Code (official installer). A device that has it
#   all just gets the normal installation. --no-setup only checks and tells you what is missing
#   (--no-deps-check skips the package part, --no-guest the guest part). --setup is still accepted and
#   changes nothing. Still manual afterwards: the root grant, Termux:Boot once, the widget on the home
#   screen, the Claude login.
#
# --autonomous yes|no|ask: yes (default) sets skipDangerousModePermissionPrompt in the guest, so Claude
#   Code shows no warning dialog for bypass mode, and makes bypass mode the start mode
#   (permissions.defaultMode = bypassPermissions, only if settings.json has no default mode yet).
#   Every Android-root command still asks. no leaves both settings alone (an earlier value stays),
#   ask asks on a terminal.
#
# --model NAME|none: model in the guest's ~/.claude/settings.json. Default "opusplan" (Opus plans,
#   Sonnet works), written only if settings.json has no model yet; --model always writes it, none
#   leaves the model alone.
#
# --no-claude / --no-codex: leave one of the two tools out (Codex only, or Claude Code only; at least one stays).
#   Both are part of the installation by default: Claude Code (widget "Claude") and Codex (widget "Codex"), and each
#   one starts with the update of the other (rootbridge-update), because the two review each other: the Codex plugin
#   of Claude Code and a pre-commit review hook (Codex checks every `git commit` Claude Code makes; the strict loop,
#   fail-closed, emergency switch `rootbridge codex-off`). Without Claude Code there is no plugin and no hook.
#   Both choices are asked once on a terminal and stored (TOOL_CLAUDE, TOOL_CODEX); --claude / --codex turn one on
#   again. --codex-update sets how often `codex update` runs at the start of a
#   session (6h default, like --claude-update; stored as CODEX_UPDATE). Still manual: the Codex login,
#   `rootbridge codex-login`.
#
# --codex-bypass / --no-codex-bypass: Codex without its own sandbox, on by default (needs Codex). Under proot the bubblewrap
#   sandbox of Codex fails on every command ("unsupported host mount"), so Codex would not run at all. The installer sets
#   CODEX_ARGS="--dangerously-bypass-approvals-and-sandbox" in the guest config (your other arguments stay).
#   --no-codex-bypass removes the flag again. The choice is stored (CODEX_BYPASS). Android root stays closed either way: the
#   Termux daemon asks you in an Android dialog for every request, and the managed hook rootbridge-hook.py
#   (/etc/codex/requirements.toml, no /hooks review needed; an /etc/codex/requirements.toml of your own stays untouched)
#   tells Codex when you said no.
# --opencode / --no-opencode: OpenCode as a third tool, off by default (widget "OpenCode", `opencode`, its own session).
#   Asked once on a terminal and stored (TOOL_OPENCODE); the login is /connect in the OpenCode window. --opencode-update
#   sets how often `opencode upgrade` runs at the start of a session (6h default; stored as OPENCODE_UPDATE).
# --reviewers codex|opencode|codex,opencode: who reviews every `git commit` of Claude Code (with both, each one must say
#   ALLOW). Asked once when Claude Code, Codex and OpenCode are all installed, stored as REVIEWERS; default codex. Only
#   tools of the installation review: without Codex it is OpenCode. Emergency switch: `rootbridge review-off`.
# --guidelines / --no-guidelines: code quality guidelines for the agents, on by default: a marked block in the guest's
#   ~/.claude/CLAUDE.md (with Claude Code), ~/.codex/AGENTS.md (with Codex) and ~/.config/opencode/AGENTS.md (with
#   OpenCode); your own text in those files stays and
#   --no-guidelines removes the blocks again. The choice is stored (GUIDELINES).
# --voice / --no-voice: voice dictation for Claude Code's /voice, on by default (needs Claude Code). The installer sets up sox in
#   the guest (rec), PulseAudio in Termux (127.0.0.1 only, with the microphone source and 200 % gain, started with the session),
#   the guest's ~/.claude/keybindings.json (meta+k = voice:pushToTalk) and "voice": {"enabled": true, "mode": "tap"} in
#   ~/.claude/settings.json (both only where you have not decided yet), and `ptt` (start / stop). Android's microphone
#   permission for Termux needs root: on a terminal the installer asks for it (the root manager prompts), otherwise run
#   `rootbridge voice grant` once. The choice is stored in the Termux config (VOICE).
# --speak / --no-speak: reading Claude's answers aloud, on by default (needs Claude Code), asked apart from --voice: PulseAudio
#   in Termux and sox in the guest (it plays), Piper with the voice de_DE-kerstin-medium in the guest (/opt/piper) and
#   Articulino for your own voice (/opt/articulino; record it in the guest: rootbridge-speak --record), a Stop hook that reads
#   Claude's answers (without code, tables and URLs) one after another and pauses while you speak (`ptt start`, /voice), the
#   voice commands ("Welche Sprachbefehle gibt es"), `rootbridge voice speak on|off|toggle|stop` and the widgets "Vorlesen"
#   (on/off) and "Stopp" in ~/.shortcuts/tasks. Stored as SPEAK; a config from before it follows VOICE.
# --sidekey / --no-sidekey: the side key of the Hisense A9 as push to talk (hold = record, release = stop): installs sidekey-ptt,
#   which keeps a root `cat` on /dev/input/event2 running, and starts it with the session. Off by default, stored as SIDEKEY.
#   Set the long press of the E-Ink app to "Nothing". A bridge until the E-Ink app does it itself.
# --home-key / --no-home-key: a long press on Home starts and stops push to talk: the installer makes Termux the digital
#   assistant (root, `rootbridge voice assistant on`), on every run on a terminal ("Force stop" in the app info takes the role
#   away). Needs the Termux app of this repository (Termux push to talk). Stored as HOMEKEY; --no-home-key takes the role back.
# --headset / --no-headset: a long press on the key of a wired headset starts and stops push to talk: installs headset-ptt,
#   which reads the key as root. Stored as HEADSET.
# Keys nobody decided yet (no option, nothing in the config) are asked on a terminal, one question each; the answer is stored.
# --language de|en: the language of Claude Code ("language" in its settings.json), of the texts in its CLAUDE.md and of the
#   voice that reads aloud (Piper de_DE-kerstin-medium or en_US-lessac-medium; Articulino reads both). Asked once on a
#   terminal (suggested: the language of the phone, English or else German; also the one without a terminal), stored as
#   LANGUAGE; Claude Code's own setting changes only when you choose in that run.
# --phantom-killer-off / --phantom-killer-on: Android ends child processes of an app beyond 32 ("Trimming phantom processes"),
#   tmux with the sessions among them. Off switches that off as root (`rootbridge phantom-killer off`, on every run on a
#   terminal: an Android update may set it back); on gives Android's defaults back. Asked once (default off), stored as
#   PHANTOM_KILLER. Without root: Developer options, "Disable child process restrictions".
# --device ID|none: the device file devices/ID.conf describes the keys of the device (where the side key and the key of a
#   wired headset are read, how a long press on Home arrives; devices/README.md). The installer looks for the file of the
#   device it runs on (<manufacturer>-<model> from the vendor partition) and asks once whether to use it; stored as DEVICE,
#   installed as device.conf next to the Termux config. The questions about the keys stay; a key the file does not
#   describe is not asked for. Its NAME is the suggestion for the Remote Control name (else the id read from the device).
# --distro ubuntu|debian: the guest (proot-distro). Asked once on a terminal when there is no guest yet (default Ubuntu),
#   stored as DISTRO once the guest is installed. Another one than the installed guest is a switch: the old guest stays
#   (back with --distro and its name; remove it with proot-distro remove NAME), and on a terminal the installer offers to
#   take its settings and logins along (rootbridge backup into /sdcard/backup/termux-NAME, then rootbridge restore, which
#   asks what of it) and the work folder (copied when the new one is empty).
# Performance: before the questions the installer measures cores, clock, memory and free space (`rootbridge perf` shows it
#   again); what does not suit the device is suggested as no (reading aloud).
#
# Claude Code starts in /root/work in the guest (WORKDIR; the installer creates the folder).
#
# What it does (idempotent, with backups):
#   1. installs rootbridge + rootbridge-daemon + ptt (push to talk) into $PREFIX/bin
#   2. config ~/.config/termux-rootbridge/config (the Remote Control name is "android" unless
#      --remote-name NAME says otherwise; NAME is stored there as REMOTE_NAME and reused by every
#      later install), tmux clipboard settings
#   3. colours: no colour file is written (the E-Paper Termux build has the light and the dark scheme built in
#      and follows the phone; ~/.termux/colors-light.properties, colors-dark.properties and colors.properties
#      are optional overrides of yours). Only colour files that earlier versions installed, still exactly as
#      installed, are removed. --no-colors leaves those and the Claude Code theme alone. A ~/.bashrc block
#      (aliases `ubuntu` for the guest shell, `claude` / `codex` for the tool sessions; reloads the Termux settings
#      in every new shell; ordinary Termux windows stay plain shells, Claude Code starts
#      via the widgets, `claude`, `codex` or `rootbridge attach`), the Termux:Widget shortcuts
#      "Claude" and "Ubuntu" with the widget icon (an icon you chose stays; icons of the
#      earlier names "Claude Code" / "Ubuntu Shell" / "Claude >_" / "Ubuntu >_" are carried
#      over; --no-widgets skips all this), optional boot script, an extra keys row in
#      ~/.termux/termux.properties (S-TAB = Shift+Tab, KEYBOARD = soft keyboard on/off; an
#      extra-keys line of your own stays; --no-extra-keys skips it) and volume-keys = volume
#      in the same block (the volume keys change the volume, not CTRL/FN)
#   4. migrates the old popup based bridge (v1) away
#   5. installs the guest part (hooks, androidsu, managed settings, Claude Code
#      theme "Auto epaper" = custom:epaper, colour-blind friendly, follows light/dark) via proot-distro. The guest runs apt-get update + upgrade
#      at the start of the Claude Code session, at most once every 6 h (--apt-upgrade 12h
#      or daily = 24 h changes the distance, --no-apt-upgrade turns it off, --apt-upgrade
#      always runs it at every start; the choice is stored in the Termux config as
#      APT_UPGRADE and reused by every later install). A value already in
#      /etc/termux-rootbridge.conf stays when you run the installer without the option,
#      so switch an older "daily" once with --apt-upgrade 6h --claude-update 6h. `claude
#      update` follows the same rules: every 6 h by default (--claude-update 12h|daily|
#      always, --no-claude-update turns it off; stored as CLAUDE_UPDATE)

set -eu

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
BRIDGE_DIR="${BRIDGE_DIR:-$HOME/.rootbridge}"
STAMP="$(date +%Y%m%d%H%M%S)"
BEGIN='# >>> termux-rootbridge >>>'
END='# <<< termux-rootbridge <<<'

DO_SETUP=1; SETUP_DID=0; DO_GUEST=1; DO_BOOT=1; DO_MIGRATE=1; DO_COLORS=1; DO_WIDGETS=1; DO_EXTRAKEYS=1; DEPS=1; AUTONOMOUS=yes
CLAUDE_THEME=custom:epaper   # "Auto epaper": light-/dark-ansi, switched by the tmux hook (rootbridge theme)
REMOTE_NAME="android"; REMOTE_NAME_SET=0   # default name in the Remote Control view
APT_MODE=""; APT_MODE_SET=0
MODEL=""; MODEL_SET=0
CLAUDE_UPD_MODE=""; CLAUDE_UPD_SET=0
CODEX_UPD_MODE=""; CODEX_UPD_SET=0
OPENCODE_UPD_MODE=""; OPENCODE_UPD_SET=0
USE_OPENCODE=no; USE_OPENCODE_SET=0   # OpenCode, the third tool (off unless chosen)
REVIEWERS=""; REVIEWERS_SET=0         # who reviews the commits of Claude Code: codex | opencode | codex,opencode
USE_CLAUDE=yes; USE_CLAUDE_SET=0; USE_CODEX=yes; USE_CODEX_SET=0   # which tools: yes | no
USE_VOICE=yes; USE_VOICE_SET=0; USE_SIDEKEY=no; USE_SIDEKEY_SET=0   # voice dictation / side key as push to talk
USE_SPEAK=yes; USE_SPEAK_SET=0     # reading Claude's answers aloud
LANGUAGE=""; LANGUAGE_SET=0        # de | en: Claude Code's language, the texts in CLAUDE.md, the voice that reads aloud
USE_HOMEKEY=no; USE_HOMEKEY_SET=0; USE_HEADSET=no; USE_HEADSET_SET=0   # long press on Home / on the headset key as push to talk
HOMEKEY_OFF_OPT=0   # --no-home-key given: the assistant role is taken back in any case
USE_BYPASS=yes; USE_BYPASS_SET=0   # Codex without its own sandbox
USE_GUIDE=yes; USE_GUIDE_SET=0     # code quality guidelines in CLAUDE.md / AGENTS.md
USE_PHANTOM_OFF=no; USE_PHANTOM_OFF_SET=0   # switch Android's phantom process killer off (root)
DEVICE=""; DEVICE_SET=0            # the device file in devices/ (its id) or none
DISTRO=""; DISTRO_SET=0            # the guest: ubuntu | debian
NAME_RE='^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$'
DEVICE_RE='^[a-z0-9][a-z0-9._-]{0,63}$'
APT_RE='^(always|off|daily|[1-9][0-9]{0,2}h)$'
while [ $# -gt 0 ]; do
    case "$1" in
        --setup) DO_SETUP=1 ;;   # the default, kept for older command lines
        --no-setup) DO_SETUP=0 ;;
        --no-guest) DO_GUEST=0 ;;
        --no-boot) DO_BOOT=0 ;;
        --no-migrate) DO_MIGRATE=0 ;;
        --no-colors) DO_COLORS=0 ;;
        --no-widgets) DO_WIDGETS=0 ;;
        --no-extra-keys) DO_EXTRAKEYS=0 ;;
        --no-deps-check) DEPS=0 ;;
        --autonomous) AUTONOMOUS="$2"; shift ;;
        --remote-name)
            [ $# -ge 2 ] || { echo "--remote-name braucht einen Namen" >&2; exit 2; }
            REMOTE_NAME="$2"; REMOTE_NAME_SET=1; shift ;;
        --apt-upgrade)
            [ $# -ge 2 ] || { echo "--apt-upgrade braucht 6h (Stunden), daily, always oder off" >&2; exit 2; }
            APT_MODE="$2"; APT_MODE_SET=1; shift ;;
        --no-apt-upgrade) APT_MODE=off; APT_MODE_SET=1 ;;
        --claude-update)
            [ $# -ge 2 ] || { echo "--claude-update braucht 6h (Stunden), daily, always oder off" >&2; exit 2; }
            CLAUDE_UPD_MODE="$2"; CLAUDE_UPD_SET=1; shift ;;
        --no-claude-update) CLAUDE_UPD_MODE=off; CLAUDE_UPD_SET=1 ;;
        --codex-update)
            [ $# -ge 2 ] || { echo "--codex-update braucht 6h (Stunden), daily, always oder off" >&2; exit 2; }
            CODEX_UPD_MODE="$2"; CODEX_UPD_SET=1; shift ;;
        --no-codex-update) CODEX_UPD_MODE=off; CODEX_UPD_SET=1 ;;
        --opencode-update)
            [ $# -ge 2 ] || { echo "--opencode-update braucht 6h (Stunden), daily, always oder off" >&2; exit 2; }
            OPENCODE_UPD_MODE="$2"; OPENCODE_UPD_SET=1; shift ;;
        --no-opencode-update) OPENCODE_UPD_MODE=off; OPENCODE_UPD_SET=1 ;;
        --opencode) USE_OPENCODE=yes; USE_OPENCODE_SET=1 ;;
        --no-opencode) USE_OPENCODE=no; USE_OPENCODE_SET=1 ;;
        --reviewers)
            [ $# -ge 2 ] || { echo "--reviewers braucht codex, opencode oder codex,opencode" >&2; exit 2; }
            case "$2" in
                codex|opencode|codex,opencode) REVIEWERS="$2" ;;
                opencode,codex) REVIEWERS=codex,opencode ;;
                *) echo "--reviewers: ungültiger Wert '$2' (erlaubt: codex, opencode, codex,opencode)" >&2; exit 2 ;;
            esac
            REVIEWERS_SET=1; shift ;;
        --claude) USE_CLAUDE=yes; USE_CLAUDE_SET=1 ;;
        --no-claude) USE_CLAUDE=no; USE_CLAUDE_SET=1 ;;
        --codex) USE_CODEX=yes; USE_CODEX_SET=1 ;;
        --no-codex) USE_CODEX=no; USE_CODEX_SET=1 ;;
        --guidelines) USE_GUIDE=yes; USE_GUIDE_SET=1 ;;
        --no-guidelines) USE_GUIDE=no; USE_GUIDE_SET=1 ;;
        --codex-bypass) USE_BYPASS=yes; USE_BYPASS_SET=1 ;;
        --no-codex-bypass) USE_BYPASS=no; USE_BYPASS_SET=1 ;;
        --voice) USE_VOICE=yes; USE_VOICE_SET=1 ;;
        --no-voice) USE_VOICE=no; USE_VOICE_SET=1 ;;
        --language)
            [ $# -ge 2 ] || { echo "--language braucht de oder en" >&2; exit 2; }
            case "$2" in de|en) ;; *) echo "--language: ungültiger Wert '$2' (erlaubt: de, en)" >&2; exit 2 ;; esac
            LANGUAGE="$2"; LANGUAGE_SET=1; shift ;;
        --speak) USE_SPEAK=yes; USE_SPEAK_SET=1 ;;
        --no-speak) USE_SPEAK=no; USE_SPEAK_SET=1 ;;
        --sidekey) USE_SIDEKEY=yes; USE_SIDEKEY_SET=1 ;;
        --no-sidekey) USE_SIDEKEY=no; USE_SIDEKEY_SET=1 ;;
        --home-key) USE_HOMEKEY=yes; USE_HOMEKEY_SET=1 ;;
        --no-home-key) USE_HOMEKEY=no; USE_HOMEKEY_SET=1; HOMEKEY_OFF_OPT=1 ;;
        --headset) USE_HEADSET=yes; USE_HEADSET_SET=1 ;;
        --phantom-killer-off) USE_PHANTOM_OFF=yes; USE_PHANTOM_OFF_SET=1 ;;
        --phantom-killer-on) USE_PHANTOM_OFF=no; USE_PHANTOM_OFF_SET=1 ;;
        --no-headset) USE_HEADSET=no; USE_HEADSET_SET=1 ;;
        --distro)
            [ $# -ge 2 ] || { echo "--distro braucht ubuntu oder debian" >&2; exit 2; }
            case "$2" in ubuntu|debian) ;; *) echo "--distro: ungültiger Wert '$2' (erlaubt: ubuntu, debian)" >&2; exit 2 ;; esac
            DISTRO="$2"; DISTRO_SET=1; shift ;;
        --device)
            [ $# -ge 2 ] || { echo "--device braucht die Kennung einer Gerätedatei (devices/) oder none" >&2; exit 2; }
            DEVICE="$2"; DEVICE_SET=1; shift ;;
        --model)
            [ $# -ge 2 ] || { echo "--model braucht einen Namen oder none" >&2; exit 2; }
            MODEL="$2"; MODEL_SET=1; shift ;;
        -h|--help) sed -n '2,/^set -eu/{ /^set -eu/d; p; }' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unbekannte Option: $1" >&2; exit 2 ;;
    esac
    shift
done

case "$AUTONOMOUS" in
    yes|no|ask) ;;
    *) echo "--autonomous: ungültiger Wert '$AUTONOMOUS' (erlaubt: yes, no, ask)" >&2; exit 2 ;;
esac

MODEL_RE='^(none|[A-Za-z0-9][]A-Za-z0-9._:[-]{0,63})$'
if [ "$MODEL_SET" = 1 ] && ! [[ "$MODEL" =~ $MODEL_RE ]]; then
    echo "--model: ungültiger Name '$MODEL' (erlaubt: Buchstaben, Ziffern, . _ : - [ ]; max. 64 Zeichen; oder none)" >&2
    exit 2
fi

if [ "$DEVICE_SET" = 1 ] && [ "$DEVICE" != none ] \
        && ! { [[ "$DEVICE" =~ $DEVICE_RE ]] && [ -f "$REPO/devices/$DEVICE.conf" ]; }; then
    echo "--device: keine Gerätedatei devices/$DEVICE.conf (erlaubt: none oder eine Datei aus devices/)" >&2
    exit 2
fi

if [ "$REMOTE_NAME_SET" = 1 ] && ! [[ "$REMOTE_NAME" =~ $NAME_RE ]]; then
    echo "--remote-name: ungültiger Name '$REMOTE_NAME' (erlaubt: Buchstaben, Ziffern, . _ -; max. 64 Zeichen; nicht mit - beginnen)" >&2
    exit 2
fi

# check_mode <option> <value> <set 0|1>: exit 2 unless the value is 6h (1-999 hours), daily, always or off
check_mode() {
    [ "$3" = 1 ] || return 0
    [[ "$2" =~ $APT_RE ]] || { echo "--$1: ungültiger Wert '$2' (erlaubt: 6h (1-999 Stunden), daily, always, off)" >&2; exit 2; }
}
check_mode apt-upgrade "$APT_MODE" "$APT_MODE_SET"
check_mode claude-update "$CLAUDE_UPD_MODE" "$CLAUDE_UPD_SET"
check_mode codex-update "$CODEX_UPD_MODE" "$CODEX_UPD_SET"
check_mode opencode-update "$OPENCODE_UPD_MODE" "$OPENCODE_UPD_SET"

BOTH_OFF_MSG="Mindestens eines von Claude Code, Codex und OpenCode muss installiert werden (nicht --no-claude und --no-codex zusammen, ohne --opencode)."
if [ "$USE_CLAUDE" = no ] && [ "$USE_CODEX" = no ] && [ "$USE_OPENCODE" = no ]; then echo "$BOTH_OFF_MSG" >&2; exit 2; fi
if [ "$USE_SIDEKEY" = yes ] && [ "$USE_VOICE" = no ] && [ "$USE_SIDEKEY_SET" = 1 ] && [ "$USE_VOICE_SET" = 1 ]; then
    echo "--sidekey braucht die Sprachsteuerung (nicht zusammen mit --no-voice)." >&2; exit 2
fi

say() { printf '%s\n' "$*"; }
die() { echo "install.sh: $*" >&2; exit 1; }

[ -d "$PREFIX/bin" ] || die "Das sieht nicht nach Termux aus (PREFIX=$PREFIX). Dieses Skript in einer Termux-Shell starten."
if [ -z "${ROOTBRIDGE_ALLOW_GUEST:-}" ] && [ "$(id -u)" -eq 0 ] \
        && [ -f /etc/os-release ] && grep -qiE '^ID="?(ubuntu|debian)"?$' /etc/os-release 2>/dev/null; then
    die "Du bist im Gast. Bitte in einer normalen Termux-Shell ausführen (nicht in proot-distro)."
fi

backup() {
    # nothing to keep of a missing or empty file (set_block creates an empty one first)
    [ -s "$1" ] || return 0
    local dest="$1.bak-$STAMP"
    # Termux:Widget lists EVERY file in ~/.shortcuts and Termux:Boot runs EVERY file in
    # ~/.termux/boot: backups of those must not sit next to the originals
    case "$1" in
        "$HOME/.shortcuts/"*|"$HOME/.termux/boot/"*)
            mkdir -p "$BRIDGE_DIR/backups"
            dest="$BRIDGE_DIR/backups/${1##*/}.bak-$STAMP" ;;
    esac
    [ -e "$dest" ] && return 0   # a second change in the same run: the first backup holds the state before the run
    cp -p "$1" "$dest" && say "  Sicherung: $dest" || true
}

# inst <src> <dest> [interpreter]: copy with the Termux shebang (bash, or e.g. python3); back up only on change
inst() {
    local tmp="$2.new.$$"
    mkdir -p "$(dirname "$2")"
    sed "1s|^#!.*|#!$PREFIX/bin/${3:-bash}|" "$1" > "$tmp"
    chmod 755 "$tmp"
    if [ -e "$2" ] && cmp -s "$tmp" "$2"; then rm -f "$tmp"; return 0; fi
    backup "$2"
    mv -f "$tmp" "$2"
    say "  installiert: $2"
}

# put_data <src> <dest> <mode>: copy a data file as it is (no shebang rewrite); back up only on
# change. Returns 0 if the file was written, 1 if it was already identical, 2 if it could not be written.
put_data() {
    local tmp="$2.new.$$"
    # every step checked: a caller in a condition (put_data ... && ...) runs without set -e
    { mkdir -p "$(dirname "$2")" && cp "$1" "$tmp" && chmod "$3" "$tmp"; } || { rm -f "$tmp"; say "  FEHLER: $2 nicht geschrieben"; return 2; }
    if [ -e "$2" ] && cmp -s "$tmp" "$2"; then rm -f "$tmp"; return 1; fi
    backup "$2"
    mv -f "$tmp" "$2" || { rm -f "$tmp"; say "  FEHLER: $2 nicht geschrieben"; return 2; }
    say "  installiert: $2"
}

# set_block <file> <content-file>: replace our marked block, keep the rest
set_block() {
    local file="$1" content="$2" tmp
    touch "$file"
    tmp="$file.new.$$"
    python3 -I "$REPO/guest/lib/rbfile.py" set "$file" "$tmp" "$BEGIN" "$END" "$content"
    if cmp -s "$tmp" "$file"; then rm -f "$tmp"; else backup "$file"; mv -f "$tmp" "$file"; say "  aktualisiert: $file"; fi
}

# own_extra_keys <file>: succeeds if the file sets `extra-keys` OUTSIDE our block, i.e. a row of the user's
# own. Our block is appended at the end and a later duplicate key wins, so it would silently replace it.
own_extra_keys() {
    [ -f "$1" ] || return 1
    python3 -I "$REPO/guest/lib/rbfile.py" other "$1" "$BEGIN" "$END" '\s*extra-keys\s*[=:]'
}

# All questions come here, before anything is installed; the installation then runs through without asking. Each one is
# asked once on a terminal: the answer is stored in the Termux config, an option changes it later.
say "== Fragen und Einstellungen"
# Android's shared storage (/sdcard) for Termux: the backup lives there, and the guest gets it as /sdcard. Android asks
# itself (termux-setup-storage), once; only with --setup and on a terminal, where you can answer its dialog.
STORAGE="${RB_STORAGE_CHECK:-/sdcard}"
if [ "$DO_SETUP" = 1 ] && ! ls "$STORAGE" >/dev/null 2>&1; then
    if { [ -t 0 ] || [ "${ROOTBRIDGE_FORCE_INTERACTIVE:-}" = 1 ]; } && command -v termux-setup-storage >/dev/null 2>&1; then
        say "Zugriff auf den Telefonspeicher ($STORAGE): Android fragt gleich, bitte erlauben."
        termux-setup-storage || true
        for _ in $(seq 30); do ls "$STORAGE" >/dev/null 2>&1 && break; sleep 1; done
        ls "$STORAGE" >/dev/null 2>&1 && say "  Telefonspeicher: ok" \
            || say "  Hinweis: noch kein Zugriff auf $STORAGE (später: termux-setup-storage)"
    else
        say "  Hinweis: kein Zugriff auf $STORAGE; einmal in Termux:  termux-setup-storage"
    fi
fi
CFG="$HOME/.config/termux-rootbridge/config"
mkdir -p "$(dirname "$CFG")" "$BRIDGE_DIR"
chmod 700 "$BRIDGE_DIR"
if [ ! -e "$CFG" ]; then
    cat > "$CFG" <<'EOF'
# termux-rootbridge - read as data (no shell code is executed)
# DISTRO=ubuntu         # the guest: ubuntu | debian; stored by install.sh once the guest is there (install.sh --distro)
WORKDIR=/root/work
SESSION=ubuntu
# ASK_TIMEOUT=120       # seconds the Android dialog for a root request waits for your answer (no answer = refused)
# SU_ARGS=-mm -c      # global mount namespace (Magisk), if paths look empty
AUTOSTART_DELAY=3
# REMOTE_NAME=android   # name in the Remote Control view (claude.ai/code); default android, change with install.sh --remote-name
# APT_UPGRADE=6h        # apt-get update + upgrade in the guest at session start: 6h (<N>h = every N hours) | daily (= 24h) | always | off; set with install.sh --apt-upgrade / --no-apt-upgrade
# CLAUDE_UPDATE=6h      # claude update in the guest at session start: 6h (<N>h = every N hours) | daily (= 24h) | always | off; set with install.sh --claude-update / --no-claude-update
# CODEX_UPDATE=6h       # codex update at session start: same values; set with install.sh --codex-update / --no-codex-update
# TOOL_CLAUDE=on        # on | off: Claude Code is part of this installation; set with install.sh --claude / --no-claude
# TOOL_CODEX=on         # on | off: Codex is part of this installation; set with install.sh --codex / --no-codex
# TOOL_OPENCODE=off     # on | off: OpenCode is part of this installation; set with install.sh --opencode / --no-opencode
# OPENCODE_UPDATE=6h    # opencode upgrade at session start: same values; set with install.sh --opencode-update / --no-opencode-update
# REVIEWERS=codex       # codex | opencode | codex,opencode: who reviews the commits of Claude Code; install.sh --reviewers
# GUIDELINES=on         # on | off: code quality block in the guest's CLAUDE.md / AGENTS.md; set with install.sh --guidelines / --no-guidelines
# CODEX_BYPASS=on       # on | off: Codex without its own sandbox (CODEX_ARGS in the guest config); set with install.sh --codex-bypass / --no-codex-bypass
# VOICE=on              # on | off: voice dictation for Claude Code (PulseAudio, microphone); set with install.sh --voice / --no-voice
# LANGUAGE=de           # de | en: Claude Code's language, the texts in CLAUDE.md, the voice that reads aloud; install.sh --language
# SPEAK=on              # on | off: reading Claude's answers aloud (Piper, Articulino); set with install.sh --speak / --no-speak
# SPEAK_SHORT=set       # set by install.sh the first time it installs voice, after it switched reading aloud to the short version
# SIDEKEY=off           # on | off: side key of the Hisense A9 as push to talk; set with install.sh --sidekey / --no-sidekey
# HOMEKEY=off           # on | off: long press on Home as push to talk (Termux is the assistant); install.sh --home-key / --no-home-key
# HEADSET=off           # on | off: long press on the key of a wired headset as push to talk; install.sh --headset / --no-headset
# PHANTOM_KILLER=off    # off: Android's phantom process killer switched off (root, on every install); install.sh --phantom-killer-off / -on
# DEVICE=none           # the device file in devices/ (its id) or none; installed as device.conf next to this file; install.sh --device
# PTT_TARGET=ubuntu:claude   # `ptt`: tmux window it presses its key in (default <SESSION>:claude)
# PTT_KEY=M-k           # `ptt`: tmux key name (Claude Code: voice:pushToTalk is bound to meta+k)
# PTT_MODE=auto         # `ptt`: auto (the mode of Claude Code's /voice, read from its settings) | hold (repeat the key until stop) | tap (one press each); PTT_INTERVAL=50 (ms), PTT_WARMUP=1200 (ms before the first repeat), PTT_MAX=120 (s), PTT_BEEP=on (high beep: recording, low: ended)
EOF
    say "  neu: $CFG"
fi
# ask_key <yes|no var> <set var> <config key> <default yes|no> <question>: on a terminal, a choice that neither an option
# nor the config decided; the answer counts as an option (it is stored). No answer (end of input): undecided, asked next
# time.
ask_key() {
    local answer hint="[j/N]"
    [ "${!2}" != 1 ] && [ -z "$(cfg_get "$3")" ] || return 0
    [ -t 0 ] || [ "${ROOTBRIDGE_FORCE_INTERACTIVE:-}" = 1 ] || return 0
    [ "$4" = yes ] && hint="[J/n]"
    printf '%s %s ' "$5" "$hint"
    IFS= read -r answer || { echo; return 0; }
    case "$answer" in
        j|J|ja|Ja|JA|y|Y|yes) answer=yes ;;
        n|N|nein|Nein|NEIN|no) answer=no ;;
        *) answer="$4" ;;
    esac
    printf -v "$1" '%s' "$answer"; printf -v "$2" '%s' 1
}
# onoff <yes|no>: the config spelling of a choice
onoff() { if [ "$1" = yes ]; then echo on; else echo off; fi; }
# cfg_get KEY [FILE]: the value stored in the Termux config, or in FILE (quotes stripped; empty if there is none)
cfg_get() {
    local v
    v="$(sed -n "s/^$1=//p" "${2:-$CFG}" | tail -n 1)"
    v="${v%\"}"; v="${v#\"}"; v="${v%\'}"; v="${v#\'}"
    printf '%s' "$v"
}
# cfg_set KEY VALUE MESSAGE: store KEY=VALUE (replace the line or add it; a backup only on a change)
cfg_set() {
    local tmp="$CFG.new.$$"
    cp "$CFG" "$tmp"
    [ -z "$(tail -c1 "$tmp")" ] || echo >> "$tmp"
    if grep -q "^$1=" "$tmp"; then sed -i "s|^$1=.*|$1=$2|" "$tmp"; else printf '%s=%s\n' "$1" "$2" >> "$tmp"; fi
    if cmp -s "$tmp" "$CFG"; then rm -f "$tmp"; else backup "$CFG"; mv -f "$tmp" "$CFG"; say "  $3"; fi
}
# The old default WORKDIR=/root/workspace was never created. If the folder is not in the guest nobody uses it:
# move to the new default /root/work (an existing /root/workspace and any other value stay).
if grep -qx 'WORKDIR=/root/workspace' "$CFG"; then
    d="$(cfg_get DISTRO)"; d="${d:-ubuntu}"
    if [ ! -e "$PREFIX/var/lib/proot-distro/containers/$d/rootfs/root/workspace" ] \
       && [ ! -e "$PREFIX/var/lib/proot-distro/installed-rootfs/$d/root/workspace" ]; then
        tmp="$CFG.new.$$"
        sed 's|^WORKDIR=/root/workspace$|WORKDIR=/root/work|' "$CFG" > "$tmp"
        backup "$CFG"; mv -f "$tmp" "$CFG"
        say "  WORKDIR: /root/workspace -> /root/work (der alte Standardordner wurde nie angelegt)"
    fi
fi
# The device: its file in devices/ describes its keys (devices/README.md). The id is <manufacturer>-<model> as the vendor
# partition reports them (a custom system image reports names of its own in ro.product.*). An option wins, else the stored
# choice, else asked once on a terminal (stored as DEVICE: the id or none). Without a terminal nothing is chosen.
dev_prop() {   # dev_prop <field>: the first of ro.product.vendor.<field>, ro.product.odm.<field>, ro.product.<field>
    local p v
    for p in "ro.product.vendor.$1" "ro.product.odm.$1" "ro.product.$1"; do
        v="$(getprop "$p" 2>/dev/null)" || continue
        if [ -n "$v" ]; then printf '%s' "$v"; return 0; fi
    done
    return 1
}
DEV_MAKER="$(dev_prop manufacturer || true)"; DEV_MODEL="$(dev_prop model || true)"
DEV_FOUND=""   # the id of this device (empty: unknown)
if [ -n "$DEV_MAKER" ] && [ -n "$DEV_MODEL" ]; then
    DEV_FOUND="$(printf '%s-%s' "$DEV_MAKER" "$DEV_MODEL" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9._-' '-')"
    DEV_FOUND="${DEV_FOUND#-}"; DEV_FOUND="${DEV_FOUND%-}"
    [[ "$DEV_FOUND" =~ $DEVICE_RE ]] || DEV_FOUND=""
fi
if [ "$DEVICE_SET" != 1 ]; then
    DEVICE="$(cfg_get DEVICE)"
    if [ -n "$DEVICE" ] && [ "$DEVICE" != none ] && ! { [[ "$DEVICE" =~ $DEVICE_RE ]] && [ -f "$REPO/devices/$DEVICE.conf" ]; }; then
        say "  Gerätedatei devices/$DEVICE.conf gibt es nicht (mehr); ändern mit --device ID|none"
        DEVICE=""
    fi
fi
if [ -z "$DEVICE" ] && [ -n "$DEV_FOUND" ] && [ -f "$REPO/devices/$DEV_FOUND.conf" ]; then
    label="$(cfg_get LABEL "$REPO/devices/$DEV_FOUND.conf")"
    if [ -t 0 ] || [ "${ROOTBRIDGE_FORCE_INTERACTIVE:-}" = 1 ]; then
        printf '%s ' "${label:-$DEV_FOUND} erkannt ($DEV_MAKER $DEV_MODEL): Gerätedatei devices/$DEV_FOUND.conf verwenden (wo die Tasten des Geräts liegen)? [J/n]"
        if IFS= read -r answer; then
            case "$answer" in n|N|nein|Nein|NEIN|no) DEVICE=none ;; *) DEVICE="$DEV_FOUND" ;; esac
            DEVICE_SET=1
        else
            echo
        fi
    else
        say "  Gerät: ${label:-$DEV_FOUND} (devices/$DEV_FOUND.conf); verwenden mit --device $DEV_FOUND"
    fi
elif [ -z "$DEVICE" ] && [ -n "$DEV_FOUND" ]; then
    say "  Gerät: $DEV_MAKER $DEV_MODEL (keine Gerätedatei; eigene anlegen: devices/$DEV_FOUND.conf, siehe devices/README.md)"
fi
if [ "$DEVICE_SET" = 1 ]; then cfg_set DEVICE "$DEVICE" "Gerät: $DEVICE"; fi
DEV_SRC=""; DEV_LABEL=""   # the device file in use, and its name
if [ -n "$DEVICE" ] && [ "$DEVICE" != none ]; then
    DEV_SRC="$REPO/devices/$DEVICE.conf"
    DEV_LABEL="$(cfg_get LABEL "$DEV_SRC")"
    label_re='^[A-Za-z0-9 ._()+-]{1,64}$'
    [[ "$DEV_LABEL" =~ $label_re ]] || DEV_LABEL="$DEVICE"
fi
# dev_key <SIDEKEY|HEADSET>: the device file in use describes that key (without a device file: as before, yes)
dev_key() { [ -z "$DEV_SRC" ] || grep -Eq "^$1_(DEVICE|DEVICE_NAME)=" "$DEV_SRC"; }
# dev_home: a long press on Home starts Android's assistant on this device (without a device file: as before, yes)
dev_home() { [ -z "$DEV_SRC" ] || [ "$(cfg_get HOMEKEY_METHOD "$DEV_SRC")" = assistant ]; }
# find_guest_root <distro>: the root directory of the guest as seen from Termux; fails if it is not installed
find_guest_root() {
    local c
    for c in "$PREFIX/var/lib/proot-distro/containers/$1/rootfs" "$PREFIX/var/lib/proot-distro/installed-rootfs/$1"; do
        if [ -d "$c" ]; then printf '%s' "$c"; return 0; fi
    done
    return 1
}

# The guest: an option wins, else the config, else asked once on a terminal when there is no guest yet (Ubuntu or Debian).
# Another one than the installed guest is a switch: the old one stays; its settings and logins can come along (a backup of
# it, restored into the new one, which asks what of it) and so can the work folder. DISTRO is stored once the guest is there.
OLD_DISTRO="$(cfg_get DISTRO)"; OLD_DISTRO="${OLD_DISTRO:-ubuntu}"
if [ "$DISTRO_SET" = 1 ] && [ "$DO_GUEST" != 1 ]; then
    say "  --distro $DISTRO gilt nur mit dem Gast (ohne --no-guest); der Gast bleibt $OLD_DISTRO"
    DISTRO="$OLD_DISTRO"
elif [ "$DISTRO_SET" != 1 ]; then
    DISTRO="$OLD_DISTRO"
    # not stored yet (a run that failed while setting the guest up): the one guest that is installed
    if [ -z "$(cfg_get DISTRO)" ] && find_guest_root debian >/dev/null && ! find_guest_root ubuntu >/dev/null; then
        DISTRO=debian; OLD_DISTRO=debian
    fi
    if [ -z "$(cfg_get DISTRO)" ] && [ "$DO_GUEST" = 1 ] && ! find_guest_root ubuntu >/dev/null \
            && ! find_guest_root debian >/dev/null && { [ -t 0 ] || [ "${ROOTBRIDGE_FORCE_INTERACTIVE:-}" = 1 ]; }; then
        printf '%s ' "Gastsystem: Ubuntu oder Debian? [U/d]"
        if IFS= read -r answer; then
            case "$answer" in d|D|debian|Debian) DISTRO=debian ;; esac
        else
            echo
        fi
    fi
fi
GUEST_ALIAS="$DISTRO"; GUEST_WIDGET=Ubuntu   # the shell of the guest: its alias and its widget
if [ "$DISTRO" = debian ]; then GUEST_WIDGET=Debian; fi
case "$DISTRO" in ubuntu|debian) ;; *) GUEST_ALIAS=ubuntu ;; esac   # another guest of the config: as before
SWITCH_FROM=""; SWITCH_BACKUP=no; SWITCH_WORK=no; OLD_GROOT=""   # a switch of the guest, and what comes along
if [ "$DO_GUEST" = 1 ] && [ "$DISTRO" != "$OLD_DISTRO" ] && OLD_GROOT="$(find_guest_root "$OLD_DISTRO")"; then
    SWITCH_FROM="$OLD_DISTRO"
    say "  Gast wechselt: $OLD_DISTRO -> $DISTRO (der $OLD_DISTRO-Gast bleibt; zurück mit --distro $OLD_DISTRO)"
    if [ -t 0 ] || [ "${ROOTBRIDGE_FORCE_INTERACTIVE:-}" = 1 ]; then
        printf '%s ' "Einstellungen und Zugangsdaten aus dem $OLD_DISTRO-Gast mitnehmen (Sicherung und Wiederherstellung, fragt ein Passwort und was davon)? [J/n]"
        if IFS= read -r answer; then case "$answer" in n|N|nein|Nein|NEIN|no) ;; *) SWITCH_BACKUP=yes ;; esac; else echo; fi
        printf '%s ' "Arbeitsordner und Claude-Unterhaltungen aus dem $OLD_DISTRO-Gast mitnehmen (der Ordner, wenn er im neuen Gast leer ist)? [J/n]"
        if IFS= read -r answer; then case "$answer" in n|N|nein|Nein|NEIN|no) ;; *) SWITCH_WORK=yes ;; esac; else echo; fi
    else
        say "  ohne Terminal: nichts mitgenommen (Sicherung: rootbridge backup, dann im neuen Gast rootbridge restore)"
    fi
fi
if [ "$APT_MODE_SET" = 1 ]; then
    # same idea as REMOTE_NAME: the choice survives a reinstall of the guest
    cfg_set APT_UPGRADE "$APT_MODE" "apt-Modus gespeichert: $APT_MODE"
else
    v="$(cfg_get APT_UPGRADE)"
    if [[ "$v" =~ $APT_RE ]]; then APT_MODE="$v"; say "  apt-Modus aus der Konfig: $APT_MODE"; fi
fi
if [ "$CLAUDE_UPD_SET" = 1 ]; then
    # same idea as APT_UPGRADE: the choice survives a reinstall of the guest
    cfg_set CLAUDE_UPDATE "$CLAUDE_UPD_MODE" "claude-update-Modus gespeichert: $CLAUDE_UPD_MODE"
else
    v="$(cfg_get CLAUDE_UPDATE)"
    if [[ "$v" =~ $APT_RE ]]; then CLAUDE_UPD_MODE="$v"; say "  claude-update-Modus aus der Konfig: $CLAUDE_UPD_MODE"; fi
fi
# Claude Code and Codex: an option wins, else the stored choice, else asked once (default yes). Both choices are settled
# and checked BEFORE either is stored: a refused combination leaves the config as it was.
if [ "$USE_CLAUDE_SET" != 1 ] && [ "$(cfg_get TOOL_CLAUDE)" = off ]; then
    USE_CLAUDE=no; say "  Claude Code: abgewählt (aus der Konfig; wieder an mit --claude)"
fi
if [ "$USE_CODEX_SET" != 1 ] && [ "$(cfg_get TOOL_CODEX)" = off ]; then
    USE_CODEX=no; say "  Codex: abgewählt (aus der Konfig; wieder an mit --codex)"
fi
ask_key USE_CLAUDE USE_CLAUDE_SET TOOL_CLAUDE yes "Claude Code installieren?"
ask_key USE_CODEX USE_CODEX_SET TOOL_CODEX yes \
    "Codex installieren (sind Claude Code und Codex installiert, prüft Codex jeden Commit von Claude Code)?"
if [ "$USE_OPENCODE_SET" != 1 ] && [ "$(cfg_get TOOL_OPENCODE)" = on ]; then
    USE_OPENCODE=yes; say "  OpenCode: gewählt (aus der Konfig; ab mit --no-opencode)"
fi
ask_key USE_OPENCODE USE_OPENCODE_SET TOOL_OPENCODE no \
    "OpenCode installieren (ein drittes Werkzeug; es kann auch die Commits von Claude Code prüfen)?"
if [ "$USE_CLAUDE" = no ] && [ "$USE_CODEX" = no ] && [ "$USE_OPENCODE" = no ]; then
    die "$BOTH_OFF_MSG (eines wieder an: --claude, --codex oder --opencode)"
fi
# Who reviews the commits of Claude Code: the option, else the stored choice, else asked once when both could
# (default Codex). install-guest.sh keeps only the tools of the installation.
if [ "$REVIEWERS_SET" != 1 ]; then
    v="$(cfg_get REVIEWERS)"
    case "$v" in codex|opencode|codex,opencode) REVIEWERS="$v"; say "  Prüfer der Commits: $v (aus der Konfig)" ;; esac
fi
if [ "$REVIEWERS_SET" != 1 ] && [ -z "$REVIEWERS" ] && [ "$USE_CLAUDE$USE_CODEX$USE_OPENCODE" = yesyesyes ] \
        && { [ -t 0 ] || [ "${ROOTBRIDGE_FORCE_INTERACTIVE:-}" = 1 ]; }; then
    printf '%s ' "Wer prüft die Commits von Claude Code: Codex, OpenCode oder beide (beide müssen zustimmen)? [C/o/b]"
    IFS= read -r v || echo
    case "$v" in o|O|opencode|OpenCode) REVIEWERS=opencode ;; b|B|beide|Beide) REVIEWERS=codex,opencode ;; *) REVIEWERS=codex ;; esac
    REVIEWERS_SET=1
fi
# stored at the end, once the chosen tools are installed: the launchers (rootbridge attach) go by it, and a run that fails
# half way must not switch them to a tool that is not there yet (the question then comes again)
# Android's phantom process killer (switched later, as root): a stored choice counts, else asked once. restore: it was off
# and is to go on again, which has not worked yet (no terminal, root refused): tried again on the next run.
OLD_PHANTOM="$(cfg_get PHANTOM_KILLER)"   # off or restore before this run: switching it on gives Android's defaults back
# switched off by hand (rootbridge phantom-killer off leaves this marker): it counts as off as well
PHANTOM_MARKER="$(dirname "${ROOTBRIDGE_CONFIG:-$CFG}")/phantom-killer-off"   # where rootbridge-lib.sh puts it
if [ -e "$PHANTOM_MARKER" ] && [ "$OLD_PHANTOM" != restore ]; then OLD_PHANTOM=off; fi
if [ "$USE_PHANTOM_OFF_SET" != 1 ]; then
    case "$OLD_PHANTOM" in off) USE_PHANTOM_OFF=yes ;; restore) USE_PHANTOM_OFF=no; USE_PHANTOM_OFF_SET=1 ;; esac
fi
ask_key USE_PHANTOM_OFF USE_PHANTOM_OFF_SET PHANTOM_KILLER yes \
    "Den Phantom Process Killer von Android abschalten? Er beendet sonst tmux, Claude Code und Codex, wenn viele Prozesse laufen. Solange er aus ist, lädt Android auch keine Systemeinstellungen mehr aus der Ferne nach (device_config; zurück mit rootbridge phantom-killer on). Braucht Root"
if [ "$USE_PHANTOM_OFF_SET" = 1 ]; then
    if [ "$USE_PHANTOM_OFF" = yes ]; then v=off; elif [ "$OLD_PHANTOM" = off ] || [ "$OLD_PHANTOM" = restore ]; then v=restore
    else v=on; fi
    cfg_set PHANTOM_KILLER "$v" "Phantom Process Killer: $v"
fi
# code quality guidelines: same idea (default on)
if [ "$USE_GUIDE_SET" != 1 ] && [ "$(cfg_get GUIDELINES)" = off ]; then
    USE_GUIDE=no; say "  Richtlinien: abgewählt (aus der Konfig; wieder an mit --guidelines)"
fi
if [ "$USE_GUIDE_SET" = 1 ]; then
    cfg_set GUIDELINES "$(onoff "$USE_GUIDE")" "Richtlinien: $USE_GUIDE"
fi
# Codex without its sandbox: same idea (default on; Codex off = nothing to decide)
if [ "$USE_BYPASS_SET" != 1 ] && [ "$(cfg_get CODEX_BYPASS)" = off ]; then
    USE_BYPASS=no; say "  Codex-Sandbox: bleibt an (aus der Konfig; ohne Sandbox mit --codex-bypass)"
fi
if [ "$USE_BYPASS_SET" = 1 ]; then
    cfg_set CODEX_BYPASS "$(onoff "$USE_BYPASS")" "Codex ohne eigene Sandbox: $USE_BYPASS"
fi
# voice and side key: same idea (an option wins and is stored; without one the stored value counts)
if [ "$USE_VOICE_SET" != 1 ] && [ "$(cfg_get VOICE)" = off ]; then
    USE_VOICE=no; say "  Sprache: abgewählt (aus der Konfig; wieder an mit --voice)"
fi
if [ "$USE_SIDEKEY_SET" != 1 ] && [ "$(cfg_get SIDEKEY)" = on ]; then
    USE_SIDEKEY=yes; say "  Seitentaste: an (aus der Konfig; aus mit --no-sidekey)"
fi
# the language (Claude Code only): an option wins, else the stored one, else asked once on a terminal. The suggestion (and the
# language without a terminal) is the one of the phone: English when Android's language is English, else German.
sys_lang=de
case "$( (getprop persist.sys.locale; getprop ro.product.locale) 2>/dev/null | grep -m1 . || echo "${LANG:-}")" in
    en*) sys_lang=en ;;
esac
if [ "$USE_CLAUDE" = yes ] && [ "$LANGUAGE_SET" != 1 ]; then
    v="$(cfg_get LANGUAGE)"
    if [ "$v" = de ] || [ "$v" = en ]; then
        LANGUAGE="$v"
    elif [ -t 0 ] || [ "${ROOTBRIDGE_FORCE_INTERACTIVE:-}" = 1 ]; then
        if [ "$sys_lang" = en ]; then hint="[d/E]"; else hint="[D/e]"; fi
        printf '%s ' "Sprache für Claude Code und das Vorlesen: Deutsch oder Englisch (wie das Telefon: $sys_lang)? $hint"
        if IFS= read -r answer; then
            case "$answer" in
                e|E|en|EN|englisch|Englisch|english|English) LANGUAGE=en ;;
                d|D|de|DE|deutsch|Deutsch|german|German) LANGUAGE=de ;;
                *) LANGUAGE="$sys_lang" ;;
            esac
            LANGUAGE_SET=1
        else
            echo
        fi
    fi
fi
LANGUAGE="${LANGUAGE:-$sys_lang}"   # stored at the end, once the guest has it (a run that fails before asks again)
# reading aloud and voice dictation: asked apart, once (with Claude Code only: there is nothing else to talk to)
if [ "$USE_SPEAK_SET" != 1 ] && [ "$(cfg_get SPEAK)" = off ]; then
    USE_SPEAK=no; say "  Vorlesen: abgewählt (aus der Konfig; wieder an mit --speak)"
fi
# the performance of the device (rb_perf in rootbridge-lib.sh, bash only: python3 may not be there yet): what does not suit
# it is suggested as no
PERF="$( . "$REPO/termux/lib/rootbridge-lib.sh" && rb_perf )" || PERF=""
perf_get() { sed -n "s/^$1=//p" <<< "$PERF" | tail -n 1; }
[ -z "$PERF" ] || say "  Leistung: $(perf_get SUMMARY)"
speak_default=yes
if [ "$USE_CLAUDE" = yes ] && [ "$(perf_get FIT_SPEAK)" != yes ] && [ -n "$(perf_get FIT_SPEAK)" ]; then
    say "  Vorlesen auf diesem Gerät: $(perf_get TEXT_SPEAK)"
    [ "$(perf_get FIT_SPEAK)" = tight ] || speak_default=no
fi
if [ "$USE_CLAUDE" = yes ]; then
    ask_key USE_SPEAK USE_SPEAK_SET SPEAK "$speak_default" "Vorlesen: Claudes Antworten vorlesen lassen (Piper, auf Wunsch mit deiner eigenen Stimme)?"
    ask_key USE_VOICE USE_VOICE_SET VOICE yes "Spracheingabe: Claude Code per Mikrofon diktieren (/voice, Push to Talk)?"
fi
# reading aloud undecided (a config from before it, no terminal): as voice dictation, which it was part of
if [ "$USE_SPEAK_SET" != 1 ] && [ -z "$(cfg_get SPEAK)" ]; then USE_SPEAK="$USE_VOICE"; fi
if [ "$USE_SPEAK_SET" = 1 ]; then
    cfg_set SPEAK "$(onoff "$USE_SPEAK")" "Vorlesen: $USE_SPEAK"
fi
OLD_VOICE="$(cfg_get VOICE)"   # off before this run, or on (also empty): switching voice off gives the Home key role back
if [ "$USE_VOICE_SET" = 1 ]; then
    cfg_set VOICE "$(onoff "$USE_VOICE")" "Sprache: $USE_VOICE"
fi
# Resolve the device name after the enabled tools, so Codex-only installs ask no Claude question. Asked once, like the
# keys: a valid name in the config counts (change it with --remote-name NAME).
if [ "$REMOTE_NAME_SET" != 1 ]; then
    v="$(cfg_get REMOTE_NAME)"
    if [[ "$v" =~ $NAME_RE ]]; then
        REMOTE_NAME="$v"
        say "  Remote-Control-Name: $REMOTE_NAME (aus der Konfig; ändern mit --remote-name NAME)"
    elif [ "$USE_CLAUDE" = yes ] && [ -t 0 ]; then
        # the suggestion: NAME of the device file, else the id read from the device, else android
        v="$( [ -z "$DEV_SRC" ] || cfg_get NAME "$DEV_SRC" )"
        if [[ "$v" =~ $NAME_RE ]]; then REMOTE_NAME="$v"; elif [ -n "$DEV_FOUND" ]; then REMOTE_NAME="$DEV_FOUND"; fi
        say "Wie soll dieses Gerät in Claude Remote Control heißen?"
        say "  Erlaubt: Buchstaben, Ziffern, Punkt, _ und -; maximal 64 Zeichen (z. B. boox-max-lumi)."
        while true; do
            printf 'Gerätename [%s]: ' "$REMOTE_NAME"
            IFS= read -r answer || die "Namensabfrage abgebrochen; für einen Aufruf ohne Nachfrage --remote-name NAME verwenden."
            answer="${answer:-$REMOTE_NAME}"
            if [[ "$answer" =~ $NAME_RE ]]; then
                REMOTE_NAME="$answer"; REMOTE_NAME_SET=1; break
            fi
            say "Ungültiger Gerätename. Bitte ohne Leerzeichen oder Sonderzeichen eingeben."
        done
    else
        say "  Remote-Control-Name: $REMOTE_NAME (ohne Nachfrage; ändern mit --remote-name NAME)"
    fi
fi
if [ "$REMOTE_NAME_SET" = 1 ]; then
    # store the name in the Termux config: it survives a reinstall of the guest
    cfg_set REMOTE_NAME "$REMOTE_NAME" "Remote-Control-Name gespeichert: $REMOTE_NAME"
fi
if [ "$USE_HOMEKEY_SET" != 1 ] && [ "$(cfg_get HOMEKEY)" = on ]; then USE_HOMEKEY=yes; fi
# HEADSET not decided yet (a config from before it): the headset key follows the side key, as the reader always read both
if [ "$USE_HEADSET_SET" != 1 ]; then
    case "$(cfg_get HEADSET)" in
        on) USE_HEADSET=yes ;;
        "") USE_HEADSET="$USE_SIDEKEY" ;;
    esac
fi
OLD_HOMEKEY="$(cfg_get HOMEKEY)"   # on before this run: --no-home-key takes the assistant role back
# the keys for push to talk work only with voice dictation; a key the device file does not describe is not asked for
if [ "$USE_VOICE" = yes ] && [ "$USE_CLAUDE" = yes ]; then
    if [ -z "$DEV_SRC" ]; then
        ask_key USE_SIDEKEY USE_SIDEKEY_SET SIDEKEY no \
            "Seitentaste als Push to Talk (halten = sprechen; nur Hisense A9, braucht Root)?"
    elif dev_key SIDEKEY; then
        ask_key USE_SIDEKEY USE_SIDEKEY_SET SIDEKEY yes \
            "Seitentaste des $DEV_LABEL als Push to Talk (halten = sprechen, braucht Root)?"
    else
        say "  Seitentaste: $DEV_LABEL hat laut Gerätedatei keine"
    fi
    if dev_home; then
        ask_key USE_HOMEKEY USE_HOMEKEY_SET HOMEKEY yes \
            "Langer Druck auf Home startet und stoppt die Spracheingabe (Termux wird digitaler Assistent, braucht Root)?"
    else
        say "  Home-Taste: bei $DEV_LABEL kommt ein langer Druck nicht beim Assistenten an (Gerätedatei)"
    fi
    if dev_key HEADSET; then
        ask_key USE_HEADSET USE_HEADSET_SET HEADSET yes \
            "Langer Druck auf die Taste eines Kabel-Headsets startet und stoppt die Spracheingabe (braucht Root)?"
    else
        say "  Headset-Taste: $DEV_LABEL hat laut Gerätedatei keine"
    fi
fi
if [ "$USE_SIDEKEY_SET" = 1 ]; then
    cfg_set SIDEKEY "$(onoff "$USE_SIDEKEY")" "Seitentaste: $USE_SIDEKEY"
fi
if [ "$USE_HOMEKEY_SET" = 1 ]; then
    cfg_set HOMEKEY "$(onoff "$USE_HOMEKEY")" "Home-Taste: $USE_HOMEKEY"
fi
if [ "$USE_HEADSET_SET" = 1 ]; then
    cfg_set HEADSET "$(onoff "$USE_HEADSET")" "Headset-Taste: $USE_HEADSET"
fi
# a backup of an earlier installation (rootbridge backup into /sdcard/backup/termux) on a fresh one (no guest yet): asked
# now, restored at the end by rootbridge restore, after the guest is there. Nothing from that folder runs: other apps can
# write there (rootbridge restore reads it as data). Not stored: a later run has the guest.
BACKUP_DIR="${RB_BACKUP_DIR:-/sdcard/backup/termux}"
DO_RESTORE=no
RESTORE_DIR="$BACKUP_DIR"   # a switch of the guest restores the backup made of the old one
if [ "$SWITCH_BACKUP" = yes ]; then
    RESTORE_DIR="$BACKUP_DIR-$SWITCH_FROM"; DO_RESTORE=yes
elif [ -f "$BACKUP_DIR/a.tgz" ] && [ "$DO_GUEST" = 1 ] \
        && ! [ -d "$PREFIX/var/lib/proot-distro/containers/$DISTRO/rootfs/root" ] \
        && ! [ -d "$PREFIX/var/lib/proot-distro/installed-rootfs/$DISTRO/root" ]; then
    if [ -t 0 ] || [ "${ROOTBRIDGE_FORCE_INTERACTIVE:-}" = 1 ]; then
        printf '%s ' "Sicherung gefunden ($BACKUP_DIR): am Ende Einstellungen und Zugangsdaten wiederherstellen (fragt ihr Passwort)? [J/n]"
        if IFS= read -r answer; then
            case "$answer" in n|N|nein|Nein|NEIN|no) ;; *) DO_RESTORE=yes ;; esac
        else
            echo
        fi
    else
        say "  Sicherung gefunden: nach der Installation in Termux:  rootbridge restore $BACKUP_DIR"
    fi
fi
if [ "$CODEX_UPD_SET" = 1 ]; then
    cfg_set CODEX_UPDATE "$CODEX_UPD_MODE" "codex-update-Modus gespeichert: $CODEX_UPD_MODE"
else
    v="$(cfg_get CODEX_UPDATE)"
    if [[ "$v" =~ $APT_RE ]]; then CODEX_UPD_MODE="$v"; say "  codex-update-Modus aus der Konfig: $CODEX_UPD_MODE"; fi
fi
if [ "$OPENCODE_UPD_SET" = 1 ]; then
    cfg_set OPENCODE_UPDATE "$OPENCODE_UPD_MODE" "opencode-update-Modus gespeichert: $OPENCODE_UPD_MODE"
else
    v="$(cfg_get OPENCODE_UPDATE)"
    if [[ "$v" =~ $APT_RE ]]; then OPENCODE_UPD_MODE="$v"; say "  opencode-update-Modus aus der Konfig: $OPENCODE_UPD_MODE"; fi
fi
# Setup, part 1: the Termux packages that are missing. pkg_for maps a command to its Termux package.
# Without recommended packages: python recommends python-pip, which recommends clang, make and pkg-config (about 500 MB with
# LLVM on the A9); rootbridge needs none of them.
PKG_OPTS=(-y -o Dpkg::Options::=--force-confold -o APT::Install-Recommends=false)
pkg_for() {
    case "$1" in
        python3) echo python ;;
        termux-open-url|termux-dialog) echo termux-api ;;
        sha256sum|stat|timeout) echo coreutils ;;
        setsid) echo util-linux ;;
        openssl) echo openssl-tool ;;
        *) echo "$1" ;;
    esac
}
if [ "$DO_SETUP" = 1 ] && [ "$DEPS" = 1 ] && command -v pkg >/dev/null 2>&1; then
    need_pkgs=""
    # openssl: the backup in /sdcard/backup/termux encrypts its secrets with it
    for c in tmux proot-distro python3 sha256sum stat timeout setsid termux-open-url termux-dialog openssl; do
        command -v "$c" >/dev/null 2>&1 && continue
        p="$(pkg_for "$c")"
        case " $need_pkgs " in *" $p "*) ;; *) need_pkgs="$need_pkgs $p" ;; esac
    done
    if [ -n "$need_pkgs" ]; then
        say "== 0/5 Einrichtung: Termux-Pakete"
        say "  pkg install -y$need_pkgs"
        # shellcheck disable=SC2086   # $need_pkgs is a list of package names on purpose
        DEBIAN_FRONTEND=noninteractive pkg install "${PKG_OPTS[@]}" $need_pkgs \
            || die "pkg install$need_pkgs ist fehlgeschlagen (Netz? pkg update?). Erneut starten: bash install.sh"
        hash -r
        SETUP_DID=1
    fi
fi

if [ "$DEPS" = 1 ]; then
    missing=""
    for c in tmux proot-distro sha256sum stat timeout setsid; do
        command -v "$c" >/dev/null 2>&1 || missing="$missing $c"
    done
    if [ -n "$missing" ]; then
        say "Fehlende Pakete:$missing"
        say "Installieren mit: pkg install tmux proot-distro coreutils util-linux"
        exit 1
    fi
    command -v su >/dev/null 2>&1 || say "Hinweis: kein 'su' gefunden - Root-Befehle werden mit Code 127 beantwortet."
    command -v termux-dialog >/dev/null 2>&1 \
        || say "Hinweis: pkg install termux-api und die App Termux:API (für die Rückfrage bei Root-Anfragen, Browser-Öffnen und Zwischenablage). Ohne den Dialog lehnt der Daemon jede Root-Anfrage ab."
fi

command -v python3 >/dev/null 2>&1 || die "python3 fehlt (pkg install python)"

say "== 1/5 Programme"
inst "$REPO/termux/bin/rootbridge"        "$PREFIX/bin/rootbridge"
inst "$REPO/termux/bin/rootbridge-daemon" "$PREFIX/bin/rootbridge-daemon"
inst "$REPO/termux/bin/ptt"               "$PREFIX/bin/ptt"
inst "$REPO/termux/lib/rootbridge-lib.sh" "$PREFIX/lib/termux-rootbridge/rootbridge-lib.sh"
inst "$REPO/termux/lib/keyreader.py"      "$PREFIX/lib/termux-rootbridge/keyreader.py"
inst "$REPO/termux/lib/rootbridge-backup.py" "$PREFIX/lib/termux-rootbridge/rootbridge-backup.py" python3
put_data "$REPO/termux/lib/backup.list"   "$PREFIX/lib/termux-rootbridge/backup.list" 644 || true
chmod 644 "$PREFIX/lib/termux-rootbridge/rootbridge-lib.sh" "$PREFIX/lib/termux-rootbridge/keyreader.py"
# A running daemon keeps its old code in memory (an old one wants tickets that nothing issues any more): stop it. The new
# one starts at the end of the installation.
old_pid="$(cat "$BRIDGE_DIR/.lock/pid" 2>/dev/null || true)"
if [[ "$old_pid" =~ ^[0-9]+$ ]] && kill -0 "$old_pid" 2>/dev/null; then
    "$PREFIX/bin/rootbridge" daemon-stop >/dev/null 2>&1 || kill "$old_pid" 2>/dev/null || true
    say "  laufender Daemon beendet (der neue startet am Ende der Installation)"
fi

say "== 2/5 Konfiguration"
TMP_SNIP="$(mktemp)"; cp "$REPO/termux/tmux.conf.snippet" "$TMP_SNIP"
set_block "$HOME/.tmux.conf" "$TMP_SNIP"; rm -f "$TMP_SNIP"
# device_conf: the valid lines of the device file as device.conf next to the config (keyreader.py checks each one); with
# DEVICE=none it goes (also run again after a restore, whose device.conf may belong to another choice)
DEV_CONF="$(dirname "$CFG")/device.conf"
device_conf() {
    local tmp
    if [ -n "$DEV_SRC" ]; then
        tmp="$(mktemp)"
        python3 -I "$REPO/termux/lib/keyreader.py" --check "$DEV_SRC" > "$tmp" || die "Gerätedatei $DEV_SRC ließ sich nicht lesen"
        put_data "$tmp" "$DEV_CONF" 644 || true
        rm -f "$tmp"
    elif [ "$DEVICE" = none ] && [ -e "$DEV_CONF" ]; then
        backup "$DEV_CONF"; rm -f "$DEV_CONF"
        say "  entfernt: $DEV_CONF (ohne Gerätedatei)"
    fi
}
device_conf

say "== 3/5 Farben, Shell-Block, Widgets"
if [ "$DO_COLORS" = 1 ]; then
    # This installer writes no colour file any more: the E-Paper Termux build brings the light and the dark scheme with it
    # and follows the phone. The files below are what earlier versions installed (SHA-256 of the content). One that is still
    # exactly like that goes, because it would override the built-in scheme and keep the terminal light in dark mode (or
    # stay behind a later change of the built-in scheme). A file you changed stays, with a note. Nothing is overwritten.
    colors_changed=0
    FORMER_COLOR_FILES="colors.properties:3eaffea743c0ad78e60a98f5a2ccf57dfd31b3c8b6b71ae5a3dcef66b91bb54e
colors-light.properties:ddf723e84243925a9e09b468fb87bbcbca9b13a2aef1467835b46f6dba7bc53a"
    for entry in $FORMER_COLOR_FILES; do
        f="$HOME/.termux/${entry%%:*}"
        [ -f "$f" ] || continue
        if [ "$(sha256sum "$f" 2>/dev/null | cut -d' ' -f1)" = "${entry#*:}" ]; then
            rm -f "$f"
            say "  entfernt: $f (von einer früheren Version installiert, die App bringt das Schema jetzt selbst mit)"
            colors_changed=1
        elif [ -s "$f" ]; then
            say "  $f bleibt (von dir geändert) und überschreibt das eingebaute Schema."
        fi
    done
    if [ "$colors_changed" = 1 ]; then
        command -v termux-reload-settings >/dev/null 2>&1 && termux-reload-settings || true
    fi
else
    say "  Farben und Theme übersprungen (--no-colors)"
fi
# extra_keys: our block in termux.properties (also run again after a restore, whose termux.properties replaces the file)
extra_keys() {
    if [ "$DO_EXTRAKEYS" = 1 ]; then
        # S-TAB (a phone keyboard has no Shift+Tab, Claude Code switches its permission mode with it) and
        # KEYBOARD (show/hide the soft keyboard) in the Termux extra keys row; volume-keys = volume in the same block
        TP="$HOME/.termux/termux.properties"
        mkdir -p "$HOME/.termux"
        if own_extra_keys "$TP"; then
            say "  Zusatztasten: $TP enthält eine eigene extra-keys-Zeile, sie bleibt unverändert."
            say "    Für Shift+Tab die Taste {macro: \"SHIFT TAB\", display: \"S-TAB\"} selbst ergänzen,"
            say "    oder die Zeile löschen und install.sh erneut starten (Vorlage: termux/extra-keys.snippet)."
        else
            before="$(cksum < "$TP" 2>/dev/null || true)"
            set_block "$TP" "$REPO/termux/extra-keys.snippet"
            chmod 600 "$TP"
            if [ "$before" != "$(cksum < "$TP")" ]; then
                command -v termux-reload-settings >/dev/null 2>&1 && termux-reload-settings || true
            fi
        fi
    else
        say "  Zusatztasten übersprungen (--no-extra-keys)"
    fi
}
extra_keys
TMP_RC="$(mktemp)"
cat > "$TMP_RC" <<'EOF'
alias ubuntu='rootbridge shell'
alias debian='rootbridge shell'
alias claude='rootbridge attach claude'
alias codex='rootbridge attach codex'
alias opencode='rootbridge attach opencode'
if [[ $- == *i* ]] && [ -z "${TMUX:-}" ]; then
    # reload the Termux settings in every new Termux shell (Claude Code is NOT started here:
    # use the widgets, `claude`, `codex`, `opencode` or `rootbridge attach`)
    if command -v termux-reload-settings >/dev/null 2>&1; then termux-reload-settings; fi
fi
EOF
set_block "$HOME/.bashrc" "$TMP_RC"; rm -f "$TMP_RC"
# Voice dictation (/voice of Claude Code) and reading aloud work only with Claude Code: without it there is nothing to talk to.
VOICE_ON=no; SPEAK_ON=no
if [ "$USE_VOICE" = yes ] && [ "$USE_CLAUDE" = yes ]; then VOICE_ON=yes; fi
if [ "$USE_SPEAK" = yes ] && [ "$USE_CLAUDE" = yes ]; then SPEAK_ON=yes; fi
# Reading aloud reads the short version (speak-first: the summary paragraph and the last question; the guest's CLAUDE.md asks
# Claude to write them). Set once: SPEAK_SHORT=set remembers it, so `rootbridge voice speak all` stays your choice.
if [ "$SPEAK_ON" = yes ] && [ -z "$(cfg_get SPEAK_SHORT)" ]; then
    # mktemp + mv replaces a link instead of writing through it; only a switch that is in place is remembered
    if mkdir -p "$BRIDGE_DIR" && tmp="$(mktemp "$BRIDGE_DIR/.speak-first.XXXXXX")" && mv -fT "$tmp" "$BRIDGE_DIR/speak-first"; then
        cfg_set SPEAK_SHORT set "Vorlesen: nur die Kurzfassung (die ganze Antwort: rootbridge voice speak all)"
    else
        say "  Vorlesen: Kurzfassung ließ sich nicht einschalten (rootbridge voice speak first)"
    fi
fi
# put_widget <shortcut> <name>: our widget script, with the default icon. One default icon for all widgets: installed if there
# is none, and in place of an icon that is exactly a default icon of an earlier version (termux/shortcuts/icons/legacy). An
# icon the user chose stays.
SC="$HOME/.shortcuts"
put_widget() {
    local icon="$SC/icons/$2.png" replace=0 old
    inst "$REPO/termux/shortcuts/$1" "$SC/$2"
    if [ ! -e "$icon" ]; then
        replace=1
    else
        for old in "$REPO"/termux/shortcuts/icons/legacy/*.png; do
            cmp -s "$old" "$icon" 2>/dev/null && replace=1
        done
    fi
    if [ "$replace" = 1 ] && ! cmp -s "$REPO/termux/shortcuts/icons/widget.png" "$icon" 2>/dev/null; then
        cp "$REPO/termux/shortcuts/icons/widget.png" "$icon"
        say "  Icon: $icon"
    fi
}
# guest_widget <distro>: the widget of the guest shell, named after the guest ("Ubuntu" or "Debian"). Our widget of the other
# guest goes, its icon comes along (only ours: a widget of that name of your own stays, and so does its icon).
guest_widget() {
    local other=Debian
    GUEST_WIDGET=Ubuntu
    if [ "$1" = debian ]; then GUEST_WIDGET=Debian; other=Ubuntu; fi
    if [ -f "$SC/$other" ] && grep -q 'rootbridge' "$SC/$other" 2>/dev/null; then
        if [ -e "$SC/icons/$other.png" ] && [ ! -e "$SC/icons/$GUEST_WIDGET.png" ]; then
            mv "$SC/icons/$other.png" "$SC/icons/$GUEST_WIDGET.png"
            say "  Icon übernommen: $other.png -> $GUEST_WIDGET.png"
        fi
        mv "$SC/$other" "$BRIDGE_DIR/backups/$other.old-$STAMP"
        say "  Widget entfernt: $other (der Gast ist $1; Kopie in $BRIDGE_DIR/backups)"
    fi
    put_widget ubuntu "$GUEST_WIDGET"
}
if [ "$DO_WIDGETS" = 1 ]; then
    mkdir -p "$SC/icons" "$BRIDGE_DIR/backups"
    # Earlier versions called the widgets "Claude Code" / "Ubuntu Shell", then "Claude >_" / "Ubuntu >_":
    # carry the user's icon over to the new name (before a default icon is installed), and move our old
    # scripts and their *.bak-* files out of the widget list.
    # the guest widget follows the guest that is stored: after a switch only once the new guest is set up (step 5)
    w_guest=Ubuntu; [ "${SWITCH_FROM:-$DISTRO}" != debian ] || w_guest=Debian
    for pair in "Claude >_:Claude" "Claude Code:Claude" "Ubuntu >_:$w_guest" "Ubuntu Shell:$w_guest"; do
        old="${pair%%:*}"; new="${pair#*:}"
        if [ -e "$SC/icons/$old.png" ] && [ ! -e "$SC/icons/$new.png" ]; then
            mv "$SC/icons/$old.png" "$SC/icons/$new.png"
            say "  Icon übernommen: $old.png -> $new.png"
        fi
        if [ -f "$SC/$old" ] && grep -q 'rootbridge' "$SC/$old" 2>/dev/null; then
            mv "$SC/$old" "$BRIDGE_DIR/backups/$old.old-$STAMP"
            say "  altes Widget entfernt: $old (Kopie in $BRIDGE_DIR/backups)"
        fi
        for f in "$SC/$old".bak-*; do
            if [ -e "$f" ]; then mv "$f" "$BRIDGE_DIR/backups/"; say "  Sicherung aus der Widget-Liste verschoben: ${f##*/}"; fi
        done
    done
    # a tool that is switched off gets no widget (and our widget of an earlier install goes, with a copy in backups)
    for pair in "claude:Claude:$USE_CLAUDE" "codex:Codex:$USE_CODEX" "opencode:OpenCode:$USE_OPENCODE"; do
        if [ "${pair##*:}" = no ]; then
            w="${pair#*:}"; w="${w%%:*}"
            if [ -f "$SC/$w" ] && grep -q 'rootbridge' "$SC/$w" 2>/dev/null; then
                mv "$SC/$w" "$BRIDGE_DIR/backups/$w.old-$STAMP"
                say "  Widget entfernt: $w (abgewählt; Kopie in $BRIDGE_DIR/backups)"
            fi
        fi
    done
    # the widget "Claude Neu" is gone (a new conversation starts with /clear): our script of an earlier install goes, with a copy
    if [ -f "$SC/Claude Neu" ] && grep -q 'rootbridge' "$SC/Claude Neu" 2>/dev/null; then
        mv "$SC/Claude Neu" "$BRIDGE_DIR/backups/Claude Neu.old-$STAMP"
        say "  Widget entfernt: Claude Neu (gibt es nicht mehr; Kopie in $BRIDGE_DIR/backups)"
    fi
    guest_widget "${SWITCH_FROM:-$DISTRO}"
    [ "$USE_CODEX" = yes ] && put_widget codex Codex
    [ "$USE_OPENCODE" = yes ] && put_widget opencode OpenCode
    [ "$USE_CLAUDE" = yes ] && put_widget claude Claude
    # reading aloud: two widgets in tasks/, which Termux:Widget runs in the background (no terminal opens)
    for pair in "speak:Vorlesen" "speak-stop:Stopp"; do
        src="${pair%%:*}"; name="${pair#*:}"
        if [ "$SPEAK_ON" = yes ]; then
            inst "$REPO/termux/shortcuts/$src" "$SC/tasks/$name"
        elif [ -f "$SC/tasks/$name" ] && grep -q 'rootbridge voice speak' "$SC/tasks/$name" 2>/dev/null; then
            rm -f "$SC/tasks/$name"
            say "  Widget entfernt: tasks/$name (Vorlesen abgewählt)"
        fi
    done
else
    say "  Widgets übersprungen (--no-widgets)"
fi
if [ "$DO_BOOT" = 1 ] && [ -d "$HOME/.termux/boot" ]; then
    inst "$REPO/termux/boot/10-rootbridge.sh" "$HOME/.termux/boot/10-rootbridge.sh"
fi

# pa_daemon_conf: reading aloud only: ~/.config/pulse/daemon.conf with allow-module-loading = no, so also a PulseAudio that
# starts by itself (autospawn of a client) gives the guest, which has the cookie, no way to load the microphone source.
# Only when the setting is missing it is added, right after our marker (also to a daemon.conf of your own; with a backup).
# Otherwise just that pair goes again (a setting of your own stays); lines of your own stay (with a backup), and the file
# goes only when nothing else is left.
PA_MARK="# termux-rootbridge voice: reading aloud only, no microphone (installed by install.sh)"
pa_daemon_conf() {
    local dc="$HOME/.config/pulse/daemon.conf" tmp
    if [ "$VOICE_ON" != yes ] && [ "$SPEAK_ON" = yes ]; then
        tmp="$(mktemp)" || die "keine temporäre Datei für $dc"
        if [ -e "$dc" ]; then cp "$dc" "$tmp" || die "$dc ließ sich nicht lesen"; fi
        grep -qx 'allow-module-loading = no' "$tmp" || printf '%s\n' "$PA_MARK" 'allow-module-loading = no' >> "$tmp"
        local rc=0
        put_data "$tmp" "$dc" 644 || rc=$?
        rm -f "$tmp"
        # without the restriction a server a client starts by itself would let the guest load the microphone
        [ "$rc" != 2 ] || die "$dc ließ sich nicht schreiben; ohne die Sperre hätte der Gast das Mikrofon. Erneut: bash install.sh"
    elif grep -qs 'termux-rootbridge voice' "$dc"; then
        local rc=0
        tmp="$(mktemp)" || { say "  Hinweis: $dc bleibt (keine temporäre Datei)"; return 0; }
        # our pair only: the marker and the setting right after it
        awk '/^# termux-rootbridge voice/ { ours = 1; next } ours && $0 == "allow-module-loading = no" { ours = 0; next }
             { ours = 0; print }' "$dc" > "$tmp" || rc=2
        if [ "$rc" -gt 1 ]; then   # an error (a full disk): the file stays as it is
            rm -f "$tmp"
            say "  Hinweis: $dc ließ sich nicht lesen oder abschreiben und bleibt (die Sperre für nur Vorlesen darin)"
            return 0
        fi
        if grep -q '[^[:space:]]' "$tmp"; then
            put_data "$tmp" "$dc" 644 || true   # with a backup
            say "  $dc: die Sperre für nur Vorlesen entfernt, deine Zeilen bleiben"
        else
            rm -f "$dc"
            say "  entfernt: $dc (die Sperre für nur Vorlesen)"
        fi
        rm -f "$tmp"
        # a server running with that restriction (also one a client started by itself) cannot load the microphone: anew
        if [ "$VOICE_ON" = yes ]; then
            { "$PREFIX/bin/rootbridge" voice stop && "$PREFIX/bin/rootbridge" voice start; } >/dev/null \
                || say "  Hinweis: PulseAudio ließ sich nicht neu starten (rootbridge voice stop, dann voice start)"
        fi
    fi
}
say "== Sprache (/voice), Vorlesen und Tasten"
if [ "$VOICE_ON" = yes ] || [ "$SPEAK_ON" = yes ]; then
    # PulseAudio in Termux: the guest records from it and plays through it (sox in the guest, PULSE_SERVER=127.0.0.1)
    if [ ! -x "$PREFIX/bin/pulseaudio" ]; then
        if [ "$DO_SETUP" = 1 ] && [ "$DEPS" = 1 ] && command -v pkg >/dev/null 2>&1; then
            say "  pkg install -y pulseaudio"
            if DEBIAN_FRONTEND=noninteractive pkg install "${PKG_OPTS[@]}" pulseaudio; then
                hash -r; SETUP_DID=1
            else
                say "  Hinweis: pkg install pulseaudio ist fehlgeschlagen - ohne PulseAudio kein Mikrofon. Erneut starten: bash install.sh"
            fi
        else
            say "  Hinweis: pulseaudio fehlt (pkg install pulseaudio) - ohne PulseAudio kein Mikrofon."
        fi
    fi
    # PulseAudio configuration: Termux' own default.pa plus the microphone and the local socket. A default.pa of your own stays.
    # the restriction for reading aloud only first: a server that starts meanwhile (a restart below, or one a client starts by
    # itself) already has it
    pa_daemon_conf
    PA_FILE="$HOME/.config/pulse/default.pa"
    if [ -e "$PA_FILE" ] && ! grep -q 'termux-rootbridge voice' "$PA_FILE" 2>/dev/null; then
        say "  $PA_FILE ist deine eigene Datei und bleibt unverändert (ohne die Zeilen aus termux/pulse/default.pa kein Mikrofon)"
    else
        TMP_PA="$(mktemp)"
        sed "s|@PREFIX@|$PREFIX|g" "$REPO/termux/pulse/default.pa" > "$TMP_PA"
        # reading aloud only: no microphone source (it would record whenever Termux has the permission). Also one that
        # Termux' own default.pa may load goes, right after it and before the listener for the guest opens.
        if [ "$VOICE_ON" != yes ]; then
            sed -i -e '/module-sles-source\|OpenSL_ES_source/d' \
                -e 's|^\.nofail$|.nofail\n# reading aloud only: no source for recording, also none of the include above\nunload-module module-sles-source\nunload-module module-aaudio-source|' "$TMP_PA"
        fi
        pa_rc=0
        put_data "$TMP_PA" "$PA_FILE" 644 || pa_rc=$?   # 0 written, 1 unchanged, 2 failed (then no restart)
        rm -f "$TMP_PA"
        # reading aloud only must not go on with an older default.pa that loads the microphone
        if [ "$pa_rc" = 2 ] && [ "$VOICE_ON" != yes ]; then
            die "$PA_FILE ließ sich nicht schreiben; ohne sie hätte der Gast das Mikrofon. Nichts umgestellt, erneut: bash install.sh"
        fi
        # a server that runs already keeps the setup it started with (the listener for the guest, the microphone): anew
        if [ "$pa_rc" = 0 ] && "$PREFIX/bin/rootbridge" voice status 2>/dev/null | grep -q 'PulseAudio: *läuft'; then
            { "$PREFIX/bin/rootbridge" voice stop && "$PREFIX/bin/rootbridge" voice start; } >/dev/null \
                || say "  Hinweis: PulseAudio ließ sich nicht neu starten (rootbridge voice stop, dann voice start)"
        fi
    fi
    # reading aloud only: a running PulseAudio may still have the microphone of before. voice_start finds every server of
    # Termux (also one whose pid file is gone), keeps exactly one and starts it anew without a source for recording. With our
    # default.pa a source for recording still there (any source but the monitors of the outputs) ends the installation:
    # the guest would have the microphone; with one of your own it is a note.
    if [ "$VOICE_ON" != yes ] && [ -x "$PREFIX/bin/pulseaudio" ]; then
        "$PREFIX/bin/rootbridge" voice start >/dev/null || say "  Hinweis: PulseAudio startet nicht (rootbridge voice start)"
        if ! sources="$(pactl list short sources 2>/dev/null)"; then
            say "  Hinweis: ob PulseAudio das Mikrofon noch geladen hat, ließ sich nicht prüfen (pactl). Sicher aus:  rootbridge voice stop"
        elif cut -f2 <<< "$sources" | grep -qv '\.monitor$'; then
            if grep -qs 'termux-rootbridge voice' "$PA_FILE"; then
                # the guest must not keep that server
                if "$PREFIX/bin/rootbridge" voice stop >/dev/null 2>&1; then
                    die "PulseAudio hatte trotz nur Vorlesen eine Quelle zum Aufnehmen geladen und ist beendet (rootbridge voice status)"
                fi
                die "PulseAudio hat trotz nur Vorlesen eine Quelle zum Aufnehmen geladen und ließ sich NICHT beenden; der Gast könnte noch aufnehmen: pulseaudio --kill"
            fi
            say "  Hinweis: deine eigene $PA_FILE lädt eine Quelle zum Aufnehmen (nur Vorlesen)"
        else
            say "  Mikrofon: aus (nur Vorlesen)"
        fi
    fi
else
    say "  übersprungen ($([ "$USE_CLAUDE" = yes ] && echo '--no-voice, --no-speak' || echo 'ohne Claude Code gibt es kein /voice'))"
    # neither: our PulseAudio setup goes (the listener for the guest first, and the server that has it), then the restriction
    pa="$HOME/.config/pulse/default.pa"
    if grep -qs 'termux-rootbridge voice' "$pa"; then
        if cp -p "$pa" "$pa.bak-$STAMP"; then   # also yours, should you have changed ours: removed only with its backup
            "$PREFIX/bin/rootbridge" voice stop >/dev/null 2>&1 \
                || say "  Hinweis: PulseAudio ließ sich nicht beenden (rootbridge voice stop)"
            rm -f "$pa"
            say "  entfernt: $pa (weder Vorlesen noch Spracheingabe; Sicherung: $pa.bak-$STAMP)"
        else
            say "  Hinweis: $pa ließ sich nicht sichern und bleibt (von Hand entfernen)"
        fi
    fi
    pa_daemon_conf
fi
if [ "$VOICE_ON" = yes ]; then
    # Android's microphone permission for Termux (root). Only on a terminal, where the root manager can ask you; a pipe or a
    # script run never starts a root command by itself.
    if [ "$DO_SETUP" = 1 ] && { [ -t 0 ] || [ "${ROOTBRIDGE_FORCE_INTERACTIVE:-}" = 1 ]; }; then
        "$PREFIX/bin/rootbridge" voice start >/dev/null 2>&1 || true
        if "$PREFIX/bin/rootbridge" voice status 2>/dev/null | grep -q 'Mikrofon:  *ok'; then
            say "  Mikrofon: ok (die Berechtigung für Termux ist da)"
        else
            say "  Mikrofon-Berechtigung für Termux erteilen (Root; der Root-Manager fragt):"
            "$PREFIX/bin/rootbridge" voice grant \
                || say "  Hinweis: ohne Berechtigung kein Mikrofon. Später:  rootbridge voice grant"
        fi
    else
        say "  Mikrofon-Berechtigung: einmal von Hand   rootbridge voice grant   (braucht Root; PulseAudio startet mit der Sitzung)"
    fi
fi
# Home key: Termux as the digital assistant (root), on every run: "Force stop" in the app info takes the role away. Taken back
# when the key was on before this run, or always with --no-home-key (also without voice, also a role set by hand), and when
# voice goes off (HOMEKEY stays on: voice on again sets the role again).
role=""
if [ "$USE_HOMEKEY" = yes ] && [ "$VOICE_ON" = yes ] && dev_home; then
    role=on
elif [ "$USE_HOMEKEY" = no ] && { [ "$OLD_HOMEKEY" = on ] || [ "$HOMEKEY_OFF_OPT" = 1 ]; }; then
    role=off
elif [ "$USE_HOMEKEY" = yes ] && [ "$OLD_VOICE" != off ] && [ "$VOICE_ON" = no ]; then
    role=off
fi
if [ -n "$role" ]; then
    if [ "$DO_SETUP" = 1 ] && { [ -t 0 ] || [ "${ROOTBRIDGE_FORCE_INTERACTIVE:-}" = 1 ]; }; then
        say "  Home-Taste: Assistenten-Rolle $role (Root; der Root-Manager fragt):"
        "$PREFIX/bin/rootbridge" voice assistant "$role" \
            || say "  Hinweis: Assistenten-Rolle nicht geändert. Später:  rootbridge voice assistant $role"
    else
        say "  Home-Taste: einmal von Hand   rootbridge voice assistant $role   (braucht Root)"
    fi
fi
# key_reader <reader> <yes|no> <label>: a key reader (sidekey-ptt: side key of the Hisense A9, headset-ptt: key of a wired
# headset) is installed on request only; one of an earlier install goes when it is switched off. It runs as
# "<python> $PREFIX/bin/<reader>" (its shebang): only that command line is the reader, not an editor or a `tail` on its file
# or log.
key_reader() {
    local reader="$1" re="^[^ ]*python[^ ]* $PREFIX/bin/$1\$" label="$3"
    if [ "$2" = yes ] && [ "$VOICE_ON" = yes ]; then
        inst "$REPO/termux/bin/$reader" "$PREFIX/bin/$reader" python3
        # start it now (otherwise only the next `rootbridge start` does), and a reader of an earlier install with the new
        # code. The old one has to be gone first: it holds the lock, and a new one that does not get it leaves without a word.
        pkill -f "$re" 2>/dev/null || true
        for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -f "$re" >/dev/null 2>&1 || break; sleep 0.3; done
        if pgrep -f "$re" >/dev/null 2>&1; then
            say "  $label: der alte Leser läuft noch, nicht neu gestartet (pkill -f $reader, dann rootbridge start)"
        else
            setsid nohup "$PREFIX/bin/$reader" >/dev/null 2>&1 < /dev/null &
            sleep 0.5
            if pgrep -f "$re" >/dev/null 2>&1; then
                say "  $label: Leser gestartet (fragt einmal nach Root; Log: ~/.cache/$reader.log)"
            else
                say "  $label: Start fehlgeschlagen (siehe ~/.cache/$reader.log; rootbridge start versucht es erneut)"
            fi
        fi
    elif [ -f "$PREFIX/bin/$reader" ] && grep -q "$reader" "$PREFIX/bin/$reader" 2>/dev/null; then
        pkill -f "$re" 2>/dev/null || true
        rm -f "$PREFIX/bin/$reader"
        say "  $label: Leser entfernt (abgewählt)"
    elif [ "$2" = yes ]; then
        say "  $label: ohne die Sprachsteuerung nicht eingerichtet"
    fi
}
# a key the device file does not describe gets no reader (one of an earlier install goes)
if dev_key SIDEKEY; then key_reader sidekey-ptt "$USE_SIDEKEY" Seitentaste; else key_reader sidekey-ptt no Seitentaste; fi
if dev_key HEADSET; then key_reader headset-ptt "$USE_HEADSET" Headset-Taste; else key_reader headset-ptt no Headset-Taste; fi

# Android's phantom process killer: off on every run on a terminal (an Android update may set it back); on again only when
# it was off before this run. Root: only on a terminal, where the root manager can ask you.
# Switching it on is done once it worked: until then PHANTOM_KILLER=restore keeps it pending.
phantom=""
if [ "$USE_PHANTOM_OFF" = yes ]; then phantom=off; elif [ "$(cfg_get PHANTOM_KILLER)" = restore ]; then phantom=on; fi
if [ -n "$phantom" ]; then
    if [ "$DO_SETUP" = 1 ] && { [ -t 0 ] || [ "${ROOTBRIDGE_FORCE_INTERACTIVE:-}" = 1 ]; }; then
        say "  Phantom Process Killer $phantom (Root; der Root-Manager fragt):"
        if "$PREFIX/bin/rootbridge" phantom-killer "$phantom"; then
            [ "$phantom" = off ] || cfg_set PHANTOM_KILLER on "Phantom Process Killer: on (Android-Standard)"
        else
            say "  Hinweis: nicht geändert. Später:  rootbridge phantom-killer $phantom"
        fi
    else
        say "  Phantom Process Killer: einmal von Hand   rootbridge phantom-killer $phantom   (braucht Root)"
    fi
fi

say "== 4/5 Migration der alten Popup-Bridge (v1)"
if [ "$DO_MIGRATE" = 1 ]; then
    OLD_FILES=""
    for f in "$HOME"/bin/root-bridge-watch.sh "$HOME"/bin/root-bridge-confirm.sh \
             "$HOME"/bin/bridge-lib.sh* "$HOME"/bin/ubuntu-switch.sh* "$HOME"/bin/ubuntu-toggle.sh* \
             "$HOME"/bin/shortcut-backup-* "$HOME"/bin/fix-bashrc.sh "$HOME"/bin/androidsu \
             "$HOME/.termux/boot/10-ubuntu-bridge.sh" \
             "$HOME/.shortcuts/U Toggle" "$HOME/.shortcuts/U Switch" "$HOME/.shortcuts/U 2" \
             "$HOME/.shortcuts/icons/U Toggle.png" "$HOME/.shortcuts/icons/U Switch.png" \
             "$HOME/.shortcuts/icons/U 2.png"; do
        [ -e "$f" ] && OLD_FILES="$OLD_FILES
$f"
    done
    if [ -n "$OLD_FILES" ] || pgrep -f 'root-bridge-watch\.sh' >/dev/null 2>&1; then
        pkill -f 'root-bridge-watch\.sh' 2>/dev/null || true
        tmux kill-window -t "ubuntu:bridge" 2>/dev/null || true
        bk="$BRIDGE_DIR/backup-$STAMP"
        mkdir -p "$bk"
        printf '%s\n' "$OLD_FILES" | while IFS= read -r f; do
            [ -n "$f" ] || continue
            mv "$f" "$bk/" && say "  verschoben nach $bk: ${f#"$HOME"/}"
        done
        sed -i '/^alias ubuntu=~\/bin\/ubuntu-toggle\.sh$/d' "$HOME/.bashrc" 2>/dev/null || true
    else
        say "  nichts zu migrieren"
    fi
    rm -f "$BRIDGE_DIR"/req-*.txt "$BRIDGE_DIR"/res-*.txt 2>/dev/null || true
    # Keep the lock of a RUNNING daemon: deleting it makes the next `rootbridge start` spawn a second
    # daemon while the old one keeps polling. Only leftovers (no pid, dead pid, e.g. from v1) go.
    lock_pid="$(cat "$BRIDGE_DIR/.lock/pid" 2>/dev/null || true)"
    if ! { [[ "$lock_pid" =~ ^[0-9]+$ ]] && kill -0 "$lock_pid" 2>/dev/null; }; then
        rm -rf "$BRIDGE_DIR/.lock" 2>/dev/null || true
    fi
else
    say "  übersprungen"
fi

say "== 5/5 Gast ($DISTRO)"
if [ "$DO_GUEST" = 1 ]; then
    if [ -n "$SWITCH_FROM" ]; then
        # the sessions run in the old guest; the daemon starts again at the end
        "$PREFIX/bin/rootbridge" stop >/dev/null 2>&1 || true
        if [ "$SWITCH_BACKUP" = yes ]; then
            say "== Sicherung des $SWITCH_FROM-Gasts ($RESTORE_DIR)"
            # DISTRO is still the old guest's: the backup takes its files
            ROOTBRIDGE_CONFIG="$CFG" "$PREFIX/bin/rootbridge" backup "$RESTORE_DIR" \
                || die "Die Sicherung des $SWITCH_FROM-Gasts ist fehlgeschlagen; nichts umgestellt. Erneut: bash install.sh --distro $DISTRO"
        fi
    fi
    GROOT="$(find_guest_root "$DISTRO" || true)"
    if [ -z "$GROOT" ] && [ "$DO_SETUP" = 1 ]; then
        say "  Gast '$DISTRO' fehlt: proot-distro install $DISTRO (Download, das dauert)"
        proot-distro install "$DISTRO" || die "proot-distro install $DISTRO ist fehlgeschlagen (Netz? Speicherplatz?). Erneut starten: bash install.sh"
        SETUP_DID=1
        GROOT="$(find_guest_root "$DISTRO" || true)"
    fi
    [ -n "$GROOT" ] || die "Gast '$DISTRO' nicht gefunden (proot-distro list). Ohne --no-setup legt install.sh ihn an; oder mit --no-guest überspringen."
    STAGE="$GROOT/var/tmp/termux-rootbridge-install"
    rm -rf "$STAGE"; mkdir -p "$STAGE"
    cp -r "$REPO/guest/." "$STAGE/"
    # Setup, part 3: python3 / curl / certificates / shellcheck and Claude Code in the guest. Looked up from outside
    # (a link that points outside the guest only counts as missing: setup-guest.sh then looks properly)
    guest_ready() {
        local h="${ROOTBRIDGE_GUEST_HOME:-/root}"
        { [ -e "$GROOT/usr/bin/python3" ] && [ -e "$GROOT/usr/bin/curl" ] && [ -s "$GROOT/etc/ssl/certs/ca-certificates.crt" ]; } || return 1
        [ -e "$GROOT/usr/bin/shellcheck" ] || return 1      # the agents check their shell scripts with it
        [ -e "$GROOT/usr/bin/ssh" ] || return 1             # git over SSH with the keys of the backup
        [ -e "$GROOT/usr/bin/gh" ] || return 1              # GitHub CLI, its login comes with the backup
        if [ "$USE_CLAUDE" = yes ]; then
            { [ -x "$GROOT$h/.local/bin/claude" ] || [ -x "$GROOT/usr/local/bin/claude" ] || [ -x "$GROOT/usr/bin/claude" ]; } || return 1
        fi
        if [ "$USE_CODEX" = yes ]; then
            # ~/.local/bin/codex is a link with an absolute target inside the guest: the link itself counts
            { [ -x "$GROOT$h/.local/bin/codex" ] || [ -L "$GROOT$h/.local/bin/codex" ]; } || return 1
            [ -e "$GROOT/usr/bin/git" ] || return 1
            [ -e "$GROOT/usr/bin/bwrap" ] || return 1
        fi
        if [ "$USE_OPENCODE" = yes ]; then
            [ -x "$GROOT$h/.opencode/bin/opencode" ] || return 1
            [ -e "$GROOT/usr/bin/git" ] || return 1
        fi
        if [ "$VOICE_ON" = yes ] || [ "$SPEAK_ON" = yes ]; then
            [ -e "$GROOT/usr/bin/rec" ] || return 1      # sox: Claude Code records through it, the guest plays through it
        fi
        if [ "$SPEAK_ON" = yes ]; then
            [ -e "$GROOT/opt/piper/bin/piper" ] || return 1   # Piper reads the answers aloud
            local voice=de_DE-kerstin-medium; [ "$LANGUAGE" = en ] && voice=en_US-lessac-medium
            [ -s "$GROOT/opt/piper/voices/$voice.onnx" ] || return 1
            [ -s "$GROOT/opt/piper/voices/$voice.onnx.json" ] || return 1
            # Articulino (your own voice): its model comes last, so it stands for the whole step; a failed download is
            # tried again with the next installation
            [ -s "$GROOT/opt/articulino/model/int8/voice.onnx" ] || return 1
        fi
        if [ "$USE_CLAUDE" = yes ] && [ "$USE_CODEX" = yes ]; then
            { [ -e "$GROOT/usr/bin/node" ] || [ -e "$GROOT/usr/bin/nodejs" ]; } || return 1
        fi
        return 0
    }
    if [ "$DO_SETUP" = 1 ] && ! guest_ready; then
        say "  Gast: Voraussetzungen und Werkzeuge einrichten (Claude Code: $USE_CLAUDE, Codex: $USE_CODEX, OpenCode: $USE_OPENCODE)"
        proot-distro login "$DISTRO" -- bash /var/tmp/termux-rootbridge-install/setup-guest.sh \
            --claude "$USE_CLAUDE" --codex "$USE_CODEX" --opencode "$USE_OPENCODE" --voice "$VOICE_ON" --speak "$SPEAK_ON" --language "$LANGUAGE" \
            || die "Die Einrichtung im Gast ist fehlgeschlagen. Erneut starten: bash install.sh"
        SETUP_DID=1
    fi
    GUEST_ARGS=(--src /var/tmp/termux-rootbridge-install --autonomous "$AUTONOMOUS" --claude "$USE_CLAUDE" --codex "$USE_CODEX" --opencode "$USE_OPENCODE" --voice "$VOICE_ON" --speak "$SPEAK_ON" --language "$LANGUAGE" --codex-bypass "$USE_BYPASS" --guidelines "$USE_GUIDE")
    if [ -n "$REVIEWERS" ]; then GUEST_ARGS+=(--reviewers "$REVIEWERS"); fi
    if [ -n "$REMOTE_NAME" ]; then GUEST_ARGS+=(--remote-name "$REMOTE_NAME"); fi
    if [ "$LANGUAGE_SET" = 1 ]; then GUEST_ARGS+=(--set-language); fi   # chosen in this run: Claude Code's setting follows
    if [ "$MODEL_SET" = 1 ]; then GUEST_ARGS+=(--model "$MODEL"); fi
    if [ "$DO_COLORS" = 1 ]; then GUEST_ARGS+=(--theme "$CLAUDE_THEME"); fi
    if [ -n "$APT_MODE" ]; then GUEST_ARGS+=(--apt-upgrade "$APT_MODE"); fi
    if [ -n "$CLAUDE_UPD_MODE" ]; then GUEST_ARGS+=(--claude-update "$CLAUDE_UPD_MODE"); fi
    if [ -n "$CODEX_UPD_MODE" ]; then GUEST_ARGS+=(--codex-update "$CODEX_UPD_MODE"); fi
    if [ -n "$OPENCODE_UPD_MODE" ]; then GUEST_ARGS+=(--opencode-update "$OPENCODE_UPD_MODE"); fi
    # rb_config_line_ok LINE: may this KEY=VALUE line of a restored config be taken over? Keys that rb_load_config knows: only
    # when that parser accepts the value (SU_ARGS=-mm -c, CLAUDE_ARGS, ...); keys only the installer reads: plain values.
    rb_config_line_ok() {
        local line="$1" key val probe rc
        key="${line%%=*}"; val="${line#*=}"
        val="${val%\"}"; val="${val#\"}"; val="${val%\'}"; val="${val#\'}"
        case "$key" in
            APT_UPGRADE|CLAUDE_UPDATE|CODEX_UPDATE|OPENCODE_UPDATE|CODEX_BYPASS|DEVICE|GUIDELINES|LANGUAGE|PHANTOM_KILLER|REMOTE_NAME|REVIEWERS|SPEAK_SHORT)
                [[ "$val" =~ ^[A-Za-z0-9_.:@,+-]*$ ]] ;;
            *)
                probe="$(mktemp "$STAGE_DIR/probe.XXXXXX")"   # in the private folder, not in TMPDIR
                printf '%s\n' "$line" > "$probe"
                ( ROOTBRIDGE_CONFIG="$probe"
                  # shellcheck source=termux/lib/rootbridge-lib.sh
                  . "$REPO/termux/lib/rootbridge-lib.sh"
                  printf -v "$key" '%s' "__rb_unset__"
                  rb_load_config
                  [ "${!key}" != "__rb_unset__" ] ) >/dev/null 2>&1
                rc=$?
                rm -f "$probe"
                return $rc ;;
        esac
    }
    # the backup, when it was chosen above (it asks the password of its secrets itself): after the guest is set up and
    # before install-guest.sh, which then lays this run's choices over what came back (guest config, CODEX_ARGS, settings)
    # a switch back into a guest that has its own work folder: it stays (the restore brings the other guest's config)
    DEST_WORKDIR=""
    if [ -n "$SWITCH_FROM" ] && [ -f "$GROOT/etc/termux-rootbridge.conf" ]; then
        DEST_WORKDIR="$(cfg_get WORKDIR "$GROOT/etc/termux-rootbridge.conf")"
        [[ "$DEST_WORKDIR" =~ ^/[A-Za-z0-9._/-]+$ ]] || DEST_WORKDIR=""
    fi
    if [ "$DO_RESTORE" = yes ]; then
        say "== Sicherung wiederherstellen ($RESTORE_DIR)"
        # the backup brings its Termux config back; what this run installed by (tools, voice, language, ...) stays: every
        # key set now wins over the restored one, the backup only adds the keys missing here
        # snapshots in the private staging folder, which no backup takes (beside the config a settings rule could)
        STAGE_DIR="$HOME/.cache/rootbridge-backup"
        mkdir -p "$HOME/.cache"
        mkdir -p "$STAGE_DIR" && chmod 700 "$STAGE_DIR"
        # a link anywhere on the way (~/.cache pointing to shared storage) would take the snapshots out of the private home
        if [ -L "$HOME/.cache" ] || [ -L "$STAGE_DIR" ] || [ ! -d "$STAGE_DIR" ]; then
            die "$STAGE_DIR ist kein eigener Ordner (Link): die Wiederherstellung wird nicht gestartet"
        fi
        THIS_RUN="$STAGE_DIR/config.this-run.$$"
        cp "$CFG" "$THIS_RUN"
        # into this run's guest (DISTRO is stored only at the end of this step, after a switch it still names the old one)
        if ! RB_GUEST_ROOT="$GROOT" ROOTBRIDGE_CONFIG="$CFG" "$PREFIX/bin/rootbridge" restore "$RESTORE_DIR"; then
            # a switch goes on only with what was to come along: the launchers stay on the old guest
            [ -z "$SWITCH_FROM" ] || die "Die Wiederherstellung in den $DISTRO-Gast ist nicht durchgelaufen; der Gast bleibt $SWITCH_FROM. Erneut: bash install.sh --distro $DISTRO"
            say "Hinweis: die Wiederherstellung ist nicht durchgelaufen. Später:  rootbridge restore $RESTORE_DIR  (eine ältere Sicherung ohne Siegel: mit --legacy)"
        fi
        gc="$GROOT/etc/termux-rootbridge.conf"
        if [ -n "$DEST_WORKDIR" ] && [ -f "$gc" ] && [ "$(cfg_get WORKDIR "$gc")" != "$DEST_WORKDIR" ]; then
            tmp="$gc.new.$$"
            { grep -v '^WORKDIR=' "$gc"; printf 'WORKDIR=%s\n' "$DEST_WORKDIR"; } > "$tmp" && mv -f "$tmp" "$gc"
            say "  Arbeitsordner des $DISTRO-Gasts bleibt: $DEST_WORKDIR"
        fi
        if ! cmp -s "$CFG" "$THIS_RUN"; then
            # this run's file, plus the keys only the backup had; every line is data: no sed program is built from it, and
            # only plain values are taken over (the config is read as shell)
            merged="$STAGE_DIR/config.merge.$$"
            cp "$THIS_RUN" "$merged"
            while IFS= read -r line; do
                case "$line" in
                    [A-Z]*=*) ;;
                    *) continue ;;
                esac
                key="${line%%=*}"
                if ! printf '%s' "$key" | grep -Eq '^[A-Z][A-Z0-9_]*$'; then continue; fi
                if grep -q "^$key=" "$THIS_RUN"; then continue; fi
                # the config is parsed key by key (rb_load_config), never run as shell; a line is taken over only when that
                # parser would accept it, so the restored file cannot hold anything the daemon would not read either
                if rb_config_line_ok "$line"; then
                    printf '%s\n' "$line" >> "$merged"
                else
                    say "  aus der Sicherung nicht übernommen (kein gültiger Wert): $key"
                fi
            done < "$CFG"
            if cat "$merged" > "$CFG.new.$$" && mv -f "$CFG.new.$$" "$CFG"; then
                rm -f "$merged" "$THIS_RUN"
            else
                # the merged config could not be put in place: this run's own copy goes back, the snapshots stay
                rm -f "$CFG.new.$$"
                cp "$THIS_RUN" "$CFG" || true
                die "Die Konfig konnte nach der Wiederherstellung nicht zusammengeführt werden. Kopien: $THIS_RUN, $merged"
            fi
        else
            rm -f "$THIS_RUN"
        fi
        extra_keys   # the restored termux.properties may lack our keys block
        device_conf  # the restored device.conf may belong to another device file than this run's DEVICE
        # the Codex sandbox as the restored config has it, unless an option of this run said otherwise (the guest
        # argument was built before the restore)
        # (the Termux or the restored guest config says CODEX_BYPASS=off, or the guest config has CODEX_ARGS without the bypass flag)
        gconf="$(find_guest_root "$DISTRO" || true)/etc/termux-rootbridge.conf"
        if [ "$USE_BYPASS_SET" != 1 ] && { [ "$(cfg_get CODEX_BYPASS)" = off ] \
                || { [ -f "$gconf" ] && [ "$(sed -n 's/^CODEX_BYPASS=//p' "$gconf" | tail -n 1 | tr -d "\"'")" = off ]; } \
                || { [ -f "$gconf" ] && grep -q '^CODEX_ARGS=' "$gconf" \
                     && ! grep '^CODEX_ARGS=' "$gconf" | grep -q 'dangerously-bypass'; }; }; then
            USE_BYPASS=no
            cfg_set CODEX_BYPASS off "Codex-Sandbox bleibt an: gespeichert (CODEX_BYPASS=off)"   # also for the next run
            for i in "${!GUEST_ARGS[@]}"; do
                if [ "${GUEST_ARGS[$i]}" = --codex-bypass ]; then GUEST_ARGS[i+1]=no; fi
            done
            say "  Codex-Sandbox: bleibt an (aus der Sicherung)"
        fi
    fi
    proot-distro login "$DISTRO" -- bash /var/tmp/termux-rootbridge-install/install-guest.sh "${GUEST_ARGS[@]}"
    rm -rf "$STAGE"
    # the work folder of the old guest, into an empty one of the new guest (nothing there is overwritten)
    # (each one as its guest config has it: WORKDIR in /etc/termux-rootbridge.conf, default /root/work)
    if [ "$SWITCH_WORK" = yes ]; then
        guest_workdir() { local v=""; [ ! -f "$1/etc/termux-rootbridge.conf" ] || v="$(cfg_get WORKDIR "$1/etc/termux-rootbridge.conf")"; printf '%s' "${v:-/root/work}"; }
        # no_link <root> <path>: no part of the path below the guest root is a link (one the guest set could lead out of
        # it, into the private files of Termux); cp -a itself copies the links inside the folder as links
        no_link() { local p="$1" part; for part in ${2//\// }; do p="$p/$part"; [ ! -L "$p" ] || return 1; done; }
        # proot keeps a hard link (git packs, pip) as a link to /.l2s/.l2s.NAME000N, itself a link to the file
        # /.l2s/.l2s.NAME, written with the Termux path of the old guest: copied as they are, the new guest cannot read
        # them. l2s_file <link>: that file, when every hop is an absolute path straight into the old guest's /.l2s (a
        # relative link of a project is never one, nothing the guest set can lead elsewhere; the old guest is stopped);
        # own_files <dir>: each such link becomes a copy of its file (cp -T: never into a folder the link points to)
        l2s_file() {
            local dir="$OLD_GROOT/.l2s" t
            [ -d "$dir" ] && [ ! -L "$dir" ] || return 1
            t="$(readlink "$1")"
            for _ in 1 2; do   # two hops: the link, then the file
                [ "${t%/*}" = "$dir" ] && [[ "${t##*/}" == .l2s.* ]] || return 1
                if [ -L "$t" ]; then t="$(readlink "$t")"
                elif [ -f "$t" ]; then printf '%s' "$t"; return 0
                else return 1; fi
            done
            return 1
        }
        own_files() {
            local link file
            while IFS= read -r -d '' link; do
                if file="$(l2s_file "$link")"; then cp -pT --remove-destination "$file" "$link" || return 1; fi
            done < <(find "$1" -type l -print0)
        }
        w="$(guest_workdir "$OLD_GROOT")"; nw="$(guest_workdir "$GROOT")"
        if ! [[ "$w$nw" =~ ^/[A-Za-z0-9._/-]+$ ]] || [[ "/$w/$nw/" == *"/../"* ]]; then
            say "  Arbeitsordner: WORKDIR=$w bzw. $nw ist kein einfacher Pfad, nicht kopiert"
        elif ! no_link "$OLD_GROOT" "$w" || ! no_link "$GROOT" "$nw"; then
            say "  Arbeitsordner: auf dem Weg zu $w bzw. $nw liegt ein Link, nicht kopiert (von Hand: $OLD_GROOT$w)"
        elif [ ! -d "$OLD_GROOT$w" ]; then
            say "  Arbeitsordner: $w gibt es im $SWITCH_FROM-Gast nicht"
        elif [ -n "$(ls -A "$GROOT$nw" 2>/dev/null)" ]; then
            say "  Arbeitsordner: $nw im $DISTRO-Gast ist nicht leer, nicht kopiert (von Hand: $OLD_GROOT$w)"
        elif mkdir -p "$GROOT$nw" && cp -a "$OLD_GROOT$w/." "$GROOT$nw/" && own_files "$GROOT$nw"; then
            say "  Arbeitsordner: $w aus dem $SWITCH_FROM-Gast nach $nw kopiert"
        else
            say "  Hinweis: der Arbeitsordner ließ sich nicht ganz kopieren (von Hand: $OLD_GROOT$w)"
        fi
        # Claude Code's conversations (/resume, claude --continue): those the new guest does not have yet, nothing there
        # is overwritten. Only under the same work folder path (the folders and the transcripts name it), and without the
        # private notes (PROJECT/memory): those come with the restore, as chosen there.
        copy_talks() {
            tar -C "$1" --anchored --exclude='./*/memory' -cf - . | tar -C "$2" --skip-old-files -xf - \
                && [ "${PIPESTATUS[0]}" = 0 ]
        }
        c=/root/.claude/projects
        if [ ! -d "$OLD_GROOT$c" ]; then
            :
        elif [ "$w" != "$nw" ]; then
            say "  Unterhaltungen: der Arbeitsordner ist im $DISTRO-Gast $nw statt $w, nicht kopiert (Claude Code fände sie dort nicht)"
        elif ! no_link "$OLD_GROOT" "$c" || ! no_link "$GROOT" "$c" \
                || [ -n "$(find "$GROOT$c" -type l -exec test -d {} \; -print -quit 2>/dev/null)" ]; then
            # (a link to a folder inside the new guest's conversations: tar would write through it)
            say "  Unterhaltungen: auf dem Weg zu $c liegt ein Link, nicht kopiert (von Hand: $OLD_GROOT$c)"
        elif mkdir -p "$GROOT$c" && copy_talks "$OLD_GROOT$c" "$GROOT$c" && own_files "$GROOT$c"; then
            say "  Unterhaltungen von Claude Code aus dem $SWITCH_FROM-Gast übernommen"
        else
            say "  Hinweis: die Unterhaltungen ließen sich nicht ganz kopieren (von Hand: $OLD_GROOT$c)"
        fi
    fi
    # the guest is set up (and what came along is there): from now on the launchers, backup and restore use it; a run that
    # failed before this point leaves them on the old guest, and the next one switches again
    if [ "$(cfg_get DISTRO)" != "$DISTRO" ]; then cfg_set DISTRO "$DISTRO" "Gast: $DISTRO"; fi
    if [ -n "$SWITCH_FROM" ] && [ "$DO_WIDGETS" = 1 ]; then guest_widget "$DISTRO"; fi   # the widget follows the guest now
    if [ -n "$SWITCH_FROM" ]; then
        say "  Der $SWITCH_FROM-Gast bleibt (zurück: bash install.sh --distro $SWITCH_FROM; entfernen: proot-distro remove $SWITCH_FROM)"
    fi
else
    say "  übersprungen (--no-guest)"
fi

# the language, now that the guest has it: Claude Code's setting, the texts, the voice (whose model may be missing with
# --no-setup: then a note, and speak.py reads with the German voice)
if [ "$LANGUAGE_SET" = 1 ]; then
    cfg_set LANGUAGE "$LANGUAGE" "Sprache: $LANGUAGE"
fi
if [ "$DO_GUEST" = 1 ] && [ "$SPEAK_ON" = yes ] && [ "$LANGUAGE" = en ] && [ -n "${GROOT:-}" ] \
        && ! [ -s "$GROOT/opt/piper/voices/en_US-lessac-medium.onnx" ]; then
    say "Hinweis: die englische Piper-Stimme fehlt im Gast (Piper liest bis dahin deutsch). Laden mit:  bash install.sh"
fi
# the choice of the tools, now that they are installed (see the questions)
if [ "$USE_CLAUDE_SET" = 1 ]; then
    cfg_set TOOL_CLAUDE "$(onoff "$USE_CLAUDE")" "Claude Code: $USE_CLAUDE"
fi
if [ "$USE_CODEX_SET" = 1 ]; then
    cfg_set TOOL_CODEX "$(onoff "$USE_CODEX")" "Codex: $USE_CODEX"
fi
if [ "$USE_OPENCODE_SET" = 1 ]; then
    cfg_set TOOL_OPENCODE "$(onoff "$USE_OPENCODE")" "OpenCode: $USE_OPENCODE"
fi
if [ "$REVIEWERS_SET" = 1 ]; then
    cfg_set REVIEWERS "$REVIEWERS" "Prüfer der Commits von Claude Code: $REVIEWERS"
fi

# start the daemon with the new code: without it nothing reads aloud and no root request gets through until the next session
if "$PREFIX/bin/rootbridge" daemon-start >/dev/null 2>&1; then
    say "Daemon läuft."
else
    say "Daemon startet nicht (siehe $BRIDGE_DIR/daemon.log; erneut mit: rootbridge daemon-start)"
fi

say
say "Fertig. Weiter:"
say "  rootbridge status        # Zustand prüfen"
say "  source ~/.bashrc         # Kurzbefehle in dieser Termux-Shell laden (oder ein neues Fenster öffnen)"
say "  $GUEST_ALIAS                   # $GUEST_WIDGET-Shell öffnen (auch Widget '$GUEST_WIDGET')"
if [ "$USE_CLAUDE" = yes ]; then
    say "  claude                   # Claude-Code-Sitzung öffnen (legt sie an; auch Widget 'Claude')"
    say "  claude -n                # neue Claude-Unterhaltung in einem eigenen Fenster starten"
fi
if [ "$USE_CODEX" = yes ]; then
    say "  codex                    # Codex-Sitzung öffnen (legt sie an; auch Widget 'Codex')"
fi
if [ "$USE_OPENCODE" = yes ]; then
    say "  opencode                 # OpenCode-Sitzung öffnen (legt sie an; auch Widget 'OpenCode')"
fi
say "  rootbridge start         # Daemon + Sitzung (Termux:Boot ruft das nach einem Neustart auf)"
say "Normale Termux-Fenster bleiben reine Shells; Claude Code und Codex starten nicht mehr automatisch."
if [ "$DO_GUEST" = 1 ] && [ "$AUTONOMOUS" = yes ] && [ "$USE_CLAUDE" = yes ]; then
    say "Claude Code startet im Bypass-Modus im Ordner /root/work; Android-Root-Befehle fragen weiter nach."
fi
if [ "$USE_CLAUDE" = yes ]; then
    say "Nach dem ersten Start: Claude Code neu starten, damit die Managed Settings gelten."
fi
if [ "$DO_GUEST" = 1 ] && [ "$USE_CODEX" = yes ]; then
    say "Codex: einmal anmelden mit   rootbridge codex-login   (der Browser öffnet sich)."
    if [ "$USE_CLAUDE" = yes ]; then
        case ",${REVIEWERS:-codex}," in *,codex,*)
            say "Bis dahin blockiert der Pre-Commit-Review jeden Commit von Claude Code (Notausgang: rootbridge review-off)." ;;
        esac
        say "Beim Start eines der beiden Fenster werden beide aktualisiert (claude update, codex update)."
    else
        say "Beim Start von Codex wird Codex aktualisiert (codex update)."
    fi
fi
if [ "$SETUP_DID" = 1 ]; then
    say "Noch von Hand: Root-Freigabe für Termux bestätigen (Root-Manager fragt bei der ersten Anfrage), Termux:Boot einmal öffnen,"
    if [ "$USE_CLAUDE" = yes ]; then
        say "das Widget 'Claude' auf den Homescreen legen, beim ersten Start in Claude Code anmelden (/login, der Browser öffnet sich)."
    else
        say "das Widget 'Codex' auf den Homescreen legen, Codex anmelden (rootbridge codex-login)."
    fi
fi
if [ "$DO_GUEST" = 1 ] && [ "$USE_OPENCODE" = yes ]; then
    say "OpenCode: einmal anmelden mit /connect im OpenCode-Fenster (Anbieter wählen, der Browser öffnet sich)."
    if [ "$USE_CLAUDE" = yes ] && { [ "$USE_CODEX" = no ] || [[ "$REVIEWERS" == *opencode* ]]; }; then
        say "OpenCode prüft die Commits von Claude Code; ohne Anmeldung blockiert der Review jeden Commit (Notausgang: rootbridge review-off)."
    fi
fi
if [ "$USE_CODEX" = yes ] && [ "$USE_BYPASS" = yes ]; then
    say "Codex läuft ohne eigene Sandbox (unter proot scheitert sie; aus mit --no-codex-bypass). Android-Root bekommt es nur, wenn du die Rückfrage in Termux bestätigst."
fi
if [ "$SPEAK_ON" = yes ]; then
    say "Vorlesen: Claudes Antworten liest Piper vor, mit deiner eigenen Stimme nach 'rootbridge-speak --record' im Gast; aus/an mit dem Widget 'Vorlesen' oder 'rootbridge voice speak off|on', sofort still mit 'Stopp'; beim Sprechen (ptt, /voice) pausiert es. Sprachbefehle: 'Welche Sprachbefehle gibt es'."
fi
if [ "$VOICE_ON" = yes ]; then
    say "Sprache: /voice in Claude Code (Alt+K; ptt folgt dem Modus hold oder tap); 'ptt start' / 'ptt stop' bedienen die Taste für dich (rootbridge voice status prüft das Mikrofon)."
    if [ "$USE_SIDEKEY" = yes ]; then
        say "Seitentaste: Langdruck = aufnehmen, loslassen = stoppen. In den E-Ink-Einstellungen den Langdruck auf 'Nothing' stellen."
    fi
    if [ "$USE_HOMEKEY" = yes ]; then
        say "Home-Taste: Langdruck startet die Spracheingabe, der nächste schickt ab (nach 'Beenden erzwingen' von Termux: bash install.sh)."
    fi
    if [ "$USE_HEADSET" = yes ]; then
        say "Headset-Taste: Langdruck startet, loslassen und sprechen, der nächste Langdruck schickt ab. Das Headset vor dem Start der Sitzung einstecken."
    fi
fi
if [ "$DO_EXTRAKEYS" = 1 ]; then
    say "Zusatztasten: S-TAB (Shift+Tab; Wisch nach oben = Tab) und KEYBOARD stehen in ~/.termux/termux.properties."
fi
if [ "$DO_COLORS" = 1 ]; then
    say "Farben: der E-Paper-Termux bringt das helle und das dunkle Schema selbst mit und folgt dem Telefon (eigene Dateien: ~/.termux/colors-light.properties, colors-dark.properties, colors.properties). Claude Code nutzt das Theme '$CLAUDE_THEME' (Auto epaper: ANSI-Farben des Termux-Schemas, wechselt mit dem Telefon live zwischen hell und dunkel)."
fi
