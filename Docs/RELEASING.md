# Releasing OmniVoice

How a new version goes from `main` to testers' machines. This is the process
the 0.5.x releases followed; each step names the file or command it touches.

What this is **not**: Developer ID signing, notarization or an auto-updater.
Builds are signed with the stable self-signed `OmniVoice Dev Signing`
certificate and distributed as a DMG on GitHub Releases plus a Homebrew cask.
See `Docs/SIGNING.md` for the certificate and `Docs/RELEASE_TESTING.md` for
what testers have to do to open the app. The open items (notarization,
Sparkle-style updates) are tracked under "Release pipeline" in
`Docs/PROGRESS.md`.

The contributor workflow (branches, PRs, `CHANGELOG.md` entries) is in
`AGENTS.md`; this document starts where that one ends: every change that
belongs in the release is already merged to `main` with its `[Unreleased]`
entry.

## Where the pieces live

| What | Where |
| --- | --- |
| App version | `Scripts/Info.plist`: `CFBundleShortVersionString` (e.g. `0.5.6`) and `CFBundleVersion` (build number, +1 every release; 14 at 0.5.6) |
| Release notes | `CHANGELOG.md` (Keep a Changelog, one dated section per version) |
| Download link in the docs | `README.md`: the "Current version" line and the `.dmg` link |
| Build | `Scripts/build_app.sh` → `build/OmniVoice.app`, then `Scripts/build_dmg.sh` → `build/OmniVoice-<version>.dmg` |
| Signing | `Docs/SIGNING.md` |
| Published build | A GitHub Release `v<version>` on `hdcola/OmniVoice` with the DMG attached |
| Homebrew | `Casks/omnivoice.rb` in the separate repo `hdcola/homebrew-tap` |
| Release log | `Docs/PROGRESS.md` (one "release cut" bullet per version) |

Versions are `0.MINOR.PATCH` while this is an internal test build. No bump
rule is written down: 0.5.2 to 0.5.6 were all patch bumps, features included,
and the minor moved at 0.3, 0.4 and 0.5. Decide per release and keep the
build number going up by one.

## Before you start

- `main` is what you want to ship, and CI is green on it.
- Locally, on `main`: `swift build` and `swift test` pass. CI only runs
  `swift build` (see the note in `.github/workflows/ci.yml`), so `swift test`
  is on you. Run the UI tests in `UITests/` too when the release touches the
  onboarding, Settings or the floating panel (`UITests/README.md`).
- The `OmniVoice Dev Signing` certificate is in your login keychain
  (`security find-identity -p codesigning`). A release signed with another
  identity makes every tester re-grant their permissions.
- `CHANGELOG.md`'s `[Unreleased]` has an entry for everything user-facing that
  was merged (`AGENTS.md` §7).

## 1. Cut the release PR

Never commit to `main` directly (`AGENTS.md` §1), so the cut is a PR too.

```bash
git fetch origin
git checkout -b chore/release-X.Y.Z origin/main
```

In that branch:

1. **Bump the version** in `Scripts/Info.plist`: `CFBundleShortVersionString`
   to `X.Y.Z` and `CFBundleVersion` to the previous build number + 1.
2. **Cut the changelog.** Rename `## [Unreleased]` to
   `## [X.Y.Z] - YYYY-MM-DD` and put a fresh, empty `## [Unreleased]` above it
   with the section skeleton from `AGENTS.md` §8 (`### Added` … `### Tests`).
3. **Update `README.md`**: the "Current version" line and the `.dmg` download
   link (both name the version, and the link also contains the `vX.Y.Z` tag).
4. **Check the what's-new notes** (`WhatsNewCatalog` in
   `Sources/OmniVoiceCore/WhatsNew.swift`). If this release adds something
   users have to opt into or grant a permission for, add a `WhatsNewEntry`
   whose `revision` is one above `WhatsNewCatalog.latestRevision`. Fixes and
   tweaks don't get an entry. Remove entries for features that no longer
   exist. Existing users see every entry newer than the last revision they
   saw, once, in a single window.
