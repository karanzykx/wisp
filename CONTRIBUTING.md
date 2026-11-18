# Contributing to Wisp

Thanks for helping. Wisp deletes files, so the bar for changes that affect *what can be deleted* is deliberately high.
Everything else is welcome and easy.

## How contributions work

Everyone is welcome to suggest and contribute. The ground rules:

- **Suggestions** go in [Discussions](https://github.com/karanzykx/wisp/discussions) or a feature-request issue. Nothing is too small.
- **Code** comes in as a pull request from your fork. **Only the maintainer ([@karanzykx](https://github.com/karanzykx)) merges.**
  `main` is protected: changes need passing CI and the maintainer's review, and nobody else has write access.
- **Review is stricter for anything that changes what can be deleted.** Expect questions about how the data is rebuilt, and a
  request for tests (see below). A pull request can be declined or reworked; that is about keeping users' files safe,
  not about the contributor.
- **First-time contributors:** GitHub asks the maintainer to approve the first CI run on your pull request.
- **Credit:** contributors are thanked in the changelog entry for their change.
- **Licence:** by contributing you agree that your contribution is released under the project's [MIT licence](LICENSE).
- **Conduct:** see the [Code of Conduct](CODE_OF_CONDUCT.md).

### Versions and the changelog

Wisp follows [Semantic Versioning](https://semver.org/). Versions below 1.0.0 are previews; **1.0.0** means a notarised app and
stable safety rules. Planned versions are listed in the README roadmap and as GitHub milestones.

Every pull request with a user-visible change adds one line under **Unreleased** in [`CHANGELOG.md`](CHANGELOG.md)
(Added / Changed / Fixed / Security). The maintainer moves those lines under a version heading when cutting a release.

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

## Adding a tool

Most new tools are a single line in `TOOL_CACHES` in `engine/wisp.sh`: `<category>|<folder relative to home>`.

- Use `toolcaches` when the tool rebuilds the folder by itself the next time it runs, and `toolpackages` when a project
  needs an install or restore step again.
- The folder must be an exact download or cache folder, at least two levels deep, never a tool's settings, environments or
  installed SDKs.
- You do not need to write test code. `--self-test` and `tests/e2e.sh` check every entry. In the pull request, say how the
  data is rebuilt and link the tool's documentation for that folder.

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

1. Bump `VERSION` in `engine/wisp.sh`, move the **Unreleased** entries in `CHANGELOG.md` under a new `## [x.y.z] - date`
   heading, and update the compare links at the bottom of the changelog. Releases below 1.0.0 are labelled *preview*
   automatically.
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
