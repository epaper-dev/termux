#!/usr/bin/env bash
# sync_upstream.sh - bring the upstream Termux repositories into this repository and merge them into the product branch.
# Used by .github/workflows/sync_upstream.yml; can be run by hand in a clone (see "Local use").
#
# Branch model (the same as the forks had, now for all subtrees together):
#   master   an UNCHANGED copy of upstream: termux-app/, termux-api/, ... are the master branches of
#            termux/termux-app, termux/termux-api, ... and nothing else is ever committed there
#   main     the E-Paper product: master plus our own changes
#
# What it does:
#   1. for every component: fetch termux/<component> master; when it has commits that master lacks, merge them into
#      master below the component's directory (the merge `git subtree pull` does: -X subtree=<component>)
#   2. push master
#   3. merge master into main (an ordinary three-way merge, master being the common ancestor of the last sync)
#   4. push main
#
# Exit code: 0 = done (also when there was nothing to do), 1 = problem (details in the output),
#            3 = merge conflict between upstream and main (master is updated and pushed, main is left as it was)
#
# Environment:
#   COMPONENTS       space or comma separated (default: termux-app termux-api termux-boot termux-widget termux-styling
#                    termux-float termux-tasker)
#   UPSTREAM_BASE    where the upstream repositories live (default: https://github.com/termux)
#   UPSTREAM_BRANCH  branch of each upstream repository (default: master)
#   MIRROR / PRODUCT branch names (default: master / main)
#   PUSH             0 = merge locally, do not push (default: 1)
#   GITHUB_OUTPUT, GITHUB_STEP_SUMMARY   set by GitHub Actions: results (updated, merged, conflict) and a summary
#
# Local use: clone the repository with all branches (`git clone` and `git fetch origin master main`), run the script
# from inside it. PUSH=0 only merges in your clone.
set -euo pipefail

COMPONENTS="${COMPONENTS:-termux-app termux-api termux-boot termux-widget termux-styling termux-float termux-tasker}"
UPSTREAM_BASE="${UPSTREAM_BASE:-https://github.com/termux}"
UPSTREAM_BRANCH="${UPSTREAM_BRANCH:-master}"
MIRROR="${MIRROR:-master}"
PRODUCT="${PRODUCT:-main}"
PUSH="${PUSH:-1}"
SUMMARY="${GITHUB_STEP_SUMMARY:-/dev/null}"
OUTPUT="${GITHUB_OUTPUT:-/dev/null}"

say()  { echo "== $*"; }
note() { echo "$*" >> "$SUMMARY"; }
out()  { echo "$1=$2" >> "$OUTPUT"; }
die()  { echo "::error::$*"; note "- **Error:** $*"; out failed true; exit 1; }
retry() {   # retry <command...>: fetches fail now and then with a 5xx
    local n
    for n in 1 2 3; do
        "$@" && return 0
        echo "::warning::'$*' failed (attempt $n of 3)"
        [ "$n" -lt 3 ] && sleep $((n * 10))
    done
    return 1
}

out updated false; out merged false; out conflict false; out failed false

COMPONENTS="${COMPONENTS//,/ }"
git rev-parse --git-dir >/dev/null 2>&1 || die "not inside a git repository"
[ -z "$(git status --porcelain --untracked-files=no)" ] || die "the working tree has uncommitted changes"
git config user.name  >/dev/null 2>&1 || git config user.name  "github-actions[bot]"
git config user.email >/dev/null 2>&1 || git config user.email "41898282+github-actions[bot]@users.noreply.github.com"

for b in "$MIRROR" "$PRODUCT"; do
    git rev-parse --verify -q "origin/$b" >/dev/null || die "origin has no branch '$b' (fetch it, or create $MIRROR first: see the README of the sync)"
done
if [ "$(git rev-parse --is-shallow-repository)" = true ]; then die "shallow clone: use fetch-depth: 0"; fi

