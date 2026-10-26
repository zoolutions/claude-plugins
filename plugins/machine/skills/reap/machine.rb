#!/usr/bin/env ruby
# frozen_string_literal: true

# The processes agent sessions leave behind, found and reaped, and test runs
# kept at background priority. Reads `ps` and the working directories of the
# few processes whose class depends on one (`lsof` on macOS, /proc on Linux).
# Stdlib only, Ruby >= 2.6.
#
#   machine.rb report [--json] [--older-than AGE]
#   machine.rb reap (--auto | --kill CLASS...) [--dry-run] [--older-than AGE]
#   machine.rb govern [--dry-run]
#   machine.rb status
#
# Never touched: this process's ancestors, PID 1's system daemons, anything
# another user owns.

require "etc"
require "fileutils"
require "json"
require "open3"
require "optparse"

module Machine
  # class => [minimum age in seconds, killed by `reap --auto`]
  CLASSES = {
    "orphan" => [3600, true],
    "stale-wait" => [6 * 3600, true],
    "gone-worktree" => [0, false],
    "headless-claude" => [3600, false],
    "idle-session" => [2 * 86_400, false]
  }.freeze
  AUTO = CLASSES.select { |_, (_, auto)| auto }.keys.freeze
  GOVERN_PATTERNS = ["rspec", "bin/rails test", "pytest", "jest", "vitest", "playwright", "chrome-headless-shell",
                     "go test", "cargo test", "mix test"].freeze
  # Whose working directory decides `gone-worktree`: test runners, browsers, dev servers.
  RUNNER_PATTERNS = (GOVERN_PATTERNS + ["chrome", "chromium", "Chromium", "Google Chrome for Testing", "headless_shell",
                                        "firefox", "puma", "rails server", "rails s",
                                        "bin/dev", "foreman", "overmind", "vite", "webpack", "esbuild",
                                        "next dev"]).freeze
  # PID 1's children whose executable lives here are the system's or an app's,
  # never an agent's (matched against the executable, not its arguments).
  SYSTEM_DAEMON = %r{\A(?:/System/|/usr/libexec/|/usr/sbin/|/sbin/|/Library/|/Applications/|/usr/lib/systemd/|
                       /lib/systemd/|[^ ]*/Library/)|\.app/Contents/|\.xpc/|\.framework/}x.freeze
  # An interpreter is judged by its script, wherever it is installed (macOS's
  # python3 runs from inside Xcode's bundles).
  INTERPRETER = /\A(?:python[\d.]*|Python|ruby|node|perl|sh|bash|zsh|fish)\z/.freeze
  # A live app or IDE: a headless claude under one is its child, not a leftover.
  APP = %r{\.app/Contents/|(?:\A|/)(?:code|cursor|zed|idea|webstorm|rubymine)(?:\s|\z)}i.freeze
  CLAUDE = %r{\A(?:\S*/)?claude(?:\s|\z)|\A.*/claude-code/[^/]+/claude(?:\s|\z)|\A\S*node\S*\s+\S*claude-code/cli\.m?js}.freeze
  SNAPSHOT = "shell-snapshots/snapshot-"
  WAIT = /(?:\A|[\s;&|(])(?:until|while|sleep)\s/.freeze
  WORKTREE = "/.claude/worktrees/"
  NO_TTY = ["", "?", "??", "-"].freeze
  # Where an orphan is reparented: PID 1, or a Linux session's subreaper.
  SUBREAPER = %r{\A\S*systemd --user}.freeze
  GRACE = 5
  REPORT_WIDTH = 80

  Row = Struct.new(:pid, :ppid, :pgid, :uid, :age, :tty, :command) do
    def tty?
      !NO_TTY.include?(tty)
    end
  end

  Finding = Struct.new(:klass, :row, :cwd) do
    def auto?
      AUTO.include?(klass)
    end
  end

  Context = Struct.new(:table, :uid, :self_pid, :platform, :signals, :runner, :state_dir, :config_dir, :now, :out,
                       :load, :cores, :dir_exists, keyword_init: true)

  module_function

  # --- reading the table ----------------------------------------------------

  # `ps` etime: [[dd-]hh:]mm:ss.
  def parse_etime(text)
    days, clock = text.include?("-") ? text.split("-", 2) : [0, text]
    clock.split(":").map(&:to_i).reverse.each_with_index.sum { |n, i| n * 60**i } + days.to_i * 86_400
  end

  def parse_ps(text)
    text.to_s.each_line.map do |line|
      pid, ppid, pgid, uid, etime, tty, command = line.strip.split(/\s+/, 7)
      next unless command

      Row.new(pid.to_i, ppid.to_i, pgid.to_i, uid.to_i, parse_etime(etime), tty, command)
    end.compact
  end

  # Where Claude's scratchpads live: <root>/claude-<uid>/. Without TMPDIR (a
  # launchd job) the system's per-user temp dir stands in.
  def tmp_roots(tmpdir = ENV["TMPDIR"], systmp = Etc.systmpdir)
    roots = ["/tmp", "/private/tmp"]
    [tmpdir, systmp].each do |path|
      dir = path.to_s.chomp("/")
      next if dir.empty?

      roots += [dir, dir.start_with?("/private/") ? dir.sub("/private", "") : "/private#{dir}"]
    end
    roots.uniq
  end

  def run(*argv)
    out, status = Open3.capture2(*argv, err: File::NULL)
    status.success? ? out : nil
  rescue SystemCallError
    nil
  end

  # Every process, and the working directory of the ones asked for.
  class ProcessTable
    def initialize(platform:, runner: Machine.method(:run), readlink: ->(pid) { File.readlink("/proc/#{pid}/cwd") })
      @platform = platform
      @runner = runner
      @readlink = readlink
    end

    def rows
      tty = @platform == :macos ? "tdev" : "tty" # macOS `tty` resolves device names: three times slower
      select = @platform == :macos ? ["-axww"] : ["-e", "-ww"]
      Machine.parse_ps(@runner.call("ps", *select, "-o", "pid=,ppid=,pgid=,uid=,etime=,#{tty}=,command="))
    end

    def cwds(pids)
      return {} if pids.empty?
      return linux_cwds(pids) unless @platform == :macos

      out = @runner.call("lsof", "-a", "-n", "-P", "-w", "-b", "-O", "-d", "cwd", "-Fpn", "-p", pids.join(","))
      pid = nil
      out.to_s.each_line.with_object({}) do |line, map|
        case line[0]
        when "p" then pid = line[1..-1].to_i
        when "n" then map[pid] = line[1..-1].chomp if pid
        end
      end
    end

    private

    def linux_cwds(pids)
      pids.each_with_object({}) do |pid, map|
        map[pid] = @readlink.call(pid).sub(/ \(deleted\)\z/, "")
      rescue SystemCallError
        next
      end
    end
  end

  # --- classifying ----------------------------------------------------------

  def pattern(text)
    /(?:\A|[\s\/'"])#{Regexp.escape(text)}(?:\z|[\s\/'";])/
  end

  def matcher(patterns)
    Regexp.union(patterns.map { |p| pattern(p) })
  end

  # The pids a process must never be, and the pid → row index.
  module Guard
    def ancestors(by_pid, self_pid)
      chain = []
      pid = self_pid
      while pid && pid > 1 && !chain.include?(pid)
        chain << pid
        pid = by_pid[pid]&.ppid
      end
      chain
    end

    def lineage(by_pid, row)
      seen = []
      pid = row.ppid
      while pid && pid > 1 && (parent = by_pid[pid]) && !seen.include?(pid)
        seen << pid
        yield parent
        pid = parent.ppid
      end
    end
  end

  # Which class each process falls in; a process falls in at most one.
  class Classifier
    include Guard

    def initialize(rows, uid:, self_pid:, older_than: nil, dir_exists: ->(path) { File.directory?(path) },
                   tmp_roots: Machine.tmp_roots)
      @by_pid = rows.map { |r| [r.pid, r] }.to_h
      @scratchpad = %r{\A(?:#{tmp_roots.map { |root| Regexp.escape(root) }.join('|')})/claude-#{uid}(?:/|\z)}
      @older_than = older_than
      @dir_exists = dir_exists
      @runner = Machine.matcher(RUNNER_PATTERNS)
      protected = ancestors(@by_pid, self_pid)
      @rows = rows.reject { |r| r.pid <= 1 || r.uid != uid || protected.include?(r.pid) || daemon?(r) }
    end

    def cwd_pids
      @rows.select { |r| orphan_candidate?(r) || r.command.match?(@runner) }.map(&:pid)
    end

    def findings(cwds)
      @rows.map do |row|
        cwd = cwds[row.pid]
        klass = CLASSES.keys.find { |k| old?(row, k) && send(:"#{k.tr('-', '_')}?", row, cwd) }
        Finding.new(klass, row, cwd) if klass
      end.compact
    end

    private

    # A runner or a claude CLI is never a daemon, wherever it is installed.
    def daemon?(row)
      return false unless reparented?(row)
      return false if row.command.match?(CLAUDE) || row.command.match?(@runner)

      executable = row.command.split(" -", 2).first
      return false if executable[%r{[^/]*\z}].split(" ").first.to_s.match?(INTERPRETER)

      executable.match?(SYSTEM_DAEMON)
    end

    def reparented?(row)
      row.ppid == 1 || @by_pid[row.ppid]&.command&.match?(SUBREAPER) || false
    end

    def old?(row, klass)
      row.age >= (@older_than || CLASSES.fetch(klass)[0])
    end

    def orphan_candidate?(row)
      reparented?(row) && old?(row, "orphan")
    end

    def orphan?(row, cwd)
      reparented?(row) && cwd && (cwd.match?(@scratchpad) || cwd.include?(WORKTREE))
    end

    def stale_wait?(row, _cwd)
      row.command.include?(SNAPSHOT) && (row.command[/eval '(.*)'/m, 1] || row.command).match?(WAIT)
    end

    def gone_worktree?(row, cwd)
      cwd && row.command.match?(@runner) && !@dir_exists.call(cwd)
    end

    def headless_claude?(row, _cwd)
      return false if row.tty? || !row.command.match?(CLAUDE)

      lineage(@by_pid, row) { |parent| return false if parent.command.match?(APP) }
      true
    end

    def idle_session?(row, _cwd)
      row.tty? && row.command.match?(CLAUDE)
    end
  end

  # --- reaping --------------------------------------------------------------

  # The real signals: TERM/KILL, and whether a pid still runs.
  class Signals
    def kill(signal, target)
      Process.kill(signal, target)
    end

    def alive?(target)
      Process.kill(0, target)
      true
    rescue Errno::ESRCH
      false
    rescue Errno::EPERM
      true
    end
  end

  # TERM to each target's process group, KILL after GRACE seconds for survivors.
  class Reaper
    include Guard

    def self.select(findings, auto: false, classes: [])
      wanted = auto ? AUTO : classes
      findings.select { |f| wanted.include?(f.klass) }
    end

    def initialize(rows:, self_pid:, uid:, signals:, out:, clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) },
                   sleeper: ->(s) { sleep(s) })
      @rows = rows
      @by_pid = rows.map { |r| [r.pid, r] }.to_h
      @protected = ancestors(@by_pid, self_pid)
      @own_group = @by_pid[self_pid]&.pgid
      @uid = uid
      @signals = signals
      @out = out
      @clock = clock
      @sleeper = sleeper
    end

    def reap(targets, dry_run: false)
      return targets.each { |f| @out.puts("would kill #{line(f)}") } if dry_run

      pids = targets.map { |f| f.row.pid }
      sent = targets.map do |f|
        to = target(f.row, pids)
        [f, to, signal("TERM", to)]
      end
      # A group target survives while any member does: `kill 0` to -pgid.
      survivors = await(sent.select { |_, _, result| result == :sent }.map { |_, to, _| to })
      sent.each do |f, to, result|
        result = signal("KILL", to) == :sent ? :killed : :gone if survivors.include?(to)
        @out.puts(report(f, result))
      end
    end

    private

    # The group, when every process in it is a target or a target's
    # descendant; otherwise the pid alone.
    def target(row, pids)
      group = @rows.select { |r| r.pgid == row.pgid }
      whole = row.pgid > 1 && row.pgid != @own_group && group.all? do |r|
        r.uid == @uid && !@protected.include?(r.pid) && (pids.include?(r.pid) || descends?(r, pids))
      end
      whole ? -row.pgid : row.pid
    end

    def descends?(row, pids)
      lineage(@by_pid, row) { |parent| return true if pids.include?(parent.pid) }
      false
    end

    def signal(name, target)
      @signals.kill(name, target)
      :sent
    rescue Errno::ESRCH
      :gone
    rescue Errno::EPERM
      :denied
    end

    def await(targets)
      deadline = @clock.call + GRACE
      loop do
        targets = targets.select { |to| @signals.alive?(to) }
        return targets if targets.empty? || @clock.call >= deadline

        @sleeper.call(0.2)
      end
    end

    def report(finding, result)
      case result
      when :sent then "killed #{line(finding)} (TERM)"
      when :killed then "killed #{line(finding)} (KILL)"
      when :gone then "already gone: #{line(finding)}"
      else "not permitted: #{line(finding)}"
      end
    end

    def line(finding)
      "#{finding.klass} #{finding.row.pid} #{Machine.age(finding.row.age)} #{Machine.truncate(finding.row.command)}"
    end
  end

  # --- governing ------------------------------------------------------------

  # Test processes to background QoS, once each; the pids done are remembered
  # with their start time, so a reused pid is demoted again.
  class Governor
    include Guard
    SAME_START = 5

    def initialize(rows:, uid:, self_pid:, patterns:, platform:, runner:, state_path:, now:, out:)
      by_pid = rows.map { |r| [r.pid, r] }.to_h
      protected = ancestors(by_pid, self_pid)
      match = Machine.matcher(patterns)
      @rows = rows.select { |r| r.pid > 1 && r.uid == uid && !protected.include?(r.pid) && r.command.match?(match) }
      @all = rows
      @platform = platform
      @runner = runner
      @state_path = state_path
      @now = now
      @out = out
    end

    def govern(dry_run: false)
      state = live(read_state)
      @rows.each do |row|
        started = (@now - row.age).to_i
        next if state.key?(row.pid.to_s) && (state[row.pid.to_s] - started).abs <= SAME_START

        if dry_run
          @out.puts("would demote #{row.pid} #{Machine.truncate(row.command)}")
        elsif commands(row.pid).all? { |argv| @runner.call(*argv) }
          state[row.pid.to_s] = started
          @out.puts("demoted #{row.pid} #{Machine.truncate(row.command)}")
        end
      end
      write_state(state) unless dry_run
    end

    private

    def commands(pid)
      return [["taskpolicy", "-b", "-p", pid.to_s]] if @platform == :macos

      [["renice", "-n", "10", "-p", pid.to_s], ["ionice", "-c3", "-p", pid.to_s]]
    end

    # Only the pids still running with the start time recorded.
    def live(state)
      started = @all.map { |r| [r.pid.to_s, (@now - r.age).to_i] }.to_h
      state.select { |pid, at| started.key?(pid) && (started[pid] - at.to_i).abs <= SAME_START }
    end

    def read_state
      data = JSON.parse(File.read(@state_path))
      data.is_a?(Hash) ? data : {}
    rescue SystemCallError, JSON::ParserError
      {}
    end

    def write_state(state)
      FileUtils.mkdir_p(File.dirname(@state_path))
      File.write(@state_path, JSON.generate(state))
    end
  end

  # --- status ---------------------------------------------------------------

  def status_line(findings, load:, cores:)
    return nil if findings.empty?

    auto = findings.count(&:auto?)
    review = findings.size - auto
    counts = []
    counts << "#{auto} auto-reapable" if auto.positive?
    counts << "#{review} to review" if review.positive?
    "load #{load.round}/#{cores} · #{counts.join(', ')} · /machine:reap"
  end

  def load_average(platform, runner)
    text = platform == :macos ? runner.call("sysctl", "-n", "vm.loadavg") : File.read("/proc/loadavg")
    text.to_s[/\d+(?:\.\d+)?/].to_f
  end

  # --- formatting -----------------------------------------------------------

  def age(seconds)
    return "#{seconds / 86_400}d" if seconds >= 86_400
    return "#{seconds / 3600}h" if seconds >= 3600
    return "#{seconds / 60}m" if seconds >= 60

    "#{seconds}s"
  end

  def truncate(text, width = REPORT_WIDTH)
    text.length > width ? "#{text[0, width - 1]}…" : text
  end

  # "0", "90" (seconds), "30m", "6h", "2d".
  def duration(text)
    number, unit = text.to_s.match(/\A(\d+)([smhd]?)\z/)&.captures
    raise ArgumentError, "not a duration: #{text}" unless number

    number.to_i * { "" => 1, "s" => 1, "m" => 60, "h" => 3600, "d" => 86_400 }.fetch(unit)
  end

  def govern_patterns(config_dir)
    data = JSON.parse(File.read(File.join(config_dir, "machine", "config.json")))
    patterns = data.is_a?(Hash) && data["govern_patterns"]
    patterns.is_a?(Array) && patterns.all? { |p| p.is_a?(String) } ? patterns : GOVERN_PATTERNS
  rescue SystemCallError, JSON::ParserError
    GOVERN_PATTERNS
  end

  # --- the command line -----------------------------------------------------

  USAGE = "usage: machine.rb report [--json] [--older-than AGE] | reap (--auto | --kill CLASS...) [--dry-run] " \
          "[--older-than AGE] | govern [--dry-run] | status"

  FLAGS = { "report" => %i[json older_than], "reap" => %i[auto kill dry_run older_than], "govern" => %i[dry_run] }.freeze

  def default_context
    platform = RUBY_PLATFORM.include?("darwin") ? :macos : :linux
    home = Dir.home
    Context.new(table: ProcessTable.new(platform: platform), uid: Process.uid, self_pid: Process.pid,
                platform: platform, signals: Signals.new, runner: method(:run),
                state_dir: File.join(ENV.fetch("XDG_CACHE_HOME", File.join(home, ".cache")), "machine"),
                config_dir: ENV.fetch("XDG_CONFIG_HOME", File.join(home, ".config")), now: Time.now, out: $stdout,
                load: -> { load_average(platform, method(:run)) }, cores: Etc.nprocessors,
                dir_exists: ->(path) { File.directory?(path) })
  end

  def options(argv)
    opts = { classes: [] }
    rest = OptionParser.new do |o|
      o.on("--json") { opts[:json] = true }
      o.on("--auto") { opts[:auto] = true }
      o.on("--kill CLASS", Array) { |v| opts[:classes].concat(v) }
      o.on("--dry-run") { opts[:dry_run] = true }
      o.on("--older-than AGE") { |v| opts[:older_than] = duration(v) }
    end.parse(argv)
    opts[:classes].concat(rest) if opts[:classes].any?
    opts[:rest] = opts[:classes].any? ? [] : rest
    opts
  end

  def findings_of(ctx, rows, older_than)
    classifier = Classifier.new(rows, uid: ctx.uid, self_pid: ctx.self_pid, older_than: older_than,
                                      dir_exists: ctx.dir_exists)
    classifier.findings(ctx.table.cwds(classifier.cwd_pids))
  end

  def main(argv, ctx = default_context)
    command, *args = argv
    return status(ctx) if command == "status"

    opts = options(args)
    raise OptionParser::InvalidArgument, opts[:rest].join(" ") if opts[:rest].any?

    extra = opts.keys - [:rest, :classes] - FLAGS.fetch(command, [])
    extra << :kill if opts[:classes].any? && !FLAGS.fetch(command, []).include?(:kill)
    raise ArgumentError, "#{command} takes no --#{extra.first.to_s.tr('_', '-')}" if extra.any?

    case command
    when "report" then report(ctx, opts)
    when "reap" then reap(ctx, opts)
    when "govern" then govern(ctx, opts)
    else raise OptionParser::InvalidArgument, command.to_s
    end
  rescue OptionParser::ParseError, ArgumentError => e
    warn "machine: #{e.message}\n#{USAGE}"
    2
  end

  def status(ctx)
    line = status_line(findings_of(ctx, ctx.table.rows, nil), load: ctx.load.call, cores: ctx.cores)
    ctx.out.puts(line) if line
    0
  rescue StandardError
    0
  end

  def report(ctx, opts)
    found = findings_of(ctx, ctx.table.rows, opts[:older_than])
    if opts[:json]
      ctx.out.puts(JSON.pretty_generate(found.map do |f|
        { "class" => f.klass, "auto" => f.auto?, "pid" => f.row.pid, "ppid" => f.row.ppid,
          "age_seconds" => f.row.age, "cwd" => f.cwd, "command" => f.row.command }
      end))
    elsif found.empty?
      ctx.out.puts("nothing to reap")
    else
      found.each do |f|
        ctx.out.puts(format("%-15s %7d %4s  %s  %s", f.klass, f.row.pid, age(f.row.age), f.cwd || "-",
                            truncate(f.row.command)))
      end
    end
    0
  end

  def reap(ctx, opts)
    unknown = opts[:classes] - CLASSES.keys
    raise ArgumentError, "unknown class: #{unknown.join(', ')} (classes: #{CLASSES.keys.join(', ')})" if unknown.any?
    raise ArgumentError, "reap needs --auto or --kill CLASS" unless opts[:auto] || opts[:classes].any?
    raise ArgumentError, "reap takes --auto or --kill CLASS, not both" if opts[:auto] && opts[:classes].any?

    rows = ctx.table.rows
    targets = Reaper.select(findings_of(ctx, rows, opts[:older_than]), auto: opts[:auto], classes: opts[:classes])
    Reaper.new(rows: rows, self_pid: ctx.self_pid, uid: ctx.uid, signals: ctx.signals, out: ctx.out)
          .reap(targets, dry_run: opts[:dry_run])
    0
  end

  def govern(ctx, opts)
    Governor.new(rows: ctx.table.rows, uid: ctx.uid, self_pid: ctx.self_pid, patterns: govern_patterns(ctx.config_dir),
                 platform: ctx.platform, runner: ctx.runner, state_path: File.join(ctx.state_dir, "governed.json"),
                 now: ctx.now, out: ctx.out).govern(dry_run: opts[:dry_run])
    0
  end
end

exit(Machine.main(ARGV)) if $PROGRAM_NAME == __FILE__
