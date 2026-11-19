#!/bin/bash
# setup-guest.sh - runs INSIDE the guest (install.sh --setup calls it through proot-distro, before
# install-guest.sh). Makes a fresh Ubuntu ready for the bridge, without any question:
#   1. python3, curl and the CA certificates (apt-get; only when one is missing); git when Codex is part of
#      the installation (Codex reviews through git, and so does the pre-commit hook), plus bubblewrap for its sandbox; nodejs when both tools are
#      (the Codex plugin of Claude Code is a node program, Node.js 18.18 or newer); sox for /voice
#      when Claude Code and voice are both part of it (Claude Code records through `rec`); shellcheck for the
#      agents' shell scripts (the CI of this repository checks them with it)
#   2. Claude Code with the official installer (only when there is no claude yet)
#   3. Codex with the official standalone installer (only when there is no codex yet)
#   4. Piper for the speech output (with Claude Code and voice): pip package piper-tts in a venv (PIPER_DIR) and the
#      German voice de_DE-kerstin-medium (only what is missing; python3-venv from apt when venv cannot be made)
# The hooks and Codex plugin declaration are written by install-guest.sh. Claude Code fetches the plugin at
# session start; setup never invokes `claude plugin ...`.
# Idempotent: with everything in place it changes nothing and does not touch the network.
#
#   setup-guest.sh [--claude yes|no] [--codex yes|no] [--voice yes|no]       (all default to yes)
#     --voice: sox with the PulseAudio plugin (apt-get), which Claude Code's /voice records through, and Piper (step 4),
#              which reads the answers aloud; only with Claude Code
#
#   CLAUDE_INSTALL_URL        installer script of Claude Code (default https://claude.ai/install.sh)
#   CODEX_INSTALL_URL         installer script of Codex (default https://chatgpt.com/codex/install.sh)
#   ROOTBRIDGE_GUEST_HOME     home of the guest user (default /root, like install-guest.sh)
#   ROOTBRIDGE_CA_BUNDLE      certificate bundle to look for (default /etc/ssl/certs/ca-certificates.crt)
#   PIPER_DIR                 venv of Piper (default /opt/piper; the voices in its voices/)

set -eu

HOME_DIR="${ROOTBRIDGE_GUEST_HOME:-/root}"
CA_BUNDLE="${ROOTBRIDGE_CA_BUNDLE:-/etc/ssl/certs/ca-certificates.crt}"
INSTALL_URL="${CLAUDE_INSTALL_URL:-https://claude.ai/install.sh}"
CODEX_URL="${CODEX_INSTALL_URL:-https://chatgpt.com/codex/install.sh}"
PIPER_DIR="${PIPER_DIR:-/opt/piper}"
PIPER_VOICE_NAME=de_DE-kerstin-medium   # speak.py reads this voice
CLAUDE_ON=yes; CODEX_ON=yes; VOICE_ON=yes

say() { printf '%s\n' "$*"; }
die() { echo "setup-guest.sh: $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
    case "$1" in
        --claude) [ $# -ge 2 ] || die "--claude braucht yes oder no"; CLAUDE_ON="$2"; shift 2 ;;
        --codex)  [ $# -ge 2 ] || die "--codex braucht yes oder no";  CODEX_ON="$2";  shift 2 ;;
        --voice)  [ $# -ge 2 ] || die "--voice braucht yes oder no";  VOICE_ON="$2";  shift 2 ;;
        *) echo "setup-guest.sh: unbekannte Option: $1" >&2; exit 2 ;;
    esac
done
case "$CLAUDE_ON$CODEX_ON" in
    yesyes|yesno|noyes) ;;
    *) die "--claude / --codex: erlaubt ist yes oder no, und mindestens eines von beiden muss yes sein" ;;
esac
case "$VOICE_ON" in yes|no) ;; *) die "--voice: erlaubt ist yes oder no" ;; esac

TMPDIR_SETUP="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_SETUP"' EXIT