5. **Note the cut in `Docs/PROGRESS.md`** with a bullet in the same shape as
   the earlier ones ("**X.Y.Z release cut** (date, `chore/release-X.Y.Z`): …").

Commit as `chore(release): cut X.Y.Z`, push, open the PR and merge it once
reviewed. The cut itself is the `CHANGELOG.md` change for this PR; it doesn't
need its own line under `[Unreleased]`.

## 2. Build and check the DMG

On the machine that holds the signing certificate, from an up-to-date `main`
that contains the merged release PR:

```bash
git checkout main && git pull origin main
./Scripts/build_app.sh
./Scripts/build_dmg.sh
```

- `build_app.sh` prints which identity it used. You want
  `==> codesigning with "OmniVoice Dev Signing"`. If it says
  `ad-hoc codesigning`, stop: the certificate is missing and testers would
  lose their permissions. Fix it (`Docs/SIGNING.md`) and rebuild.
- `build_dmg.sh` names the file from the app's version:
  `build/OmniVoice-X.Y.Z.dmg`. Check that the version in the name is the one
  you meant to ship.
- Smoke-test the DMG, not just the `.app` in `build/`: mount it, drag the app
  out, clear the quarantine flag (`xattr -cr /Applications/OmniVoice.app`,
  see `Docs/RELEASE_TESTING.md`), launch it, and try one real thing (a
  transcription, ⌥A).

## 3. Tag and publish

The tag goes on the merge commit of the release PR on `main`, as in 0.5.x.

```bash
git tag vX.Y.Z <merge commit of the release PR>
git push origin vX.Y.Z

gh release create vX.Y.Z build/OmniVoice-X.Y.Z.dmg \
  --title "OmniVoice X.Y.Z" \
  --notes-file <notes file>
```

The notes file is the short intro the earlier releases used (internal test
build, signed with `OmniVoice Dev Signing`, not notarized, point to
`Docs/RELEASE_TESTING.md` and the `xattr -cr` step) followed by the new
`[X.Y.Z]` section copied from `CHANGELOG.md`.

Do not move or delete a published tag, and don't swap the DMG after the
Homebrew cask has hashed it. If something is wrong, ship a new patch version.

## 4. Update the Homebrew cask

The cask lives in `hdcola/homebrew-tap`, not in this repository. Its
`scripts/update-omnivoice.sh` reads the latest GitHub Release, recomputes the
DMG's sha256 and rewrites `Casks/omnivoice.rb`.

```bash
cd <checkout of hdcola/homebrew-tap>
./scripts/update-omnivoice.sh -n      # dry run: shows the new version and sha256
./scripts/update-omnivoice.sh -p      # update, commit and push
```

(`-c` commits without pushing, `-f` forces a recalculation, and an explicit
version can be passed as an argument; the tap's own `README.md` has the
list.) The commit it makes is `chore(omnivoice): bump cask to vX.Y.Z`.

## 5. Verify

- The `.dmg` link in `README.md` downloads the file you built.
- `brew update && brew upgrade --cask omnivoice` installs `X.Y.Z` (or
  `brew install --cask omnivoice` on a fresh machine; see the README for
  `brew trust`).
- The new version opens and its permissions survived the update. They do as
  long as the signing identity didn't change; the first release after
  switching identity resets them once (`Docs/SIGNING.md`).
- Launch it on a profile that has onboarding completed and check the
  what's-new window shows up (or correctly doesn't) for this release.

## Checklist

```
[ ] main green; swift build + swift test pass locally (UI tests if relevant)
[ ] chore/release-X.Y.Z: Info.plist (version + build), CHANGELOG cut,
    README, what's-new entry, PROGRESS.md; PR merged
[ ] build_app.sh used "OmniVoice Dev Signing"; build_dmg.sh produced X.Y.Z
[ ] DMG smoke-tested
[ ] tag vX.Y.Z pushed; GitHub Release created with the DMG
[ ] homebrew-tap cask bumped and pushed
[ ] README link, brew upgrade and what's-new verified
```
