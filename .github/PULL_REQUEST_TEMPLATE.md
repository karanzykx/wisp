## What and why

<!-- What does this change, and why is it needed? -->

## Checklist

- [ ] `shellcheck -s bash engine/wisp.sh scripts/build.sh tests/e2e.sh` prints nothing
- [ ] `engine/wisp.sh --self-test` passes
- [ ] `tests/e2e.sh` passes
- [ ] If this changes what can be deleted: I added *refuse* / *allow* cases to `--self-test` and a survives/removed
      case to `tests/e2e.sh`, and updated `docs/SAFETY.md`
- [ ] User-visible change: added a line under **Unreleased** in `CHANGELOG.md`

Thanks for contributing. The maintainer reviews and merges every pull request.
