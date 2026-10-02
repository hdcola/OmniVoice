# Stable code-signing identity

## Why permissions reset after every update

macOS (TCC) ties microphone / speech recognition / screen recording grants to
the app's code-signing identity. An ad-hoc signature (`codesign --sign -`) has
no certificate, so the identity is just the binary's cdhash, which changes on
every build. After `brew upgrade` the new app looks like a different app and
every permission has to be granted again.

Signing with the same certificate every time makes the identity
`bundle id + certificate`, which survives updates.

This is **not** Developer ID signing or notarization: Gatekeeper still warns on
first launch, exactly as with the ad-hoc build.

## One-time setup (on the release build machine)

1. Keychain Access → Certificate Assistant → Create a Certificate…
   - Name: `OmniVoice Dev Signing` (the name `build_app.sh` looks for by default;
     any other name works if you pass it as `SIGN_IDENTITY`)
   - Identity Type: Self Signed Root
   - Certificate Type: Code Signing
   - Check "Let me override defaults", and set validity to 3650 days
2. Store it in the `login` keychain. In the private key's access settings,
   allow `codesign` to use it.
3. Verify: `security find-identity -p codesigning` lists the certificate.
4. **Back up the certificate and private key** (right-click → Export… → `.p12`).
   If it is lost or replaced, the next release gets a new identity and users
   have to re-grant permissions once more.

## Building

```bash
./Scripts/build_app.sh
./Scripts/build_dmg.sh
```

`build_app.sh` picks the signing identity in this order, and prints which one
it used:

1. `SIGN_IDENTITY`, if set. `SIGN_IDENTITY=-` forces ad-hoc signing; a name that
   is not in the keychain is an error.
2. The `OmniVoice Dev Signing` certificate, if it exists in the keychain.
3. Ad-hoc signing (e.g. contributors without the certificate).

Check the `==> codesigning with ...` line before releasing, and always use the
same certificate for every release.

## Notes

- The first release signed this way still resets permissions once (the identity
  changes from cdhash to certificate); later updates keep them.
- To clear stale entries manually: `tccutil reset All <bundle id>`.
