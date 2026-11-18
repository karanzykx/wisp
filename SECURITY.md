# Security Policy

## Supported versions

Only the latest release receives fixes.

## Reporting a vulnerability

Wisp deletes files, so a bug can mean data loss. Please report these **privately**:

- Wisp offered or removed something outside caches, logs or rebuildable build output (documents, logins, passkeys,
  browser profiles, keychains, credentials, databases).
- A way to make the guard (`guard_path` / `dep_ok`) accept a path it should refuse, for example through symlinks, `..`
  segments, odd file names or race conditions.
- Anything that causes the app or engine to run code you did not ask for.

Use GitHub's private reporting: **[Report a vulnerability](https://github.com/karanzykx/wisp/security/advisories/new)**.
Please include your macOS version, Wisp version (`wisp --version`), what you ran, and the log from `~/Library/Logs/Wisp/`
with personal paths removed.

You can expect an acknowledgement within a few days. Fixes ship as a new release with credit in the changelog unless you
prefer to stay anonymous.

Ordinary bugs and feature requests belong in the public issue tracker.
