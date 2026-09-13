# State, locks and concurrency

Accepted findings in pgbus (semaphores, leases, batches), dash (deploy locks, connections), importmap-plus (concurrent downloads).

- **Two processes, same resource.** For every file, row, lock or cache the diff touches, ask what happens when two runs do it at once. A shared temp name, a read-modify-write without a lock, a check-then-act on a row.
- **Release semantics are explicit.** When a lock or semaphore is released, say whether the row is deleted, zeroed, or marked expired, and make the reaper agree. A zeroed row that still renders "live" is a finding.
- **Time ceilings on unbounded waits.** A lock with no expiry, a lease shorter than the delay it covers, a heartbeat that can extend forever.
- **Caches are invalidated where the data changes**, not where it is read. A long-lived cache of a schema, a queue list or a lock table needs a reset path and a test that exercises it.
- **Transactions own one thing.** A backfill inside the caller's transaction, a savepoint cached across connections, a connection used from two threads: each has produced a finding. Keep PG connections single-owner.
- **Idempotent retries.** A retried operation must not double-count, double-delete or re-acquire what it already holds; check the retry path against the first-attempt path.
- **Ambiguity holds, it does not release.** When the system cannot tell whether an action completed (a send that timed out, an archive that may have happened), keep the hold and re-check, never assume success.
