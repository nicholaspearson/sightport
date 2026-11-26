# Sightport updates

With **Check Automatically** enabled, Sightport checks for signed updates at launch and about once an hour while running. The update window appears in Sightport when a release is available, or when you return to the app. With **Download and Install Automatically** enabled, the window appears after the download is ready. You can install then or let Sparkle finish on quit. Use **Sightport → Check for Updates…** to check immediately, and **Sightport → Automatic Updates** to change either preference. [Sparkle update preferences](https://sparkle-project.org/documentation/customization/)

## Configure the release

The project pins its update feed and publisher key in two Xcode build settings.

| Setting | Value |
| --- | --- |
| `SIGHTPORT_UPDATE_FEED_URL` | Stable HTTPS URL of the signed appcast. The project defaults to the `appcast.xml` asset on the latest release in `nicholaspearson/sightport` on GitHub. |
| `SIGHTPORT_UPDATE_PUBLIC_KEY` | Base64 Ed25519 public key for the Sightport signing account. The public key is embedded in both Debug and Release. |

The release Mac stores the Sightport Ed25519 private key in macOS Keychain under the Sparkle service and account `app.sightport.mac.sparkle`. Use `generate_keys --account app.sightport.mac.sparkle -p` to read the matching public key. Retain the same key for subsequent builds. Back up the signing key securely. The release tools are in `SourcePackages/artifacts/sparkle/Sparkle/bin` under Xcode’s derived data directory. [Sparkle key setup](https://sparkle-project.org/documentation/)

Install the first update-enabled build manually. Its embedded public key authenticates subsequent releases. **Check for Updates…** fetches the signed feed once the publisher has uploaded the first release assets.

## Publish a version

1. Increase `CURRENT_PROJECT_VERSION` above every previously published build for the channel and set `MARKETING_VERSION`. Preserve the bundle identifier and Sparkle public key.
2. Build and export your Developer ID signed release with hardened runtime, notarize it, and staple the ticket. Verify the exported app and its embedded Sparkle framework with `codesign --verify --strict --deep Sightport.app`.
3. Make a zip and generate a signed appcast using the same Sparkle tool version as the client. The example expects `tag` to be the intended GitHub release tag, `app` to point at the exported Sightport.app, and `sparkle_bin` to point at Sparkle’s tools. Use a clean staging directory for a single latest release.

   ```sh
   mkdir -p release-stage
   ditto -c -k --sequesterRsrc --keepParent "$app" "release-stage/Sightport-$tag.zip"
   "$sparkle_bin/generate_appcast" --account app.sightport.mac.sparkle \
     --download-url-prefix "https://github.com/nicholaspearson/sightport/releases/download/$tag/" \
     release-stage
   "$sparkle_bin/sign_update" --account app.sightport.mac.sparkle --verify release-stage/appcast.xml
   ```

4. Attach the zip, `appcast.xml`, and any other files referenced in the feed to the same GitHub release before marking it latest. For a custom host, supply its archive URL prefix and publish `appcast.xml` at the configured feed URL. The feed, archives, and external release notes need matching signatures. Re-run the generator after changing them.
5. Install the previous signed build on a test Mac, select **Check for Updates…**, and verify the new version after relaunch. [Sparkle publishing guide](https://sparkle-project.org/documentation/publishing/)
