#!/bin/bash
# setup-guest.sh - runs INSIDE the guest (install.sh --setup calls it through proot-distro, before
# install-guest.sh). Makes a fresh Ubuntu ready for the bridge, without any question:
#   1. python3, curl and the CA certificates (apt-get; only when one is missing)
#   2. Claude Code with the official installer (only when there is no claude yet)
# Idempotent: with everything in place it changes nothing and does not touch the network.
#
#   CLAUDE_INSTALL_URL        installer script (default https://claude.ai/install.sh)
#   ROOTBRIDGE_GUEST_HOME     home of the guest user (default /root, like install-guest.sh)
#   ROOTBRIDGE_CA_BUNDLE      certificate bundle to look for (default /etc/ssl/certs/ca-certificates.crt)

set -eu

HOME_DIR="${ROOTBRIDGE_GUEST_HOME:-/root}"
CA_BUNDLE="${ROOTBRIDGE_CA_BUNDLE:-/etc/ssl/certs/ca-certificates.crt}"
INSTALL_URL="${CLAUDE_INSTALL_URL:-https://claude.ai/install.sh}"

say() { printf '%s\n' "$*"; }
die() { echo "setup-guest.sh: $*" >&2; exit 1; }

# ------------------------------------------------------------------ 1. packages
say "== Gast: Voraussetzungen"
pkgs=""
command -v python3 >/dev/null 2>&1 || pkgs="$pkgs python3"
command -v curl    >/dev/null 2>&1 || pkgs="$pkgs curl"
[ -s "$CA_BUNDLE" ]                 || pkgs="$pkgs ca-certificates"
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

# ------------------------------------------------------------------ 2. Claude Code
say "== Gast: Claude Code"
if [ -x "$HOME_DIR/.local/bin/claude" ] || command -v claude >/dev/null 2>&1; then
    say "  claude ist schon installiert"
    exit 0
fi

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
say "  lade den Installer: $INSTALL_URL"
curl -fsSL "$INSTALL_URL" -o "$tmp" \
    || die "Download von $INSTALL_URL ist fehlgeschlagen (Netz?). Erneut starten: bash install.sh --setup"
HOME="$HOME_DIR" bash "$tmp" \
    || die "Der Claude-Code-Installer ist fehlgeschlagen. Erneut starten: bash install.sh --setup"
[ -x "$HOME_DIR/.local/bin/claude" ] || command -v claude >/dev/null 2>&1 \
    || die "Der Claude-Code-Installer lief durch, aber es gibt kein claude ($HOME_DIR/.local/bin/claude)."
say "  claude installiert: $HOME_DIR/.local/bin/claude"
