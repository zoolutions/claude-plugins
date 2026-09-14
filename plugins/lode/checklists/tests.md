# Tests

Accepted findings in several repositories.

- **A new test must fail without the change.** Apply only the test hunks to the base and run them; a green result means the test cannot fail. The gate's test agent does this mechanically; do it yourself before that.
- **Assert every half of the outcome.** Two pins moved, two rows updated, a message *and* an exit status, both sides of a provider split. A test that checks one side stays green when the other silently fails.
- **Pin exact versions in live tests.** `md5@2.2.0`, never `md5`; a CDN publishing a release must not change expected output.
- **No `retry`, `sleep` or loosened assertion to make a test pass.** A flaky test is a bug with a root cause; find it.
- **Stub at the boundary the code owns.** Stub `Net::HTTP.get_response` or the client method, not the class under test's own private methods.
- **Test fakes mirror production conversions.** A fake `dom_id`, a fake clock, a fake stream helper must produce the same keys production produces, or the test proves nothing about coalescing, ordering or identity.
- **Fixtures fork; they do not mutate.** A test needing a different shape of an existing fixture adds a new fixture named for the shape.
- **Isolation.** Anything that writes takes a path inside a `Dir.mktmpdir`; anything that sets a class-level accessor restores it in `ensure`.
