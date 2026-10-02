#!/bin/bash
# Package the tagged commit on this Mac and publish it as a GitHub release.
# This is the same job the Signed release workflow runs, for when no
# self-hosted runner is online. Credentials come from the login keychain:
#   NOTARY_KEYCHAIN_PROFILE  a `xcrun notarytool store-credentials` profile
#   Sparkle private key      created once with Sparkle's `generate_keys`
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_DIR"

: "${NOTARY_KEYCHAIN_PROFILE:?NOTARY_KEYCHAIN_PROFILE is required (see docs/RELEASING.md)}"

VERSION="$(tr -d '[:space:]' < VERSION)"
TAG="v$VERSION"

if [[ -n "$(git status --porcelain)" ]]; then
  echo "The working tree has uncommitted changes; release only committed source." >&2
  exit 2
fi
if ! git tag --points-at HEAD | grep -Fxq "$TAG"; then
  echo "HEAD is not tagged $TAG. Tag the merge commit on master first." >&2
  exit 2
fi
if [[ "$(git ls-remote --tags origin "refs/tags/$TAG" | awk '{print $1}')" != "$(git rev-parse "$TAG")" ]]; then
  echo "Push $TAG to origin before publishing." >&2
  exit 2
fi
if gh release view "$TAG" >/dev/null 2>&1; then
  echo "Release $TAG already exists." >&2
  exit 2
fi

swift test -Xswiftc -warnings-as-errors
RELEASE_TAG="$TAG" ./scripts/package_release.sh

gh release create "$TAG" \
  dist/MacComputerUse-*.dmg \
  dist/MacComputerUse-*.zip \
  dist/appcast.xml \
  dist/mac-computer-use.rb \
  --verify-tag \
  --generate-notes \
  --title "Mac Computer Use $VERSION"
