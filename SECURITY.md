# Security Policy

## Reporting a Vulnerability

**Please do not open a public GitHub issue for a security vulnerability.**

Instead, use GitHub's private vulnerability reporting:

1. Go to the **Security** tab of this repository.
2. Click **Report a vulnerability** under "Advisories."
3. Describe the issue: what it is, how to reproduce it, and its potential impact.

This opens a private conversation with the maintainers, visible only to you and them,
so the issue can be discussed and fixed before any public disclosure.

If private reporting isn't available to you for some reason, open an issue that
describes only that you've found a security issue and would like a private channel to
share details — without describing the vulnerability itself — and a maintainer will
follow up.

## Scope

This is an OpenRosa/ODK client. Areas of particular interest for security reports:

- Credential handling (`Packages/ProjectSettingsKit` — passwords must only ever be
  stored in the Keychain, never `UserDefaults` or written to disk in plain text).
- Network communication with the configured OpenRosa server
  (`Packages/OpenRosaKit/Sources/OpenRosaKit/OpenRosaClient.swift`) — TLS handling,
  authentication, and how server responses are parsed.
- Local submission storage (`SubmissionStore`) — whether draft/sent form data (which
  may contain sensitive survey responses) is stored in a way that's exposed to other
  apps or processes on the device.
- The headless Enketo engine (`Packages/ODKWebEngine`) — since it runs a JS engine
  (`enketo-core`/`enketo-transformer`) inside a `WKWebView`, anything that could let a
  malicious or malformed XForm execute unintended native-side behavior via the
  `bridge.js` message channel.

## Supported Versions

This project does not yet have a formal release/versioning process — the `main` branch
is the only supported version. Security fixes will be released as soon as practical
after a report is triaged.
