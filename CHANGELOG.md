# Changelog

All notable changes to this project are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this
project intends to follow [Semantic Versioning](https://semver.org/) once the first
tagged release ships (`vMAJOR.MINOR.PATCH` — see `DEPLOYMENT.md` for how a tag becomes a
distributed build).

## [Unreleased]

### Added

- Native, fully SwiftUI one-question-at-a-time form-filling flow (`QuestionFlowEngine`,
  `QuestionFlowView`), driven by a headless `enketo-core`/`enketo-transformer` engine
  running invisibly in a `WKWebView` — the engine's own rendered HTML is never shown.
- `field-list` XForm groups are presented together as one page (`.questionGroup` step)
  instead of one question at a time, matching standard ODK/Enketo behavior.
- A dedicated final step (`.finish`) offering explicit **Send** / **Save Draft**
  choices once every question has been answered, rather than an icon bolted onto the
  last question — shown as a centered page (icon, headline, full-width buttons)
  rather than a left-aligned list row.
- Offline-first local storage (`SubmissionStore`): drafts and sent forms are saved with
  their own copy of the form's XML, so both can be reopened without any network.
- `SubmissionStore` now tracks three distinct states — `.draft` (mid-fill,
  incomplete), `.readyToSend` (fully answered, awaiting upload), and `.sent` — instead
  of conflating the first two, mirroring ODK Collect (Android)'s own
  `INCOMPLETE`/`COMPLETE`+`SUBMISSION_FAILED`/`SUBMITTED` instance states. A new
  **Ready to Send** screen lists `.readyToSend` entries with a manual "Send Now" retry
  per entry.
- **Form Management** (Settings → Form Management → Form Submission → Auto Send):
  choose **Off** (default — forms wait in Ready to Send until you tap Send Now),
  **Wi-Fi only**, **Cellular only**, or **Wi-Fi or Cellular** to retry every
  `.readyToSend` submission on its own over a matching connection — when that connection
  comes back, when the app returns to the foreground on it, and when a new submission is
  saved while already on it. Automatic attempts are silent (success just moves the item
  to Sent; failure leaves it in Ready to Send for the next trigger), run one at a time,
  and never skip the local-first save. `ConnectivityMonitor` (`NWPathMonitor`) and
  `AutoSendCoordinator` back this; `SubmissionSender` is the one shared upload routine
  every send path uses.
- Auto Send now also runs while the app isn't open, via a `BGAppRefreshTask` the system
  schedules opportunistically (based on its own judgment of usage, battery, and
  connectivity — not a guaranteed schedule, and only if the user hasn't disabled
  Background App Refresh for the app). `BackgroundSendRunner` is the same "send when
  eligible" pass `AutoSendCoordinator` runs in the foreground, with no view hierarchy
  required; `AppDelegate` registers and reschedules the task.
- Offline form access: `FormCacheStore` caches the form list and each form's XForm XML
  locally; `FormListView` tries the live server first and falls back to the cache with
  no connection (`OfflineFallback`, generic and independently unit-tested), so a form
  seen once stays usable offline indefinitely. Every not-yet-cached form is now
  downloaded automatically in the background as soon as the list loads (matching ODK
  Collect's "Get Blank Form" sync), not only ones a user happens to tap into; each
  form's row shows a fixed `yyyy-MM-dd HH:mm:ss` (device-local time) download
  timestamp once cached.
- Native input widgets for every XForm question kind: text/number, single/multi-select
  (including cascading itemsets, `minimal`, and `autocomplete` appearances), date/time,
  a native **Bikram Sambat** (Nepali calendar) date picker, range, rank, geopoint/
  geotrace/geoshape (via `CLLocationManager`), signature capture, and photo/audio/video/
  file attachments.
- Per-question and per-group validation with the error shown directly under the
  offending control (and that control tinted red), rather than as a generic banner.
- Repeat groups with "Add another?" prompts.
- Server Settings (server URL/username/password) persisted via `UserDefaults` +
  Keychain, with live "Test Connection" against the configured OpenRosa server, and a
  "Clear Project" action that resets all three — including the Keychain-stored
  password, which (unlike `UserDefaults`) iOS does not remove on its own when the app
  is deleted.
- Open-source project scaffolding: `LICENSE` (MIT), `CONTRIBUTING.md`,
  `CODE_OF_CONDUCT.md`, `SECURITY.md`, `THIRD_PARTY_NOTICES.md`, issue/PR templates, a
  CI workflow (build + test on every PR), and a tag-triggered Firebase App Distribution
  pipeline (`DEPLOYMENT.md`).

### Fixed

- Opening any form, draft, or sent submission with a date/time question briefly showed
  iOS's native, English, full-screen date/time picker on top of the app before the
  correct (possibly Bikram Sambat) picker or read-only answer appeared underneath —
  `enketo-core`'s date/time widget calls `.focus()` on its hidden native `<input>`
  while syncing a value, and iOS presents that as a system-level picker overlay outside
  the headless `WKWebView`'s own hidden styling. The headless engine now neutralizes
  every `.focus()` call, since nothing inside it should ever actually receive focus.
- An incorrect username or password against a server using HTTP Basic/Digest auth left
  Test Connection — and any form-list, form-download, or submission request — stuck
  loading indefinitely instead of failing: the client kept re-offering the same
  rejected credential on every re-challenge. It now gives up after the first rejection
  with a clear "The server rejected the username or password" error.
- Leaving Server Settings after entering a password triggered iOS's own "Save
  Password" prompt, offering to save it to iCloud Keychain — redundant, since the app
  already stores it in its own Keychain entry as you type. Both fields now explicitly
  opt out of iOS's login-form autofill heuristic.
- Read-only "Sent Forms" answers showed a Bikram Sambat date question's answer as its
  raw stored Gregorian string (e.g. "2025-04-14") instead of the BS date it was
  actually answered in (e.g. "1 Baisakh 2082") — the one-question flow's own picker
  already displayed it correctly; the read-only summary now matches.
- The "Save your progress?" prompt shown when leaving a form mid-fill rendered as an
  iPad popover with a pointer arrow instead of a centered modal, inconsistent with
  every other alert in the app — it's now a plain centered alert on every device.
- A validation race could permanently disable the "Next" button in the one-question
  flow if a stale/mismatched validation result ever arrived — `isBusy` now always
  resets on any result, not only one matching the currently displayed question.
- Reopening a form whose questions hadn't finished loading yet could permanently
  strand navigation on the final Send/Save Draft step instead of the first question,
  if that transient loading state was mistaken for a genuinely-reached finish position.
- Returning to Home (or any screen) by tapping back could flicker/re-pop its
  navigation title — about half the app's screens left `.navigationBarTitleDisplayMode`
  unset (defaulting to a large title) while the rest set `.inline` explicitly, so
  popping between an inline screen and an unset one visibly resized the title bar.
  Every screen now sets `.inline` explicitly.
- A fresh `OpenRosaClient` (and the `URLSession` + credential it holds) was created
  for every form-list fetch, form download, and submission — including every
  automatic Auto Send attempt — and never invalidated, leaking each one for the life
  of the app process. It now invalidates its session once it's no longer referenced.
- A submission attachment (photo, signature, audio/video/file) that failed to read
  from disk during upload was silently dropped instead of failing the send — the
  server received, and the app marked `.sent`, a submission permanently missing that
  attachment with no indication anything was wrong. A read failure now fails the
  whole send instead, leaving the submission `.readyToSend` for retry.
- The app's first `WKWebView` load (opening any form, draft, or sent submission) had a
  ~9s one-time WebKit "cold start" cost, making local-only screens like Drafts/Ready to
  Send/Sent Forms feel slow despite involving no network. `RootView` now loads a
  trivial, invisible form in the background as soon as Home appears, absorbing that
  cost silently before the user opens anything — subsequent loads measure ~0.7s.
