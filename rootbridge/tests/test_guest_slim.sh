#!/usr/bin/env bash
# Test: the guest stays small.
#   1. prune_versions() from guest/bin/rootbridge-update: old Claude Code / Codex versions go, the one in use and
#      the newest other one stay; other layouts are left alone (fake folders, nothing real is touched)
#   2. guest installer: the uutils copies become links to GNU coreutils (staged root)
#   bash tests/test_guest_slim.sh
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib.sh
. "$ROOT/tests/lib.sh"
SCRIPT="$ROOT/guest/bin/rootbridge-update"
GUEST="$ROOT/guest/install-guest.sh"

make_tmp
export ROOTBRIDGE_GUEST_HOME=/home/tester

# ------------------------------------------------ 1. prune_versions
FUNCS="$(sed -n '/^prune_versions() {/,/^}/p' "$SCRIPT")"
case "$FUNCS" in *"prune_versions() {"*) ;; *) echo "ABBRUCH: prune_versions() nicht in $SCRIPT gefunden." >&2; exit 1 ;; esac
EMPTYPROC="$T/noproc"; mkdir -p "$EMPTYPROC"
# prune <label> <link> <folder> <kind> [proc]: one run; output in OUT (last line rc=N)
prune() { OUT="$(ROOTBRIDGE_PROC="${5:-$EMPTYPROC}" bash -c 'eval "$1"; prune_versions "$2" "$3" "$4" "$5"; echo "rc=$?"' _ "$FUNCS" "$1" "$2" "$3" "$4" 2>&1)"; }
left() { find "$1" -mindepth 1 -maxdepth 1 -printf '%f\n' | sort -V | tr '\n' ' ' | sed 's/ $//'; }
mkrel() { mkdir -p "$1/bin"; echo '{}' > "$1/codex-package.json"; echo x > "$1/bin/codex"; }   # a Codex release folder

V="$T/claude/versions"; mkdir -p "$V" "$T/bin"
for v in 2.1.323 2.1.325 2.1.326; do echo "$v" > "$V/$v"; done
: > "$V/.lock"
ln -s "$V/2.1.326" "$T/bin/claude"
prune "Claude Code" "$T/bin/claude" "$V" file
check "Claude: aktuelle und eine davor bleiben"        ".lock 2.1.325 2.1.326" "$(left "$V")"
check "Claude: Meldung zur gelöschten Version"         1 "$(printf '%s\n' "$OUT" | grep -c '^Claude Code: alte Version 2.1.323 gelöscht$')"
check "Claude: Exit 0"                                 "rc=0" "$(printf '%s\n' "$OUT" | tail -n 1)"
prune "Claude Code" "$T/bin/claude" "$V" file
check "Claude zweiter Lauf: nichts mehr zu tun"        "rc=0" "$OUT"
check "Claude zweiter Lauf: Bestand gleich"            ".lock 2.1.325 2.1.326" "$(left "$V")"

V="$T/sortv/versions"; mkdir -p "$V"
for v in 2.1.9 2.1.10 2.1.11 2.1.12; do echo "$v" > "$V/$v"; done
ln -s "$V/2.1.12" "$T/bin/sortv"
prune x "$T/bin/sortv" "$V" file
check "Versionen numerisch: 2.1.11 ist die davor"      "2.1.11 2.1.12" "$(left "$V")"

V="$T/back/versions"; mkdir -p "$V"
for v in 1.0.0 1.0.1 1.0.2; do echo "$v" > "$V/$v"; done
ln -s "$V/1.0.0" "$T/bin/back"
prune x "$T/bin/back" "$V" file
check "Zurückgestellt: aktuelle und die neueste bleiben" "1.0.0 1.0.2" "$(left "$V")"

