# frozen_string_literal: true

# ruby test/rigor_test.rb — the flow rigor classifier against throw-away git
# repositories. Stdlib only, like the script.
require "minitest/autorun"
require "fileutils"
require "json"
require "open3"
require "tmpdir"
require_relative "../plugins/flow/skills/lfg/rigor"

class RigorTest < Minitest::Test
  CONFIG = <<~YAML
    version: 1
    default: standard
    critical:
      paths:
        - "app/services/payments/"
        - "db/migrate/**"
        - "app/models/{account,posting}.rb"
      signals:
        - "with_lock"
        - { pattern: "_cents\\\\b", paths: ["app/**"] }
      labels: ["risk:high"]
    light:
      paths:
        - "docs/**"
        - "**/*.md"
        - "config/locales/**/*.{fr,af}.yml"
        - ".i18n-state/"
  YAML

  AGENTS = <<~MD
    # Project

    ## Workflow

    - **Verify:** `bin/check`
    - **Rigor:** `.github/review-rigor.yml`
  MD

  def setup
    @dir = Dir.mktmpdir("rigor")
    git("init", "-q", "-b", "main")
    git("config", "user.email", "test@example.com")
    git("config", "user.name", "Test")
    git("config", "commit.gpgsign", "false")
    write("README.md", "hello\n")
    write("app/services/payments/charge.rb", "class Charge; end\n")
    write("app/models/account.rb", "class Account; end\n")
    write("app/models/user.rb", "class User; end\n")
    write("docs/guide.md", "guide\n")
    write("spec/user_spec.rb", "describe User\n")
    commit("base")
    git("update-ref", "refs/remotes/origin/main", "HEAD")
    git("switch", "-q", "-c", "work")
  end

  def teardown
    FileUtils.rm_rf(@dir)
  end

  def git(*args)
    out, status = Open3.capture2e("git", "-C", @dir, *args)
    raise "git #{args.join(' ')}: #{out}" unless status.success?

    out
  end

  def write(path, text)
    full = File.join(@dir, path)
    FileUtils.mkdir_p(File.dirname(full))
    File.write(full, text)
  end

  def commit(message)
    git("add", "-A")
    git("commit", "-q", "-m", message)
  end

  def configure(config = CONFIG, agents = AGENTS)
    write(".github/review-rigor.yml", config) if config
    write("AGENTS.md", agents) if agents
    commit("configure")
    git("update-ref", "refs/remotes/origin/main", "HEAD")
  end

  def classify(**options)
    FlowRigor.classify(root: @dir, base: "origin/main", **options)
  end

  # --- fallbacks: every unknown state is critical, today's behaviour --------

  def test_no_workflow_line_is_critical_with_a_warning
    configure(CONFIG, "# Project\n\n## Workflow\n\n- **Verify:** `bin/check`\n")
    write("docs/guide.md", "changed\n")
    result = classify
    assert_equal "critical", result.tier
    assert_equal "fallback", result.reasons.first[:kind]
    assert_match(/no Rigor line/, result.warnings.join)
  end

  def test_no_agents_md_is_critical
    configure(CONFIG, nil)
    write("docs/guide.md", "changed\n")
    assert_equal "critical", classify.tier
  end

  def test_a_named_file_that_does_not_exist_is_critical
    configure(nil, AGENTS)
    write("docs/guide.md", "changed\n")
    result = classify
    assert_equal "critical", result.tier
    assert_match(/review-rigor\.yml/, result.warnings.join)
  end

  def test_bad_yaml_is_critical
    configure("version: 1\ndefault: [standard\n")
    write("docs/guide.md", "changed\n")
    assert_equal "critical", classify.tier
  end

  def test_an_unknown_tier_word_is_critical
    configure(CONFIG.sub("default: standard", "default: relaxed"))
    write("docs/guide.md", "changed\n")
    result = classify
    assert_equal "critical", result.tier
    assert_match(/relaxed/, result.warnings.join)
  end

  def test_an_unknown_version_is_critical
    configure(CONFIG.sub("version: 1", "version: 2"))
    write("docs/guide.md", "changed\n")
    assert_equal "critical", classify.tier
  end

  def test_a_bad_regex_is_critical
    configure(CONFIG.sub('"with_lock"', '"with_(lock"'))
    write("docs/guide.md", "changed\n")
    result = classify
    assert_equal "critical", result.tier
    assert_match(/with_\(lock/, result.warnings.join)
  end

  def test_a_bad_base_is_critical
    configure
    write("docs/guide.md", "changed\n")
    result = FlowRigor.classify(root: @dir, base: "origin/nope")
    assert_equal "critical", result.tier
    assert_match(/origin\/nope/, result.warnings.join)
  end

  def test_an_explicit_config_path_wins_over_agents_md
    configure(CONFIG, nil)
    write("docs/guide.md", "changed\n")
    assert_equal "light", classify(config: File.join(@dir, ".github/review-rigor.yml")).tier
  end

  # --- path rules ------------------------------------------------------------

  def test_an_empty_change_is_the_default
    configure
    result = classify
    assert_equal "standard", result.tier
    assert_equal "default", result.reasons.first[:kind]
  end

  def test_a_docs_only_change_is_light
    configure
    write("docs/guide.md", "changed\n")
    write("docs/new/page.md", "new\n")
    assert_equal "light", classify.tier
  end

  def test_light_plus_an_unmatched_file_is_the_default
    configure
    write("docs/guide.md", "changed\n")
    write("spec/user_spec.rb", "describe User do\nend\n")
    assert_equal "standard", classify.tier
  end

  def test_a_critical_path_among_light_files_is_critical
    configure
    write("docs/guide.md", "changed\n")
    write("app/services/payments/charge.rb", "class Charge\n  def call; end\nend\n")
    result = classify
    assert_equal "critical", result.tier
    reason = result.reasons.find { |r| r[:tier] == "critical" }
    assert_equal({ tier: "critical", kind: "path", match: "app/services/payments/", file: "app/services/payments/charge.rb" }, reason)
  end

  def test_a_file_matching_two_tiers_takes_the_higher
    configure(CONFIG.sub('- "docs/**"', "- \"docs/**\"\n    - \"app/services/payments/README.md\""))
    write("app/services/payments/README.md", "notes\n")
    assert_equal "critical", classify.tier
  end

  def test_a_deleted_critical_file_is_critical
    configure
    git("rm", "-q", "app/models/account.rb")
    assert_equal "critical", classify.tier
  end

  def test_a_rename_out_of_a_critical_path_is_critical
    configure
    FileUtils.mkdir_p(File.join(@dir, "lib"))
    git("mv", "app/services/payments/charge.rb", "lib/charge.rb")
    assert_equal "critical", classify.tier
  end

  def test_a_committed_change_counts
    configure
    write("db/migrate/20261104_add.rb", "class Add; end\n")
    commit("migration")
    assert_equal "critical", classify.tier
  end

  def test_an_untracked_file_counts
    configure
    write("db/migrate/20261104_add.rb", "class Add; end\n")
    assert_equal "critical", classify.tier
  end

  def test_glob_forms
    rule = ->(pattern, path) { FlowRigor.glob_match?(pattern, path) }
    assert rule.call("docs/", "docs/a/b.md"), "trailing slash is the whole directory"
    assert rule.call("docs/**", "docs/a/b.md"), "dir/** crosses directories"
    assert rule.call("docs/**", "docs/b.md")
    refute rule.call("docs/**", "docsx/b.md")
    assert rule.call("**/*.md", "README.md"), "**/ matches zero directories"
    assert rule.call("**/*.md", "app/models/MEMORY.md")
    assert rule.call("app/models/{account,posting}.rb", "app/models/posting.rb")
    refute rule.call("app/models/{account,posting}.rb", "app/models/user.rb")
    assert rule.call(".i18n-state/", ".i18n-state/a/b.json"), "dotfiles match"
    assert rule.call("config/deploy*.yml", "config/deploy.ma-staging.yml")
    refute rule.call("config/*.yml", "config/locales/en.yml"), "a single star stays in its directory"
    assert rule.call("app/models/account.rb", "app/models/account.rb"), "an exact path"
  end

  # --- signals and labels ----------------------------------------------------

  def test_an_added_line_matching_a_signal_raises_a_light_change
    configure
    write("docs/guide.md", "call with_lock here\n")
    result = classify
    assert_equal "critical", result.tier
    assert(result.reasons.any? { |r| r[:kind] == "signal" && r[:match] == "with_lock" && r[:file] == "docs/guide.md" })
  end

  def test_a_removed_line_matching_a_signal_does_not_raise
    write("docs/old.md", "with_lock was here\n")
    commit("old")
    configure
    write("docs/old.md", "gone\n")
    assert_equal "light", classify.tier
  end

  def test_a_scoped_signal_outside_its_paths_does_not_raise
    configure
    write("spec/user_spec.rb", "let(:amount_cents) { 100 }\n")
    assert_equal "standard", classify.tier
  end

  def test_a_scoped_signal_inside_its_paths_raises
    configure
    write("app/models/user.rb", "class User\n  attribute :amount_cents\nend\n")
    result = classify
    assert_equal "critical", result.tier
    assert(result.reasons.any? { |r| r[:kind] == "signal" && r[:file] == "app/models/user.rb" })
  end

  def test_a_signal_in_an_untracked_file_raises
    configure
    write("app/models/wallet.rb", "class Wallet\n  def pay = with_lock { }\nend\n")
    assert_equal "critical", classify.tier
  end

  def test_a_signal_in_a_tracked_path_with_a_space_raises
    write("lib/sp ace.rb", "x\n")
    commit("space")
    configure(CONFIG.sub("default: standard", "default: light"))
    write("lib/sp ace.rb", "x\nwith_lock { }\n")
    assert_equal "critical", classify.tier
  end

  def test_a_signal_in_a_tracked_path_with_a_quote_raises
    write("lib/qu\"ote.rb", "x\n")
    commit("quote")
    configure(CONFIG.sub("default: standard", "default: light"))
    write("lib/qu\"ote.rb", "x\nwith_lock { }\n")
    assert_equal "critical", classify.tier
  end

  def test_an_added_line_that_looks_like_a_diff_header_keeps_its_file
    write("docs/notes.md", "start\n")
    commit("notes")
    configure
    write("docs/notes.md", "start\n++ b/lib/other.rb\nwith_lock { }\n")
    result = classify
    assert_equal "critical", result.tier
    assert(result.reasons.any? { |r| r[:kind] == "signal" && r[:file] == "docs/notes.md" })
  end

  def test_latin1_content_is_read_not_a_fallback
    File.binwrite(File.join(@dir, "docs/latin.md"), "caf\xE9\n".b)
    commit("latin")
    configure
    File.binwrite(File.join(@dir, "docs/latin.md"), "caf\xE9 au lait\n".b)
    result = classify
    assert_equal "light", result.tier
    assert_empty result.warnings
  end

  def test_a_path_that_is_not_utf8_is_critical
    configure
    name = "docs/bad\xFF.md".b
    begin
      File.binwrite(File.join(@dir.b, name), "x\n")
    rescue SystemCallError
      skip "this filesystem refuses non-UTF-8 names"
    end
    assert_equal "critical", classify.tier
  end

  def test_a_root_below_the_toplevel_still_sees_every_signal
    configure
    write("app/models/user.rb", "class User\n  def pay = with_lock { }\nend\n")
    write("db/migrate/20261104_add.rb", "class Add; end\n")
    result = classify(root: File.join(@dir, "docs"), config: File.join(@dir, ".github/review-rigor.yml"))
    assert_equal "critical", result.tier
    assert(result.reasons.any? { |r| r[:kind] == "signal" && r[:file] == "app/models/user.rb" })
    assert(result.reasons.any? { |r| r[:kind] == "path" && r[:file] == "db/migrate/20261104_add.rb" })
  end

  def test_a_pure_rename_adds_no_lines
    write("docs/old.md", "uses with_lock\n")
    commit("old")
    configure
    git("mv", "docs/old.md", "docs/new.md")
    assert_equal "light", classify.tier
  end

  def test_a_rename_with_an_edit_adds_only_the_new_line
    write("docs/old.md", "one\ntwo\nthree\nfour\nfive\n")
    commit("old")
    configure
    git("mv", "docs/old.md", "docs/new.md")
    write("docs/new.md", "one\ntwo\nthree\nfour\nfive\nwith_lock\n")
    result = classify
    assert_equal "critical", result.tier
    assert(result.reasons.any? { |r| r[:kind] == "signal" && r[:file] == "docs/new.md" })
  end

  def test_a_label_raises
    configure
    write("docs/guide.md", "changed\n")
    result = classify(labels: %w[docs risk:high])
    assert_equal "critical", result.tier
    assert(result.reasons.any? { |r| r[:kind] == "label" && r[:match] == "risk:high" })
  end

  def test_an_unrelated_label_does_not_raise
    configure
    write("docs/guide.md", "changed\n")
    assert_equal "light", classify(labels: %w[docs]).tier
  end

  # --- planned files (no diff yet) ------------------------------------------

  def test_files_from_a_list
    configure
    assert_equal "critical", classify(files: ["docs/x.md", "app/services/payments/refund.rb"]).tier
    assert_equal "light", classify(files: ["docs/x.md"]).tier
    assert_equal "standard", classify(files: []).tier
  end

  def test_files_from_a_list_check_no_signals
    configure
    result = classify(files: ["docs/x.md"])
    assert_match(/signals not checked/, result.warnings.join)
  end

  # --- output ----------------------------------------------------------------

  def test_summary_line
    configure
    write("app/services/payments/charge.rb", "class Charge\n  def call; end\nend\n")
    result = classify
    assert_equal "Rigor: critical — path app/services/payments/ (app/services/payments/charge.rb)", FlowRigor.summary(result)
  end

  def test_summary_counts_the_rest
    configure
    write("app/services/payments/a.rb", "a\n")
    write("app/services/payments/b.rb", "b\n")
    write("app/services/payments/c.rb", "c\n")
    write("app/services/payments/d.rb", "d\n")
    assert_match(/\+2 more\z/, FlowRigor.summary(classify))
  end

  def test_summary_of_a_fallback_names_why
    configure(CONFIG, "# no workflow\n")
    assert_match(/\ARigor: critical — fallback: no Rigor line/, FlowRigor.summary(classify))
  end

  def test_the_command_line
    configure
    write("docs/guide.md", "changed\n")
    out, err, status = Open3.capture3("ruby", script, "--base", "origin/main", chdir: @dir)
    assert status.success?, err
    assert_equal "light\n", out

    out, = Open3.capture3("ruby", script, "--base", "origin/main", "--json", "--labels", "risk:high", chdir: @dir)
    data = JSON.parse(out)
    assert_equal "critical", data["tier"]
    assert_equal "standard", data["default"]
    assert(data["reasons"].any? { |r| r["kind"] == "label" })

    out, = Open3.capture3("ruby", script, "--files", "-", chdir: @dir, stdin_data: "app/models/posting.rb\n")
    assert_equal "critical\n", out

    out, = Open3.capture3("ruby", script, "--base", "origin/main", "--summary", chdir: @dir)
    assert_equal "Rigor: light — path docs/** (docs/guide.md)\n", out
  end

  def test_an_argument_that_is_not_utf8_prints_critical
    configure
    out, _, status = Open3.capture3({ "LC_ALL" => "C" }, "ruby", script, "--base", "origin/\xFF".b, chdir: @dir)
    assert_equal 0, status.exitstatus
    assert_equal "critical\n", out
  end

  def test_an_unknown_flag_is_a_usage_error
    _, err, status = Open3.capture3("ruby", script, "--nope", chdir: @dir)
    assert_equal 2, status.exitstatus
    assert_match(/usage/i, err)
  end

  def test_outside_a_repository_prints_critical_and_exits_zero
    out, _, status = Open3.capture3("ruby", script, "--base", "origin/main", chdir: Dir.tmpdir)
    assert status.success?
    assert_equal "critical\n", out
  end

  def script
    File.expand_path("../plugins/flow/skills/lfg/rigor.rb", __dir__)
  end
end
