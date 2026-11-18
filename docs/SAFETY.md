# Safety

Wisp deletes files, so this page states exactly what it will and will not do, how that is enforced in code, and how you
can check it yourself. If anything here is not true of the code, that is a bug: please
[report it](../SECURITY.md).

## The rule

> Only data that can be rebuilt automatically is ever removed, and every removal passes a guard that refuses
> everything else.

## What is never touched

| Area | Examples | How it is enforced |
|---|---|---|
| Your files | Documents, Desktop, Downloads, Pictures, Movies, iCloud Drive | Not inside any allowlisted root, so the guard refuses them |
| Logins and passkeys | Keychains, browser `Cookies`, `Login Data`, `Web Data`, `Local Storage`, `Session Storage`, `IndexedDB`, `WebAuthn`, `Passwords` | Explicit deny patterns that apply wherever the path is |
| Browser profiles | Chrome, Edge, Brave, Firefox, Arc, Opera, Vivaldi, Chromium and any `…/Default/…` or `…/Profile N/…` folder in Application Support | Explicit deny patterns; only the web cache under `~/Library/Caches` can be cleaned |
| App data | Everything in Application Support except exact cache folder names (`Cache`, `Code Cache`, `GPUCache`, `CachedData`, `Dawn*Cache`, `ShaderCache`, `logs`) | Name allowlist |
| Sandboxed app data | `~/Library/Containers`, `~/Library/Group Containers` | Explicit deny |
| System caches | `com.apple.*` caches (except Xcode's `com.apple.dt.*`) | Explicit deny |
| Backups and history | iPhone backups, Xcode Archives, JetBrains Local History, Time Machine | Not allowlisted / explicit deny |
| Databases and environments | Docker volumes and containers, Python virtualenvs, Poetry environments | Not touched / explicit deny |
| Credentials | `~/.ssh`, `~/.composer/auth.json`, `~/.gradle/gradle.properties`, `~/.cargo/registry/index` | Only exact cache sub-folders of each dot-directory are allowed |

## How a deletion is decided

Every removal, without exception, goes through one of three functions (`nuke`, `prune_old`, `run_cmd`).
`nuke` and `prune_old` call `guard_path`, which returns *refuse* unless **all** of these hold:

1. The path is absolute and normalised (no `..`, `//` or newlines). `nuke` additionally refuses symbolic links, and the
   scanner never queues them, so a link planted inside a cache folder cannot redirect a delete elsewhere.
2. It is not on your **never-touch list** (`~/.config/wisp/keep.txt`).
3. It sits strictly *inside* an allowlisted cache or log root (the root itself can never be removed).
4. It does not match a deny pattern for logins, passkeys, profiles, containers or system caches.
5. If it lives in Application Support or a dot-directory, its name is one of the exact cache folder names.

The only path that bypasses the root allowlist is a **project dependency folder**, and it must satisfy a separate, stricter
rule (`dep_ok`): it is named `node_modules`, `vendor` or `target`; it sits directly next to its manifest **and** lockfile
(`package.json` + a lockfile, `composer.json` + `composer.lock`, or `pom.xml`) so one install command restores it; it
is inside your home but outside `Library` and dot-folders; it is not a symlink; and its project has had no changes for
90+ days (configurable). Only the dependency folder is removed, never the project.

## Other protections

- **Running apps are skipped.** Before cleaning, Wisp records every file open by your processes (`lsof`) and every running
  app. A cache that belongs to either is left alone and listed as skipped.
- **One clean at a time.** A lock prevents two runs overlapping.
- **A real dry run.** `--dry-run` turns all three deletion functions into no-ops.
- **No surprise privileges.** `sudo` is only used when you pass `--system` or `--maintenance` on the command line.
- **Scanning stays in the places it needs.** Cleaning looks only at cache, log and build-output locations, and the
  dependency finder only at your project folders, never Desktop, Documents or Downloads. The app therefore does not trigger
  macOS folder-permission prompts. Two read-only exceptions: **Large Files** uses Spotlight's index and can list big files
  anywhere you have access (it only ever offers *Move to Trash*, after you confirm), and the interactive command line
  looks in `~/Downloads` for old `.dmg`/`.pkg` installers and moves them to the Trash only if you say yes.
- **Honest limits.** Items that cannot be undone (the Trash) or that cost time to rebuild (dependency folders, Gradle and
  Cargo stores) are off by default and ask for confirmation in the app.
- **The app never deletes anything itself.** `Wisp.app` only runs the bundled engine, first as a preview, then for
  exactly the categories you ticked.

## Verify it yourself

```bash
wisp --self-test      # or: engine/wisp.sh --self-test
```

runs the guard against 50+ dangerous paths (your home folder, Documents, `.ssh`, keychains, browser cookies and
profiles…) that it must refuse, then checks that real deletion, in-use detection, symlink handling, log pruning,
dependency rules and category selection behave. The same check is available in the app under
**Settings → Safety check**.

`tests/e2e.sh` goes further: it runs the real engine against a temporary home folder that contains fake caches, a fake
browser profile, personal documents and projects, and asserts which files were removed and which survived.

Both run in CI on every commit. The script is plain bash: read `guard_path` and `dep_ok` in
[`engine/wisp.sh`](../engine/wisp.sh) to audit the rules yourself.

## Reporting a problem

If Wisp ever offers or removes something it should not, please open a
[security advisory](https://github.com/karanzykx/wisp/security/advisories/new) (private) rather than a public issue.
