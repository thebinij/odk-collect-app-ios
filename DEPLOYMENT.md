# Deployment: Firebase App Distribution

Pushing a version tag (`v1.2.3`) triggers `.github/workflows/firebase-distribution.yml`,
which builds a signed, ad-hoc `.ipa` and uploads it to Firebase App Distribution. None
of the credentials it needs are stored in this repo — this doc is the one-time setup to
create them and add them as GitHub Secrets/Variables.

This app has no Firebase SDK integrated (deliberately — see below), so this setup only
covers *distributing builds to testers*, not Analytics/Crashlytics/in-app update
prompts.

## Why no Firebase SDK in the app

`firebase appdistribution:distribute` (the CLI command the workflow runs) uploads a
signed `.ipa` straight to Firebase's distribution service — it needs zero code in the
app itself. Adding `FirebaseCore`/`FirebaseAnalytics` would only be needed for actual
Firebase *products* running on-device (Analytics, Crashlytics, or the
`FirebaseAppDistribution-Beta` SDK's in-app "a new build is available" prompt) — none
of which this pipeline requires.

## One-time setup

### 1. Pick your bundle ID

This repo ships no real bundle ID (see `Config.xcconfig.example`/"Local signing setup"
in `CONTRIBUTING.md`) — decide on the one you're actually shipping and register it as a
GitHub Actions **Variable** named `IOS_BUNDLE_ID` (step 5 below). The workflow writes it
into its own `Config.xcconfig` and the export's `ExportOptions.plist` at build time, so
nothing here is hardcoded.

### 2. Apple: a distribution certificate + ad-hoc provisioning profile

You need an **Apple Distribution** certificate and an **Ad Hoc** provisioning profile
for the bundle ID you picked above, registered in your Apple Developer account. If you
don't have these yet, create them in Xcode (Settings → Accounts → Manage Certificates)
or at
[developer.apple.com](https://developer.apple.com/account/resources/certificates/list).

**Export the certificate as a `.p12`:**

1. Open **Keychain Access**, find the certificate (under "My Certificates"), and
   expand it to reveal the private key.
2. Select both the certificate and its private key, right-click → **Export 2 items…**.
3. Save as `.p12`, and set a password (this becomes `IOS_DIST_CERTIFICATE_PASSWORD`).
4. Base64-encode it:
   ```sh
   base64 -i Certificates.p12 | pbcopy
   ```
   This is `IOS_DIST_CERTIFICATE_BASE64`.

**Get the provisioning profile — from developer.apple.com, not Xcode's automatic
signing:**

It's tempting to let `xcodebuild archive -allowProvisioningUpdates` generate one —
don't. A profile Xcode auto-creates this way gets its default name ("iOS Team Ad Hoc
Provisioning Profile: …"), and `xcodebuild` specifically refuses that kind of profile
when `CODE_SIGN_STYLE=Manual` (what this workflow needs, since there's no interactive
Xcode session on a CI runner to manage anything): **"is Xcode managed, but signing
settings require a manually managed profile."** A profile created directly on the
Developer Portal with your own name doesn't carry that restriction.

1. [developer.apple.com → Profiles](https://developer.apple.com/account/resources/profiles/list)
   → **+** → **Ad Hoc** (under Distribution)
2. Select the App ID for your bundle ID, then your **Apple Distribution** certificate
3. Select at least one registered test device
4. Give it any name of your own choosing (not Xcode's auto-generated pattern) →
   **Generate** → **Download**

```sh
base64 -i YourProfile.mobileprovision | pbcopy
```

This is `IOS_PROVISIONING_PROFILE_BASE64`. (The workflow reads the profile's UUID and
Team ID directly out of this file at build time — you don't need to supply those
separately.)

**If you ever generate a new Distribution certificate** (e.g. the old one's private key
isn't on this Mac — check with `security find-identity -v -p codesigning`), any
existing provisioning profile goes stale silently: it still decodes and looks valid,
but references a certificate whose key you no longer hold, so CI fails signing with
something like `security: failed to decode message`. Repeat the steps above to issue a
fresh profile tied to the new certificate, and update the
`IOS_PROVISIONING_PROFILE_BASE64` secret — a profile is pinned to one specific
certificate, not just a team.

### 3. Firebase: a service account for the App Distribution API

1. In the [Firebase console](https://console.firebase.google.com), open **Project
   settings → Service accounts**.
2. Click **Generate new private key** — this downloads a JSON key file. (If your
   organization restricts key creation, ask an owner to create one scoped to the
   **Firebase App Distribution Admin** role instead of the default Editor role.)
3. Base64-encode it:
   ```sh
   base64 -i service-account.json | pbcopy
   ```
   This is `FIREBASE_SERVICE_ACCOUNT_BASE64`.

### 4. Firebase: find your iOS App ID

In **Project settings → General**, under "Your apps," find the iOS app for the bundle
ID you picked in step 1 — its **App ID** looks like `1:1234567890:ios:abcdef1234567890`.
That's `FIREBASE_IOS_APP_ID`. (No app registered yet for that bundle ID? `firebase
apps:create IOS "<display name>" --bundle-id <your bundle id> --project <firebase
project id>` creates one from the CLI.)

### 5. Firebase: create a tester group

In **App Distribution → Testers & Groups**, create a group (e.g. `testers`) and add
the people who should receive builds. The group's name is `FIREBASE_TESTER_GROUPS`
(comma-separate multiple group names if you have more than one).

### 6. Add everything to GitHub

In this repo's **Settings → Secrets and variables → Actions**:

**Secrets** (Repository secrets tab):

| Name | Value |
|---|---|
| `IOS_DIST_CERTIFICATE_BASE64` | from step 2 |
| `IOS_DIST_CERTIFICATE_PASSWORD` | the password you set exporting the `.p12` |
| `IOS_PROVISIONING_PROFILE_BASE64` | from step 2 |
| `CI_KEYCHAIN_PASSWORD` | any password of your choosing — used only to protect the temporary keychain created during the CI run itself |
| `FIREBASE_SERVICE_ACCOUNT_BASE64` | from step 3 |

**Variables** (Variables tab — not secret, but easier to change without touching the
workflow file):

| Name | Value |
|---|---|
| `IOS_BUNDLE_ID` | from step 1 |
| `FIREBASE_IOS_APP_ID` | from step 4 |
| `FIREBASE_TESTER_GROUPS` | from step 5 |

## Shipping a build

Tags follow semver with a leading `v`: `v<major>.<minor>.<patch>`, optionally with a
`-beta.<n>` suffix for a build going to testers before it's considered stable —
`v0.1.1-beta.1`, then `v0.1.1-beta.2` if testers find something, then a plain `v0.1.1`
once it's confirmed good. Drop the suffix once this project reaches a stable 1.0.

```sh
git tag v0.1.1-beta.1
git push origin v0.1.1-beta.1
```

That's it — the workflow builds, signs, and distributes automatically. Watch its
progress under the **Actions** tab.

The **build number** (`CFBundleVersion` — the `(1)` in "Version 1.0 (1)" on Home) isn't
part of the tag — it's `$GITHUB_RUN_NUMBER`, which the workflow derives automatically
and always increases, even across differently-named tags. Never set it by hand.

## Local Firebase config (`GoogleService-Info.plist`)

This file is gitignored on purpose — it's not needed for this pipeline (see above), and
committing it publishes a live API key. If you later add an actual Firebase SDK to the
app (Analytics, Crashlytics, etc.), keep the file gitignored and instead have the app
target read it from a location injected at build/CI time, rather than committing it.
