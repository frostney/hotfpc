# Releasing

> **Audience: contributors.** How a hotfpc release is made.

A release is a version tag. The release workflow builds the archives from it, checks their
version against the tag and publishes them with the changelog's section as the notes.

## Versions

Versions are `MAJOR.MINOR.PATCH`, and tags have no prefix: `1.1.0`. The version lives in
`HotFPCVersion` in `source/HotFPC.pas`, and a unit test checks it, so the two change
together.

## Changelog

`CHANGELOG.md` is written by hand, for people who use hotfpc: what each release changes in
what they see. Changes go under `## Unreleased` as they are made. The release workflow takes
the notes from the section named after the tag and fails without one.

## Cutting a release

1. In one pull request, rename `## Unreleased` to `## <version>` in `CHANGELOG.md`, and set
   `HotFPCVersion` and the version the unit test expects in `source/HotFPC.pas`
   (`chore(release): <version>`).
2. Once it is merged, tag the merge commit and push the tag:

   ```sh
   git tag <version>
   git push origin <version>
   ```

3. `.github/workflows/release.yml` builds `hotfpc` with fpc 3.2.2 and release settings
   (`./build.sh clean hotfpc --production`, `build.bat` on Windows) on GitHub's runners for
   `linux-x64`, `linux-arm64`, `macos-arm64` and `windows-x64`. It checks that
   `hotfpc --version` prints `hotfpc <tag>`, packs each binary with `README.md` and
   `LICENSE` into `hotfpc-<version>-<system>.tar.gz` (`.zip` for Windows), writes
   `hotfpc-<version>-checksums.txt` with their SHA-256 sums, and creates the GitHub release.
4. Once the release is published, set its version in the download commands of the
   [quick start](../guides/quick-start.md#install-hotfpc) with a pull request: the archive
   names and the source download carry it.

## Homebrew

The formula `hotfpc` in [frostney/homebrew-tap](https://github.com/frostney/homebrew-tap)
installs the release binary. After a release, update `Formula/hotfpc.rb` there with a pull
request: each archive's URL and its SHA-256 from the checksum file. The formula has
archives for macOS on Apple silicon and Linux on x86-64; the `linux-arm64` archive needs a
block of its own in it before Homebrew installs hotfpc on Linux arm64.
