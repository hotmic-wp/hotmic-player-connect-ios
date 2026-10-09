# Authentication and tokens

Obtain a short-lived viewer token from your partner backend.

## Keep signing on the backend

Access tokens are HS256 JWTs minted by the partner backend using the API signing secret.
Never ship the API secret in an app, plist, sample, source repository or shared Xcode scheme.
The app receives an API key and viewer access token through your authenticated backend:

```swift
import HotMicCore
let client = HotMicClient(apiKey: apiKey, accessToken: accessToken)
```

Do not log credentials or raw authentication responses. Keep the client, resolver and interaction
source scoped to the signed-in user. On sign-out or credential replacement, tear down the old player
and construct new adapters with the new client; the resolver and player cache media independently.
Core 1.0.2 targets production and offers no configurable API base URL.

## Example credential loading

The examples read nonempty `HOTMIC_API_KEY` and `HOTMIC_ACCESS_TOKEN` from the Run environment first.
Alternatively, create `HotMicCredentials.json` in the running app’s Documents directory with those
same two keys. The file is ignored by Git and never bundled. Missing/incomplete credentials select
fake mode with a visible label. `--fake` bypasses both credential sources, guaranteeing no HotMic calls.
Never put credentials into a tracked file or shared scheme. Real-credential verification requires an
authorized HotMic account and a known VOD ID; it is a separate manual check.
