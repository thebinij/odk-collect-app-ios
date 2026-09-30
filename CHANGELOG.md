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

### Known limitations

See `README.md`'s "Known limitations" section — notably, the form list and each form's
XML definition are always fetched fresh from the server (no offline cache yet), and
only one project/credential set is stored at a time.
