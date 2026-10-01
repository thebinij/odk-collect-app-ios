# Architecture

Four local Swift Packages plus a thin app target:

| Module | What it is | Depends on |
|---|---|---|
| `Packages/ODKWebEngine` | The headless engine: `EnketoFormView` (a `WKWebView` wrapper) + `EnketoFormState` (the `ObservableObject` driving it), plus the vendored `enketo-core`/`enketo-transformer` bundles and `bridge.js` (`Resources/EnketoEngine/`). Exposes `Question`/`RepeatSeries` models and the bridge API (`setValue`, `validateQuestion(s)`, `addRepeatInstance`, …). No UI, no branding. | WebKit |
| `Packages/OpenRosaKit` | Native OpenRosa client (`OpenRosaClient.fetchFormList()` / `.fetchFormXML(from:)`, HTTP Basic/Digest auth, `X-OpenRosa-Version`) plus two local, offline-first stores: `SubmissionStore` (`.draft`/`.readyToSend`/`.sent` submissions, each saved with its own `form.xml` copy so it can be reopened/resent without any network) and `FormCacheStore` (the last-synced form list and each form's own XForm XML, so a form stays usable offline once seen). `OfflineFallback` is the shared "try live, fall back to cache" decision logic both use; `ConnectivityMonitor` (`NWPathMonitor`) and `SubmissionSender` (the one shared upload routine every send path uses) back Auto Send. | Foundation, Network |
| `Packages/ProjectSettingsKit` | `Project` model (server URL, username) + `ProjectStore`: server URL/username persist in `UserDefaults`, the password lives only in the Keychain (`KeychainStore`), and every field saves as it's typed. `FormSubmissionSettingsStore` persists the Auto Send mode the same way. | Foundation, Security |
| `Packages/ODKCollectUI` | Every screen: `RootView` (Home), `SettingsView` → `ServerSettingsView`/`FormManagementView`, `FormListView`, `DraftsView`/`ReadyToSendView`/`SentFormsView`, `SentFormAnswersView` (read-only, all-questions-at-once), and the native form-filling stack — `EnketoFormContainerView` (hosts the hidden engine + save/submit orchestration) → `QuestionFlowView` (navigation) → `QuestionFlowEngine` (pure step-sequencing logic) → `QuestionInputView` (+ per-kind widgets: date/Bikram-Sambat/rank/geopoint/geotrace/signature/media). `AutoSendCoordinator` wires the Auto Send setting to `ConnectivityMonitor`/`SubmissionStore` triggers while the app is open; `BackgroundSendRunner` is the same "send when eligible" pass with no view hierarchy, for a `BGAppRefreshTask` to call while it isn't. | ODKWebEngine, OpenRosaKit, ProjectSettingsKit |
| `ODKCollect/` | The app shell: `ODKCollectApp.swift` (`@main`), `AppDelegate.swift` (registers/schedules the Auto Send `BGAppRefreshTask`), `Info.plist`, `Assets.xcassets` (icon, splash logo, accent color), privacy manifest. | ODKCollectUI |

`ODKWebEngine` and `OpenRosaKit` have no dependency on each other, on
`ProjectSettingsKit`, or on the app shell — either can be dropped into a different app
largely as-is.

## The one-question-at-a-time flow

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

## Offline behavior

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
  visible in the **Ready to Send** list, with a manual "Send Now" retry per entry. By
  default it waits for that tap, but **Settings → Form Management → Auto Send** can be
  set to **Wi-Fi only**, **Cellular only**, or **Wi-Fi or Cellular** to also retry
  waiting submissions on its own — both while the app is open (`AutoSendCoordinator`,
  triggered by a matching connection becoming available or the app returning to the
  foreground on one) and, opportunistically, while it isn't (`BackgroundSendRunner`,
  run from a `BGAppRefreshTask` the system schedules on its own timing — see
  `README.md`'s "Known limitations"). Automatic attempts are silent and run one at a
  time.
- **Viewing sent forms**: pure local read, no network involved.
