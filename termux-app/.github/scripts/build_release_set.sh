#!/usr/bin/env bash
# build_release_set.sh - build the Termux app of this repository and Termux plugin apps (from upstream),
# sign them ALL with ONE key and check that they belong together. Used by .github/workflows/release_set.yml.
#
# Why one key: the app and its plugins share the user id `com.termux` (android:sharedUserId). Android only
# installs them side by side when all APKs carry the same signing certificate. APKs from F-Droid (signed by
# F-Droid), from GitHub (public test key) and from this set (this key) can therefore never be mixed: switching
# means uninstalling every Termux app first and installing the whole set.
#
# Environment:
#   SIGNING     test-key      debug builds, signed with the public upstream test key (same as upstream's
#                             GitHub builds; fits a Termux installed from GitHub)
#               ephemeral-key release builds, signed with a throwaway key made in this run (tests the whole
#                             pipeline; the APKs are valid but must not be distributed)
#               release-key   release builds, signed with the real key from the secrets below
#   COMPONENTS  comma separated: app, termux-api, termux-boot, termux-widget, termux-styling, termux-float,
#               termux-tasker (default: all of them)
#   PLUGIN_OWNER  GitHub owner of the plugin forks the sources come from (default: epaper-dev; falls back to
#               termux when a fork lacks the release tag)
#   OUT_DIR     result directory (default: ./set-out)
#   GH_TOKEN    used by `gh api` to find the latest release of each plugin
#   SIGNING_KEYSTORE_BASE64, SIGNING_KEYSTORE_PASSWORD, SIGNING_KEY_ALIAS, SIGNING_KEY_PASSWORD   (release-key)
#       the PKCS12 keystore as base64 and its passwords
set -euo pipefail

SIGNING="${SIGNING:-ephemeral-key}"
COMPONENTS="${COMPONENTS:-app,termux-api,termux-boot,termux-widget,termux-styling,termux-float,termux-tasker}"
OUT_DIR="${OUT_DIR:-$PWD/set-out}"
PLUGINS="termux-api termux-boot termux-widget termux-styling termux-float termux-tasker"
WORK="${RUNNER_TEMP:-/tmp}/release-set-work"
SUMMARY="${GITHUB_STEP_SUMMARY:-/dev/null}"

die() { echo "::error::$*"; exit 1; }
say() { echo "== $*"; }
# retry <command...>: downloads (Gradle distribution, dependencies, git) fail now and then with a 5xx; try 3 times
retry() {
    local n
    for n in 1 2 3; do
        "$@" && return 0
        echo "::warning::'$*' failed (attempt $n of 3)"
        [ "$n" -lt 3 ] && sleep $((n * 20))
    done
    return 1
}

case "$SIGNING" in test-key|ephemeral-key|release-key) ;; *) die "SIGNING must be test-key, ephemeral-key or release-key (got '$SIGNING')" ;; esac

# --- components ----------------------------------------------------------------------------------------
IFS=',' read -r -a WANT <<< "${COMPONENTS// /}"
[ "${#WANT[@]}" -gt 0 ] || die "COMPONENTS is empty"
for c in "${WANT[@]}"; do
    case " app $PLUGINS " in *" $c "*) ;; *) die "unknown component '$c' (allowed: app $PLUGINS)" ;; esac
done

# --- Android build tools ---------------------------------------------------------------------------------
SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-/usr/local/lib/android/sdk}}"
BT="$(find "$SDK/build-tools" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort -V | tail -n 1)"
[ -n "$BT" ] && [ -x "$BT/apksigner" ] || die "Android build-tools (apksigner) not found below $SDK"
say "build tools: ${BT##*/}"

rm -rf "$WORK" "$OUT_DIR"
mkdir -p "$WORK" "$OUT_DIR/apks" "$OUT_DIR/unsigned"
KS=""
cleanup() { [ -z "$KS" ] || rm -f "$KS"; }
trap cleanup EXIT

