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

The script, `skills/reap/machine.rb` (stdlib Ruby ≥ 2.6, so macOS's `/usr/bin/ruby` will do):

| Command | Does |
|---|---|
| `report [--json] [--older-than AGE]` | One line per finding: class, pid, age, working directory, command |
| `reap (--auto \| --kill CLASS...) [--dry-run]` | SIGTERM to the process group, SIGKILL after 5 s; prints what it killed. `--auto`: `orphan` and `stale-wait` only |
| `govern [--dry-run]` | Running test processes to background QoS (`taskpolicy -b`; Linux `renice 10` + `ionice -c3`), once per process |
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

## Wiring a machine

The plugin ships no hooks and no schedule. The machine's own setup installs these, calling the script
at the marketplace clone's stable path — never the `cache/<hash>` path, which changes on every update:

```
~/.claude/plugins/marketplaces/zoolutions/plugins/machine/skills/reap/machine.rb
```

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

`~/Library/LaunchAgents/world.zoolutions.machine.govern.plist`, every 60 s:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>world.zoolutions.machine.govern</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/sh</string><string>-c</string>
    <string>exec /usr/bin/ruby "$HOME/.claude/plugins/marketplaces/zoolutions/plugins/machine/skills/reap/machine.rb" govern</string>
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
    <string>/bin/sh</string><string>-c</string>
    <string>m="$HOME/.claude/plugins/marketplaces/zoolutions/plugins/machine/skills/reap/machine.rb"; killed=$(/usr/bin/ruby "$m" reap --auto | grep -c '^killed'); left=$(/usr/bin/ruby "$m" status); [ "$killed" -gt 0 ] || [ -n "$left" ] || exit 0; /usr/bin/osascript -e "display notification \"killed $killed · ${left:-nothing left}\" with title \"machine:reap\""</string>
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
ExecStart=/bin/sh -c 'exec ruby %h/.claude/plugins/marketplaces/zoolutions/plugins/machine/skills/reap/machine.rb govern'
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
ExecStart=/bin/sh -c 'm=%h/.claude/plugins/marketplaces/zoolutions/plugins/machine/skills/reap/machine.rb; killed=$$(ruby $$m reap --auto | grep -c "^killed"); left=$$(ruby $$m status); [ "$$killed" -gt 0 ] || [ -n "$$left" ] || exit 0; notify-send machine:reap "killed $$killed · $${left:-nothing left}"'
```

```ini
[Timer]
OnBootSec=5min
OnUnitActiveSec=30min

[Install]
WantedBy=timers.target
```

`%h` is systemd's home directory and `$$` a literal `$` for the shell.
`systemctl --user daemon-reload && systemctl --user enable --now machine-govern.timer machine-reap.timer`.
