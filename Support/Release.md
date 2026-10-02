# Packaging and signed updates

The generated app links Sparkle 2.10.0. `UpdateController` starts it only when the built bundle contains an HTTPS `SUFeedURL` and a valid 32-byte base64 Ed25519 `SUPublicEDKey`. This workspace has neither release configuration nor a published feed. The Updates settings and Check for Updates menu entries show that state explicitly; no update host is contacted in this build.

Automatic checks and automatic downloading default to off. Users can opt into checks in Settings → Updates. Sparkle owns these preferences and its checking schedule. System profiling is disabled; process metrics, paths, and history are not sent. Archive signatures are verified before extraction.

Set these Xcode build settings when making a release:

- `PORTMASTER_UPDATE_FEED_URL`: your real HTTPS appcast URL.
- `PORTMASTER_UPDATE_PUBLIC_KEY`: your Ed25519 public key from Sparkle's `generate_keys`. Keep the private key in your own Keychain; never commit it.
- `CURRENT_PROJECT_VERSION`: a strictly increasing release build number.
- `MARKETING_VERSION`: the visible release version.

Use Xcode Archive → Distribute App → Developer ID, or `xcodebuild archive` and `xcodebuild -exportArchive` with your actual team and signing configuration. The exporter signs Sparkle's helpers for distribution. Release uses `Support/Portmaster.entitlements`; the library-validation exception in `Portmaster-Debug.entitlements` applies only to Debug ad-hoc testing.

Package an already exported app:

```sh
./scripts/package-dmg.sh /absolute/export/Portmaster.app /absolute/releases/Portmaster-1.0.dmg
```

The script verifies the app signature, preserves bundle symlinks/permissions, includes the app and an Applications shortcut, refuses to overwrite an existing output, and verifies the image. It does **not** sign, notarize, install, or publish anything. A development image is labeled as such. For public distribution, sign the DMG with Developer ID, notarize it and staple the ticket using your existing Apple signing credentials.

After notarization, run Sparkle's `generate_appcast` on your release archive directory using your signing key; host the generated appcast and archives at the configured HTTPS release location. Test an actual older signed/notarized build upgrading to a newer one before calling update delivery verified. Do not hand-write signatures or substitute an invented host.

References: [Sparkle setup and distribution](https://sparkle-project.org/documentation/), [programmatic updater setup](https://sparkle-project.org/documentation/programmatic-setup/), [publishing updates](https://sparkle-project.org/documentation/publishing/).