# --- signing key -------------------------------------------------------------------------------------------
case "$SIGNING" in
    test-key) say "signing: the public upstream test key (debug builds)" ;;
    ephemeral-key)
        KS="$WORK/ephemeral.p12"
        KS_ALIAS=epaper-ephemeral
        KS_PASS="$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
        KEY_PASS="$KS_PASS"
        keytool -genkeypair -keystore "$KS" -storetype PKCS12 -alias "$KS_ALIAS" -keyalg RSA -keysize 2048 \
            -validity 3650 -dname "CN=ephemeral test key, O=epaper-dev" -storepass "$KS_PASS" -keypass "$KEY_PASS" 2>&1 | tail -n 2
        export KS_PASS KEY_PASS
        say "signing: a throwaway key made in this run (do not distribute these APKs)"
        ;;
    release-key)
        for v in SIGNING_KEYSTORE_BASE64 SIGNING_KEYSTORE_PASSWORD SIGNING_KEY_ALIAS SIGNING_KEY_PASSWORD; do
            [ -n "${!v:-}" ] || die "release-key needs the secret $v (Settings > Secrets and variables > Actions)"
        done
        KS="$WORK/release.p12"
        ( umask 077; printf '%s' "$SIGNING_KEYSTORE_BASE64" | base64 -d > "$KS" ) || die "SIGNING_KEYSTORE_BASE64 is not valid base64"
        KS_ALIAS="$SIGNING_KEY_ALIAS"
        KS_PASS="$SIGNING_KEYSTORE_PASSWORD"
        KEY_PASS="$SIGNING_KEY_PASSWORD"
        export KS_PASS KEY_PASS
        say "signing: the release key from the repository secrets"
        ;;
esac

if [ "$SIGNING" = test-key ]; then TASK=assembleDebug; KIND=debug; else TASK=assembleRelease; KIND=release; fi

# --- build ---------------------------------------------------------------------------------------------------
collect() {   # collect <component> <dir with the build output>: copy every APK to unsigned/<component>/
    local name="$1" dir="$2" n=0 f
    mkdir -p "$OUT_DIR/unsigned/$name"
    while IFS= read -r f; do
        cp "$f" "$OUT_DIR/unsigned/$name/"
        n=$((n + 1))
    done < <(find "$dir" -maxdepth 1 -name '*.apk' | sort)
    [ "$n" -gt 0 ] || die "$name: no APK found in $dir"
    say "$name: $n APK(s)"
}

build_app() {
    local ver sha
    ver="$(grep -m 1 -E '^\s+versionName "' app/build.gradle | sed -r 's/^\s+versionName "([^"]+)".*/\1/')"
    sha="$(git rev-parse --short=7 HEAD)"
    say "app: version $ver+$sha, variant apt-android-7, task $TASK"
    # app/build.gradle hooks the bootstrap download onto the Java compile task, but the native build of a release
    # variant runs first and needs the zips (`Could not find incbin file 'bootstrap-aarch64.zip'`): fetch them up front
    TERMUX_PACKAGE_VARIANT=apt-android-7 retry ./gradlew --no-daemon downloadBootstraps || die "app: downloading the bootstrap packages failed"
    TERMUX_PACKAGE_VARIANT=apt-android-7 \
    TERMUX_APP_VERSION_NAME="$ver+$sha" \
    TERMUX_APK_VERSION_TAG="v$ver+$sha-apt-android-7-epaper-$KIND" \
    TERMUX_SPLIT_APKS_FOR_RELEASE_BUILDS=1 \
        retry ./gradlew --no-daemon "$TASK" || die "app: the Gradle build failed"
    collect app "app/build/outputs/apk/$KIND"
}

