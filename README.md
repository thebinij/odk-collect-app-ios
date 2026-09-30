# ODK Collect (iOS)

[![CI](https://github.com/thebinij/odk-collect-app-ios/actions/workflows/ci.yml/badge.svg)](https://github.com/thebinij/odk-collect-app-ios/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

A native iOS app in the spirit of [getodk/collect](https://github.com/getodk/collect):
a **Project** (OpenRosa server URL + username + password) drives native OpenRosa
discovery of forms (`formList` / `form.xml`), and every form is filled out with a fully
native, SwiftUI, one-question-at-a-time interface — not a webview showing a rendered
Enketo page. The XForm logic itself (relevant/calculate/constraint, cascading selects,
repeats) still runs on the real [Enketo](https://enketo.org) engine (`enketo-core` +
`enketo-transformer`), vendored and run headlessly inside a hidden, zero-size
`WKWebView` purely as an XPath/validation engine — its own rendered HTML is never shown.

> **Naming/branding note:** this project is unaffiliated with the ODK organization and
> is not the official ODK Collect app. It uses its own bundle identifier prefix
> (`np.com.yipl`, see `project.yml`) precisely to avoid colliding with the real app. If
> you fork this, update `project.yml`'s `bundleIdPrefix` and `PRODUCT_BUNDLE_IDENTIFIER`
> to your own before distributing it anywhere.

## Why headless Enketo instead of a WebView UI?

`formList`/`form.xml` return raw XForm XML. Something has to evaluate that XML's logic —
which questions are currently relevant, what a `select_one` from a secondary instance's
current options are, whether a `constraint` passes — and `enketo-core`/
`enketo-transformer` are a mature, correct implementation of exactly that. Rather than
reimplement XPath/JavaRosa semantics from scratch (real ODK Collect's own approach, in
Java) or show Enketo's own rendered web page in a `WKWebView` (simpler, but a
noticeably non-native feel and no access to native camera/GPS/file pickers), this
project runs the engine invisibly and drives it with a small JS bridge
(`bridge.js`) that exposes just what a native UI needs: the current question list
(labels, hints, options, relevance, values), `setValue`, `validateQuestion(s)`, and
repeat add/remove. Every visible control — text fields, pickers, the Bikram Sambat date
wheel, camera/photo/audio/signature capture — is plain SwiftUI.

## Architecture

Four local Swift Packages plus a thin app target:

| Module | What it is | Depends on |
|---|---|---|
| `Packages/ODKWebEngine` | The headless engine: `EnketoFormView` (a `WKWebView` wrapper) + `EnketoFormState` (the `ObservableObject` driving it), plus the vendored `enketo-core`/`enketo-transformer` bundles and `bridge.js` (`Resources/EnketoEngine/`). Exposes `Question`/`RepeatSeries` models and the bridge API (`setValue`, `validateQuestion(s)`, `addRepeatInstance`, …). No UI, no branding. | WebKit |
| `Packages/OpenRosaKit` | Native OpenRosa client (`OpenRosaClient.fetchFormList()` / `.fetchFormXML(from:)`, HTTP Basic/Digest auth, `X-OpenRosa-Version`) plus two local, offline-first stores: `SubmissionStore` (`.draft`/`.readyToSend`/`.sent` submissions, each saved with its own `form.xml` copy so it can be reopened/resent without any network) and `FormCacheStore` (the last-synced form list and each form's own XForm XML, so a form stays usable offline once seen). `OfflineFallback` is the shared "try live, fall back to cache" decision logic both use. | Foundation |
| `Packages/ProjectSettingsKit` | `Project` model (server URL, username) + `ProjectStore`: server URL/username persist in `UserDefaults`, the password lives only in the Keychain (`KeychainStore`), and every field saves as it's typed. | Foundation, Security |
| `Packages/ODKCollectUI` | Every screen: `RootView` (Home), `SettingsView` → `ProjectSettingsView`, `FormListView`, `DraftsView`/`ReadyToSendView`/`SentFormsView`, `SentFormAnswersView` (read-only, all-questions-at-once), and the native form-filling stack — `EnketoFormContainerView` (hosts the hidden engine + save/submit orchestration) → `QuestionFlowView` (navigation) → `QuestionFlowEngine` (pure step-sequencing logic) → `QuestionInputView` (+ per-kind widgets: date/Bikram-Sambat/rank/geopoint/geotrace/signature/media). | ODKWebEngine, OpenRosaKit, ProjectSettingsKit |
| `ODKCollect/` | The app shell: `ODKCollectApp.swift` (`@main`), `Info.plist`, `Assets.xcassets` (icon, splash logo, accent color), privacy manifest. | ODKCollectUI |

`ODKWebEngine` and `OpenRosaKit` have no dependency on each other, on
`ProjectSettingsKit`, or on the app shell — either can be dropped into a different app
largely as-is.

### The one-question-at-a-time flow

`QuestionFlowEngine.buildSteps(questions:repeats:)` is pure, fully unit-tested logic
that turns the engine's flat, reactive question list into a navigable sequence:

- Irrelevant (`relevant == false`) and `hidden` (`appearance="hidden"`, or any
  `/meta/*` bookkeeping field) questions are skipped entirely.
- Consecutive questions sharing a `field-list` group's ref are clustered into one
  `.questionGroup` step — answered together on one page, like a real ODK "page" — while
  everything else is navigated one question at a time.
- An "Add another?" step is inserted after the last question of the last instance of
  each repeat series.
- A `.finish` step is always last, reached only once every real question/group has been
  validated — it offers **Send** or **Save Draft** as explicit choices, not an icon
  bolted onto the last question.

### Offline behavior

This app is designed to work fully offline once a project's forms have been synced
once — mirroring ODK Collect (Android)'s own local forms/instances cache, just backed
by flat files instead of SQLite:

- **Starting a new form**: `FormListView` always tries the live server first, then
  falls back to `FormCacheStore` — a local cache of the last-fetched form list and each
  form's own XForm XML — if there's no connection (`OfflineFallback.resolve`, shared,
  pure decision logic). A live fetch also refreshes the cache. A form seen once stays
  usable offline indefinitely after that; a "showing forms from your last sync"
  indicator appears whenever the list came from the cache rather than the network.
  Every not-yet-cached form's XML is also downloaded automatically in the background
  as soon as the list loads (matching ODK Collect's own "Get Blank Form" sync) — not
  only the ones a user happens to tap — with a small progress indicator and each
  form's row showing when it was last downloaded.
- **Filling in, saving, and resuming**: entirely on-device — the engine runs locally
  and `SubmissionStore` writes everything (including a copy of the form's own XML)
  to local files, so a `.draft` or `.readyToSend` entry can be reopened/resent without
  any network at all.
- **Sending**: always saves locally first as `.readyToSend`, then tries to upload. If
  that fails (most commonly: no network), the entry simply stays `.readyToSend` —
  visible in the **Ready to Send** list, with a manual "Send Now" retry per entry. (A
  Settings toggle for automatic retry-when-online, versus always-manual, is planned but
  not yet built.)
- **Viewing sent forms**: pure local read, no network involved.

## Requirements

- macOS with **Xcode** (latest stable recommended) — the iOS SDK ships inside
  `Xcode.app`, not with Command Line Tools alone.
- [Homebrew](https://brew.sh)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) — generates `ODKCollect.xcodeproj`
  from `project.yml`. The `.xcodeproj` itself is **not** committed; regenerate it any
  time you pull changes to `project.yml` or add/remove files.

## Setup & first build

```sh
brew install xcodegen   # if you don't already have it
xcodegen generate       # produces ODKCollect.xcodeproj
open ODKCollect.xcodeproj
```

In Xcode: pick any iOS 16.4+ simulator (or a real device), then **Run** (⌘R).

**First run:** Home shows a "+ Start new form" button (always enabled; tapping it with
no project configured prompts you to set one up) and a gear icon top-right for
**Settings → Project Settings** — enter your OpenRosa-compatible server URL, username,
and password (each field saves as you type; **Test Connection** confirms the
credentials work via `formList`). Back on Home, "+ Start new form" opens the **Forms**
list; tapping a form downloads its XML and opens the native question flow directly —
no external Enketo webform involved.

## Making this your own

- **App identity** — `project.yml`: `PRODUCT_BUNDLE_IDENTIFIER`, `options.bundleIdPrefix`,
  top-level `name:`; `ODKCollect/Info.plist`: `CFBundleDisplayName`.
- **App icon / splash / accent color** — `ODKCollect/Assets.xcassets`.
- **Look and feel** — everything visible lives in `Packages/ODKCollectUI`; the three
  packages it composes have no UI of their own.
- **Reuse just one piece** — `ODKWebEngine` and `OpenRosaKit` have no app-specific code,
  so either can be added to a different Xcode project as a local Swift Package on its
  own.

After changing `project.yml` (bundle ID, adding files, etc.), re-run `xcodegen generate`.

## Testing

This project leans heavily on real, automated tests over manual verification —
including regression tests for bugs that only show up against `enketo-core`'s actual
rendered DOM (see `Packages/ODKWebEngine/Tests/ODKWebEngineTests/EnketoEngineIntegrationTests.swift`
and `RealFormEndToEndTests.swift`, which drive the real engine through a live
`WKWebView`, not a mock).

```sh
# Pure Foundation logic — no iOS SDK needed:
cd Packages/OpenRosaKit && swift test
cd Packages/ProjectSettingsKit && swift test

# Needs the iOS SDK (WebKit/UIKit/SwiftUI) — run via xcodebuild against a simulator:
xcodebuild test -project Packages/ODKWebEngine \
  -scheme ODKWebEngine -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
xcodebuild test -project Packages/ODKCollectUI \
  -scheme ODKCollectUI -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

(Or just use Xcode's Test navigator / ⌘U after opening `ODKCollect.xcodeproj`.)

See `CONTRIBUTING.md` for the testing philosophy this project expects contributions to
follow.

## Known limitations

- **Single active project.** Only one server/credential set is stored at a time — a
  multi-project switcher would be an additive change to `ProjectSettingsKit`, not a
  rewrite.
- **Ready to Send is manual-only for now.** A Settings toggle for automatic
  retry-when-online is planned but not yet built — see "Offline behavior" above.
- **Self-signed/untrusted TLS certificates aren't handled** — the server needs a
  certificate the OS already trusts.
- **iOS 16.4 is the deployment floor**, matching `WKWebView`'s modern JS engine
  requirements for running `enketo-core` reliably.
- **Camera/microphone/GPS can't be exercised in the Simulator** the way they can on a
  real device — the Simulator has no camera/mic hardware, and has no real GPS unless
  you set a location manually (Simulator → Features → Location).

## Deployment

Pushing a version tag (`v1.2.3`) builds a signed release and distributes it to testers
via Firebase App Distribution — see `DEPLOYMENT.md` for the one-time setup.

## License

MIT — see `LICENSE`. This project vendors/ports a small amount of Apache-2.0-licensed
third-party code (`enketo-core`, `enketo-transformer`, the Bikram Sambat date
algorithm); see `THIRD_PARTY_NOTICES.md` for full attribution.

## Contributing

Contributions are welcome — see `CONTRIBUTING.md` for the dev workflow, coding
conventions, and testing expectations this project uses, and `CODE_OF_CONDUCT.md` for
how we expect people to treat each other here.

## Changelog

See `CHANGELOG.md` for notable changes, organized by release.
