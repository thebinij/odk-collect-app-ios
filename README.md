# ODK Collect (iOS)

[![CI](https://github.com/thebinij/odk-collect-app-ios/actions/workflows/ci.yml/badge.svg)](https://github.com/thebinij/odk-collect-app-ios/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

A native iOS app in the spirit of [getodk/collect](https://github.com/getodk/collect):
a **Project** (OpenRosa server URL + username + password) drives native OpenRosa
discovery of forms, filled out one question at a time in a fully native SwiftUI
interface — not a webview showing a rendered Enketo page. The actual XForm logic
(relevant/calculate/constraint, cascading selects, repeats) still runs on the real
[Enketo](https://enketo.org) engine, vendored and run headlessly in a hidden,
zero-size `WKWebView` purely as an XPath/validation engine — its own rendered HTML is
never shown. See `ARCHITECTURE.md` for how the pieces fit together and why.

> **Naming/branding note:** unaffiliated with the ODK organization, not the official
> ODK Collect app. Forking this for your own use? Set your own bundle ID in
> `Config.xcconfig` (see below) before distributing it anywhere.

## Requirements

- macOS with **Xcode** (latest stable) — the iOS SDK ships inside `Xcode.app`, not
  Command Line Tools alone.
- [Homebrew](https://brew.sh)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) — generates `ODKCollect.xcodeproj`
  from `project.yml`; the `.xcodeproj` itself isn't committed.

## Setup & first build

```sh
brew install xcodegen   # if you don't already have it
xcodegen generate       # produces ODKCollect.xcodeproj
open ODKCollect.xcodeproj
```

Pick any iOS 16.4+ simulator and **Run** (⌘R) — no signing setup needed.

Real device or Archive? Needs your own Apple Developer Team (nobody's identifiers ship
in a public repo):

```sh
cp Config.xcconfig.example Config.xcconfig   # gitignored — stays local to you
```
Fill in `DEVELOPMENT_TEAM` (Xcode → Settings → Accounts → your account → the ID next to
your team's name), then `xcodegen generate` again. See `CONTRIBUTING.md`'s "Local
signing setup" for more.

**First run:** Home's "+ Start new form" prompts you to set up a project if none
exists (gear icon → **Server Settings** — server URL, username, password; **Test
Connection** confirms it). Tapping a form downloads its XML and opens the native
question flow directly.

## Making this your own

- **App identity** — `Config.xcconfig` (bundle ID), `project.yml` (`bundleIdPrefix`,
  `name:`), `ODKCollect/Info.plist` (`CFBundleDisplayName`).
- **App icon / splash / accent color** — `ODKCollect/Assets.xcassets`.
- **Look and feel** — all in `Packages/ODKCollectUI`; the other packages have no UI.
- **Reuse just one piece** — `ODKWebEngine` and `OpenRosaKit` are self-contained and
  drop into a different Xcode project as local Swift Packages on their own.

Re-run `xcodegen generate` after changing `project.yml`.

## Testing

Real, automated tests over manual verification — including regression tests that
drive the actual engine through a live `WKWebView`
(`Packages/ODKWebEngine/Tests/ODKWebEngineTests/`), not a mock. See `CONTRIBUTING.md`
for the full testing philosophy.

```sh
# Pure Foundation logic — no iOS SDK needed:
cd Packages/OpenRosaKit && swift test
cd Packages/ProjectSettingsKit && swift test

# Needs the iOS SDK — via xcodebuild against a simulator:
xcodebuild test -project Packages/ODKWebEngine -scheme ODKWebEngine \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
xcodebuild test -project Packages/ODKCollectUI -scheme ODKCollectUI \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

(Or Xcode's Test navigator / ⌘U after opening `ODKCollect.xcodeproj`.)

## Known limitations

- **Single active project** — one server/credential set at a time.
- **Auto Send's background runs are opportunistic, not guaranteed** — `BGAppRefreshTask`
  only grants an *opportunity* to run, on the system's own schedule. A platform
  constraint, not a bug; manual **Send Now** always works regardless.
- **Self-signed/untrusted TLS certificates aren't handled** — the server needs an
  OS-trusted certificate.
- **iOS 16.4 is the deployment floor**, matching what `WKWebView` needs to run
  `enketo-core` reliably.
- **Camera/microphone/GPS can't be exercised in the Simulator** — no camera/mic
  hardware, and GPS needs a manually set location (Simulator → Features → Location).

## Deployment

Pushing a version tag builds a signed release and distributes it to testers via
Firebase App Distribution — see `DEPLOYMENT.md` for setup and the tagging convention.

## License

MIT — see `LICENSE`. Vendors/ports a small amount of Apache-2.0-licensed third-party
code (`enketo-core`, `enketo-transformer`, the Bikram Sambat date algorithm); see
`THIRD_PARTY_NOTICES.md` for full attribution.

## Contributing

See `CONTRIBUTING.md` for the dev workflow, coding conventions, and testing
expectations, and `CODE_OF_CONDUCT.md` for how we expect people to treat each other
here.

## Changelog

See `CHANGELOG.md`, organized by release.
