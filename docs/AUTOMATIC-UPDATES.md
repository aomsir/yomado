# Automatic updates and release signing

yomado uses [Sparkle 2.10.0](https://github.com/sparkle-project/Sparkle/releases/tag/2.10.0). `scripts/fetch-sparkle.sh` downloads the official distribution and verifies its pinned SHA-256 before using its framework or tools. Expanded cached files are checked against that archive. Dependencies stay in the ignored `.build-deps/` directory; `YOMADO_DEPS_DIR` can select another build cache. The bundled license and third-party notices are in `ThirdPartyNotices/Sparkle-LICENSE.txt`.

`build.sh` copies the framework with its symlinks and executable permissions intact. It signs Installer.xpc, Downloader.xpc, Autoupdate, Updater.app, the framework, the watchdog, and the host app from the inside out. Downloader entitlements are preserved as described in [Sparkle's signing instructions](https://sparkle-project.org/documentation/sandboxing/#code-signing). An explicit `YOMADO_SIGNING_IDENTITY` enables Developer ID signing, hardened runtime, and secure timestamps throughout. Local builds are ad hoc signed and are not distribution builds.

## Release key and feed

The production feed is `https://raw.githubusercontent.com/chekusu/yomado/main/appcast.xml`. Keep this URL stable across releases. Update archives remain immutable GitHub Release assets. The application must contain its real `SUPublicEDKey` before the updater can start; an empty or example key must never enable automatic updates. `SURequireSignedFeed` and `SUVerifyUpdateBeforeExtraction` protect the feed and archive before extraction.

Create the release key once, on the authorized release machine, using Sparkle's `bin/generate_keys --account yomado-updates`. This explicitly creates a Keychain item; it is not part of the build. Copy only the public key into `Info.plist`. Keep the private key in Keychain and a secure backup outside source control. Do not put a key in the app, an appcast, build logs, environment files in the repository, or a public CI workflow. `bin/generate_keys --account yomado-updates -p` only reads an existing public key. See [Sparkle's key guidance](https://sparkle-project.org/documentation/#eddsa-ed25519-signatures).

Build with the release identity, verify nested signatures, notarize the application, and staple the ticket **before** making the final ZIP. The ZIP should contain only `Yomado.app`. Never modify it after generating its EdDSA signature.

Place only the current final ZIP in a dedicated release-archive directory, then run:

```sh
scripts/generate-appcast.sh path/to/release-archives/ \
  https://github.com/chekusu/yomado/releases/download/vVERSION/
```

The script uses the existing `yomado-updates` Keychain account (`YOMADO_SPARKLE_KEY_ACCOUNT` overrides its name). It checks the bundle identity, production feed, public-key match, security settings, and build number. Sparkle generates and signs a feed for the latest full update; its verification tool then checks the feed and referenced archive. This command does not create keys or publish files. Keeping one full update avoids inventing new URLs for archives hosted under older release tags. Increment `CFBundleVersion` for each release; this script does not compare against the live production feed.

Publish the immutable archive first, verify its downloaded bytes and signature, and only then commit the generated `appcast.xml`. Re-run the generator after any appcast or release-note modification. Do not edit a signed XML feed by hand. No delta updates are generated initially.

## Acceptance before enabling production updates

Use an isolated macOS test guest and a separate fixture application identity, feed and disposable signing key. Do not point an installed production app at a test feed. Test a real old-to-new application replacement and relaunch, rejection of a tampered archive/feed, cancellation, unavailable networking, and protected workspace recovery. A passing policy test, valid archive signature, or successful build does not prove that the installation UI or relaunch works.

The hosted runtime fixture uses a temporary code-signing certificate and explicitly provisions Accessibility and Screen Recording for its own test bundle, bound to the same designated requirement in both builds. This avoids inheriting the runner shell's permission before update and losing it when Sparkle relaunches the app. The setup runs only in a disposable GitHub-hosted macOS guest; it never grants permissions on a developer's Mac. It verifies installation and recovery under a preauthorized test identity, but does not establish that an existing user's Developer ID permission grant survives a production upgrade. Verify that separately with the actual signed release and a user-authorized test account.

Automatic checks, automatic downloads, install timing, and system-profile sharing are separate settings. Preserve user choices rather than overwriting them on each launch. Keep optional system-profile sharing disabled by default; an HTTPS update request still reveals its network address and ordinary request metadata to the hosting service. Update installation must wait for the app's workspace-safety check; a background download is not authorization to interrupt active virtual-screen work.
