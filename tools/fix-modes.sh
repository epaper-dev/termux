#!/usr/bin/env bash
# fix-modes.sh - set mode 100755 in the git index for every tracked file that
# starts with a shebang (#!).
#
# Why: on Android shared storage (/sdcard) chmod has no effect and git runs with
# core.fileMode=false, so new scripts would be committed as 100644. Run this
# after `git add` and before `git commit`:
#
#   git add -A && bash tools/fix-modes.sh && git commit
#
# Harmless on normal filesystems. tests/test_modes.py fails if a shebang file
# is not executable in the index.
set -eu

cd "$(git rev-parse --show-toplevel)"
n=0
while IFS= read -r -d '' f; do
    [ -f "$f" ] || continue
    [ "$(head -c 2 -- "$f")" = '#!' ] || continue
    mode="$(git ls-files -s -- "$f" | cut -d' ' -f1)"
    if [ "$mode" != 100755 ]; then
        git update-index --chmod=+x -- "$f"
        echo "chmod +x: $f"
        n=$((n + 1))
    fi
done < <(git ls-files -z)
echo "fix-modes: $n Datei(en) angepasst."
