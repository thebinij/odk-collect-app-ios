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
  last question.
- Offline-first local storage (`SubmissionStore`): drafts and sent forms are saved with
  their own copy of the form's XML, so both can be reopened without any network.
- `SubmissionStore` now tracks three distinct states — `.draft` (mid-fill,
  incomplete), `.readyToSend` (fully answered, awaiting upload), and `.sent` — instead
  of conflating the first two, mirroring ODK Collect (Android)'s own
  `INCOMPLETE`/`COMPLETE`+`SUBMISSION_FAILED`/`SUBMITTED` instance states. A new
  **Ready to Send** screen lists `.readyToSend` entries with a manual "Send Now" retry
  per entry.
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
- Project Settings (server URL/username/password) persisted via `UserDefaults` +
  Keychain, with live "Test Connection" against the configured OpenRosa server.
- Open-source project scaffolding: `LICENSE` (MIT), `CONTRIBUTING.md`,
  `CODE_OF_CONDUCT.md`, `SECURITY.md`, `THIRD_PARTY_NOTICES.md`, issue/PR templates, a
  CI workflow (build + test on every PR), and a tag-triggered Firebase App Distribution
  pipeline (`DEPLOYMENT.md`).

### Fixed

- Read-only "Sent Forms" answers showed a Bikram Sambat date question's answer as its
  raw stored Gregorian string (e.g. "2025-04-14") instead of the BS date it was
  actually answered in (e.g. "1 Baisakh 2082") — the one-question flow's own picker
  already displayed it correctly; the read-only summary now matches.
- A validation race could permanently disable the "Next" button in the one-question
  flow if a stale/mismatched validation result ever arrived — `isBusy` now always
  resets on any result, not only one matching the currently displayed question.
- The app's first `WKWebView` load (opening any form, draft, or sent submission) had a
  ~9s one-time WebKit "cold start" cost, making local-only screens like Drafts/Ready to
  Send/Sent Forms feel slow despite involving no network. `RootView` now loads a
  trivial, invisible form in the background as soon as Home appears, absorbing that
  cost silently before the user opens anything — subsequent loads measure ~0.7s.

### Known limitations

See `README.md`'s "Known limitations" section — notably, only one project/credential
set is stored at a time, and Ready to Send only retries via manual "Send Now" (a
Settings toggle for automatic retry-when-online is planned but not yet built).
