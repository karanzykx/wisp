# Changelog

All notable changes to Wisp are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/).

**Versioning:** versions below 1.0.0 are *preview* releases. They are tested and usable, but behaviour can still change between
minor versions (0.1 → 0.2 → 0.3). **1.0.0** will mean a notarised app and a stable set of safety rules. What is planned next is
tracked in the [milestones](https://github.com/karanzykx/wisp/milestones) and the roadmap in the README.

Every pull request that changes behaviour adds a line under **Unreleased**; the maintainer moves them under a version heading when
cutting a release.

## [Unreleased]

Nothing yet.

## [0.1.0] - 2026-11-18

**First public preview.** The cleaner, the app and the safety checks are complete enough to use daily; the next versions add
more categories and automation (see the roadmap).

### Added
- **Wisp.app**: a native window (SwiftUI, universal binary for Apple Silicon and Intel, macOS 11+) that scans first,
  shows every category with its size and risk, lets you expand and untick anything, and only then cleans.
- **Large Files** tab: files over 250 MB found through Spotlight, with *Show in Finder* and *Move to Trash*
  (recoverable). App data is shown but never offered for removal.
- **History** tab and a **Settings** tab with a never-clean list, tunable log and project age rules,
  extra project folders, and a one-click safety check.
- **`wisp` engine** (`engine/wisp.sh`, bash 3.2 compatible): browser, app, editor and Xcode caches, old logs,
  package-manager caches (npm, Yarn, Bun, pip, uv, Poetry, Composer, Ivy), Gradle and Cargo stores, Homebrew,
  Docker leftovers, old `node_modules` / `vendor` / `target` folders, and the Trash.
- Safety model: an allowlist guard on every deletion, browser profiles (logins, passkeys, saved passwords)
  refused outright, in-use files and running apps skipped, symlinks never followed, one clean at a time,
  and a real `--dry-run`.
- `--self-test` command, a ShellCheck-clean engine, and an end-to-end test suite that runs the real engine against
  a throwaway home folder.
- Direct DMG download (with SHA-256) and a Homebrew tap: `brew install --cask karanzykx/tap/wisp`.
- A registry of developer tool caches (`TOOL_CACHES` in the engine) and two categories built on it: **Developer tool caches**
  (safe, on by default) and **Language package downloads** (off by default, marked Reinstall because projects need an
  install or restore step again). It starts with Dart/Flutter and Conda/Mamba packages, thanks to @P1LOTRX, plus NuGet, Hex,
  Cabal, the Terraform plugin cache, minikube, rustup, pre-commit, Zig, mise, kubectl and the Android SDK manager.
  Supporting another tool is one line, and the tests check every entry automatically.
- `wisp --list-targets` prints every folder in the registry.

### Known limitations
- The app is not notarised by Apple, so macOS asks for one extra approval on first launch; see the README.
- Automated tests run on macOS 15 (Apple Silicon). Intel Macs and macOS 11 to 14 are supported by the build but not
  covered by CI.

[Unreleased]: https://github.com/karanzykx/wisp/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/karanzykx/wisp/releases/tag/v0.1.0
