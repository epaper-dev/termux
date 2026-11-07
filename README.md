# Termux E-Paper

The Termux app and its plugin apps for the E-Paper phone, in one repository. Each project lives in its own directory
(a git subtree with its full history): `termux-app/`, `termux-api/`, `termux-boot/`, `termux-widget/`,
`termux-styling/`, `termux-float/`, `termux-tasker/`. The installer for the phone (Claude Code with confirmed root actions,
widgets, logins) is `rootbridge/`, moved here from `hisense-a9/termux-root-bridge`; it is not part of upstream and lives on `main` only.

## Branches

| Branch   | Content |
|----------|---------|
| `master` | An **unchanged copy of upstream**: every directory is the `master` branch of `termux/<directory>`. Nothing of our own is ever committed here. |
| `main`   | The E-Paper product: `master` plus our changes (the default branch). |

## Workflows

| Workflow | What it does |
|----------|--------------|
| `Sync upstream` | Every 6 hours: takes new upstream commits into `master`, merges `master` into `main`, then starts `Release set` (release key, publish). Without new upstream commits nothing happens. A merge conflict opens an issue with the steps to fix it; `master` stays up to date, `main` unchanged. Set the repository variable `RELEASE_AFTER_SYNC` to `false` to skip the release. |
| `Rootbridge tests` | Runs the tests and ShellCheck of `rootbridge/` when it changes. |
| `Termux app unit tests` | Runs `./gradlew test` of `termux-app/` (terminal emulator, termux-shared, app) when it changes. |
| `Release set` | Builds the app and the six plugins, signs them all with **one** key and checks that they belong together (same certificate, `sharedUserId` `com.termux`). With `publish` and the release key the APKs appear as single files under **Releases**. `ephemeral-key` (throwaway key) tests the pipeline and publishes nothing. |

Scripts: `.github/scripts/sync_upstream.sh`, `build_release_set.sh`, `make_signing_key.sh`.

## Terminal colors follow the phone

The terminal (not only the menus) follows the light/dark mode of the phone, without any file: in the light theme it uses a
built-in white scheme (`termux-shared/src/main/res/raw/colors_light_default.properties`), in the dark theme a built-in
black one (`colors_dark_default.properties`). Both keep every text color clearly dark (light scheme: R+G+B below 384) or
clearly light (dark scheme: 576 or more, so also dimmed text stays above 384); the one exception is the grey that
Claude Code's ANSI themes use as the background of your messages (light: `color7` #E4E4E4, dark: `color8` #404040). Android's "High contrast text", often on
by default on E-Ink phones, draws text black or white by exactly this threshold and gives it an outline in the other
color, so a color near the middle comes out as hollow letters. `BuiltInColorSchemesTest` checks the thresholds.
Phones without a system dark mode stay light. `night-mode` in `termux.properties` (`system` by
default, or `true`/`false`) decides the mode; menus, settings and dialogs follow it as well.

Files in `~/.termux/` only override this: `colors-light.properties` and/or `colors-dark.properties` (any Termux:Styling
scheme file works as it is) are used in their mode, otherwise `colors.properties` applies in both modes, as before. The
same goes for Termux:Float. The change for the Termux app is also prepared for upstream (branch
`terminal-colors-light-dark` of `epaper-dev/termux-app`).

Programs learn about a change between light and dark: Termux supports DECSET 2031 (`CSI ? 2031 h`, reports
`CSI ? 997 ; 1 n` for dark and `CSI ? 997 ; 2 n` for light whenever the scheme changes) and answers the query
`CSI ? 996 n`. tmux 3.6 and later passes this on and runs its hooks `client-light-theme` / `client-dark-theme`;
Claude Code with the theme `auto` follows at once, rootbridge's theme **Auto epaper** via those hooks.

## Signing key

All APKs of the set carry one certificate; Android installs the app and its plugins side by side only then, and an
update is accepted only with the same key. The key is made once with `.github/scripts/make_signing_key.sh` and read by
the workflow from four repository secrets: `SIGNING_KEYSTORE_BASE64`, `SIGNING_KEYSTORE_PASSWORD`,
`SIGNING_KEY_PASSWORD`, `SIGNING_KEY_ALIAS`. **Keep `release.p12` and `password.txt` backed up outside GitHub**: secrets
cannot be read back, and without the key every user has to uninstall and reinstall the whole set.

The upstream repositories ship their own `.github` folders; below a subtree they are inert (GitHub only reads the
workflows of the repository root).