# only real versions of the tool: no folder, link or odd name among the Claude files
V="$T/strict/versions"; mkdir -p "$V/1.0.0" "$T/elsewhere"
for v in 1.0.1 1.0.2 1.0.3 1.0.1-beta; do echo "$v" > "$V/$v"; done
echo x > "$T/elsewhere/0.9.0"; ln -s "$T/elsewhere/0.9.0" "$V/0.9.0"
ln -s "$V/1.0.3" "$T/bin/strict"
prune x "$T/bin/strict" "$V" file
check "Nur Versionsdateien: Ordner, Link, Vorabname bleiben" "0.9.0 1.0.0 1.0.1-beta 1.0.2 1.0.3" "$(left "$V")"
check "Nur Versionsdateien: Ziel des Links unberührt"  ja "$([ -f "$T/elsewhere/0.9.0" ] && echo ja || echo nein)"

R="$T/codex/packages/standalone/releases"
for v in 0.167.1 0.168.0 0.169.0; do mkrel "$R/$v-aarch64-unknown-linux-musl"; done
mkdir -p "$R/0.100.0-aarch64-unknown-linux-musl" "$R/.staging.1"
ln -s "$R/0.169.0-aarch64-unknown-linux-musl" "$T/codex/packages/standalone/current"
prune Codex "$T/codex/packages/standalone/current" "$R" release
check "Codex: aktuelle und eine davor bleiben, Fremdes auch" ".staging.1 0.100.0-aarch64-unknown-linux-musl 0.168.0-aarch64-unknown-linux-musl 0.169.0-aarch64-unknown-linux-musl" "$(left "$R")"
check "Codex: Meldung"                                 1 "$(printf '%s\n' "$OUT" | grep -c '^Codex: alte Version 0.167.1-aarch64-unknown-linux-musl gelöscht$')"

# the link must point into the tool's own folder
V="$T/shared/versions"; mkdir -p "$V"
for v in 1.0.0 1.0.1 1.0.2; do echo "$v" > "$V/$v"; done
ln -s "$V/1.0.2" "$T/bin/shared"
prune x "$T/bin/shared" "$T/claude/versions" file
check "Link in einen fremden Ordner: nichts gelöscht"  "1.0.0 1.0.1 1.0.2" "$(left "$V")"

# a version in use stays: its program, or a helper from its folder
R="$T/run/releases"
for v in 0.1.0 0.2.0 0.3.0 0.4.0; do mkrel "$R/$v-aarch64-linux"; done
ln -s "$R/0.4.0-aarch64-linux" "$T/run/current"
P="$T/proc"; mkdir -p "$P/101" "$P/102" "$P/103"
ln -s "$R/0.1.0-aarch64-linux/bin/codex-code-mode-host" "$P/101/exe"
ln -s /usr/bin/bash "$P/102/exe"
echo bash > "$P/103/comm"
prune Codex "$T/run/current" "$R" release "$P"
check "Läuft noch: Version bleibt, die andere geht"    "0.1.0-aarch64-linux 0.3.0-aarch64-linux 0.4.0-aarch64-linux" "$(left "$R")"
check "Läuft noch: Meldung"                            1 "$(printf '%s\n' "$OUT" | grep -c '^Codex: alte Version 0.1.0-aarch64-linux läuft noch - bleibt$')"
mkrel "$R/0.0.9-aarch64-linux"; echo codex > "$P/103/comm"
prune Codex "$T/run/current" "$R" release "$P"
check "Codex-Prozess nicht lesbar: nichts gelöscht"    "0.0.9-aarch64-linux 0.1.0-aarch64-linux 0.3.0-aarch64-linux 0.4.0-aarch64-linux" "$(left "$R")"
printf 'State:\tZ (zombie)\n' > "$P/103/status"
mkdir -p "$P/104"; ln -s /data/data/com.termux/files/usr/libexec/proot/loader "$P/104/exe"
prune Codex "$T/run/current" "$R" release "$P"
check "Lader einer anderen proot-Sitzung: nichts gelöscht" "0.0.9-aarch64-linux 0.1.0-aarch64-linux 0.3.0-aarch64-linux 0.4.0-aarch64-linux" "$(left "$R")"
rm -rf "$P/104"
prune Codex "$T/run/current" "$R" release "$P"
check "Zombie zählt nicht: alte Version geht"          "0.1.0-aarch64-linux 0.3.0-aarch64-linux 0.4.0-aarch64-linux" "$(left "$R")"

