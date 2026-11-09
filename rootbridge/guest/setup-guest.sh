#!/bin/bash
# setup-guest.sh - runs INSIDE the guest (install.sh --setup calls it through proot-distro, before
# install-guest.sh). Makes a fresh Ubuntu ready for the bridge, without any question:
#   1. python3, curl and the CA certificates (apt-get; only when one is missing); git when Codex is part of
#      the installation (Codex reviews through git, and so does the pre-commit hook); nodejs when both tools are
#      (the Codex plugin of Claude Code is a node program, Node.js 18.18 or newer)
#   2. Claude Code with the official installer (only when there is no claude yet)
#   3. Codex with the official standalone installer (only when there is no codex yet)
#   4. the Codex plugin of Claude Code, openai/codex-plugin-cc (only when both tools are part of it and the
#      plugin is not there yet)
# Idempotent: with everything in place it changes nothing and does not touch the network.
#
#   setup-guest.sh [--claude yes|no] [--codex yes|no]       (both default to yes)
#
#   CLAUDE_INSTALL_URL        installer script of Claude Code (default https://claude.ai/install.sh)
#   CODEX_INSTALL_URL         installer script of Codex (default https://chatgpt.com/codex/install.sh)
#   ROOTBRIDGE_GUEST_HOME     home of the guest user (default /root, like install-guest.sh)
#   ROOTBRIDGE_CA_BUNDLE      certificate bundle to look for (default /etc/ssl/certs/ca-certificates.crt)

set -eu

HOME_DIR="${ROOTBRIDGE_GUEST_HOME:-/root}"
CA_BUNDLE="${ROOTBRIDGE_CA_BUNDLE:-/etc/ssl/certs/ca-certificates.crt}"
INSTALL_URL="${CLAUDE_INSTALL_URL:-https://claude.ai/install.sh}"
CODEX_URL="${CODEX_INSTALL_URL:-https://chatgpt.com/codex/install.sh}"
CLAUDE_ON=yes; CODEX_ON=yes

say() { printf '%s\n' "$*"; }
die() { echo "setup-guest.sh: $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
    case "$1" in
        --claude) [ $# -ge 2 ] || die "--claude braucht yes oder no"; CLAUDE_ON="$2"; shift 2 ;;
        --codex)  [ $# -ge 2 ] || die "--codex braucht yes oder no";  CODEX_ON="$2";  shift 2 ;;
        *) echo "setup-guest.sh: unbekannte Option: $1" >&2; exit 2 ;;
    esac
done
case "$CLAUDE_ON$CODEX_ON" in
    yesyes|yesno|noyes) ;;
    *) die "--claude / --codex: erlaubt ist yes oder no, und mindestens eines von beiden muss yes sein" ;;
esac

TMPDIR_SETUP="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_SETUP"' EXIT

claude_present() { [ -x "$HOME_DIR/.local/bin/claude" ] || command -v claude >/dev/null 2>&1; }
# the codex in ~/.local/bin is a link with an absolute target (the standalone package under ~/.codex)
codex_present() { [ -x "$HOME_DIR/.local/bin/codex" ] || [ -L "$HOME_DIR/.local/bin/codex" ] || command -v codex >/dev/null 2>&1; }
# the plugin is "there" when its files are (claude plugin install fetches them into the plugin cache)
plugin_present() { ls -d "$HOME_DIR"/.claude/plugins/cache/openai-codex/codex/*/ >/dev/null 2>&1; }

# ------------------------------------------------------------------ 1. packages
say "== Gast: Voraussetzungen"
pkgs=""
command -v python3 >/dev/null 2>&1 || pkgs="$pkgs python3"
command -v curl    >/dev/null 2>&1 || pkgs="$pkgs curl"
[ -s "$CA_BUNDLE" ]                 || pkgs="$pkgs ca-certificates"
if [ "$CODEX_ON" = yes ]; then
    command -v git >/dev/null 2>&1 || pkgs="$pkgs git"
fi
if [ "$CLAUDE_ON" = yes ] && [ "$CODEX_ON" = yes ]; then
    command -v node >/dev/null 2>&1 || pkgs="$pkgs nodejs"
fi
if [ -n "$pkgs" ]; then
    say "  apt-get install:$pkgs"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update || die "apt-get update ist fehlgeschlagen (Netz?). Erneut starten: bash install.sh --setup"
    # shellcheck disable=SC2086   # $pkgs is a list of package names on purpose
    apt-get install -y --no-install-recommends $pkgs \
        || die "apt-get install$pkgs ist fehlgeschlagen. Erneut starten: bash install.sh --setup"
else
    say "  python3, curl und Zertifikate sind da"
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

# ------------------------------------------------------------------ 4. Codex plugin for Claude Code
if [ "$CLAUDE_ON" = yes ] && [ "$CODEX_ON" = yes ]; then
    say "== Gast: Codex-Plugin für Claude Code"
    if plugin_present; then
        say "  das Plugin codex@openai-codex ist schon installiert"
    else
        claude_bin="$HOME_DIR/.local/bin/claude"
        [ -x "$claude_bin" ] || claude_bin="$(command -v claude)"
        export PATH="$HOME_DIR/.local/bin:$PATH"
        HOME="$HOME_DIR" timeout 180 "$claude_bin" plugin marketplace add https://github.com/openai/codex-plugin-cc.git \
            || die "claude plugin marketplace add https://github.com/openai/codex-plugin-cc.git ist fehlgeschlagen (Netz? git?). Erneut starten: bash install.sh --setup (ohne Codex: --no-codex)"
        HOME="$HOME_DIR" timeout 180 "$claude_bin" plugin install codex@openai-codex \
            || die "claude plugin install codex@openai-codex ist fehlgeschlagen. Erneut starten: bash install.sh --setup (ohne Codex: --no-codex)"
        plugin_present \
            || die "claude plugin install lief durch, aber die Plugin-Dateien fehlen ($HOME_DIR/.claude/plugins/cache/openai-codex/codex)."
        say "  Plugin codex@openai-codex installiert"
    fi
fi
