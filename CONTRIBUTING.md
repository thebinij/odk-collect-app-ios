# Contributing

Thanks for considering a contribution. This document covers how to get set up, how
this codebase is organized, and the conventions pull requests are expected to follow —
reading it fully before opening a PR will save you a review round-trip.

## Getting set up

```sh
brew install xcodegen   # if you don't already have it
xcodegen generate       # produces ODKCollect.xcodeproj — not committed, regenerate
                         # any time you pull changes to project.yml or add/remove files
open ODKCollect.xcodeproj
```

You'll need Xcode itself (not just Command Line Tools) for the iOS SDK. See `README.md`
for the full setup/first-run walkthrough.

## Local signing setup

`project.yml` ships with a placeholder bundle ID (`np.com.yipl.odk`) and no Apple
Developer Team — nobody's personal/org identifiers belong in a public repo, and
XcodeGen regenerates `ODKCollect.xcodeproj` entirely from this file for every
contributor, so anything committed here silently becomes everyone else's default on
their next `xcodegen generate`.

To Run or Archive with your own identifiers locally, without ever risking committing
them:

1. One-time per clone — enable the pre-commit guard that blocks this mistake if it
   happens anyway:
   ```sh
   git config core.hooksPath scripts/git-hooks
   ```
2. Edit `project.yml` yourself: change `PRODUCT_BUNDLE_IDENTIFIER` to something unique
   you control, and add `DEVELOPMENT_TEAM: <your team ID>` next to
   `CODE_SIGN_STYLE: Automatic`.
3. Tell git to stop tracking further changes to this file locally, so your edit can
   never get staged or committed by accident (including by a broad `git add -A`):
   ```sh
   git update-index --skip-worktree project.yml
   ```
4. `xcodegen generate` as usual — your identifiers now survive every regenerate.

If you later need to pull upstream changes to `project.yml` (a new target setting,
dependency, etc.), temporarily restore tracking first — `git status` won't show the
file as modified while skip-worktree is active, so a plain `git pull` can otherwise
leave your copy silently out of date:
```sh
git update-index --no-skip-worktree project.yml
git pull
# reapply your PRODUCT_BUNDLE_IDENTIFIER / DEVELOPMENT_TEAM edits, then:
git update-index --skip-worktree project.yml
```

## Before you start: open an issue first for anything non-trivial

Small, obvious fixes (typos, a clear bug with an obvious one-line fix) can go straight
to a PR. For anything bigger — a new feature, a behavior change, a refactor spanning
multiple files — please open an issue first describing what you want to do and why.
This project has a fairly specific architecture (see `README.md`'s Architecture
section) and it's much cheaper to align on an approach before code is written than
after.

## Project structure

- `Packages/ODKWebEngine` — the headless Enketo engine wrapper. If your change touches
  `bridge.js` or how `Question`/`RepeatSeries` are decoded, it's here.
- `Packages/OpenRosaKit` — OpenRosa protocol client + local submission storage. No UI.
- `Packages/ProjectSettingsKit` — project/credential persistence. No UI.
- `Packages/ODKCollectUI` — every screen. Depends on the three packages above.
- `ODKCollect/` — the thin app shell (entry point, Info.plist, assets).

Each package builds and tests independently (`swift build`/`swift test` for the two
pure-Foundation ones; `xcodebuild` against a simulator for the two that need
WebKit/SwiftUI). Keep that independence — don't introduce a dependency from
`ODKWebEngine` or `OpenRosaKit` back onto `ODKCollectUI` or the app shell.

## Coding conventions

These aren't arbitrary style preferences — they reflect real lessons learned building
this codebase (see the commit history and, if you have access to it, the extended
development discussion this project came out of).

- **Comments explain WHY, never WHAT.** A well-named function/variable already says
  what the code does. Only add a comment for a genuinely non-obvious reason: a subtle
  invariant, a workaround for a specific upstream quirk (e.g. the notes throughout
  `bridge.js` about `enketo-core`'s DOM structure), a constraint that would otherwise
  surprise the next reader. If you'd remove a comment and nothing would be lost, don't
  add it in the first place. PRs that add comments restating the code next to it will
  be asked to remove them.
- **No speculative abstraction.** Don't add configuration, protocols, or generic
  helpers for a use case that doesn't exist yet. Three similar lines beat a premature
  abstraction.
- **Don't add error handling for scenarios that can't happen.** Validate at real
  boundaries (user input, network responses, decoding external data) — trust your own
  internal code's guarantees elsewhere.
- **Match the existing native-first philosophy.** Every visible control is plain
  SwiftUI; `enketo-core`'s own rendered HTML is never shown to the user. If a change
  would require showing the engine's own UI to get some capability, that's a sign it
  belongs in `bridge.js` as a new headless API instead.

## Testing expectations

This is the single most important convention in this codebase: **a bug fix is not done
until there's a test that would have caught it.** Manual verification (even careful
manual verification against a real `WKWebView`) is not a substitute — this project has
concrete history of "fixed" bugs that turned out to only be fixed in one environment
(e.g. a macOS-hosted `WKWebView` scratch script behaving differently from the same code
running on a real iOS host), caught only once a permanent automated test replaced the
manual check.

