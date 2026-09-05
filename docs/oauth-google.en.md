# Configure Google OAuth for OkamiUNI

[Português (Brasil)](oauth-google.md) · **English**

This guide is for the person building or distributing the app. End users of an already configured build sign in through the Accounts window; they do not need to create a Cloud project.

OkamiUNI uses a Google desktop OAuth client, PKCE (S256) and the system's `ASWebAuthenticationSession`. Without a configured client ID, the Google connection explains the missing configuration and opens this guide. The IMAP form remains available.

## 1. Create a project and enable APIs

In the [Google Cloud console](https://console.cloud.google.com/), create or select the project that will own the app's OAuth identity. Enable **Gmail API**, **Google Calendar API** and **Google Meet API** for the mail and meeting features implemented by the app.

## 2. Configure consent and access

Configure the app name, support email, audience and developer contact in Google Auth Platform. For an external app in testing, add the Google accounts you will connect as test users. Testing is a development configuration; review Google's publishing and verification requirements before public distribution. See [Google's native-app OAuth documentation](https://developers.google.com/identity/protocols/oauth2/native-app).

The current `GoogleAuthConfig.defaultScopes` requests:

| Scope | Use in OkamiUNI |
|---|---|
| `https://mail.google.com/` | Read, organize, send and permanently delete mail. |
| `https://www.googleapis.com/auth/userinfo.email` | Identify the connected email address. |
| `https://www.googleapis.com/auth/calendar.events` | Calendar events used by meeting creation. |
| `https://www.googleapis.com/auth/meetings.space.created` | Create Google Meet spaces. |

The previous pair `gmail.modify` + `gmail.send` does not cover the app's permanent-deletion operation. Accounts authorized with older scopes may need to reconnect once when using features requiring the new scopes. Grant access only to the project you intend to use.

## 3. Create a desktop client

Create an OAuth client with application type **Desktop app**. Copy its client ID and the `client_secret` from its downloaded configuration when Google provides one.

The current Google implementation derives its callback scheme from the client ID:

```text
Client ID: 123-example.apps.googleusercontent.com
Callback:  com.googleusercontent.apps.123-example:/oauth
```

Do not substitute the obsolete `com.okamiops.okamiuni:/oauth` callback from early plans. `GoogleAuthConfig` derives the scheme and `ASWebAuthenticationSession` receives it. The separate LiteLLM OAuth flow uses a loopback callback; it is not the Google flow described here.

Desktop clients cannot keep an embedded value confidential. Nevertheless, Google may require the supplied `client_secret` during token exchange and refresh, and OkamiUNI sends it when configured. PKCE remains enabled. This configuration is separate from user access/refresh tokens, which the app stores in Keychain.

## 4. Configure the local build

From the repository root, create the local configuration only if it does not already exist:

```bash
test -e Config/Google.xcconfig || cp Config/Google.example.xcconfig Config/Google.xcconfig
```

Edit both values as appropriate in `Config/Google.xcconfig`:

```text
OKAMIUNI_GOOGLE_CLIENT_ID = YOUR_DESKTOP_CLIENT_ID.apps.googleusercontent.com
OKAMIUNI_GOOGLE_CLIENT_SECRET = YOUR_DESKTOP_CLIENT_SECRET
```

`Config/Google.xcconfig` is ignored by Git. Do not replace an existing configured file with the empty example. Xcode passes these values into the app's `Info.plist`; they are part of the local build, not a confidential server-side secret store.

```bash
xcodegen generate
xcodebuild -project OkamiUNI.xcodeproj -scheme OkamiUNI \
  -configuration Debug -derivedDataPath build/DerivedData build
```

Use your own development signing team if you are building outside the maintainer's setup. The [repository README](https://github.com/OkamiOps/okamiuni/blob/v0.5.4/README.md) covers build requirements.

## 5. Check the result

Open the built app, go to Accounts and start the Google connection. A missing-ID message means the app was built without the setting. `client_secret is missing` means the desktop client's supplied value needs to be configured. A callback mismatch calls for checking the client type and ID; do not add arbitrary redirect strings to the code. An access denial can also reflect audience, test-user or administrator restrictions.

For offline developer checks, `swift test --package-path Packages/UNISync --filter GoogleAuthTests` exercises the OAuth logic with a stub transport. It does not prove live Google consent. The internal `--ensaiar-contas` rehearsal also uses a fake authorization presenter and local test data; a successful rehearsal is not evidence that a real account can sign in.
