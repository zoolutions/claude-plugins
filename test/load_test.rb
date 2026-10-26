# frozen_string_literal: true

# ruby test/load_test.rb — the flow load check against a stubbed load average
# and core count. Stdlib only, like the script.
require "minitest/autorun"
require "tmpdir"
require_relative "../plugins/flow/skills/follow-through/load"

class LoadTest < Minitest::Test
  def check(load, cores: 12, max: FlowLoad::DEFAULT_MAX)
    FlowLoad.check(load: load, cores: cores, max: max)
  end

  def test_ok_under_the_threshold
    assert_equal ["load 2.4 / 12 cores (0.20×) — ok", 0], check(2.44)
  end

  def test_busy_over_the_threshold
    assert_equal ["load 28.2 / 12 cores (2.35×) — busy", 3], check(28.2)
  end

  def test_exactly_at_the_threshold_is_ok
    assert_equal ["load 18.0 / 12 cores (1.50×) — ok", 0], check(18.0)
  end

  def test_just_over_the_threshold_is_busy
    assert_equal 3, check(18.1).last
  end

  def test_a_custom_max_load
    assert_equal ["load 28.2 / 12 cores (2.35×) — ok", 0], check(28.2, max: 2.5)
    assert_equal 3, check(28.2, max: 2.0).last
  end

  def test_unreadable_load_is_unknown_and_never_blocks
    assert_equal ["load unknown / 12 cores — unknown", 0], check(nil)
  end

  def test_unknown_core_count_is_unknown
    assert_equal ["load 2.4 / ? cores — unknown", 0], check(2.44, cores: nil)
  end

  def test_parses_the_macos_sysctl_shape
    assert_in_delta 2.44, FlowLoad.parse("{ 2.44 9.86 15.56 }")
  end

  def test_parses_the_linux_proc_loadavg_shape
    assert_in_delta 0.52, FlowLoad.parse("0.52 0.58 0.59 1/389 12345\n")
  end

  def test_parses_a_comma_decimal
    assert_in_delta 2.44, FlowLoad.parse("{ 2,44 9,86 15,56 }")
  end

  def test_odd_bytes_parse_to_nil
    assert_nil FlowLoad.parse("\xff\xfe load".dup.force_encoding("UTF-8"))
  end

  def test_odd_bytes_in_proc_loadavg_read_nil
    Dir.mktmpdir do |dir|
      path = File.join(dir, "loadavg")
      File.binwrite(path, "\xff\xfe\n")
      assert_nil FlowLoad.read_load(platform: "x86_64-linux", proc_path: path)
    end
  end

  def cpu_max(dir, text)
    path = File.join(dir, "cpu.max")
    File.write(path, text)
    path
  end

  def test_a_cgroup_cpu_quota_lowers_the_core_count
    Dir.mktmpdir do |dir|
      assert_equal 2, FlowLoad.cores(nprocessors: 64, cpu_max_path: cpu_max(dir, "200000 100000\n"))
      assert_equal 2, FlowLoad.cores(nprocessors: 64, cpu_max_path: cpu_max(dir, "150000 100000\n"))
      assert_equal 4, FlowLoad.cores(nprocessors: 4, cpu_max_path: cpu_max(dir, "800000 100000\n"))
    end
  end

  def test_no_cgroup_quota_keeps_the_core_count
    Dir.mktmpdir do |dir|
      assert_equal 12, FlowLoad.cores(nprocessors: 12, cpu_max_path: cpu_max(dir, "max 100000\n"))
      assert_equal 12, FlowLoad.cores(nprocessors: 12, cpu_max_path: cpu_max(dir, "garbage"))
      assert_equal 12, FlowLoad.cores(nprocessors: 12, cpu_max_path: File.join(dir, "missing"))
    end
  end

  def test_garbage_parses_to_nil
    assert_nil FlowLoad.parse("")
    assert_nil FlowLoad.parse(nil)
    assert_nil FlowLoad.parse("sysctl: unknown oid")
  end

  def test_reads_a_proc_loadavg_file_on_linux
    Dir.mktmpdir do |dir|
      path = File.join(dir, "loadavg")
      File.write(path, "3.25 1.00 0.50 2/400 999\n")
      assert_in_delta 3.25, FlowLoad.read_load(platform: "x86_64-linux", proc_path: path)
    end
  end

  def test_a_missing_proc_file_reads_nil
    assert_nil FlowLoad.read_load(platform: "x86_64-linux", proc_path: "/nonexistent/loadavg")
  end

  def test_an_unsupported_platform_reads_nil
    assert_nil FlowLoad.read_load(platform: "x64-mingw32")
  end

  def test_max_option
    assert_in_delta 2.0, FlowLoad.max_from(["--max", "2"])
    assert_in_delta 2.5, FlowLoad.max_from(["--max=2.5"])
    assert_output("", "") { assert_in_delta FlowLoad::DEFAULT_MAX, FlowLoad.max_from([]) }
  end

  def test_a_bad_max_warns_and_uses_the_default
    ["nope", "0", "-1", "Infinity", nil].each do |bad|
      argv = ["--max", bad].compact
      assert_output("", /\Aload\.rb: ignoring --max .*; using 1\.5\n\z/) do
        assert_in_delta FlowLoad::DEFAULT_MAX, FlowLoad.max_from(argv)
      end
    end
  end
end