- **Pure logic** (`QuestionFlowEngine`, `Project.resolveEnketoURL`, `SubmissionStore`,
  XML parsing, the Bikram Sambat calendar math) gets plain `XCTest` unit tests — fast,
  no simulator needed for the Foundation-only packages.
- **Anything touching the real engine's DOM** (a new `bridge.js` function, a fix to how
  `Question` fields are extracted, a new question `Kind`) needs an integration test in
  `EnketoEngineIntegrationTests.swift` that drives the actual `EnketoFormView`/
  `EnketoFormState` through a real `WKWebView` — not a hand-rolled duplicate of the
  logic, and not a bare macOS-hosted `WKWebView` script (that environment doesn't
  reliably match how `enketo-core` renders on real iOS, e.g. `appearance="minimal"`
  selects render completely differently under touch detection).
- **A bug reported against a real-world form** should get a regression test using that
  form's actual compiled XML (or as close a minimal reproduction as possible) — see
  `RealFormEndToEndTests.swift` for the pattern: real pyxform-compiled XML embedded as
  a fixture, not a hand-simplified approximation that might not reproduce the actual
  DOM shape that caused the bug.
- When you add a test to `EnketoEngineIntegrationTests.swift`, group related
  assertions into as few test methods as reasonably possible. Each method spins up a
  real `WKWebView`, which costs an actual WebContent process — too many in one test run
  exhausts that pool and causes unrelated tests to fail with `WebProcessProxy::didClose`.
- Before submitting, run the full test suite for every package you touched at least
  twice in a row (`xcodebuild test`, not just once) — a couple of real bugs in this
  codebase's own test helpers only showed up as intermittent flakes under full-suite
  load, not in isolation.

## Pull requests

- Keep PRs focused — one logical change per PR is much easier to review than several
  unrelated fixes bundled together.
- Describe *why*, not just *what* — link the issue if there is one, and explain the
  reasoning behind any non-obvious decision, the same way you would in a "why" code
  comment.
- Include the test(s) that cover your change (see above) — a PR fixing a bug without a
  regression test will be asked to add one before merge.
- Make sure `xcodegen generate` output is **not** committed — check `git status` before
  pushing; the `.xcodeproj` is gitignored for a reason (it's fully regenerable from
  `project.yml`, and committing it just creates merge-conflict noise).

## Updating the changelog

`CHANGELOG.md` follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Any
PR that changes behavior a user of the app (or a consumer of `ODKWebEngine`/
`OpenRosaKit` as a package) could notice needs an entry under `## [Unreleased]`:

- **Pick the right section.** `### Added` for new capability, `### Changed` for a
  behavior change to something that already existed, `### Fixed` for a bug fix. Don't
  invent other section headers — if it doesn't fit one of Keep a Changelog's own
  categories (Added/Changed/Deprecated/Removed/Fixed/Security), it likely belongs in
  `README.md` instead (e.g. ongoing constraints belong in "Known limitations" there,
  not in the changelog — the changelog records *changes*, not standing state).
- **Write it for someone who didn't see the code.** Say what was actually wrong/added
  and, for a fix, what the user-visible symptom was — not just the internal mechanism.
  "Fixed a validation bug" tells a reader nothing; "correcting an answer no longer
  leaves Next permanently disabled" does.
- **Name the real thing, not the task.** Describe the behavior, not the conversation
  that produced it — no "per user request", no referencing an issue/PR number inline
  (GitHub already links commits to PRs), no first-person or casual phrasing. Write it
  the way you'd write documentation, not a commit message aside.
- **One bullet per change**, ideally one sentence plus a second only if the "why" needs
  it. If a PR bundles several unrelated fixes (it shouldn't — see "Pull requests"
  above), give each its own bullet rather than merging them.
- **Skip pure internals.** A refactor, test-only change, or internal rename with no
  observable effect doesn't need an entry — the changelog is for users of the app/
  packages, not a log of every commit.
- Leave `## [Unreleased]` as the only version heading until a release actually ships;
  don't pre-create a version number for work still in progress.

## Reporting bugs / requesting features

Please use the issue templates — they ask for the specific information (repro steps,
the actual XForm if the bug is form-specific, expected vs. actual behavior) that's
needed to act on a report quickly. See `SECURITY.md` instead if what you found is a
security vulnerability — please don't open a public issue for those.

## Code of Conduct

This project follows the Contributor Covenant — see `CODE_OF_CONDUCT.md`.