claude_present() { [ -x "$HOME_DIR/.local/bin/claude" ] || command -v claude >/dev/null 2>&1; }
# the codex in ~/.local/bin is a link with an absolute target (the standalone package under ~/.codex)
codex_present() { [ -x "$HOME_DIR/.local/bin/codex" ] || [ -L "$HOME_DIR/.local/bin/codex" ] || command -v codex >/dev/null 2>&1; }

# ------------------------------------------------------------------ 1. packages
say "== Gast: Voraussetzungen"
pkgs=""
# guest_has <command>: the guest has it itself, not only as a program of Termux on the PATH. Isolated sessions
# (rootbridge GUEST_ISOLATE) do not see Termux, so python3, curl and git of Termux would be gone there.
guest_has() { local p; p="$(command -v "$1" 2>/dev/null)" && [ "${p#/data/data/com.termux/}" = "$p" ]; }
guest_has python3 || pkgs="$pkgs python3"
guest_has curl    || pkgs="$pkgs curl"
[ -s "$CA_BUNDLE" ] || pkgs="$pkgs ca-certificates"
guest_has shellcheck || pkgs="$pkgs shellcheck"
if [ "$CODEX_ON" = yes ]; then
    guest_has git || pkgs="$pkgs git"
    command -v bwrap >/dev/null 2>&1 || pkgs="$pkgs bubblewrap"
fi
if [ "$CLAUDE_ON" = yes ] && [ "$CODEX_ON" = yes ]; then
    guest_has node || pkgs="$pkgs nodejs"
fi
if [ "$CLAUDE_ON" = yes ] && [ "$VOICE_ON" = yes ]; then
    guest_has rec || pkgs="$pkgs sox libsox-fmt-pulse"
    # Piper goes into a venv; Ubuntu's python3 makes one only with python3-venv (ensurepip)
    if [ ! -x "$PIPER_DIR/bin/piper" ] && ! python3 -I -c 'import ensurepip' >/dev/null 2>&1; then
        pkgs="$pkgs python3-venv"
    fi
fi
if [ -n "$pkgs" ]; then
    say "  apt-get install:$pkgs"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update || die "apt-get update ist fehlgeschlagen (Netz?). Erneut starten: bash install.sh --setup"
    # shellcheck disable=SC2086   # $pkgs is a list of package names on purpose
    apt-get install -y --no-install-recommends $pkgs \
        || die "apt-get install$pkgs ist fehlgeschlagen. Erneut starten: bash install.sh --setup"
else
    say "  python3, curl, Zertifikate und shellcheck sind da"
fi
# the plugin needs Node.js 18.18 or newer; only a warning (an older node is the user's own choice)
if [ "$CLAUDE_ON" = yes ] && [ "$CODEX_ON" = yes ] && command -v node >/dev/null 2>&1; then
    nv="$(node --version 2>/dev/null || true)"; nv="${nv#v}"
    nmaj="${nv%%.*}"; nrest="${nv#*.}"; nmin="${nrest%%.*}"
    if [[ "$nmaj" =~ ^[0-9]+$ ]] && [[ "$nmin" =~ ^[0-9]+$ ]] && { [ "$nmaj" -lt 18 ] || { [ "$nmaj" -eq 18 ] && [ "$nmin" -lt 18 ]; }; }; then
        say "  Hinweis: node $nv ist älter als 18.18 - das Codex-Plugin von Claude Code braucht mindestens 18.18."
    fi
fi

# ------------------------------------------------------------------ 2. Claude Code
if [ "$CLAUDE_ON" = yes ]; then
    say "== Gast: Claude Code"
    if claude_present; then
        say "  claude ist schon installiert"
    else
        tmp="$TMPDIR_SETUP/claude-install.sh"
        say "  lade den Installer: $INSTALL_URL"
        curl -fsSL "$INSTALL_URL" -o "$tmp" \
            || die "Download von $INSTALL_URL ist fehlgeschlagen (Netz?). Erneut starten: bash install.sh --setup"
        HOME="$HOME_DIR" bash "$tmp" \
            || die "Der Claude-Code-Installer ist fehlgeschlagen. Erneut starten: bash install.sh --setup"
        claude_present \
            || die "Der Claude-Code-Installer lief durch, aber es gibt kein claude ($HOME_DIR/.local/bin/claude)."
        say "  claude installiert: $HOME_DIR/.local/bin/claude"
    fi
