# Releasing Mac Computer Use

The release job turns a version-matching tag into four public artifacts:

- a universal, notarized `MacComputerUse.app` inside a drag-to-Applications DMG;
- a notarized ZIP signed for Sparkle delivery;
- a signed `appcast.xml` whose enclosure points at that tag's ZIP;
- a versioned Homebrew cask with the DMG SHA-256 filled in.

The bundle identifier remains `com.modestnerd.mac-computer-use` and the executable remains `mac-computer-use`. Do not change either during release work: they are part of the app's permission and MCP registration identity.

## One-time setup

Create an Ed25519 key with Sparkle's `generate_keys` tool after resolving the package. Keep the private key stable and secret; changing the public key in later builds breaks the trust chain for installed copies.

Configure these GitHub Actions secrets:

| Secret | Value |
| --- | --- |
| `MACOS_CERTIFICATE` | Base64-encoded Developer ID Application `.p12` |
| `MACOS_CERTIFICATE_PASSWORD` | Password used when exporting that `.p12` |
| `MACOS_SIGNING_IDENTITY` | Full `Developer ID Application: …` identity |
| `APPLE_ID` | Apple ID used by notarytool |
| `APPLE_TEAM_ID` | Apple Developer team ID |
| `APPLE_APP_SPECIFIC_PASSWORD` | App-specific password for notarization |
| `SPARKLE_PRIVATE_KEY` | Private Ed25519 key exported for CI |
| `SPARKLE_PUBLIC_ED_KEY` | Matching public key embedded in release builds |

The workflow imports the certificate into an isolated temporary keychain and deletes it even when packaging fails. Local builds do not require these secrets and omit all updater configuration.

## Cut a release

1. Change `VERSION` in a pull request and merge it to `master`.
2. Tag the merge commit as `v<VERSION>` and push the tag.
3. Watch the **Signed release** workflow. It rejects a tag that does not exactly match `VERSION`.
4. Download the published DMG on a clean Mac and verify Gatekeeper, first-run setup, client registration, and a real MCP action.
5. Publish the attached `mac-computer-use.rb` in the Homebrew tap when the tap is ready. The cask already contains the exact release URL and checksum.

The workflow can also be dispatched manually for an existing tag; it never packages arbitrary untagged source.

## Update safety model

Every MCP process holds a shared file lock. Sparkle must acquire the exclusive side before invoking its installer, so an update waits for active sessions to end. The updater then leaves a handoff marker while the manager exits and Sparkle swaps the bundle. New MCP processes fail with a temporary-unavailable exit during that interval. The newly launched manager clears the marker only after it owns the app again.

Automatic checks and downloads are enabled only in Developer ID release builds. A user can also trigger **Check for Updates…** from the menu. Both paths use the same session gate.
