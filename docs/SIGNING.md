# Signing and notarizing Sozvon

Without a Developer ID signature, macOS says it "cannot verify the developer" on first launch
(workaround: right-click → Open) and resets the microphone and screen recording permissions
on every update. With signing and notarization the DMG opens with a double click and permissions
survive updates.

## 0. Prerequisites

- A paid Apple Developer Program membership ($99 per year) for the team that signs the app.
- The **Account Holder** role in that team. Only the account holder (or an Admin they granted
  certificate access) can create a Developer ID certificate. If "Developer ID Application" is
  missing from the list of certificate types, ask the account holder.
- A Mac with Xcode (or at least the Command Line Tools) and Keychain.
- Node.js 22 or later, to bundle the own server into the app and run its tests (optional for local builds).

## 1. "Developer ID Application" certificate

**With Xcode (easier):**
1. Xcode → Settings → Accounts → "+" → Apple ID, sign in.
2. Select the team → **Manage Certificates…** → "+" → **Developer ID Application**.
3. The certificate and its private key are added to the "login" keychain automatically.

**Through the website:**
1. Keychain Access → Keychain Access menu → Certificate Assistant → "Request a Certificate
   From a Certificate Authority…". Email, name, "Saved to disk" → you get a `.certSigningRequest` file.
2. https://developer.apple.com/account/resources/certificates → "+" → **Developer ID Application**
   (G2 Sub-CA profile) → upload the request file → download the `.cer` → double-click it to add it to the keychain.

**Check:**
```bash
security find-identity -v -p codesigning
# expected: "Developer ID Application: <Team> (<TEAMID>)"
```

## 2. Notarization key (App Store Connect API)

1. https://appstoreconnect.apple.com → Users and Access → Integrations → **App Store Connect API**
   → Team Keys → "+" (Generate API Key), role **Developer**.
2. Download `AuthKey_XXXXXXXXXX.p8`. It can be downloaded **only once**, store it safely.
3. Note the **Key ID** (in the key row) and the **Issuer ID** (above the table).

(Instead of a key you can use an app-specific password: appleid.apple.com → App-Specific Passwords; then
pass `--apple-id`, `--team-id`, `--password` to `notarytool store-credentials`.)

## 3. Signed build on your Mac

```bash
# once: store the notarization key in the keychain under the name sozvon
xcrun notarytool store-credentials sozvon \
  --key ~/Downloads/AuthKey_XXXXXXXXXX.p8 --key-id XXXXXXXXXX --issuer xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx

# build: build.sh finds the Developer ID in the keychain, signs, notarizes and staples the ticket
NOTARY_PROFILE=sozvon ./build.sh dmg

# check
spctl -a -vvv -t install build/Sozvon.dmg      # expected: accepted, source=Notarized Developer ID
```

## 4. Signed releases on GitHub

Repository secrets: Settings → Secrets and variables → Actions → New repository secret.

1. Export the certificate: Keychain Access → My Certificates → right-click
   "Developer ID Application: …" → Export → `.p12` format, set a password.
2. Add the secrets (with `gh` or manually in the web UI):
```bash
gh secret set DEVELOPER_ID_P12          --body "$(base64 -i ~/Desktop/DeveloperID.p12)"
gh secret set DEVELOPER_ID_P12_PASSWORD --body "p12-password"
gh secret set NOTARY_KEY_P8             --body "$(base64 -i ~/Downloads/AuthKey_XXXXXXXXXX.p8)"
gh secret set NOTARY_KEY_ID             --body "XXXXXXXXXX"
gh secret set NOTARY_ISSUER_ID          --body "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
```
3. Release a version:
```bash
git tag v0.1.1 && git push origin v0.1.1
```
GitHub Actions (`.github/workflows/release.yml`) runs the tests, signs, notarizes and uploads
`Sozvon-0.1.1.dmg` to Releases. Without the secrets the release still builds, but unsigned and marked
as a pre-release. The workflows set up Node.js (22 or later is required) so that `build.sh` bundles `server/`
into the app for Connect Cloudflare and `test.sh` runs the server tests; in CI a missing server bundle fails the build, and `test.sh` fails without Node.js 22+. A local build without
Node.js still works, the button then says it is unavailable.

## 5. Notes

- Never commit `.p12` and `.p8` files (they are in `.gitignore`). Delete local copies after uploading
  them as secrets; the original certificate stays in the keychain.
- Do not change the bundle id `io.github.able1991.sozvon`: user permissions depend on it.
- When switching from local signing to Developer ID, users who installed an unsigned build lose
  their permissions once. Later updates keep them.
- A Developer ID certificate is valid for 5 years. Versions already signed and notarized keep
  working after it expires.
