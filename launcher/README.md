# headroom home

The launcher: clock, date, a dock of six apps at most, an app grid, and options.
No permissions, no internet, no background components. Design rules live in
`headroom-plan.md` Phase 12; the safety contract is in the root `AGENTS.md`.

## Build

The Gradle wrapper is committed (Gradle 8.9). You need JDK 17 and the Android
SDK if you build locally. The launcher was built, unit-tested and linted with
`launcher/docker-build.sh` without either: the release APK is 24 KB with zero
permissions and no lint issues.

```sh
brew install openjdk@17
export JAVA_HOME="$(brew --prefix openjdk@17)/libexec/openjdk.jdk/Contents/Home"
sdkmanager "platforms;android-34" "build-tools;34.0.0"
```

Then, from `launcher/`:

```sh
./gradlew testReleaseUnitTest lintRelease assembleRelease
./check-budgets.sh
```

## Build with Docker

If you do not want a JDK and the Android SDK on your machine:

```sh
launcher/docker-build.sh
```

It builds a `linux/amd64` image with JDK 17 and the SDK, runs the unit tests,
lint and release build, then `check-budgets.sh`. The image is x86_64 because the
SDK build-tools are; Docker Desktop emulates it on Apple Silicon (the first run
is slow and downloads the SDK). The APK is written to
`launcher/app/build/outputs/apk/release/app-release.apk` on the host.

Docker on macOS cannot run a hardware-accelerated Android emulator (no nested
KVM). The emulator checks in the plan still need a real device, a head unit, or
a machine with the SDK emulator installed.

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
nothing from `android.*`. `launcher/check-budgets.sh` adds the real build, lint,
APK size and permission checks; CI and `launcher/docker-build.sh` both call it.

## Per-car defaults

`launcher/install.sh` writes `headroom.local.properties` (`dock=<csv>`) before
building; `app/build.gradle` turns it into the `default_dock` string resource.
The file is git-ignored. After installation the dock lives in the app's private
storage, editable from Options.
