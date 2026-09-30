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

### 1. Apple: a distribution certificate + ad-hoc provisioning profile

You need an **Apple Distribution** certificate and an **Ad Hoc** provisioning profile
for this app's bundle ID (`np.com.yipl.odk`, or whatever you've changed it to in
`project.yml`), registered in your Apple Developer account. If you don't have these
yet, create them in Xcode (Settings → Accounts → Manage Certificates) or at
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

**Get the provisioning profile:**

Download the `.mobileprovision` file from developer.apple.com (or find it locally under
`~/Library/MobileDevice/Provisioning Profiles/` if Xcode already downloaded it), then:

```sh
base64 -i YourProfile.mobileprovision | pbcopy
```

This is `IOS_PROVISIONING_PROFILE_BASE64`. (The workflow reads the profile's UUID and
Team ID directly out of this file at build time — you don't need to supply those
separately.)

### 2. Firebase: a service account for the App Distribution API

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

### 3. Firebase: find your iOS App ID

In **Project settings → General**, under "Your apps," find the iOS app for this bundle
ID — its **App ID** looks like `1:1234567890:ios:abcdef1234567890`. That's
`FIREBASE_IOS_APP_ID`.

### 4. Firebase: create a tester group

In **App Distribution → Testers & Groups**, create a group (e.g. `testers`) and add
the people who should receive builds. The group's name is `FIREBASE_TESTER_GROUPS`
(comma-separate multiple group names if you have more than one).

### 5. Add everything to GitHub

In this repo's **Settings → Secrets and variables → Actions**:

**Secrets** (Repository secrets tab):

| Name | Value |
|---|---|
| `IOS_DIST_CERTIFICATE_BASE64` | from step 1 |
| `IOS_DIST_CERTIFICATE_PASSWORD` | the password you set exporting the `.p12` |
| `IOS_PROVISIONING_PROFILE_BASE64` | from step 1 |
| `CI_KEYCHAIN_PASSWORD` | any password of your choosing — used only to protect the temporary keychain created during the CI run itself |
| `FIREBASE_SERVICE_ACCOUNT_BASE64` | from step 2 |

**Variables** (Variables tab — not secret, but easier to change without touching the
workflow file):

| Name | Value |
|---|---|
| `FIREBASE_IOS_APP_ID` | from step 3 |
| `FIREBASE_TESTER_GROUPS` | from step 4 |

## Shipping a build

```sh
git tag v1.0.0
git push origin v1.0.0
```

That's it — the workflow builds, signs, and distributes automatically. Watch its
progress under the **Actions** tab.

## Local Firebase config (`GoogleService-Info.plist`)

This file is gitignored on purpose — it's not needed for this pipeline (see above), and
committing it publishes a live API key. If you later add an actual Firebase SDK to the
app (Analytics, Crashlytics, etc.), keep the file gitignored and instead have the app
target read it from a location injected at build/CI time, rather than committing it.
