# shellcheck shell=bash
# lib.sh - helpers shared by the shell tests. Sourced by every test_*.sh, not run itself:
#   . "$ROOT/tests/lib.sh"          (ROOT = the rootbridge directory)
# A test counts its results with check() and ends with finish().

# The guest scripts source their library from /usr/local/lib/termux-rootbridge/; in the tests it is the copy in the repo
export ROOTBRIDGE_GUEST_LIB="${ROOTBRIDGE_GUEST_LIB:-$ROOT/guest/lib/rootbridge-guest-lib.sh}"

PASS=0; FAIL=0
check() {   # check <name> <expected> <actual>
    if [ "$2" = "$3" ]; then PASS=$((PASS + 1)); printf 'ok    %s\n' "$1"
    else FAIL=$((FAIL + 1)); printf 'FAIL  %s\n      erwartet: %s\n      erhalten: %s\n' "$1" "$2" "$3"; fi
}

# finish: the result line and the exit code of the test run
finish() { echo "Ergebnis: $PASS bestanden, $FAIL fehlgeschlagen"; [ "$FAIL" -eq 0 ]; }

# make_tmp: T = a private temp directory that is removed when the test ends (a test with more to clean up sets its own
# trap afterwards)
make_tmp() { T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT; }