# Most plugins depend on `com.termux.termux-app:termux-shared:<commit>` from JitPack. JitPack no longer has the
# commit the latest releases were built against (HTTP 404), so termux-shared is built from that commit of termux-app
# and published to the local Maven repository, the way F-Droid builds these apps (app/build.gradle names the
# coordinates `com.termux:termux-shared:<version>` and build.gradle has `mavenLocal()` commented out for this).
SHARED_LOCAL_HASH=""
SHARED_NOTES=""
SOURCE_NOTES=""
use_local_shared() {   # use_local_shared <plugin> <plugin dir> <commit>
    local name="$1" dir="$2" hash="$3" code full src ver
    code="$(curl -s -o /dev/null -m 90 -w '%{http_code}' "https://jitpack.io/com/termux/termux-app/termux-shared/$hash/termux-shared-$hash.pom" || true)"
    if [ "$code" = 200 ]; then
        say "$name: termux-shared $hash comes from JitPack"
        return 0
    fi
    say "$name: termux-shared $hash is not on JitPack (HTTP ${code:-?}), building it from termux-app"
    full="$(gh api "repos/termux/termux-app/commits/$hash" --jq .sha)"
    [ -n "$full" ] || die "$name: termux-app has no commit $hash"
    src="$WORK/termux-app-$hash"
    if [ -z "$SHARED_LOCAL_HASH" ]; then
        mkdir -p "$src"
        ( cd "$src" && git init -q && retry git fetch -q --depth 1 https://github.com/termux/termux-app.git "$full" && git checkout -q FETCH_HEAD ) \
            || die "$name: could not fetch termux-app $hash"
        # the libraries (terminal-emulator, terminal-view, termux-shared) are published together
        ( cd "$src" && retry ./gradlew --no-daemon publishReleasePublicationToMavenLocal ) \
            || die "$name: building termux-shared $hash failed"
        SHARED_LOCAL_HASH="$hash"
        SHARED_NOTES="${SHARED_NOTES}termux-shared built from termux-app \`${full:0:10}\`; "
    elif [ "$SHARED_LOCAL_HASH" != "$hash" ]; then
        die "$name needs termux-shared $hash but $SHARED_LOCAL_HASH is already published locally under the same version"
    fi
    # every library of that commit a plugin names (termux-shared, terminal-view, terminal-emulator) moves to the local copy
    for mod in termux-shared terminal-view terminal-emulator; do
        ver="$(sed -n "s/^[[:space:]]*version = '\([^']*\)'.*/\1/p" "$WORK/termux-app-$SHARED_LOCAL_HASH/$mod/build.gradle" | head -n 1)"
        [ -n "$ver" ] || die "$name: could not read the $mod version"
        sed -i "s|com.termux.termux-app:$mod:$hash|com.termux:$mod:$ver|" "$dir/app/build.gradle"
    done
    sed -i 's|^\([[:space:]]*\)//mavenLocal()|\1mavenLocal()|' "$dir/build.gradle"
    if grep -q "com.termux.termux-app:[a-z-]*:$hash" "$dir/app/build.gradle"; then die "$name: still a JitPack dependency on $hash after the switch"; fi
    grep -qE '^[[:space:]]*mavenLocal\(\)' "$dir/build.gradle" || die "$name: could not enable mavenLocal() in build.gradle"
}

build_plugin() {
    local name="$1" tag dir dep owner
    tag="$(gh api "repos/termux/$name/releases/latest" --jq .tag_name)"
    [ -n "$tag" ] || die "$name: could not find the latest release"
    dir="$WORK/$name"
    # the sources come from our fork of the plugin (PLUGIN_OWNER, default epaper-dev) at the tag of the latest
    # upstream release; if the fork does not have that tag (not synced yet) upstream is used
    owner="${PLUGIN_OWNER:-epaper-dev}"
    if ! git ls-remote --exit-code --tags "https://github.com/$owner/$name.git" "refs/tags/$tag" >/dev/null 2>&1; then
        echo "::warning::$owner/$name has no tag $tag, using termux/$name"
        owner=termux
    fi
    say "$name: release $tag from $owner/$name, task $TASK"
    SOURCE_NOTES="${SOURCE_NOTES}$name $tag from \`$owner/$name\`; "
    retry git clone --quiet --depth 1 --branch "$tag" "https://github.com/$owner/$name.git" "$dir" || die "$name: git clone failed"
    dep="$(grep -oE 'com\.termux\.termux-app:[a-z-]+:[0-9a-f]+' "$dir/app/build.gradle" | head -n 1 | sed 's/.*://' || true)"
    if [ -n "$dep" ]; then use_local_shared "$name" "$dir" "$dep"; fi
    ( cd "$dir" && retry ./gradlew --no-daemon "$TASK" ) || die "$name: the Gradle build failed"
    collect "$name" "$dir/app/build/outputs/apk/$KIND"
}

for c in "${WANT[@]}"; do
    if [ "$c" = app ]; then build_app; else build_plugin "$c"; fi
done

# --- sign ----------------------------------------------------------------------------------------------------
if [ "$SIGNING" = test-key ]; then
    # debug builds are already signed with the test key
    cp "$OUT_DIR"/unsigned/*/*.apk "$OUT_DIR/apks/"
else
    for f in "$OUT_DIR"/unsigned/*/*.apk; do
        base="${f##*/}"
        aligned="$WORK/aligned-$base"
        "$BT/zipalign" -p -f 4 "$f" "$aligned"
        "$BT/apksigner" sign --ks "$KS" --ks-key-alias "$KS_ALIAS" --ks-pass env:KS_PASS --key-pass env:KEY_PASS \
            --v1-signing-enabled true --v2-signing-enabled true --v3-signing-enabled true \
            --out "$OUT_DIR/apks/$base" "$aligned"
        rm -f "$aligned"
    done
