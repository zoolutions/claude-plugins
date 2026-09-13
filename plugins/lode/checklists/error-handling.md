# Error handling and silent skips

Accepted findings in importmap-plus (registry errors), dash (hadolint, docker inspect), pgbus (lock release, batch completion).

- **Record the error on the item and continue, or abort the whole run.** Pick one per operation and say which. `outdated` records a registry failure per package and reports it; `audit` aborts. Neither silently drops the package.
- **Blank is not malformed.** Empty tool output means "no findings"; unparseable output is its own error with its own message, not the "could not run" path.
- **Let unreadable state raise.** A readiness loop that catches an inspect failure and reports "timed out" hides the real error. Catch only what you expected.
- **Validate config at load, including sign and type.** A negative count, a non-hash where a hash is expected, a value outside the documented set: reject with a configuration error rather than letting a typo disable a feature.
- **No `rescue StandardError => nil` around a network call.** Retries live in one shared helper; after the retries, the error is the correct outcome.
- **Ensure blocks release what was acquired**: locks, semaphores, connections, remote temp files, worktrees. Check every early return.
- **A partial success reports as partial.** A command that moved one of two pins, deployed one of two hosts, or published one of two reports says so and exits non-zero unless the user asked for best-effort.
