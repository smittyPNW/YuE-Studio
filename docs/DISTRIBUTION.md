# Package a Mac disk image

The community DMG contains YuE Studio, the complete Studio Mastering helper and catalog, MP3 encoder and its source archive, licenses, an Applications shortcut, and an offline getting-started page. It does not contain generation models, Python, personal libraries or credentials. The app's generation quality settings are unchanged by packaging.

## Local build

With Xcode command-line tools, CMake, Ninja, pkgconf and `uv` available:

```bash
bash custom/package-local.sh
bash custom/package-dmg.sh
```

The second script runs pinned `dmgbuild==1.6.7` through `uv`, creates the branded Finder layout, verifies the disk image and writes its SHA-256 sidecar. Output is in `custom/dist/`. Existing DMGs are never overwritten. Set `DISTRIBUTION_DIR` to a new folder for another attempt, or `SOURCE_APP` to a previously built bundle. Staging is temporary and the source bundle is not modified.

These defaults produce an ad-hoc signed development image. Public distribution should use your own Developer ID Application certificate and notarization credentials.

## Signed and notarized release

Set `SIGN_IDENTITY` to a Developer ID Application identity from your keychain and set `NOTARIZE=1`. Authenticate using either:

- `NOTARY_PROFILE`: an existing `notarytool` keychain profile; or
- `NOTARY_KEY_PATH`, `NOTARY_KEY_ID` and `NOTARY_ISSUER`: your App Store Connect API key path and identifiers.

Do not commit credentials, export signing keys into the repository, or place them inside the app or disk image. The script signs both helpers and app with hardened runtime and secure timestamps, notarizes/staples the app, constructs/signs the image, then notarizes/staples the image. Gatekeeper assessments must pass before the script completes. No sandbox or runtime exception entitlements are added.

Before publishing, mount the final DMG, validate the copied app's signature and staple ticket, confirm the Applications link and getting-started page, and open the copied app. Exercise the bundled helper and verify that external non-system libraries are not required. Publish the DMG, checksum and corresponding source together. Never publish the local staging directory or credentials.

Reference: [Apple's notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow), [dmgbuild settings](https://dmgbuild.readthedocs.io/en/latest/settings.html).