# --- 1. upstream -> master -----------------------------------------------------------------------------------
git switch -q -C "$MIRROR" "origin/$MIRROR"
updated=()
for c in $COMPONENTS; do
    [ -d "$c" ] || die "$c/ does not exist on $MIRROR"
    url="$UPSTREAM_BASE/$c.git"
    retry git fetch -q --no-tags "$url" "$UPSTREAM_BRANCH" || die "could not fetch $url $UPSTREAM_BRANCH"
    tip="$(git rev-parse FETCH_HEAD)"
    if git merge-base --is-ancestor "$tip" HEAD; then
        say "$c: $MIRROR already has upstream ${tip:0:10}"
        continue
    fi
    n="$(git rev-list --count "HEAD..$tip" 2>/dev/null || echo '?')"
    say "$c: merging upstream ${tip:0:10} into $MIRROR"
    if ! git merge -q -X "subtree=$c" --no-edit -m "Merge upstream termux/$c $UPSTREAM_BRANCH ($tip)" "$tip" >/dev/null 2>&1; then
        git merge --abort 2>/dev/null || git reset -q --hard "origin/$MIRROR"
        die "$MIRROR could not take upstream $c ($tip): it must stay an unchanged copy of upstream. Look at what differs below $c/ on $MIRROR."
    fi
    # the mirror must stay a plain copy: below <component>/ it has to equal upstream's tree exactly
    if [ "$(git rev-parse "HEAD:$c")" != "$(git rev-parse "$tip^{tree}")" ]; then
        git reset -q --hard "origin/$MIRROR"
        die "$MIRROR/$c/ is not identical to upstream $tip after the merge (it holds changes of its own). Nothing was pushed."
    fi
    updated+=("$c")
    note "- \`$MIRROR\`: $c took upstream \`${tip:0:10}\` ($n new commit(s))."
done

if [ "${#updated[@]}" -gt 0 ]; then
    if [ "$PUSH" = 1 ]; then retry git push -q origin "$MIRROR" || die "pushing $MIRROR failed"; fi
    out updated true
    say "$MIRROR updated: ${updated[*]}"
else
    note "- \`$MIRROR\` already has all upstream commits."
fi

# --- 2. master -> main ---------------------------------------------------------------------------------------
git switch -q -C "$PRODUCT" "origin/$PRODUCT"
if git merge-base --is-ancestor "$MIRROR" HEAD; then
    say "$PRODUCT already contains $MIRROR, nothing to merge"
    note "- \`$PRODUCT\` already contains \`$MIRROR\`, nothing to merge."
    exit 0
fi

say "merging $MIRROR into $PRODUCT"
if ! git merge -q --no-edit -m "Merge upstream $MIRROR into $PRODUCT" "$MIRROR" >/dev/null 2>&1; then
    files="$(git diff --name-only --diff-filter=U | head -n 20)"
    git merge --abort 2>/dev/null || git reset -q --hard "origin/$PRODUCT"
    out conflict true
    echo "::error::Merge conflict between $MIRROR and $PRODUCT in: $(echo "$files" | tr '\n' ' ')"
    {
        echo "### Merge conflict: \`$MIRROR\` into \`$PRODUCT\`"
        echo
        echo "Upstream changed lines that \`$PRODUCT\` changed as well:"
        echo
        echo '```'
        echo "$files"
        echo '```'
        echo
        echo "\`$MIRROR\` is up to date and pushed, \`$PRODUCT\` is unchanged. Resolve it locally:"
        echo
        echo '```sh'
        echo "git fetch origin && git switch $PRODUCT && git pull --ff-only"
        echo "git merge origin/$MIRROR"
        echo "# fix the conflicts, commit, then"
        echo "git push origin $PRODUCT"
        echo '```'
    } >> "$SUMMARY"
    exit 3
fi
if [ "$PUSH" = 1 ]; then retry git push -q origin "$PRODUCT" || die "pushing $PRODUCT failed"; fi
out merged true
note "- Merged \`$MIRROR\` into \`$PRODUCT\`."
say "$PRODUCT updated"
