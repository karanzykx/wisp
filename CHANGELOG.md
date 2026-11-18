# Changelog

All notable changes to Wisp are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/).

## [1.0.0] - 2026-11-18

First public release.

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

### Known limitations
- The app is ad-hoc signed, not notarised (no Apple Developer ID yet). macOS asks for one extra approval on first
  launch; see the README.
- Automated tests run on macOS 15 (Apple Silicon). Intel Macs and macOS 11–14 are supported by the build but not
  covered by CI.

[1.0.0]: https://github.com/karanzykx/wisp/releases/tag/v1.0.0
