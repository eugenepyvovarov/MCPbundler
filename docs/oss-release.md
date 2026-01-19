# Release packaging

This doc explains how to build and publish MCP Bundler releases (app bundle, Sparkle appcast, and Homebrew cask).

## App bundle release

Prereqs:
- Apple Developer ID Application certificate (for signing).
- Sparkle EdDSA private key (for appcast signing).
- Notarytool profile (recommended).
- Hosting for ZIP, appcast, and release notes.

Steps:
1. Update `CHANGELOG.md` with the release notes for this build.
2. Run the release script:
   `scripts/release.sh`
3. The script builds, signs, optionally notarizes, and generates:
   - `dist/MCPBundler-<version>-<build>.zip`
   - `dist/MCPBundler-latest.zip`
   - `dist/appcast.xml`
   - `dist/release-notes/*.html`
   - `dist/MCPBundler-<version>-<build>.zip.sha256`
4. Upload the ZIP to your downloads host and the appcast to its URL.
5. Publish the release notes HTML (or pass `--notes-url` to point at a hosted page).

Common overrides:
- `SPARKLE_PRIVATE_KEY` to point at the private key.
- `NOTARYTOOL_PROFILE` and `NOTARY_PRIMARY_BUNDLE_ID` for notarization.
- `DOWNLOAD_BASE` and `RELEASE_NOTES_BASE_URL` for hosting URLs.
- `RELEASE_VERSION` and `RELEASE_BUILD` to skip prompts.

## Homebrew cask release

Prereqs:
- A Homebrew tap repo that hosts the cask (e.g., `homebrew-tap`).
- A cask file for MCP Bundler (e.g., `Casks/mcp-bundler.rb`).

Steps:
1. Use the SHA-256 printed by `scripts/release.sh` (or the `.sha256` file).
2. Update the cask:
   - `version` to the new marketing version.
   - `sha256` to the new archive hash.
   - `url` to `MCPBundler-<version>-<build>.zip` on your host.
3. Test locally:
   - `brew install --cask --no-quarantine <tap>/mcp-bundler`
   - `brew audit --cask --new <tap>/mcp-bundler`
4. Commit and push the tap update.

Notes:
- Keep the appcast version/build aligned with the cask version.
- If you host a "latest" ZIP, keep it in sync with the current appcast entry.
