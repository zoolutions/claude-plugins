#!/usr/bin/env ruby
# frozen_string_literal: true

# Is this machine busy? Reads the 1-minute load average and the core count and
# prints one line: `load 28.2 / 12 cores (2.35×) — busy`. Exit 0 when ok, 3
# when busy (load more than <max> × cores), 0 with `unknown` when the load
# cannot be read: an unsupported platform never blocks the caller.
# Stdlib only, Ruby >= 2.6.
#
#   load.rb [--max <x>]   (default 1.5)

require "etc"
require "open3"

module FlowLoad
  DEFAULT_MAX = 1.5
  BUSY = 3

  module_function

  def parse(text)
    number = text.to_s[/\A[\s{]*(\d+(?:\.\d+)?)/, 1]
    number && Float(number)
  end

  def read_load(platform: RUBY_PLATFORM, proc_path: "/proc/loadavg")
    if platform.include?("darwin")
      out, status = Open3.capture2("sysctl", "-n", "vm.loadavg")
      status.success? ? parse(out) : nil
    elsif platform.include?("linux")
      parse(File.read(proc_path))
    end
  rescue SystemCallError
    nil
  end

  def check(load:, cores:, max:)
    return ["load #{load ? format('%.1f', load) : 'unknown'} / #{cores || '?'} cores — unknown", 0] unless load && cores

    ratio = load / cores
    word = ratio > max ? "busy" : "ok"
    [format("load %.1f / %d cores (%.2f×) — %s", load, cores, ratio, word), word == "busy" ? BUSY : 0]
  end

  def max_from(argv)
    i = argv.index("--max")
    raw = i ? argv[i + 1] : argv.map { |a| a[/\A--max=(.*)\z/, 1] }.compact.first
    return DEFAULT_MAX unless i || raw

    value = Float(raw.to_s, exception: false)
    return value if value && value.finite? && value.positive?

    warn "load.rb: ignoring --max #{raw.inspect} (want a positive number); using #{DEFAULT_MAX}"
    DEFAULT_MAX
  end

  def main(argv)
    line, code = check(load: read_load, cores: Etc.nprocessors, max: max_from(argv))
    puts line
    exit code
  end
end

FlowLoad.main(ARGV) if $PROGRAM_NAME == __FILE__
