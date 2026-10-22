# headroom home

The launcher: clock, date, a dock of six apps at most, an app grid, and options.
No permissions, no internet, no background components. Design rules live in
`headroom-plan.md` Phase 12; the safety contract is in the root `AGENTS.md`.

## Build

The Gradle wrapper is committed (Gradle 8.9). You need JDK 17 and the Android
SDK. The machine that wrote this launcher had neither, so the code has not
been compiled locally; the CI `launcher` job is its first real compile.

```sh
brew install openjdk@17
export JAVA_HOME="$(brew --prefix openjdk@17)/libexec/openjdk.jdk/Contents/Home"
sdkmanager "platforms;android-34" "build-tools;34.0.0"
```

Then, from `launcher/`:

```sh
./gradlew testReleaseUnitTest lintRelease assembleRelease
```

The release APK lands at `app/build/outputs/apk/release/app-release.apk`.
Signed with the debug key on purpose: it is sideloaded over ADB, never
published.

## Check the budget

```sh
aapt2 dump permissions app/build/outputs/apk/release/app-release.apk   # must list nothing
ls -l app/build/outputs/apk/release/app-release.apk                    # must be under 150 KB
```

`tests/test_launcher_static.py` checks the parts of the budget that need no
build: zero `uses-permission`, no services/receivers/providers, no runtime
dependencies, minSdk 26 / targetSdk 34, and that the pure-Java classes import
nothing from `android.*`. `.github/workflows/ci.yml` adds the real build, lint
and APK budget checks.

## Per-car defaults

`launcher/install.sh` writes `headroom.local.properties` (`dock=<csv>`) before
building; `app/build.gradle` turns it into the `default_dock` string resource.
The file is git-ignored. After installation the dock lives in the app's private
storage, editable from Options.
