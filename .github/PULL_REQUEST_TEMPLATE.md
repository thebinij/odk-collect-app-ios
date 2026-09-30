## What does this change, and why?

<!-- Explain the reasoning, not just what changed — link an issue if there is one. -->

## Testing

<!--
Per CONTRIBUTING.md: a bug fix isn't done without a test that would have caught it.
List the tests you added/ran, and how you verified this manually if applicable.
-->

- [ ] Added/updated a test covering this change
- [ ] Ran the relevant package's full test suite at least twice (not just once —
      some bugs in this codebase only showed up as flakes under full-suite load)
- [ ] Ran `xcodegen generate` and confirmed the regenerated `.xcodeproj` is **not**
      included in this PR's diff (it's gitignored — check `git status`)

## Checklist

- [ ] Comments explain *why*, not *what* (see `CONTRIBUTING.md`) — no comments
      restating what the adjacent code already says
- [ ] No speculative abstractions or unused configurability added for this change
- [ ] If this touches `bridge.js` or how `Question` is decoded, there's a
      `EnketoEngineIntegrationTests` case exercising the real DOM shape involved