fi

# ------------------------------------------------------------------ 3. Codex
if [ "$CODEX_ON" = yes ]; then
    say "== Gast: Codex"
    if codex_present; then
        say "  codex ist schon installiert"
    else
        tmp="$TMPDIR_SETUP/codex-install.sh"
        say "  lade den Installer: $CODEX_URL"
        curl -fsSL "$CODEX_URL" -o "$tmp" \
            || die "Download von $CODEX_URL ist fehlgeschlagen (Netz?). Erneut starten: bash install.sh --setup (ohne Codex: --no-codex)"
        # Non-interactive. ~/.local/bin is on the PATH of the installer, so it writes no PATH block into a shell
        # profile (the guest ~/.bashrc block of install-guest.sh takes care of the PATH).
        HOME="$HOME_DIR" CODEX_NON_INTERACTIVE=1 PATH="$HOME_DIR/.local/bin:$PATH" sh "$tmp" \
            || die "Der Codex-Installer ist fehlgeschlagen. Erneut starten: bash install.sh --setup (ohne Codex: --no-codex)"
        codex_present \
            || die "Der Codex-Installer lief durch, aber es gibt kein codex ($HOME_DIR/.local/bin/codex)."
        say "  codex installiert: $HOME_DIR/.local/bin/codex"
    fi
fi

# ------------------------------------------------------------------ 4. Piper (speech output)
if [ "$CLAUDE_ON" = yes ] && [ "$VOICE_ON" = yes ]; then
    say "== Gast: Piper (Vorlesen)"
    if [ -x "$PIPER_DIR/bin/piper" ]; then
        say "  piper ist schon installiert"
    else
        say "  pip install piper-tts in $PIPER_DIR"
        { python3 -m venv "$PIPER_DIR" && "$PIPER_DIR/bin/pip" install -q piper-tts; } \
            || die "Piper ließ sich nicht installieren (Netz?). Erneut starten: bash install.sh --setup (ohne Sprache: --no-voice)"
    fi
    voice="$PIPER_DIR/voices/$PIPER_VOICE_NAME"
    if [ -s "$voice.onnx" ] && [ -s "$voice.onnx.json" ]; then
        say "  Stimme $PIPER_VOICE_NAME ist da"
    else
        # into a fresh staging folder first (Piper's downloader keeps a partial file it finds), checked, then both moved
        # into place: an interrupted download never looks like a voice
        say "  lade die Stimme $PIPER_VOICE_NAME"
        stage="$PIPER_DIR/voices/.download"
        rm -rf "$stage"; mkdir -p "$stage"
        "$PIPER_DIR/bin/python3" -m piper.download_voices --download-dir "$stage" "$PIPER_VOICE_NAME" \
            && [ -s "$stage/$PIPER_VOICE_NAME.onnx" ] \
            && "$PIPER_DIR/bin/python3" -I -c 'import json, sys; int(json.load(open(sys.argv[1]))["audio"]["sample_rate"])' \
                "$stage/$PIPER_VOICE_NAME.onnx.json" \
            || { rm -rf "$stage"; die "Die Stimme $PIPER_VOICE_NAME ließ sich nicht laden (Netz?). Erneut starten: bash install.sh --setup"; }
        mv -f "$stage/$PIPER_VOICE_NAME.onnx.json" "$voice.onnx.json"
        mv -f "$stage/$PIPER_VOICE_NAME.onnx" "$voice.onnx"
        rm -rf "$stage"
    fi
fi
