# frozen_string_literal: true

# ruby test/effort_test.rb — the flow:effort script against a fake transcript
# tree. Stdlib only, like the script.
require "minitest/autorun"
require "fileutils"
require "json"
require "tmpdir"
require_relative "../plugins/flow/skills/effort/effort"

class EffortTest < Minitest::Test
  BRANCH = "issue-42-fix-the-thing"
  REPO = "/work/acme"

  def setup
    @projects = Dir.mktmpdir("projects")
  end

  def teardown
    FileUtils.rm_rf(@projects)
  end

  def ts(minute)
    format("2026-10-18T10:%02d:00.000Z", minute)
  end

  def usage(input:, read:, output:, write: 0, advisor: nil)
    iterations = [{ "type" => "message", "input_tokens" => input, "cache_read_input_tokens" => read,
                    "cache_creation_input_tokens" => write, "output_tokens" => output }]
    if advisor
      iterations << advisor.merge("type" => "advisor_message", "model" => "claude-fable-5-1",
                                  "cache_read_input_tokens" => 0, "cache_creation_input_tokens" => 0)
    end
    { "input_tokens" => input, "cache_read_input_tokens" => read, "cache_creation_input_tokens" => write,
      "output_tokens" => output, "iterations" => iterations }
  end

  def assistant(minute, id, branch: BRANCH, model: "claude-opus-5-5", content: [], **tokens)
    { "type" => "assistant", "timestamp" => ts(minute), "gitBranch" => branch,
      "message" => { "id" => id, "model" => model, "usage" => usage(**tokens), "content" => content } }
  end

  def user(minute, text, branch: BRANCH)
    { "type" => "user", "timestamp" => ts(minute), "gitBranch" => branch, "message" => { "content" => text } }
  end

  def spawn(id, prompt = nil)
    [{ "type" => "tool_use", "id" => id, "name" => "Agent", "input" => { "prompt" => prompt.to_s } }]
  end

  def bash(id, command)
    [{ "type" => "tool_use", "id" => id, "name" => "Bash", "input" => { "command" => command } }]
  end

  def write(dir, name, rows, meta: nil)
    path = File.join(@projects, dir, name)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, rows.map { |r| JSON.generate(r) }.join("\n") + "\n")
    File.write(path.sub(/\.jsonl\z/, ".meta.json"), JSON.generate(meta)) if meta
    path
  end

  # A session in a worktree of the repository, on the branch: two content
  # blocks of one message (same id, same usage), one call with an advisor
  # consultation, a validator it spawned, an unrelated agent, and rows from
  # before the branch existed.
  def worktree_session
    dir = "#{FlowEffort.slug(REPO)}--claude-worktrees-issue-42"
    write(dir, "s1.jsonl", [
      user(0, "/flow:lfg 42", branch: "main"),
      assistant(0, "msg_0", branch: "main", input: 1, read: 1000, output: 10),
      user(1, "go"),
      assistant(2, "msg_1", input: 2, read: 100, output: 20, content: spawn("toolu_v1")),
      assistant(2, "msg_1", input: 2, read: 100, output: 20),
      assistant(4, "msg_2", input: 3, read: 200, output: 30, advisor: { "input_tokens" => 5000, "output_tokens" => 700 }),
      assistant(30, "msg_3", input: 4, read: 300, output: 40, content: spawn("toolu_x")),
      { "type" => "user", "timestamp" => ts(31), "gitBranch" => BRANCH, "isCompactSummary" => true,
        "message" => { "content" => "summary" } }
    ])
    # An agent's transcript streams: the first line of a message carries the
    # usage so far, the last one the final count and the advisor's iteration.
    partial = assistant(3, "msg_v1", model: "claude-fable-5-1", input: 9, read: 900, output: 8)
    partial["message"]["usage"].delete("iterations")
    write(dir, "s1/subagents/agent-v1.jsonl", [
      user(2, "Validate issue #42"),
      partial,
      assistant(3, "msg_v1", model: "claude-fable-5-1", input: 9, read: 900, output: 90,
                             advisor: { "input_tokens" => 300, "output_tokens" => 30 },
                             content: [{ "type" => "text", "text" => "**PASS WITH NOTES**\n\nRisks: …" }])
    ], meta: { "agentType" => "flow:fable-validator", "toolUseId" => "toolu_v1" })
    write(dir, "s1/subagents/agent-other.jsonl", [
      user(5, "Something else entirely", branch: "main"),
      assistant(6, "msg_o1", branch: "main", input: 1, read: 1, output: 1)
    ], meta: { "agentType" => "Explore", "toolUseId" => "toolu_unrelated" })
  end

  # An orchestrator in the main checkout: its rows record its own branch; the
  # agent it briefed names this branch, and that agent's validator follows it.
  def orchestrator_session
    dir = FlowEffort.slug(REPO)
    brief = [{ "type" => "tool_use", "id" => "toolu_ft", "name" => "Agent", "input" => { "prompt" => "branch #{BRANCH}" } }]
    write(dir, "o1.jsonl", [
      { "type" => "bridge-session", "bridgeSessionId" => "cse_01ORCH" },
      user(40, "/flow:follow-through 42", branch: "main"),
      assistant(40, "msg_orch", branch: "main", input: 1, read: 50_000, output: 500, content: brief),
      assistant(45, "msg_orch2", branch: "main", input: 1, read: 50_000, output: 500, content: spawn("toolu_dry"))
    ])
    write(dir, "o1/subagents/agent-dry.jsonl", [
      user(45, "Dry-run the next epic", branch: "main"),
      assistant(46, "msg_dry", branch: "main", input: 1, read: 1, output: 1)
    ], meta: { "agentType" => "general-purpose", "toolUseId" => "toolu_dry" })
    write(dir, "o1/subagents/agent-ft.jsonl", [
      user(41, "You are running issue #42.\nYour worktree: #{REPO}/.claude/worktrees/follow-42 (branch #{BRANCH})",
           branch: "main"),
      assistant(42, "msg_ft1", branch: "main", input: 1, read: 400, output: 50, content: spawn("toolu_nested")),
      assistant(45, "msg_ft2", branch: "main", input: 1, read: 400, output: 50,
                               content: bash("toolu_c", "git -C #{REPO}/.claude/worktrees/follow-42 commit -m fix"))
    ], meta: { "agentType" => "general-purpose", "toolUseId" => "toolu_ft" })
    write(dir, "o1/subagents/agent-nested.jsonl", [
      user(43, "Validate issue #42", branch: "main"),
      assistant(44, "msg_n1", branch: "main", model: "claude-fable-5-1", input: 1, read: 10, output: 5,
                              content: [{ "type" => "text", "text" => "**BLOCK**\n\nBlockers: …" }])
    ], meta: { "agentType" => "flow:fable-validator", "toolUseId" => "toolu_nested" })
  end

  def pick(**opts)
    found = FlowEffort.find_sessions(projects: @projects, repo_root: REPO, branch: BRANCH,
                                     bridge_ids: opts.fetch(:bridge_ids, []), explicit: opts.fetch(:explicit, []),
                                     floor: opts[:floor], same_repo: opts.fetch(:same_repo, ->(_cwd) { false }))
    FlowEffort.pick(found, branch: BRANCH, since: opts[:since], till: opts[:till])
  end

  # Another clone of the repository (acme-2) counts; a different repository
  # whose path starts the same (acme2) does not, whatever its branch is called.
  def test_a_sibling_checkout_counts_only_when_it_is_the_same_repository
    %w[/work/acme2 /work/acme-2].each do |cwd|
      write(FlowEffort.slug(cwd), "sib.jsonl", [
        assistant(1, "msg_#{cwd}", input: 1, read: 0, output: 1).merge("cwd" => cwd)
      ])
    end
    picked = pick(same_repo: ->(cwd) { cwd == "/work/acme-2" })

    assert_equal ["#{FlowEffort.slug('/work/acme-2')}/sib.jsonl"],
                 picked.map { |p| p.transcript.path.delete_prefix("#{@projects}/") }
  end

  # The floor bounds only the scan for trailers across every checkout: a
  # session in this repository that ended long before the first commit counts.
  def test_an_old_session_of_this_repository_is_not_cut_by_the_floor
    worktree_session
    old = Time.now - 10 * 86_400
    Dir.glob(File.join(@projects, "**", "*.jsonl")).each { |f| File.utime(old, old, f) }

    assert_equal ["main", "flow:fable-validator"], pick(floor: Time.now).map(&:role)
  end

  def line(lines, role, model)
    lines.fetch([role, model])
  end

  def test_counts_a_message_once_and_the_advisor_beside_it
    worktree_session
    lines = FlowEffort.token_lines(pick)

    main = line(lines, "main", "claude-opus-5-5")
    assert_equal 3, main[:calls]
    assert_equal 2 + 100 + 3 + 200 + 4 + 300, main[:input]
    assert_equal 600, main[:cache_read]
    assert_equal 90, main[:output]

    # The top-level usage of msg_2 is its "message" iteration alone; the
    # advisor's iteration is its own model's and adds to the total, booked to
    # whoever consulted it.
    assert_equal [1, 5000, 700], line(lines, "advisor:main", "claude-fable-5-1").values_at(:calls, :input, :output)
    assert_equal [1, 300, 30],
                 line(lines, "advisor:flow:fable-validator", "claude-fable-5-1").values_at(:calls, :input, :output)
  end

  def test_takes_a_streamed_message_at_its_last_line
    worktree_session
    validator = line(FlowEffort.token_lines(pick), "flow:fable-validator", "claude-fable-5-1")

    assert_equal [1, 909, 90], validator.values_at(:calls, :input, :output)
  end

  def test_takes_the_branchs_rows_and_the_agents_they_spawned
    worktree_session
    picked = pick

    assert_equal ["main", "flow:fable-validator"], picked.map(&:role)
    refute(picked.flat_map(&:rows).any? { |r| r.branch == "main" })
    refute_includes FlowEffort.token_lines(picked).keys, ["Explore", "claude-opus-5-5"]
  end

  def test_follows_an_agent_briefed_with_the_branch_and_the_agents_it_spawned
    orchestrator_session
    picked = pick

    assert_equal %w[flow:fable-validator general-purpose], picked.map(&:role).sort
    refute_includes FlowEffort.token_lines(picked).keys, ["main", "claude-opus-5-5"]
    assert_equal ["BLOCK"], FlowEffort.verdicts(picked)
  end

  # The agent's commits carry the orchestrator's session id: the trailer must
  # not turn the orchestrator's own rows, or its other agents, into this work.
  def test_a_trailer_naming_an_orchestrator_counts_only_its_briefed_agent
    orchestrator_session
    picked = pick(bridge_ids: ["session_01ORCH"])

    assert_equal %w[agent-ft.jsonl agent-nested.jsonl], picked.map { |p| File.basename(p.transcript.path) }.sort
  end

  def test_a_session_found_only_by_mentioning_the_branch_counts_nothing
    write(FlowEffort.slug(REPO), "x1.jsonl", [
      user(0, "git worktree list shows #{BRANCH}", branch: "main"),
      assistant(1, "msg_x", branch: "main", input: 1, read: 1, output: 1)
    ])

    assert_empty pick
  end

  # Work on a branch of another repository, from a session whose checkout is
  # elsewhere: the commits' Claude-Session trailer names the session, and its
  # rows count from the first that names the branch.
  def test_a_session_named_by_a_trailer_counts_from_the_first_mention
    write("-elsewhere", "t1.jsonl", [
      { "type" => "bridge-session", "bridgeSessionId" => "cse_01ABC" },
      user(0, "unrelated work before", branch: "other"),
      assistant(1, "msg_t0", branch: "other", input: 1, read: 1, output: 1),
      user(2, "git switch -c #{BRANCH}", branch: "other"),
      assistant(3, "msg_t1", branch: "other", input: 7, read: 70, output: 700)
    ])
    lines = FlowEffort.token_lines(pick(bridge_ids: ["session_01ABC"]))

    assert_equal [1, 77, 700], line(lines, "main", "claude-opus-5-5").values_at(:calls, :input, :output)
  end

  def test_an_explicit_session_counts_whole_within_the_window
    write("-elsewhere", "e1.jsonl", [
      assistant(1, "msg_e0", branch: "other", input: 1, read: 0, output: 1),
      assistant(20, "msg_e1", branch: "other", input: 2, read: 0, output: 2)
    ])
    lines = FlowEffort.token_lines(pick(explicit: ["e1"], since: Time.iso8601(ts(10))))

    assert_equal [1, 2], line(lines, "main", "claude-opus-5-5").values_at(:calls, :output)
  end

  # Work on another repository's branch from this checkout's session, with a
  # validator briefed with the branch: the session did the work (its agent
  # never commits), so it is no orchestrator, found by trailer or by hand.
  def worker_elsewhere
    write("-elsewhere", "w2.jsonl", [
      { "type" => "bridge-session", "bridgeSessionId" => "cse_01WORK" },
      assistant(1, "msg_g0", branch: "other", input: 1, read: 0, output: 1),
      assistant(5, "msg_g1", branch: "other", input: 1, read: 0, output: 2,
                             content: bash("toolu_g", "git worktree add -b #{BRANCH} /tmp/x origin/main")),
      assistant(8, "msg_g2", branch: "other", input: 1, read: 0, output: 4,
                             content: spawn("toolu_gv", "Validate branch #{BRANCH}")),
      assistant(9, "msg_g3", branch: "other", input: 1, read: 0, output: 8,
                             content: bash("toolu_gc", "git commit -m feat"))
    ])
    write("-elsewhere", "w2/subagents/agent-gv.jsonl", [
      user(8, "Validate branch #{BRANCH}", branch: "other"),
      assistant(9, "msg_gv", branch: "other", model: "claude-fable-5-1", input: 1, read: 0, output: 16,
                             content: [{ "type" => "text", "text" => "**PASS**" }])
    ], meta: { "agentType" => "flow:fable-validator", "toolUseId" => "toolu_gv" })
  end

  def test_a_session_that_briefed_a_validator_is_no_orchestrator
    worker_elsewhere
    by_trailer = FlowEffort.token_lines(pick(bridge_ids: ["session_01WORK"]))
    by_hand = FlowEffort.token_lines(pick(explicit: ["w2"], since: Time.iso8601(ts(0))))

    assert_equal [3, 14], line(by_trailer, "main", "claude-opus-5-5").values_at(:calls, :output)
    assert_equal [4, 15], line(by_hand, "main", "claude-opus-5-5").values_at(:calls, :output)
    assert_equal 16, line(by_hand, "flow:fable-validator", "claude-fable-5-1")[:output]
  end

  # A session whose rows record no branch at all (an older Claude Code) is
  # reported, not silently dropped.
  def test_reports_a_transcript_that_records_no_branch
    row = assistant(1, "msg_nb", input: 1, read: 0, output: 1, content: bash("toolu_nb", "git switch #{BRANCH}"))
    row.delete("gitBranch")
    write(FlowEffort.slug(REPO), "nb.jsonl", [row])
    found = FlowEffort.find_sessions(projects: @projects, repo_root: REPO, branch: BRANCH, bridge_ids: [],
                                     explicit: [], same_repo: ->(_cwd) { false })

    assert_empty FlowEffort.pick(found, branch: BRANCH)
    assert_equal [File.join(@projects, FlowEffort.slug(REPO), "nb.jsonl")], FlowEffort.unbranched(found, branch: BRANCH)
  end

  def test_a_mention_is_the_branch_name_as_a_word
    assert FlowEffort.mentions?(%("git switch fix\\n"), "fix")
    assert FlowEffort.mentions?(%("git push origin/feat/x"), "feat/x")
    refute FlowEffort.mentions?(%("the prefix is fixture"), "fix")
    refute FlowEffort.mentions?(%("feat/x-2 is another"), "feat/x")
  end

  # Named and timed by hand: the time wins over the first mention.
  def test_an_explicit_session_with_since_counts_from_since
    write("-elsewhere", "e2.jsonl", [
      assistant(1, "msg_f0", branch: "other", input: 1, read: 0, output: 1),
      assistant(12, "msg_f1", branch: "other", input: 2, read: 0, output: 2),
      user(20, "git switch -c #{BRANCH}", branch: "other"),
      assistant(21, "msg_f2", branch: "other", input: 3, read: 0, output: 4)
    ])
    lines = FlowEffort.token_lines(pick(explicit: ["e2"], since: Time.iso8601(ts(10))))

    assert_equal [2, 6], line(lines, "main", "claude-opus-5-5").values_at(:calls, :output)
  end

  def test_leaves_out_what_comes_after_the_merge
    worktree_session
    lines = FlowEffort.token_lines(pick(till: Time.iso8601(ts(10))))

    assert_equal 2, line(lines, "main", "claude-opus-5-5")[:calls]
  end

  def row(second, assistant: false, waits: false)
    FlowEffort::Row.new(time: Time.at(second), assistant: assistant, waits: waits)
  end

  def test_active_time_leaves_out_a_long_gap
    assert_equal 180, FlowEffort.active_seconds([[0, 60, 120, 1320, 1380].map { |s| row(s) }])
  end

  # ScheduleWakeup, then its result, the wake-up prompt five minutes later and
  # the next action: waiting until that action, however short.
  def test_active_time_leaves_out_a_wait_on_ci
    rows = [row(0, assistant: true), row(30), row(40, assistant: true, waits: true), row(41), row(340),
            row(350, assistant: true), row(410)]

    assert_equal 30 + 10 + 60, FlowEffort.active_seconds([rows])
  end

  # One message, two parallel calls in two lines, only the first waits: the
  # message waits. Same-millisecond lines keep their file order.
  def test_a_wait_holds_for_every_line_of_its_message
    waits = FlowEffort::Row.new(time: Time.at(40), assistant: true, waits: true, usage_id: "m1")
    sibling = FlowEffort::Row.new(time: Time.at(40), assistant: true, waits: false, usage_id: "m1")
    rows = [row(0, assistant: true), waits, sibling, row(41), row(340), row(350, assistant: true), row(410)]

    assert_equal 40 + 60, FlowEffort.active_seconds([rows])
  end

  # The main session waits on CI while a validator works: that time is work.
  def test_active_time_counts_an_agent_working_through_a_wait
    main = [row(0, assistant: true, waits: true), row(1), row(300), row(310, assistant: true), row(320)]
    agent = [row(10), row(70), row(130), row(190), row(250)]

    assert_equal 240 + 10, FlowEffort.active_seconds([main, agent])
    assert_equal 120, FlowEffort.active_seconds([main, agent], before: Time.at(130))
  end

  def test_marks_the_calls_that_wait
    dir = "#{FlowEffort.slug(REPO)}--claude-worktrees-issue-42"
    calls = [["ScheduleWakeup", {}], ["Bash", { "command" => "gh pr checks 12 --watch --fail-fast" }],
             ["Bash", { "command" => "gh run watch 99 --exit-status" }], ["Bash", { "command" => "bundle exec rspec" }]]
    rows = calls.each_with_index.map do |(name, input), i|
      assistant(i, "msg_w#{i}", input: 1, read: 0, output: 1,
                                content: [{ "type" => "tool_use", "id" => "toolu_w#{i}", "name" => name, "input" => input }])
    end
    transcript = FlowEffort::Transcript.new(write(dir, "w1.jsonl", rows), BRANCH)

    assert_equal [true, true, true, false], transcript.rows.map(&:waits)
  end

  def test_counts_compactions
    worktree_session

    assert_equal 1, FlowEffort.compactions(pick)
  end

  def test_parses_the_last_estimate_table
    text = <<~MD
      ## Estimate

      | | Estimate |
      |---|---|
      | Size | L |

      ## Estimate

      | | Estimate |
      |---|---|
      | **Size** | M — two subsystems |
      | Active time | 2–4 h |
      | Validation passes | ~2 |
      | Review rounds | 1 to 3 |
      | Files | 6-10 |
      | Would grow if | the dashboard path is in scope |

      ## Out of scope
    MD

    assert_equal({ size: "M", active_hours: [2.0, 4.0], validation_passes: [2.0, 2.0], review_rounds: [1.0, 3.0],
                   files: [6.0, 10.0] }, FlowEffort.parse_estimate(text))
  end

  def test_reads_minutes_and_finds_nothing_without_a_table
    assert_equal [0.75, 0.75], FlowEffort.parse_estimate("## Estimate\n| Active time | 45 min |\n")[:active_hours]
    assert_nil FlowEffort.parse_estimate("## Summary\nNo estimate here.")
  end

  def test_deviation
    assert_equal "within", FlowEffort.deviation([2.0, 4.0], 3.1)
    assert_equal "+15 %", FlowEffort.deviation([2.0, 4.0], 4.6)
    assert_equal "×5.5", FlowEffort.deviation([1.0, 2.0], 11)
    assert_equal "−50 %", FlowEffort.deviation([2.0, 4.0], 1.0)
    assert_equal "—", FlowEffort.deviation(nil, 3)
    assert_equal "+2 sizes", FlowEffort.size_deviation("S", "L")
    assert_equal "within", FlowEffort.size_deviation("M", "M")
    assert_equal "L", FlowEffort.size_for(4.6)
    assert_equal "XS", FlowEffort.size_for(0.2)
  end

  def test_verdict
    assert_equal "PASS WITH NOTES", FlowEffort.verdict("**PASS WITH NOTES**\n\nRisks")
    assert_equal "PASS", FlowEffort.verdict("PASS — checked the specs")
    assert_equal "?", FlowEffort.verdict(nil)
  end

  def section(text = "new")
    "#{FlowEffort::START_MARK}\n#{text}\n#{FlowEffort::END_MARK}"
  end

  def test_inserts_the_section_before_the_deviations
    body = "## Summary\n\nx\n\n## Deviations & judgment calls\n\nNone.\n\nhttps://claude.ai/code/session_1\n"
    out = FlowEffort.splice(body, section)

    assert_match(/## Summary\n\nx\n\n## Effort & cost\n\n#{Regexp.escape(section)}\n\n## Deviations/, out)
  end

  def test_replaces_only_between_the_markers
    body = "## Effort & cost\n\n#{section("old")}\n\n**Where it went:** prose.\n\n" \
           "<!-- This is an auto-generated description by cubic. -->\nbot\n"
    out = FlowEffort.splice(body, section)

    assert_includes out, "#{section}\n\n**Where it went:** prose."
    refute_includes out, "old"
    assert_includes out, "auto-generated description by cubic. -->\nbot"
    assert_equal out, FlowEffort.splice(out, section)
  end

  # A hand-edit that lost the end marker: the section is replaced up to the
  # next one, not written twice.
  def test_replaces_a_section_whose_end_marker_was_lost
    body = "## Effort & cost\n\n#{FlowEffort::START_MARK}\nold numbers\n\n## Deviations & judgment calls\n\nNone.\n"
    out = FlowEffort.splice(body, section)

    assert_equal 1, out.scan(FlowEffort::START_MARK).size
    assert_includes out, "#{section}\n\n## Deviations & judgment calls\n\nNone."
    refute_includes out, "old numbers"
  end

  def test_inserts_before_the_session_link_or_a_bot_block_otherwise
    assert_match(/x\n\n## Effort & cost\n\n.*\n\nhttps:\/\/claude/m,
                 FlowEffort.splice("x\n\nhttps://claude.ai/code/session_1\n", section))
    assert_match(/x\n\n## Effort & cost\n\n.*\n\n<!-- This is an auto-generated/m,
                 FlowEffort.splice("x\n\n<!-- This is an auto-generated description by cubic. -->\n", section))
    assert_equal "x\n\n## Effort & cost\n\n#{section}\n", FlowEffort.splice("x\n", section)
  end

  # /flow:effort passes its arguments as typed: "570 --write", "#570", "PR570".
  def test_a_bare_pr_number_is_the_pr
    assert_equal 570, FlowEffort.options(%w[570 --write])[:pr]
    assert_equal 570, FlowEffort.options(["#570"])[:pr]
    assert_equal 570, FlowEffort.options(%w[--pr #570])[:pr]
    assert_equal 570, FlowEffort.options(%w[PR570])[:pr]
    assert_raises(OptionParser::InvalidArgument) { FlowEffort.options(%w[570 571]) }
  end

  def test_the_data_comment_cannot_close_early
    comment = FlowEffort.data_comment("branch" => "a-->b")

    assert_equal 1, comment.scan("-->").size
    assert_equal({ "branch" => "a-->b" }, FlowEffort.read_data(comment))
  end
end
