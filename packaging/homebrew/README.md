# Homebrew distribution

Users install v2s with:

```bash
brew install --cask franklioxygen/v2s/v2s
```

That name resolves to the cask `Casks/v2s.rb` in the tap repository
`franklioxygen/homebrew-v2s`. Homebrew taps it automatically on first install.

`v2s.rb.template` in this directory is the source of truth for that cask. The
`Update Homebrew tap` step in `.github/workflows/release.yml` fills in
`__VERSION__` and `__SHA256__` from the release it just published, writes the
result to `Casks/v2s.rb` in the tap, and pushes.

Because the workflow can also be dispatched manually against an existing tag,
that step first compares the version already in the tap against the one being
published and skips the push if the tap is newer — re-running the workflow for
an old tag must not downgrade what `brew install` hands users. Publishing the
same version again is allowed, so a rebuilt asset can correct a checksum.

## Setup

Setup is complete: the tap repository is seeded with the cask for v0.3.35, and
the `HOMEBREW_TAP_TOKEN` secret is set, so releases update the tap on their own.

That secret is a fine-grained personal access token scoped to `homebrew-v2s`
with `Contents: Read and write` permission. If it is ever removed or expires,
the release workflow logs a skip instead of failing, and the tap simply stops
receiving new versions until it is replaced.

To regenerate the cask by hand, from a checkout of the tap:

```bash
VERSION=0.3.35
SHA256=$(curl -fsSL "https://github.com/franklioxygen/v2s/releases/download/v${VERSION}/v2s-${VERSION}.sha256" | awk '{print $1}')
sed -e "s/__VERSION__/${VERSION}/g" -e "s/__SHA256__/${SHA256}/g" \
  ../v2s/packaging/homebrew/v2s.rb.template > Casks/v2s.rb
```

## Notarization

The release build is ad-hoc signed (`CODE_SIGN_IDENTITY = "-"`), so macOS
quarantines the app and refuses to launch it until the user runs
`xattr -dr com.apple.quarantine /Applications/v2s.app`. Homebrew 6 removed the
`--no-quarantine` install flag, so there is no way to avoid this from the cask.

Signing with a Developer ID certificate and notarizing in the release workflow
would remove that step, and is also a prerequisite for `brew audit --new`, which
currently fails with "not signed by a distributor that meets the system
Gatekeeper requirements" — the check that gates submission to the official
`homebrew/cask` repository.