N="$T/npm/lib/node_modules/claude"; mkdir -p "$N"
for v in 1.0.0 1.0.1 1.0.2; do echo x > "$N/$v"; done
echo x > "$N/cli.js"; ln -s "$N/cli.js" "$T/bin/npmclaude"
prune x "$T/bin/npmclaude" "$T/claude/versions" file
check "Anderer Aufbau (npm): nichts gelöscht"          "1.0.0 1.0.1 1.0.2 cli.js" "$(left "$N")"

V="$T/plain/versions"; mkdir -p "$V"
for v in 1.0.0 1.0.1 1.0.2; do echo "$v" > "$V/$v"; done
cp "$V/1.0.2" "$T/bin/plain"
prune x "$T/bin/plain" "$V" file
check "Kein Link: nichts gelöscht"                     "1.0.0 1.0.1 1.0.2" "$(left "$V")"
ln -s "$V/9.9.9" "$T/bin/dangling"
prune x "$T/bin/dangling" "$V" file
check "Link ins Leere: nichts gelöscht"                "1.0.0 1.0.1 1.0.2" "$(left "$V")"
prune x "$T/bin/fehlt" "$V" file
check "Ohne Link: Exit 0"                              "rc=0" "$OUT"

check "Hauptteil: Claude Code im eigenen Ordner"       1 "$(grep -c 'prune_versions "Claude Code" "$claude_bin" "$HOME/.local/share/claude/versions" file$' "$SCRIPT")"
check "Hauptteil: Codex im eigenen Ordner"             1 "$(grep -c 'prune_versions "Codex" "$codex_pkgs/current" "$codex_pkgs/releases" release$' "$SCRIPT")"

# ------------------------------------------------ 2. uutils copies -> GNU links
S="$T/stage"; UU="$S/usr/lib/cargo/bin/coreutils"
mkdir -p "$UU" "$S/usr/bin"
for u in ls cat '[' b3sum sort; do printf 'uutils\n' > "$UU/$u"; chmod 755 "$UU/$u"; done
ln "$UU/sort" "$T/sort-hardlink"
for g in ls cat '['; do printf 'gnu\n' > "$S/usr/bin/gnu$g"; chmod 755 "$S/usr/bin/gnu$g"; done
printf 'gnu\n' > "$S/usr/bin/gnusort"; chmod 755 "$S/usr/bin/gnusort"
bash "$GUEST" --root "$S" --autonomous no > "$T/guest.log" 2>&1
check "Gast-Installer läuft"                           0 "$?"
check "uutils: ls wird Link auf gnuls"                 "/usr/bin/gnuls" "$(readlink "$UU/ls")"
check "uutils: [ wird Link auf gnu["                   "/usr/bin/gnu[" "$(readlink "$UU/[")"
check "uutils: ohne GNU-Gegenstück bleibt die Kopie"   "uutils" "$([ -L "$UU/b3sum" ] || cat "$UU/b3sum")"
check "uutils: harter Link bleibt unberührt"           "uutils" "$([ -L "$UU/sort" ] || cat "$UU/sort")"
check "uutils: Meldung mit Anzahl"                     1 "$(grep -c 'uutils: 3 Kopien durch Links auf GNU coreutils ersetzt' "$T/guest.log")"
check "uutils: keine Zwischendateien"                  0 "$(find "$UU" -name '*.rb-link.*' | wc -l | tr -d ' ')"
bash "$GUEST" --root "$S" --autonomous no > "$T/guest.log" 2>&1
check "uutils zweiter Lauf: keine Meldung"             0 "$(grep -c 'uutils:' "$T/guest.log")"
check "uutils zweiter Lauf: Link bleibt"               "/usr/bin/gnuls" "$(readlink "$UU/ls")"

S2="$T/stage2"; mkdir -p "$S2"
bash "$GUEST" --root "$S2" --autonomous no > "$T/guest.log" 2>&1
check "Ohne uutils: Installer läuft, keine Meldung"    "0 0" "$? $(grep -c 'uutils:' "$T/guest.log")"

finish
