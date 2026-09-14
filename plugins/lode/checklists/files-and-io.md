# Files, temp paths and atomic writes

Accepted findings in several repositories: vendored files, deploy reports, uploads, exports.

- **Write the final file last.** Download, transform and validate in a temp location; the destination is touched only by a single `rename` at the end. Deleting the old file before the new one is committed leaves the user with nothing when the write fails.
- **Temp names are per process.** A fixed `<target>.download` is shared by two concurrent runs; one renames while the other still writes. Include the pid or use `Tempfile`/`mkstemp` in the destination directory, so the rename is on one filesystem.
- **Clean up in `ensure`.** The partial file is removed on every exit path, including `Errno::ENOSPC` and `Interrupt`. The condition for removal is "the scratch file still exists", not a boolean set after the rename returned: rename consumes the source, so its absence is the durable signal that publish happened.
- **Never rename onto a name you did not claim.** `rename` replaces silently. Claim a name with an exclusive create (`O_EXCL`, hard link from a private temp file) and retry on `EEXIST`; fall back to rename only onto a placeholder this run created.
- **A directory in the way** is the one case rename cannot replace; handle it explicitly rather than deleting the target up front for every case.
- **Paths from the network go through one helper.** Package names, image names and user input never reach `File.join` directly; a single function builds the on-disk path and it is the only place that does.
- **Shell-outs take an argv array.** `Open3.capture3(exe, *args)`, never a string with interpolation. Names that reach the shell came from a registry or a user.
- **Remote cleanup on failure.** An archive or key uploaded to a remote host is removed in `ensure`, including when the transfer that needed it failed halfway.
