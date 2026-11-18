# Contributing to Wisp

Thanks for helping. Wisp deletes files, so the bar for changes that affect *what can be deleted* is deliberately high.
Everything else is welcome and easy.

## Setup

You need a Mac with the Xcode Command Line Tools (`xcode-select --install`) and, for linting,
[ShellCheck](https://www.shellcheck.net) (`brew install shellcheck`).

```bash
git clone https://github.com/karanzykx/wisp.git && cd wisp
engine/wisp.sh --dry-run        # try the engine safely
scripts/build.sh                # build dist/Wisp.app and dist/Wisp.dmg
open dist/Wisp.app
```

## Before you open a pull request

```bash
shellcheck -s bash engine/wisp.sh scripts/build.sh tests/e2e.sh   # must print nothing
engine/wisp.sh --self-test                                         # must end with "All self-tests passed."
tests/e2e.sh                                                       # must end with "0 failed"
scripts/build.sh                                                   # must produce a universal Wisp.dmg
```

CI runs the same four steps on every pull request.

## Rules for changes that touch deletion

1. **Everything deleted goes through `nuke`, `prune_old` or `run_cmd`.** Never call `rm` directly elsewhere.
2. **Widen the guard only with a test.** If you add an allowlisted path or deny pattern in `guard_path`, add matching
   *refuse* and *allow* cases to `--self-test` and a survives/removed case to `tests/e2e.sh`.
3. **Prefer exact names over patterns.** Allow `~/.npm/_cacache`, not `~/.npm/*`.
4. **Never delete user data.** If a folder can contain anything you cannot regenerate with one command, it does not belong in
   a default category. It can be offered with the risk `review` / `reinstall` / `permanent`, off by default, with a
   confirmation.
5. **Stay bash 3.2 compatible.** macOS still ships bash 3.2: no associative arrays, no `mapfile`, no `${var,,}`.

## Adding a category

1. In `engine/wisp.sh`, add a section: call `step "Name"`, `cat_begin <id> "<title>" <risk> <sf-symbol> "<description>"`,
   `add` each candidate path, then `offer "Prompt?" <y|n>`. Commands (not file lists) use `emit_cat -1 <y|n>`,
   `confirm`, `run_cmd`, then `emit CATDONE`.
2. Add the id to the `--only` help text and to the category table in `docs/HOW_IT_WORKS.md` and the README.
3. Add the allowed paths to `ALLOWED_ROOTS` / `guard_path` and tests (see above).
4. Add an icon name that exists in SF Symbols 2 (macOS 11).

## Style

- Shell: 2-space indent, `local` for function variables, quote every expansion, `[[ ]]` over `[ ]`.
- Swift: SwiftUI, no third-party dependencies, deployment target macOS 11 (check APIs with `@available`).
- Commit messages: imperative mood, short subject, explain *why* in the body when it is not obvious.

## Releasing (maintainers)

1. Bump `VERSION` in `engine/wisp.sh` and add a `## [x.y.z] - date` section to `CHANGELOG.md`.
2. Commit, then tag and push: `git tag vX.Y.Z && git push origin main vX.Y.Z`.
3. The **Release** workflow checks the tag matches the engine version, runs the tests, builds the DMG, and publishes it
   with its SHA-256 to GitHub Releases.
4. Update `version` and `sha256` in `Casks/wisp.rb` of the
   [homebrew-tap](https://github.com/karanzykx/homebrew-tap) repository.

### Notarised builds

Release builds are ad-hoc signed. With an Apple Developer ID certificate you can sign locally with
`WISP_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" scripts/build.sh`, then notarise with
`xcrun notarytool submit dist/Wisp.dmg --keychain-profile <profile> --wait` and `xcrun stapler staple dist/Wisp.dmg`.

## Reporting bugs

Use the issue templates. For anything where Wisp deleted or offered something it should not have, please use the private
[security advisory](https://github.com/karanzykx/wisp/security/advisories/new) form instead.
