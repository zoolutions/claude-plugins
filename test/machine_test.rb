# frozen_string_literal: true

# ruby test/machine_test.rb — the machine:reap script against a fixed process
# table. No real process is read, signalled or demoted. Stdlib only, like the
# script.
require "minitest/autorun"
require "fileutils"
require "json"
require "stringio"
require "tmpdir"
require_relative "../plugins/machine/skills/reap/machine"

class MachineTest < Minitest::Test
  UID = 501
  SELF = 900
  SNAP = "/bin/zsh -c source /Users/me/.claude/shell-snapshots/snapshot-zsh-17-abc.sh 2>/dev/null || true && " \
         "setopt NO_EXTENDED_GLOB 2>/dev/null || true && eval '%s' < /dev/null && pwd -P >| /tmp/claude-1-cwd"
  SCRATCH = "/private/tmp/claude-501/-Users-me-repo/abc/scratchpad"
  WORKTREE = "/Users/me/repo/.claude/worktrees/follow-3"
  GONE = "/Users/me/repo/.claude/worktrees/removed"

  # pid ppid pgid uid etime tdev command — `ps -axww -o pid=,ppid=,pgid=,uid=,etime=,tdev=,command=` on macOS.
  PS = <<~PS
    1     0     1     0 12-00:58:29   ?? /sbin/launchd
    100   1   100   501 05-00:00:00   ?? /System/Library/CoreServices/Finder.app/Contents/MacOS/Finder
    101   1    50   501 05-00:00:00   ?? ruby busy_loop.rb
    60    1    50   501 05-00:00:00   ?? ruby unrelated_daemon.rb
    102   1   102   501       30:00   ?? ruby young.rb
    103   1   103   501    03:00:00   ?? puma 6.4 (tcp://0.0.0.0:3000)
    104   1   104   502 05-00:00:00   ?? ruby someone_elses.rb
    105   1   105   501    02:00:00   ?? node node_modules/.bin/vite
    106   1   106   501 05-00:00:00   ?? /opt/homebrew/bin/tmux new -s work
    200  46   200   501 01-00:00:00   ?? #{format(SNAP, 'until gh pr checks 5 | grep -q pass; do sleep 15; done')}
    201 200   200   501       00:05   ?? sleep 15
    202  46   202   501 01-00:00:00   ?? #{format(SNAP, 'bundle exec rspec spec/models')}
    203  46   203   501    02:00:00   ?? #{format(SNAP, 'while true; do sleep 60; done')}
    204 403   204   501 01-00:00:00   ?? #{format(SNAP, 'until curl -sf localhost:3000/up; do sleep 30; done')}
    300 202   202   501 01-00:00:00   ?? ruby bin/rspec spec/models
    400   1   400   501 02-00:00:00   ?? /Users/me/.local/bin/claude -p summarize
    410   1   410   501 02-00:00:00   ?? /Applications/Claude.app/Contents/MacOS/Claude
    401 410   401   501 02-00:00:00   ?? /Users/me/Library/Application Support/Claude/claude-code/2.1.0/claude --output-format stream-json
    402 700   402   501 03-00:00:00 16/3 /Users/me/.local/bin/claude --resume
    403 700   403   501 01-00:00:00 16/4 /Users/me/.local/bin/claude
    500 403   500   501    00:10:00   ?? /Users/me/.cache/ms-playwright/chromium_headless_shell-1/chrome-headless-shell --headless
    405 700   405   501    03:00:00 16/5 tail -f log/rspec.log
    406 600   406   501    03:00:00   ?? /Users/me/.local/bin/claude -p fix the rspec failures
    501   1   501   502    00:10:00   ?? python -m pytest
    600   1   600   501 03-00:00:00   ?? /Applications/Ghostty.app/Contents/MacOS/ghostty
    700 600   700   501 03-00:00:00 16/2 -/opt/homebrew/bin/fish
    800 700   800   501 03-00:00:00 16/2 /Users/me/.local/bin/claude --dangerously-skip-permissions
    899 800   899   501    07:00:00   ?? #{format(SNAP, 'until false; do sleep 15; done')}
    900 899   899   501       00:01   ?? ruby machine.rb report
  PS

  CWDS = {
    100 => SCRATCH, 101 => SCRATCH, 60 => "/", 102 => SCRATCH, 103 => "/Users/me/app", 104 => SCRATCH,
    105 => WORKTREE, 106 => WORKTREE, 300 => GONE, 405 => GONE, 406 => GONE, 400 => "/Users/me/app", 500 => "/Users/me/app", 501 => SCRATCH
  }.freeze

  NOW = Time.utc(2026, 10, 26, 12, 0, 0)

  def rows(text = PS)
    Machine.parse_ps(text)
  end

  def classifier(older_than: nil, text: PS)
    Machine::Classifier.new(rows(text), uid: UID, self_pid: SELF, older_than: older_than,
                                        dir_exists: ->(path) { path != GONE })
  end

  def findings(**opts)
    c = classifier(**opts)
    c.findings(CWDS.select { |pid, _| c.cwd_pids.include?(pid) })
  end

  def classes(found)
    found.map { |f| [f.row.pid, f.klass] }.sort
  end

  # --- reading the table ----------------------------------------------------

  def test_etime_reads_every_ps_shape
    assert_equal 5, Machine.parse_etime("00:05")
    assert_equal 1800, Machine.parse_etime("30:00")
    assert_equal 3 * 3600, Machine.parse_etime("03:00:00")
    assert_equal 2 * 86_400 + 3661, Machine.parse_etime("02-01:01:01")
  end

  def test_a_row_keeps_a_command_with_spaces_and_knows_whether_it_has_a_terminal
    row = rows.find { |r| r.pid == 401 }
    assert_equal 410, row.ppid
    assert_equal 2 * 86_400, row.age
    assert_match(/Application Support.*stream-json\z/, row.command)
    refute row.tty?
    assert rows.find { |r| r.pid == 402 }.tty?
  end

  def test_the_table_reads_ps_and_lsof_on_macos
    calls = []
    runner = lambda do |*argv|
      calls << argv
      argv.first == "ps" ? PS : "p101\nfcwd\nn#{SCRATCH}\np105\nfcwd\nn#{WORKTREE}\n"
    end
    table = Machine::ProcessTable.new(platform: :macos, runner: runner)
    assert_equal PS.lines.size, table.rows.size
    assert_equal({ 101 => SCRATCH, 105 => WORKTREE }, table.cwds([101, 105]))
    assert_equal ["ps", "-axww", "-o", "pid=,ppid=,pgid=,uid=,etime=,tdev=,command="], calls[0]
    assert_equal ["lsof", "-a", "-n", "-P", "-w", "-b", "-O", "-d", "cwd", "-Fpn", "-p", "101,105"], calls[1]
    assert_equal({}, table.cwds([]))
    assert_equal 2, calls.size
  end

  def test_the_table_reads_proc_on_linux_and_marks_a_deleted_directory
    links = { 7 => "/home/me/app", 8 => "/home/me/repo/.claude/worktrees/x (deleted)" }
    table = Machine::ProcessTable.new(platform: :linux, runner: ->(*_argv) { "" },
                                      readlink: ->(pid) { links.fetch(pid) { raise Errno::ENOENT } })
    assert_equal({ 7 => "/home/me/app", 8 => "/home/me/repo/.claude/worktrees/x" }, table.cwds([7, 8, 9]))
  end

  def test_linux_asks_ps_for_the_tty_column
    calls = []
    Machine::ProcessTable.new(platform: :linux, runner: ->(*argv) { calls << argv && "" }).rows
    assert_equal ["ps", "-e", "-ww", "-o", "pid=,ppid=,pgid=,uid=,etime=,tty=,command="], calls[0]
  end

  # --- classifying ----------------------------------------------------------

  def test_every_row_gets_its_class
    assert_equal [
      [101, "orphan"], [105, "orphan"], [200, "stale-wait"], [204, "stale-wait"], [300, "gone-worktree"],
      [400, "headless-claude"], [402, "idle-session"]
    ], classes(findings)
  end

  def test_the_ancestor_chain_other_users_and_system_daemons_are_never_selected
    found = findings(older_than: 0).map { |f| f.row.pid }
    # 899 is a seven-hour wait loop and 800 a three-day session: both are this process's ancestors.
    [1, 100, 104, 501, 600, 700, 800, 899, SELF].each { |pid| refute_includes found, pid }
  end

  def test_only_candidates_that_need_a_working_directory_are_looked_up
    pids = classifier.cwd_pids
    # Orphan candidates (ppid 1, not a system daemon, old enough) and runners.
    assert_includes pids, 101
    assert_includes pids, 300
    assert_includes pids, 500
    [100, 102, 104, 410, 600, 800, 899].each { |pid| refute_includes pids, pid }
  end

  def test_older_than_replaces_every_age_threshold
    found = classes(findings(older_than: 0))
    assert_includes found, [102, "orphan"]
    assert_includes found, [203, "stale-wait"]
    assert_includes found, [403, "idle-session"]
  end

  def test_a_wait_loop_is_judged_by_what_it_evals_not_by_its_preamble
    found = classes(findings(older_than: 0))
    refute_includes found, [202, "stale-wait"]
  end

  def test_a_headless_claude_under_a_live_app_is_left_alone
    refute_includes findings.map { |f| f.row.pid }, 401
  end

  def test_on_linux_an_orphan_reparented_to_the_session_subreaper_counts
    text = <<~PS
      1     0     1     0 12-00:00:00 ?     /sbin/init
      700   1   700   501 12-00:00:00 ?     /usr/lib/systemd/systemd --user
      710 700   710   501 05-00:00:00 ?     ruby busy_loop.rb
      720 700   720   501 05-00:00:00 ?     /usr/lib/systemd/systemd-tmpfiles --user
    PS
    c = classifier(text: text)
    assert_equal [710], c.cwd_pids
    assert_equal [[710, "orphan"]], classes(c.findings(710 => "/tmp/claude-501/x", 720 => "/tmp/claude-501/x"))
  end

  # Bundles and ~/Library are system or app locations only for the executable
  # itself, and never for a runner or a claude CLI.
  def test_a_runner_or_claude_under_library_or_in_a_bundle_is_not_a_system_daemon
    text = <<~PS
      1     0     1     0 12-00:00:00   ?? /sbin/launchd
      710   1   710   501 05-00:00:00   ?? /Users/me/Library/Caches/ms-playwright/chromium_headless_shell-1/chrome-mac/headless_shell --headless
      711   1   711   501 05-00:00:00   ?? /Users/me/Library/Caches/ms-playwright/chromium-1/Chromium.app/Contents/MacOS/Chromium --headless
      712   1   712   501 05-00:00:00   ?? /Users/me/Library/Application Support/Claude/claude-code/2.1.0/claude -p x
      713   1   713   501 05-00:00:00   ?? ruby x.rb --browser /Applications/X.app/Contents/MacOS/X
      714   1   714   501 05-00:00:00   ?? /Users/me/Library/Helpers/sync-agent
    PS
    c = classifier(text: text)
    assert_equal [710, 711, 712, 713], c.cwd_pids
    found = classes(c.findings(710 => GONE, 711 => SCRATCH, 712 => "/Users/me", 713 => SCRATCH, 714 => SCRATCH))
    assert_equal [[710, "orphan"], [711, "orphan"], [712, "headless-claude"], [713, "orphan"]], found
  end

  # macOS's own python3 runs from inside Xcode's bundles: an interpreter is
  # judged by its script's working directory, not by where it is installed.
  def test_an_interpreter_inside_a_bundle_is_not_a_system_daemon
    py = "/Applications/Xcode.app/Contents/Developer/Library/Frameworks/Python3.framework/Versions/3.9/Resources/" \
         "Python.app/Contents/MacOS/Python script.py"
    text = "1 0 1 0 12-00:00:00 ?? /sbin/launchd\n730 1 730 501 05-00:00:00 ?? #{py}\n" \
           "731 1 731 501 05-00:00:00 ?? /usr/libexec/ruby-helper\n"
    c = classifier(text: text)
    assert_equal [730], c.cwd_pids
    assert_equal [[730, "orphan"]], classes(c.findings(730 => SCRATCH))
  end

  # A launchd job may run without TMPDIR: the system's per-user temp dir stands in.
  def test_tmp_roots_without_tmpdir_use_the_system_temp_dir
    assert_equal ["/tmp", "/private/tmp", "/var/folders/x/T", "/private/var/folders/x/T"],
                 Machine.tmp_roots(nil, "/var/folders/x/T/")
    assert_equal ["/tmp", "/private/tmp"], Machine.tmp_roots(nil, "/tmp")
  end

  def test_a_checkout_named_like_a_scratchpad_is_not_one
    text = "1 0 1 0 12-00:00:00 ?? /sbin/launchd\n720 1 720 501 05-00:00:00 ?? ruby x.rb\n"
    c = classifier(text: text)
    assert_empty c.findings(720 => "/Users/me/Code/claude-501/app")
    assert_empty c.findings(720 => "/private/tmp/claude-502/x")
    refute_empty c.findings(720 => "/tmp/claude-501/x")
  end

  # --- reaping --------------------------------------------------------------

  class FakeSignals
    attr_reader :sent

    def initialize(survivors)
      @sent = []
      @survivors = survivors
    end

    def kill(signal, target)
      @sent << [signal, target]
    end

    def alive?(pid)
      @survivors.include?(pid)
    end
  end

  def reaper(signals, out)
    clock = [0.0]
    Machine::Reaper.new(rows: rows, self_pid: SELF, uid: UID, signals: signals, out: out,
                        clock: -> { clock[0] }, sleeper: ->(s) { clock[0] += s })
  end

  def test_auto_kills_only_orphans_and_stale_waits
    selected = Machine::Reaper.select(findings, auto: true)
    assert_equal [101, 105, 200, 204], selected.map { |f| f.row.pid }.sort
  end

  # The issue settled stale-wait as auto: a six-hour wait loop under a live
  # (often idle) session is exactly the case it was written for.
  def test_a_stale_wait_is_auto_whether_or_not_its_session_is_alive
    assert findings.find { |f| f.row.pid == 204 }.auto?
    assert findings.find { |f| f.row.pid == 200 }.auto?
  end

  def test_a_session_manager_started_from_a_worktree_is_not_an_orphan
    refute_includes findings(older_than: 0).map { |f| f.row.pid }, 106
  end

  # Runner patterns match the command being run, not words in its arguments.
  def test_a_runner_word_in_an_argument_is_not_a_runner
    pids = findings(older_than: 0).map { |f| f.row.pid }
    refute_includes pids, 405
    refute_includes pids, 406
    runner = Machine.matcher(Machine::RUNNER_PATTERNS)
    [
      "bundle exec rspec spec/models", "ruby /Users/me/.gem/bin/rspec", "env RAILS_ENV=test bin/rails test",
      "python3 -m pytest -q", "node --max-old-space-size=4096 node_modules/.bin/jest", "npx playwright test",
      "go test ./...", "/x/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing --headless",
      "puma 6.4 (tcp://0.0.0.0:3000)", "sh -c 'bundle exec rspec'",
      "node /r/node_modules/playwright/lib/common/process.js", "node /r/node_modules/@playwright/test/cli.js test",
      "node /r/node_modules/jest/bin/jest.js", "node /r/node_modules/vite/bin/vite.js"
    ].each { |cmd| assert runner.match?(cmd), cmd }
    ["tail -f log/rspec.log", "/Users/me/rspec/tool --x", "node /r/node_modules/@playwright/mcp/cli.js",
     "ruby /Users/me/Code/jest/script.rb", "claude -p fix the rspec failures", "vim spec/rspec_helper.rb", "grep -r jest .",
     "#{format(SNAP, 'bundle exec rspec')}"].each { |cmd| refute runner.match?(cmd), cmd }
  end

  def test_a_headless_claude_under_a_shell_in_a_code_directory_is_still_reported
    text = <<~PS
      1     0     1     0 12-00:00:00   ?? /sbin/launchd
      740   1   740   501 05-00:00:00   ?? /bin/zsh /Users/me/Code
      741 740   741   501 05-00:00:00   ?? /Users/me/.local/bin/claude -p x
      750   1   750   501 05-00:00:00   ?? /usr/share/code/code --type=renderer
      751 750   751   501 05-00:00:00   ?? /Users/me/.local/bin/claude -p y
    PS
    assert_equal [[741, "headless-claude"]], classes(classifier(text: text).findings({}))
  end

  def test_kill_selects_the_named_classes
    selected = Machine::Reaper.select(findings, classes: %w[idle-session gone-worktree])
    assert_equal [300, 402], selected.map { |f| f.row.pid }.sort
  end

  def test_term_goes_to_the_group_when_the_group_is_all_targets_and_kill_follows_for_survivors
    signals = FakeSignals.new([101, -200])
    out = StringIO.new
    reaper(signals, out).reap(Machine::Reaper.select(findings, auto: true))
    # 101 shares group 50 with an unrelated live process: only the pid. 105
    # leads a group of its own; 200's group holds only its own child, and a
    # member of a group that outlives TERM gets KILL too.
    assert_equal [["TERM", 101], ["TERM", -105], ["TERM", -200], ["TERM", -204], ["KILL", 101], ["KILL", -200]], signals.sent
    assert_match(/killed orphan 101 .*KILL/, out.string)
    assert_match(/killed stale-wait 200 /, out.string)
  end

  def test_dry_run_signals_nothing_and_names_each_target
    signals = FakeSignals.new([])
    out = StringIO.new
    reaper(signals, out).reap(Machine::Reaper.select(findings, auto: true), dry_run: true)
    assert_empty signals.sent
    assert_equal 4, out.string.lines.grep(/\Awould kill /).size
  end

  def test_an_already_gone_target_is_not_an_error
    signals = FakeSignals.new([])
    def signals.kill(_signal, _target)
      raise Errno::ESRCH
    end
    out = StringIO.new
    reaper(signals, out).reap(Machine::Reaper.select(findings, auto: true))
    assert_match(/already gone/, out.string)
  end

  # --- governing ------------------------------------------------------------

  def governor(platform:, state:, calls:, now: NOW)
    later = rows.each { |r| r.age += (now - NOW).to_i }
    Machine::Governor.new(rows: later, uid: UID, self_pid: SELF, patterns: Machine::GOVERN_PATTERNS,
                          platform: platform, runner: ->(*argv) { calls << argv && "" },
                          state_path: state, now: now, out: StringIO.new)
  end

  def test_govern_demotes_each_test_process_once_on_macos
    Dir.mktmpdir do |dir|
      state = File.join(dir, "machine", "governed.json")
      calls = []
      governor(platform: :macos, state: state, calls: calls).govern
      assert_equal [300, 500].map { |pid| ["taskpolicy", "-b", "-p", pid.to_s] }, calls
      calls.clear
      governor(platform: :macos, state: state, calls: calls, now: NOW + 60).govern
      assert_empty calls
    end
  end

  def test_govern_uses_renice_and_ionice_on_linux
    Dir.mktmpdir do |dir|
      calls = []
      governor(platform: :linux, state: File.join(dir, "g.json"), calls: calls).govern
      assert_equal [%w[renice -n 10 -p 300], %w[ionice -c3 -p 300]], calls.first(2)
      assert_equal 4, calls.size
    end
  end

  # Without ionice (a container) renice still counts: it never runs twice.
  def test_govern_on_linux_records_a_pid_when_only_ionice_fails
    Dir.mktmpdir do |dir|
      state = File.join(dir, "g.json")
      calls = []
      runner = ->(*argv) { calls << argv && (argv.first == "ionice" ? nil : "") }
      2.times do
        Machine::Governor.new(rows: rows, uid: UID, self_pid: SELF, patterns: Machine::GOVERN_PATTERNS,
                              platform: :linux, runner: runner, state_path: state, now: NOW, out: StringIO.new).govern
      end
      assert_equal 2, calls.count { |argv| argv.first == "renice" }
    end
  end

  def test_govern_forgets_dead_pids_and_redemotes_a_reused_one
    Dir.mktmpdir do |dir|
      state = File.join(dir, "g.json")
      started = (NOW - 86_400).to_i
      File.write(state, JSON.generate("999" => 1, "202" => started, "300" => started, "500" => 1))
      calls = []
      governor(platform: :macos, state: state, calls: calls).govern
      assert_equal [%w[taskpolicy -b -p 500]], calls
      assert_equal %w[202 300 500], JSON.parse(File.read(state)).keys.sort
    end
  end

  def test_govern_dry_run_runs_and_writes_nothing
    Dir.mktmpdir do |dir|
      state = File.join(dir, "g.json")
      calls = []
      out = StringIO.new
      Machine::Governor.new(rows: rows, uid: UID, self_pid: SELF, patterns: Machine::GOVERN_PATTERNS,
                            platform: :macos, runner: ->(*argv) { calls << argv && "" },
                            state_path: state, now: NOW, out: out).govern(dry_run: true)
      assert_empty calls
      refute File.exist?(state)
      assert_equal 2, out.string.lines.grep(/\Awould demote /).size
    end
  end

  def test_govern_skips_other_users_and_its_own_ancestors
    text = PS.sub("until false; do sleep 15; done", "bundle exec rspec")
    calls = []
    Dir.mktmpdir do |dir|
      Machine::Governor.new(rows: rows(text), uid: UID, self_pid: SELF, patterns: Machine::GOVERN_PATTERNS,
                            platform: :macos, runner: ->(*argv) { calls << argv && "" },
                            state_path: File.join(dir, "g.json"), now: NOW, out: StringIO.new).govern
    end
    pids = calls.map(&:last)
    refute_includes pids, "899"
    refute_includes pids, "501"
  end

  # lsof exits 1 when one of the pids it was given has exited, and still
  # prints the others.
  def test_capture_keeps_the_output_of_a_command_that_fails
    assert_equal "p1\n", Machine.capture("sh", "-c", "echo p1; exit 1")
    assert_equal "", Machine.capture("/nonexistent/command")
  end

  def test_a_zombie_is_not_alive
    stat = { %w[ps -o stat= -p 123] => "Z+\n", %w[ps -o stat= -p 124] => "S\n",
             %w[ps -axo pgid=,stat=] => "  50 Z\n  51 S\n  50 Z+\n" }
    signals = Machine::Signals.new(probe: ->(_target) { 1 }, runner: ->(*argv) { stat.fetch(argv) }, platform: :macos)
    refute signals.alive?(123)
    assert signals.alive?(124)
    refute signals.alive?(-50)
    assert signals.alive?(-51)
    linux = Machine::Signals.new(probe: ->(_target) { 1 }, platform: :linux,
                                 runner: ->(*argv) { argv == %w[ps -e -o pgid=,stat=] ? "51 S\n" : "" })
    assert linux.alive?(-51)
    gone = Machine::Signals.new(probe: ->(_target) { raise Errno::ESRCH }, runner: ->(*_argv) { raise "unused" })
    refute gone.alive?(123)
  end

  # --- status ---------------------------------------------------------------

  def test_status_is_silent_when_clean
    assert_nil Machine.status_line([], load: 28.4, cores: 12)
  end

  def test_status_is_one_line_otherwise
    assert_equal "load 28/12 · 4 auto-reapable, 3 to review · /machine:reap",
                 Machine.status_line(findings, load: 28.4, cores: 12)
    auto_only = findings.select(&:auto?)
    assert_equal "load 3/12 · 4 auto-reapable · /machine:reap", Machine.status_line(auto_only, load: 2.6, cores: 12)
  end

  # --- the command line -----------------------------------------------------

  def cli(*argv, clean: false)
    out = StringIO.new
    signals = FakeSignals.new([])
    text = clean ? PS.lines.reject { |l| l =~ /\A(101|102|105|200|203|204|300|400|402|403) / }.join : PS
    table = Struct.new(:rows, :cwd_map) do
      def cwds(pids)
        cwd_map.select { |pid, _| pids.include?(pid) }
      end
    end.new(Machine.parse_ps(text), CWDS)
    Dir.mktmpdir do |dir|
      ctx = Machine::Context.new(table: table, uid: UID, self_pid: SELF, platform: :macos, signals: signals,
                                 runner: ->(*_argv) { "" }, state_dir: dir, config_dir: dir, now: NOW, out: out,
                                 load: -> { 28.4 }, cores: 12, dir_exists: ->(path) { path != GONE })
      code = nil
      capture_io { code = Machine.main(argv, ctx) }
      [out.string, code, signals.sent]
    end
  end

  def test_report_prints_one_line_per_finding
    out, code, = cli("report")
    assert_equal 0, code
    assert_equal 7, out.lines.size
    assert_match(/\Aorphan\s+101\s+5d\s+#{Regexp.escape(SCRATCH)}\s+ruby busy_loop\.rb$/, out.lines.first)
  end

  def test_report_json
    out, = cli("report", "--json", "--older-than", "0")
    data = JSON.parse(out)
    row = data.find { |f| f["pid"] == 102 }
    assert_equal({ "class" => "orphan", "auto" => true, "age_seconds" => 1800, "cwd" => SCRATCH }, row.slice("class", "auto", "age_seconds", "cwd"))
  end

  def test_report_on_a_clean_machine
    out, = cli("report", clean: true)
    assert_equal "nothing to reap\n", out
  end

  def test_reap_auto_dry_run_names_the_auto_classes_only
    out, code, sent = cli("reap", "--auto", "--dry-run")
    assert_equal 0, code
    assert_empty sent
    assert_equal %w[101 105 200 204], out.lines.map { |l| l.split[3] }.sort
  end

  def test_reap_kill_takes_class_names
    _out, _code, sent = cli("reap", "--kill", "idle-session", "headless-claude")
    assert_equal [["TERM", -400], ["TERM", -402]], sent
  end

  def test_reap_refuses_an_unknown_class_and_a_missing_mode
    _out, code, sent = cli("reap", "--kill", "everything")
    assert_equal 2, code
    assert_empty sent
    assert_equal 2, cli("reap")[1]
    assert_equal 2, cli("reap", "--auto", "--kill", "orphan")[1]
    assert_empty cli("reap", "--auto", "--kill", "orphan")[2]
  end

  def test_a_command_refuses_the_flags_it_does_not_take
    assert_equal 2, cli("govern", "--json")[1]
    assert_equal 2, cli("report", "--dry-run")[1]
    assert_equal 2, cli("report", "--auto")[1]
  end

  def test_status_from_the_command_line
    assert_equal "load 28/12 · 4 auto-reapable, 3 to review · /machine:reap\n", cli("status")[0]
    assert_equal ["", 0], cli("status", clean: true).first(2)
  end

  def test_status_never_fails
    ctx = Machine::Context.new(table: nil, uid: UID, self_pid: SELF, platform: :macos, signals: nil, runner: nil,
                               state_dir: "/nonexistent", config_dir: "/nonexistent", now: NOW, out: StringIO.new,
                               load: -> { raise "boom" }, cores: 12, dir_exists: ->(_) { true })
    assert_equal 0, Machine.main(["status"], ctx)
    assert_equal "", ctx.out.string
  end

  def test_older_than_accepts_units
    assert_equal 0, Machine.duration("0")
    assert_equal 90, Machine.duration("90")
    assert_equal 1800, Machine.duration("30m")
    assert_equal 6 * 3600, Machine.duration("6h")
    assert_equal 2 * 86_400, Machine.duration("2d")
    assert_raises(ArgumentError) { Machine.duration("soon") }
  end

  def test_govern_patterns_come_from_the_config_file_when_it_sets_them
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "machine"))
      File.write(File.join(dir, "machine", "config.json"), JSON.generate("govern_patterns" => ["vite"]))
      assert_equal ["vite"], Machine.govern_patterns(dir)
      assert_equal Machine::GOVERN_PATTERNS, Machine.govern_patterns(File.join(dir, "none"))
    end
  end
end
