---
name: reap
description: Find the processes agent sessions left behind on this machine — orphaned scripts in a scratchpad or worktree, Claude wait loops polling for a condition that can no longer come true, test runners and dev servers in a removed worktree, claude processes with no terminal, sessions idle for days — explain each, and kill what the user confirms. Also demotes running test suites to background priority. Use when the machine is slow or hot, load is high, the SessionStart line says `/machine:reap`, or before a long unattended run.
argument-hint: "[--kill]"
allowed-tools: Bash(*), Read
---

# /machine:reap — $ARGUMENTS

`machine.rb` beside this file (stdlib only, any Ruby ≥ 2.6) reads `ps` and, for the few processes
whose class depends on it, their working directory (`lsof` on macOS, `/proc` on Linux). It never
touches this session's own ancestors, PID 1's system daemons, or anything another user owns.

## Run it

`ruby <this skill's base directory>/machine.rb <command>`:

| Command | Does |
|---|---|
| `report [--json] [--older-than AGE]` | One line per finding: class, pid, age, working directory, command |
| `reap --auto [--dry-run]` | Kills the auto classes only (`orphan`, `stale-wait`) |
| `reap --auto --notify` | The same, then a desktop notification (`osascript` on macOS, `notify-send` on Linux) when it killed something or something is left: the scheduled job's form |
| `reap --kill <class>… [--dry-run]` | Kills the named classes |
| `govern [--dry-run]` | Moves running test processes to background QoS, once each |
| `status` | One line when there is something (`load 28/12 · 2 auto-reapable, 3 to review · /machine:reap`), nothing otherwise; always exits 0 |

A kill is SIGTERM to the process group (only when every process in the group is a target or a
target's child; otherwise the pid alone), then SIGKILL after 5 s for survivors. `AGE` is seconds or
`30m`, `6h`, `2d`; `--older-than` replaces every class's age threshold, so `--older-than 0` also
selects a live session's wait loop that started a minute ago. Never pair it with a real `reap`.

## The classes

| Class | Rule | Auto |
|---|---|---|
| `orphan` | parent is PID 1 (or a Linux session's `systemd --user`), older than 1 h, working directory in a Claude scratchpad (`/tmp/claude-<uid>/` or `$TMPDIR/claude-<uid>/`) or an agent worktree (`/.claude/worktrees/`); never a session manager, agent or data store (tmux, screen, ssh-agent, redis-server, postgres, …) | yes |
| `stale-wait` | a Claude Bash wrapper (`shell-snapshots/snapshot-`) whose command runs `until `, `while ` or `sleep `, older than 6 h | yes |
| `gone-worktree` | a test runner, browser or dev server whose working directory no longer exists | report |
| `headless-claude` | a `claude` CLI with no terminal, older than 1 h, not under a live app or IDE | report |
| `idle-session` | a `claude` CLI with a terminal, older than 2 days — age only, it may be in use | report |

A runner is a process that runs the pattern (`rspec`, `bundle exec rspec`, `python -m pytest`,
`node …/.bin/jest`), never one that merely names it in an argument (`tail -f log/rspec.log`,
`claude -p "fix the rspec failures"`).

## The pass

1. `report`. Nothing → say so and stop.
2. Explain each group in a line: what it is, why it is (or is not) safe to kill — an orphan's script
   has no session left to read its output; a stale wait polls for a state that has already passed;
   an `idle-session` is judged by age alone and may be a session in use or one the user means to come back to, a `headless-claude` may be a
   scheduled or remote-control run.
3. `reap --auto --dry-run`, then `reap --auto`: the auto classes need no confirmation.
4. A report-only class is killed only after the user confirms it, group by group or pid by pid
   (`--kill <class>`; one pid: `kill -TERM <pid>`). Without `--kill` in the arguments, list them and
   stop. Never kill a process this skill did not classify.
5. `govern --dry-run` when a suite is running; `govern` demotes it (`taskpolicy -b` on macOS,
   `renice 10` + `ionice -c3` on Linux). A demoted suite that trips its own timeouts is put back with
   `taskpolicy -B -p <pid>` (macOS) or `renice -n 0 -p <pid>`.

The schedule (`govern` every 60 s, `reap --auto --notify` every 30 min) and the SessionStart `status`
line are wired per machine, not by this plugin: see the plugin's README. Every run is named
`machine <command>` in `ps`.