fi

# --- check that the set belongs together ----------------------------------------------------------------
{
    echo "### Release set ($SIGNING)"
    echo
    echo "| APK | package | versionCode | versionName | sharedUserId | signature schemes |"
    echo "|---|---|---|---|---|---|"
} > "$OUT_DIR/REPORT.md"

first_cert=""
problems=0
for f in "$OUT_DIR"/apks/*.apk; do
    base="${f##*/}"
    verify="$("$BT/apksigner" verify --print-certs -v "$f" 2>&1)" || { echo "::error::$base: apksigner verify failed"; echo "$verify" | head -n 8; problems=$((problems + 1)); continue; }
    # apksigner words this line differently by version and scheme ("Signer #1 certificate SHA-256 digest: ..." or
    # "Signer (minSdkVersion=24, maxSdkVersion=...) certificate SHA-256 digest: ..."): match on the common part
    cert="$(printf '%s\n' "$verify" | sed -n 's/.*certificate SHA-256 digest: *//p' | head -n 1 | tr -d ' \r')"
    if [ -z "$cert" ]; then
        echo "::warning::$base: no certificate fingerprint in the apksigner output, which was:"
        printf '%s\n' "$verify" | head -n 14 | sed 's/^/    /'
    fi
    schemes="$(printf '%s\n' "$verify" | grep -E '^Verified using v[0-9.]+ .*: true' | sed -E 's/^Verified using (v[0-9.]+) .*/\1/' | tr '\n' ' ' || true)"
    badging="$("$BT/aapt2" dump badging "$f" 2>/dev/null | head -n 1)"
    pkg="$(printf '%s\n' "$badging" | sed -n "s/.*package: name='\([^']*\)'.*/\1/p")"
    vcode="$(printf '%s\n' "$badging" | sed -n "s/.*versionCode='\([^']*\)'.*/\1/p")"
    vname="$(printf '%s\n' "$badging" | sed -n "s/.*versionName='\([^']*\)'.*/\1/p")"
    suid="$("$BT/aapt2" dump xmltree --file AndroidManifest.xml "$f" 2>/dev/null | sed -n 's/.*sharedUserId[^=]*="\([^"]*\)".*/\1/p' | head -n 1)"
    [ -n "$first_cert" ] || first_cert="$cert"
    if [ -z "$cert" ] || [ "$cert" != "$first_cert" ]; then echo "::error::$base: signing certificate differs ($cert, expected $first_cert)"; problems=$((problems + 1)); fi
    if [ "$suid" != com.termux ]; then echo "::error::$base: sharedUserId is '$suid', expected com.termux"; problems=$((problems + 1)); fi
    printf '| %s | %s | %s | %s | %s | %s |\n' "$base" "${pkg:-?}" "${vcode:-?}" "${vname:-?}" "${suid:-?}" "${schemes:-none}" >> "$OUT_DIR/REPORT.md"
done

{
    echo
    echo "Signing certificate (SHA-256): \`${first_cert:-none}\`"
    echo
    [ -z "$SOURCE_NOTES" ] || { echo "Sources: ${SOURCE_NOTES%; }."; echo; }
    [ -z "$SHARED_NOTES" ] || { echo "Build notes: ${SHARED_NOTES%; }."; echo; }
    if [ "$problems" -eq 0 ]; then echo "All APKs verify, share one certificate and use sharedUserId \`com.termux\`."
    else echo "**$problems problem(s), see the log.**"; fi
    case "$SIGNING" in
        test-key) echo; echo "Signed with the **public upstream test key**: anyone can sign updates for these apps. Fine for development, not for distribution." ;;
        ephemeral-key) echo; echo "Signed with a **throwaway key**: do not distribute, it only proves that the pipeline works." ;;
    esac
} >> "$OUT_DIR/REPORT.md"

( cd "$OUT_DIR/apks" && sha256sum ./*.apk | sed 's|\./||' > "$OUT_DIR/sha256sums.txt" )
cat "$OUT_DIR/REPORT.md" | tee -a "$SUMMARY"
[ "$problems" -eq 0 ] || die "the set has $problems problem(s)"
say "done: $(find "$OUT_DIR/apks" -name '*.apk' | wc -l) APK(s) in $OUT_DIR/apks"
