# machine

Care for the machine agents run on. Agent sessions leave processes behind — an orphaned script at a
full core for days, wait loops polling for a state that already passed, test runners in a removed
worktree, `claude` processes with no terminal — and several sessions' suites compete with the desktop.
This plugin finds them, kills the safest ones, and keeps test runs at background priority.

```bash
claude plugin install machine@zoolutions --scope user
```

Enabled per machine: keep the `"machine@zoolutions": true` that `install --scope user` writes to
`~/.claude/settings.json`, so `/machine:reap` is there in every repository.

| Skill | For |
|---|---|
| `/machine:reap [--kill]` | Report what was left behind, explain each group, reap the auto classes, kill a report-only class only on confirmation; `govern` running suites |

The script, `skills/reap/machine.rb` (stdlib Ruby ≥ 2.6, so macOS's `/usr/bin/ruby` will do). Every
scheduled or hooked call passes `--disable-gems`: the script needs no gem, and without the flag a
`GEM_HOME` left by a version manager can make `/usr/bin/ruby` load a newer Ruby's `json` gem and fail
to parse it:

| Command | Does |
|---|---|
| `report [--json] [--older-than AGE]` | One line per finding: class, pid, age, working directory, command |
| `reap (--auto \| --kill CLASS...) [--dry-run]` | SIGTERM to the process group, SIGKILL after 5 s; prints what it killed. `--auto`: `orphan` and `stale-wait` only |
| `govern [--dry-run]` | Running test processes to background QoS (`taskpolicy -b`; Linux `renice 10` + `ionice -c3`), once per process; an exempt run stays at normal QoS |
| `status` | One line for a SessionStart hook when there is something, nothing otherwise; exit 0, well under 300 ms |

Classes and their rules: [`skills/reap/SKILL.md`](skills/reap/SKILL.md). Never touched: the calling
process's ancestors, PID 1's system daemons, anything another user owns.

## Configuration

`~/.config/machine/config.json` (or `$XDG_CONFIG_HOME/machine/config.json`) replaces the patterns
`govern` demotes:

```json
{ "govern_patterns": ["rspec", "bin/rails test", "pytest", "jest", "vitest", "playwright", "chrome-headless-shell", "go test", "cargo test", "mix test"] }
```

A pattern matches a process that runs it (`rspec`, `bundle exec rspec`, `python -m pytest`), not one
that names it in an argument (`tail -f log/rspec.log`). `govern` remembers what it demoted in `~/.cache/machine/governed.json` (pid and start time; a reused
pid is demoted again). A suite that runs too slowly in the background to pass its own timeouts goes
back with `taskpolicy -B -p <pid>`, or leave its pattern out of the config.

### Keeping one run at normal QoS

A timing-sensitive run (a benchmark that measures short sleeps: background QoS coalesces timers, so
`sleep(0.006)` can take 200 ms) opts out without narrowing `govern_patterns` for every other run, in
either of two ways:

- `govern_exempt` in the same `config.json`: patterns matched by the same rule, word for word right
  after the runner, so `"rspec --tag bench"` matches `bundle exec rspec --tag bench` but neither
  `bundle exec rspec spec/x --tag bench` (the words are not next to the runner) nor, for `"bench"`,
  `rspec spec/bench`. Default `[]`. It is race-free: it holds from the first `govern` that sees the
  process.

  ```json
  { "govern_exempt": ["rspec --tag bench"] }
  ```

- The word `--machine-normal-qos` anywhere on the process's command line, with no config. A runner
  that rejects an unknown argument (`rspec`, `pytest`) can carry it in its process title instead,
  set as early as the process can: Ruby `Process.setproctitle("#{$0} --machine-normal-qos")`,
  Python's `setproctitle` package. `govern` reads the title `ps` shows. A scheduled `govern` that
  runs before the title is set (during boot) has already demoted the process, so a run that sets
  its title late either uses `govern_exempt` or restores itself before measuring: on macOS
  `taskpolicy -B -p <its own pid>` (Ruby `system("taskpolicy", "-B", "-p", Process.pid.to_s)`).
  `setpriority(PRIO_DARWIN_PROCESS, 0, 0)` does not undo the `taskpolicy -b -p` that `govern` runs.

`govern --dry-run` prints `exempt <pid> <command>` for each. An exemption is per process: a browser
the run starts is still demoted when it matches a pattern itself, unless it is exempt too. It does
not undo an earlier demotion, and `--dry-run` still prints `exempt` for a process demoted before it
became exempt: on macOS it goes back with `taskpolicy -B -p <pid>`; on Linux lowering the nice value
again needs root (`sudo renice -n 0 -p <pid>`); `ionice -c2 -p <pid>` returns its I/O class.

## Wiring a machine

The plugin ships no hooks and no schedule. The machine's own setup installs these, calling the script
at the marketplace clone's stable path — never the `cache/<hash>` path, which changes on every update:

```
~/.claude/plugins/marketplaces/zoolutions/plugins/machine/skills/reap/machine.rb
```

Each job is one `exec` of the script, no shell in front of it, and the script names its process
`machine govern` / `machine reap` in `ps`, so a schedule is told from a leftover at a glance.
`reap --auto --notify` sends the desktop notification itself (`osascript` on macOS, `notify-send` on
Linux, silent without either) when it killed something or something is left to review.

### SessionStart line

`~/.claude/settings.json` (merge into an existing `hooks` block):

```json
{
  "hooks": {
    "SessionStart": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "line=$(ruby --disable-gems ~/.claude/plugins/marketplaces/zoolutions/plugins/machine/skills/reap/machine.rb status 2>/dev/null); [ -z \"$line\" ] || printf '{\"systemMessage\":\"%s\"}\\n' \"$line\"",
            "timeout": 5
          }
        ]
      }
    ]
  }
}
```

### macOS: launchd

`~/Library/LaunchAgents/world.zoolutions.machine.govern.plist`, every 60 s. launchd expands neither
`$HOME` nor `~` in `ProgramArguments`: write the home directory out (`YOU` below is your user name).

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>world.zoolutions.machine.govern</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/bin/ruby</string><string>--disable-gems</string>
    <string>/Users/YOU/.claude/plugins/marketplaces/zoolutions/plugins/machine/skills/reap/machine.rb</string>
    <string>govern</string>
  </array>
  <key>StartInterval</key><integer>60</integer>
  <key>ProcessType</key><string>Background</string>
  <key>StandardErrorPath</key><string>/tmp/machine-govern.log</string>
</dict>
</plist>
```

`~/Library/LaunchAgents/world.zoolutions.machine.reap.plist`, every 30 min, with a notification when
it killed something or something is left to review:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>world.zoolutions.machine.reap</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/bin/ruby</string><string>--disable-gems</string>
    <string>/Users/YOU/.claude/plugins/marketplaces/zoolutions/plugins/machine/skills/reap/machine.rb</string>
    <string>reap</string><string>--auto</string><string>--notify</string>
  </array>
  <key>StartInterval</key><integer>1800</integer>
  <key>ProcessType</key><string>Background</string>
  <key>StandardErrorPath</key><string>/tmp/machine-reap.log</string>
</dict>
</plist>
```

Load each with `launchctl bootstrap gui/$(id -u) <plist>`; `launchctl bootout gui/$(id -u) <plist>`
removes it.

### Linux: systemd user timers

`~/.config/systemd/user/machine-govern.service` and `.timer`:

```ini
[Unit]
Description=machine: test processes to background priority

[Service]
Type=oneshot
ExecStart=/usr/bin/env ruby --disable-gems %h/.claude/plugins/marketplaces/zoolutions/plugins/machine/skills/reap/machine.rb govern
```

```ini
[Timer]
OnBootSec=60
OnUnitActiveSec=60
AccuracySec=5

[Install]
WantedBy=timers.target
```

`~/.config/systemd/user/machine-reap.service` and `.timer`:

```ini
[Unit]
Description=machine: reap leftover agent processes

[Service]
Type=oneshot
ExecStart=/usr/bin/env ruby --disable-gems %h/.claude/plugins/marketplaces/zoolutions/plugins/machine/skills/reap/machine.rb reap --auto --notify
```

```ini
[Timer]
OnBootSec=5min
OnUnitActiveSec=30min

[Install]
WantedBy=timers.target
```

`%h` is systemd's home directory.
`systemctl --user daemon-reload && systemctl --user enable --now machine-govern.timer machine-reap.timer`.
