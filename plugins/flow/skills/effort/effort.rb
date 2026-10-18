#!/usr/bin/env ruby
# frozen_string_literal: true

# What a pull request (or a branch before it has one) cost: time, tokens per
# role and model, validation passes, review rounds and the diff, against the
# estimate made before the work began. Reads Claude Code's transcripts on this
# machine and, given a PR, GitHub through `gh`. Stdlib only, Ruby >= 2.6.
#
#   effort.rb [--pr N] [--issue N] [--branch NAME] [--base NAME] [--repo OWNER/NAME]
#             [--estimate FILE] [--session ID]... [--since TIME] [--until TIME]
#             [--json] [--write]
#
# The transcript format is Claude Code's own and undocumented. A field this
# cannot read leaves its metric "not measured"; it never fails the caller.

require "json"
require "open3"
require "optparse"
require "set"
require "time"

module FlowEffort
  # A gap longer than this between two transcript entries is waiting (CI, a
  # review bot, a person), not work.
  IDLE_SECONDS = 600
  # Size by active hours; each bound is the exclusive top of its size.
  SIZES = [["XS", 0.5], ["S", 2.0], ["M", 4.0], ["L", 8.0], ["XL", Float::INFINITY]].freeze
  ESTIMATE_ROWS = {
    "size" => :size, "active time" => :active_hours, "validation passes" => :validation_passes,
    "review rounds" => :review_rounds, "files" => :files
  }.freeze
  HEADING = "## Effort & cost"
  START_MARK = "<!-- flow:effort:start -->"
  END_MARK = "<!-- flow:effort:end -->"
  DATA_PREFIX = "<!-- flow:effort "
  # Where a new section goes, first match wins; otherwise at the end.
  INSERT_BEFORE = [
    /^## Deviations & judgment calls/,
    %r{^https://claude\.ai/code/session_},
    /^<!-- This is an auto-generated/
  ].freeze
  PR_FIELDS = %w[number url state createdAt mergedAt closedAt headRefName baseRefName additions deletions
                 changedFiles commits closingIssuesReferences body].join(",")
  THREADS_QUERY = "query($owner: String!, $name: String!, $number: Int!) { repository(owner: $owner, name: $name) " \
                  "{ pullRequest(number: $number) { reviewThreads { totalCount } } } }"
  MERGE_HEADLINE = /\AMerge (remote-tracking )?branch /.freeze
  TRAILER = %r{claude\.ai/code/session_([A-Za-z0-9]+)}.freeze
  # A call that waits on something outside (CI, a review bot): the time until
  # the next action is waiting, however short.
  WAIT_COMMAND = /\bgh\s+(pr\s+checks\b.*--watch|run\s+watch)\b/.freeze
  # A commit: the agent making one does the branch's work (a push may be of
  # another ref, so it says nothing).
  COMMIT_COMMAND = /\bgit\s+(-C\s+\S+\s+)?commit\b/.freeze

  Row = Struct.new(:time, :branch, :mentions, :usage_id, :model, :usage, :advisor, :tool_ids, :compact,
                   :assistant, :waits, :commits, :text, keyword_init: true)
  Picked = Struct.new(:role, :transcript, :rows)

  # One transcript file: a session, or a subagent with its .meta.json beside it.
  class Transcript
    attr_reader :path, :rows, :meta, :brief

    def initialize(path, branch)
      @path = path
      @branch = branch
      @rows = []
      @meta = subagent? ? read_meta : nil
      File.foreach(path) { |line| ingest(line) }
    end

    def subagent?
      path.include?("/subagents/")
    end

    def agent_type
      type = meta && meta["agentType"].to_s
      type.nil? || type.empty? ? "subagent" : type
    end

    def spawned_by
      meta && meta["toolUseId"]
    end

    def commits?
      rows.any?(&:commits)
    end

    private

    def read_meta
      file = path.sub(/\.jsonl\z/, ".meta.json")
      File.exist?(file) ? JSON.parse(File.read(file)) : {}
    rescue JSON::ParserError
      {}
    end

    def ingest(line)
      data = JSON.parse(line)
      return unless data.is_a?(Hash)

      message = data["message"].is_a?(Hash) ? data["message"] : {}
      note_text(data["type"], message)
      time = FlowEffort.parse_time(data["timestamp"]) or return

      assistant = data["type"] == "assistant"
      usage = assistant && message["usage"].is_a?(Hash) ? message["usage"] : nil
      calls = tool_calls(message)
      @rows << Row.new(time: time, branch: data["gitBranch"], mentions: FlowEffort.mentions?(line, @branch),
                       usage_id: message["id"] || data["uuid"], model: message["model"],
                       usage: usage && FlowEffort.tokens(usage), advisor: usage ? advisor(usage) : [],
                       tool_ids: calls.map { |call| call["id"] }.compact, compact: data["isCompactSummary"] == true,
                       assistant: assistant, waits: calls.any? { |call| waits?(call) },
                       commits: calls.any? { |call| bash?(call, COMMIT_COMMAND) },
                       text: assistant ? FlowEffort.text_of(message["content"])[0, 400] : nil)
    rescue JSON::ParserError
      nil
    end

    def note_text(type, message)
      text = FlowEffort.text_of(message["content"])
      return if text.empty?

      @brief ||= text if type == "user"
    end

    # The top-level usage sums the "message" iterations alone. An advisor
    # consultation is an iteration of its own, on its own model, so it adds to
    # that total rather than repeating part of it.
    def advisor(usage)
      Array(usage["iterations"]).select { |it| it.is_a?(Hash) && it["type"] == "advisor_message" }
                                .map { |it| [it["model"].to_s, FlowEffort.tokens(it)] }
    end

    def tool_calls(message)
      Array(message["content"]).select { |block| block.is_a?(Hash) && block["type"] == "tool_use" }
    end

    def waits?(call)
      call["name"] == "ScheduleWakeup" || bash?(call, WAIT_COMMAND)
    end

    def bash?(call, pattern)
      input = call["input"].is_a?(Hash) ? call["input"] : {}
      call["name"] == "Bash" && input["command"].to_s =~ pattern ? true : false
    end
  end

  module_function

  def tokens(usage)
    { input: usage["input_tokens"].to_i, cache_write: usage["cache_creation_input_tokens"].to_i,
      cache_read: usage["cache_read_input_tokens"].to_i, output: usage["output_tokens"].to_i }
  end

  def text_of(content)
    return content if content.is_a?(String)

    Array(content).select { |block| block.is_a?(Hash) && block["type"] == "text" }.map { |b| b["text"] }.join("\n")
  end

  def parse_time(value)
    value.is_a?(String) ? Time.iso8601(value) : nil
  rescue ArgumentError
    nil
  end

  # Claude Code keeps a checkout's sessions in a directory named after its path.
  def slug(path)
    path.gsub(/[^A-Za-z0-9]/, "-")
  end

  def projects_dir
    ENV["CLAUDE_PROJECTS_DIR"] || File.join(ENV["CLAUDE_CONFIG_DIR"] || File.join(Dir.home, ".claude"), "projects")
  end

  def subagent_files(session)
    Dir.glob(File.join(session.sub(/\.jsonl\z/, ""), "subagents", "*.jsonl")).sort
  end

  def read(file)
    File.binread(file)
  rescue SystemCallError
    ""
  end

  def contains?(file, needle)
    read(file).include?(needle)
  end

  # Session files that may hold the branch's work, each with how it was found:
  # :branch (a checkout of this repository whose session, or one of its agents,
  # names the branch), :trailer (a commit's Claude-Session trailer names it, in
  # any checkout) or :explicit (--session). `floor` bounds only the trailer
  # scan over every checkout's transcripts: a session that wrote a commit was
  # alive when it did. `same_repo` decides whether another clone's directory
  # (`acme-2` beside `acme`) is this repository.
  def find_sessions(projects:, repo_root:, branch:, bridge_ids:, explicit:, floor: nil, same_repo: method(:same_repo?))
    found = {}
    checkouts(projects, repo_root, same_repo).each do |file|
      named = contains?(file, branch) || subagent_files(file).any? { |sub| contains?(sub, branch) }
      found[file] = :branch if named
    end
    names, bridges = explicit.partition { |id| id !~ /\A(session|cse)_/ }
    trailers = (bridge_ids + bridges).map { |id| id.sub(/\A(session|cse)_/, "") }.uniq
    unless trailers.empty?
      Dir.glob(File.join(projects, "*", "*.jsonl")).sort.each do |file|
        next if floor && File.mtime(file) < floor

        text = read(file)
        hit = trailers.select { |id| text.include?("cse_#{id}") }
        next if hit.empty?

        found[file] = bridges.any? { |id| hit.include?(id.sub(/\A(session|cse)_/, "")) } ? :explicit : :trailer
      end
    end
    names.each do |name|
      next found[File.expand_path(name)] = :explicit if File.file?(name)

      stem = File.basename(name, ".jsonl")
      Dir.glob(File.join(projects, "*", "#{stem}.jsonl")).each { |file| found[file] = :explicit }
    end
    found
  end

  # The repository's own session files: its checkout's directory and the
  # worktrees inside it (`<slug>--…`), and another clone of it (`<slug>-2`)
  # once the checkout it recorded has the same origin. A different repository
  # whose path starts the same (`acme2`) has another origin.
  def checkouts(projects, repo_root, same_repo)
    return [] if repo_root.to_s.empty?

    own = slug(repo_root)
    Dir.glob(File.join(projects, "#{own}*")).sort.flat_map do |dir|
      name = File.basename(dir)
      files = Dir.glob(File.join(dir, "*.jsonl")).sort
      next files if name == own || name.start_with?("#{own}--")

      files.select { |file| (cwd = recorded_cwd(file)) && same_repo.call(cwd) }
    end
  end

  def recorded_cwd(file)
    File.foreach(file).first(200).each do |line|
      cwd = line[/"cwd":"((?:[^"\\]|\\.)*)"/, 1]
      return JSON.parse(%("#{cwd}")) if cwd
    end
    nil
  rescue SystemCallError, JSON::ParserError
    nil
  end

  def same_repo?(cwd)
    @origins ||= {}
    ours = (@origins[:ours] ||= origin_key(run("git", "config", "--get", "remote.origin.url")))
    return false if ours.empty? || !File.directory?(cwd)

    theirs = (@origins[cwd] ||= origin_key(run("git", "-C", cwd, "config", "--get", "remote.origin.url")))
    theirs == ours
  end

  # host/owner/name of a remote URL, so an ssh clone and an https clone of one
  # repository compare equal.
  def origin_key(url)
    url.to_s.strip.sub(%r{\A[a-z+]+://}, "").sub(/\A[^@\/]+@/, "").sub(/:(?!\d)/, "/")
       .sub(%r{/+\z}, "").sub(/\.git\z/, "").downcase
  end

  def pick(found, branch:, since: nil, till: nil)
    found.each_with_object([]) do |(file, how), picked|
      session = Transcript.new(file, branch)
      subs = subagent_files(file).map { |sub| Transcript.new(sub, branch) }
      how = :branch if how == :trailer && orchestrator?(subs, branch)
      rows = within(how == :explicit && since ? session.rows : session_rows(session, how, branch), since, till)
      picked << Picked.new("main", session, rows) unless rows.empty?
      attribute(subs, rows.flat_map(&:tool_ids).to_set, branch).each do |sub|
        sub_rows = within(sub.rows, since, till)
        picked << Picked.new(sub.agent_type, sub, sub_rows) unless sub_rows.empty?
      end
    end
  end

  # Transcripts of this repository that name the branch but record no branch
  # on any row (a Claude Code older than gitBranch): not counted, reported.
  def unbranched(found, branch:)
    found.select { |_, how| how == :branch }.keys.select do |file|
      rows = Transcript.new(file, branch).rows
      rows.any?(&:mentions) && rows.none?(&:branch)
    end
  end

  # A session's own rows: those recorded on the branch. A session named by a
  # trailer or --session that never ran on the branch (its checkout was
  # elsewhere) counts from the first row that names it; an explicit one that
  # never names it counts whole. An explicit session with --since counts
  # everything from then (pick).
  def session_rows(session, how, branch)
    on_branch = session.rows.select { |row| row.branch == branch }
    return on_branch unless on_branch.empty?
    return [] if how == :branch

    first = session.rows.index(&:mentions)
    return session.rows[first..-1] if first

    how == :explicit ? session.rows : []
  end

  # An agent belongs to the branch when its brief names the branch (an
  # orchestrator's agent, whose rows record the orchestrator's checkout), or
  # when a counted row, or an agent already counted, spawned it.
  def attribute(subagents, spawned, branch)
    chosen = []
    loop do
      added = subagents.reject { |sub| chosen.include?(sub) }.select do |sub|
        briefed?(sub, branch) || spawned.include?(sub.spawned_by)
      end
      break if added.empty?

      added.each { |sub| sub.rows.each { |row| spawned.merge(row.tool_ids) } }
      chosen.concat(added)
    end
    chosen
  end

  def briefed?(subagent, branch)
    mentions?(subagent.brief.to_s, branch)
  end

  # A session whose agent, briefed with the branch, commits to it is an
  # orchestrator (/flow:follow-through): the work is the agent's, and the
  # agent's commits carry the session's id. A session whose briefed agents
  # only read (a validator) did the work itself.
  def orchestrator?(subagents, branch)
    subagents.any? { |sub| briefed?(sub, branch) && sub.commits? }
  end

  # The branch name as a word, in a raw JSON line or a text: not part of a
  # longer name (`fix` in `prefix`, `feat/x` in `feat/x-2`). JSON escapes
  # (`\n`) are read as the space they stand for.
  def mentions?(text, branch)
    return false unless text.include?(branch)

    text.gsub(/\\[nrt]/, "  ") =~ /(?<![\w.-])#{Regexp.escape(branch)}(?![\w\/-])/ ? true : false
  end

  def within(rows, since, till)
    rows.select { |row| (since.nil? || row.time >= since) && (till.nil? || row.time <= till) }
  end

  # One line per content block of a message, all with its id. An agent's
  # transcript streams, so its earlier lines hold the usage so far: the last
  # line of a message is its count.
  def token_lines(picked)
    last = {}
    picked.each do |entry|
      entry.rows.each do |row|
        next if row.usage.nil? || row.model.to_s.empty? || row.model == "<synthetic>"

        last[row.usage_id] = [entry, row]
      end
    end
    lines = Hash.new { |hash, key| hash[key] = { calls: 0, input: 0, cache_write: 0, cache_read: 0, output: 0, files: Set.new } }
    last.each_value do |entry, row|
      add(lines[[entry.role, row.model]], row.usage, entry.transcript.path)
      row.advisor.each { |model, usage| add(lines[["advisor:#{entry.role}", model]], usage, nil) }
    end
    lines
  end

  def add(line, usage, file)
    line[:calls] += 1
    line[:input] += usage[:input] + usage[:cache_write] + usage[:cache_read]
    line[:cache_write] += usage[:cache_write]
    line[:cache_read] += usage[:cache_read]
    line[:output] += usage[:output]
    line[:files] << file if file
  end

  # Time someone was working: per transcript, the gaps between entries that
  # are neither too long nor a wait (from a waiting call to the next action);
  # then the union over transcripts, so an agent working while the session
  # waits on CI counts, and two agents at once count once.
  def active_seconds(row_lists, before: nil)
    spans = row_lists.flat_map { |rows| busy_spans(rows) }
    spans = spans.map { |a, b| [a, [b, before].min] }.select { |a, b| b > a } if before
    merged = spans.sort.each_with_object([]) do |(a, b), out|
      if out.any? && a <= out.last[1]
        out.last[1] = [out.last[1], b].max
      else
        out << [a, b]
      end
    end
    merged.sum { |a, b| b - a }
  end

  # Rows in file order (a transcript is written in order; sorting would swap
  # same-millisecond lines). A message's content blocks are lines of their
  # own, and the waiting call may be any of them: one makes the whole
  # message wait, from its first line.
  def busy_spans(rows)
    waiting_messages = rows.select { |row| row.waits && row.usage_id }.map(&:usage_id).to_set
    waiting = false
    rows.each_cons(2).each_with_object([]) do |(a, b), spans|
      waiting = a.waits || waiting_messages.include?(a.usage_id) if a.assistant
      gap = b.time - a.time
      spans << [a.time, b.time] if !waiting && gap >= 0 && gap <= IDLE_SECONDS
    end
  end

  def compactions(picked)
    picked.sum { |entry| entry.rows.count(&:compact) }
  end

  # One verdict per answer a validator gave inside the window: an answer opens
  # with its verdict, and a validator resumed for another pass answers again in
  # the same transcript. One that never opened an answer with a verdict gives
  # the verdict its last counted text names, or "no verdict" (still working when the window closed).
  def verdicts(picked)
    picked.select { |entry| entry.role.end_with?("fable-validator") }.flat_map do |entry|
      texts = entry.rows.select { |row| row.text && !row.text.empty? }
      answers = texts.each_with_object({}) do |row, by_message|
        by_message[row.usage_id] = row.text if row.text.lstrip =~ /\A[*_`#\s]*(PASS WITH NOTES|PASS|BLOCK)\b/
      end
      answers.empty? ? [verdict(texts.last && texts.last.text)] : answers.values.map { |text| verdict(text) }
    end
  end

  def verdict(text)
    text.to_s[0, 400][/\b(PASS WITH NOTES|PASS|BLOCK)\b/, 1] || "no verdict"
  end

  def size_for(hours)
    SIZES.find { |_, top| hours < top }.first
  end

  def size_index(size)
    SIZES.index { |name, _| name == size }
  end

  # The last "## Estimate" table in a Markdown text, by its fixed row labels.
  def parse_estimate(markdown)
    parts = markdown.to_s.split(/^##\s+Estimate\s*$/i)
    return nil if parts.size < 2

    estimate = {}
    parts.last.split(/^##\s/).first.each_line do |line|
      cells = line.strip.sub(/\A\|/, "").sub(/\|\z/, "").split("|").map(&:strip)
      key = cells.size >= 2 && ESTIMATE_ROWS[cells[0].downcase.delete("*_`")]
      next unless key

      value = key == :size ? cells[1][/\b(XS|S|M|L|XL)\b/, 1] : range_of(cells[1], hours: key == :active_hours)
      estimate[key] = value if value
    end
    estimate.empty? ? nil : estimate
  end

  # "2–4 h", "1 to 3", "6-10", "~2", "45 min" → [low, high].
  def range_of(text, hours: false)
    numbers = text.scan(/\d+(?:\.\d+)?/).map(&:to_f)
    return nil if numbers.empty?

    high = text =~ /\d\s*(?:–|—|-|to)\s*~?\d/ ? numbers[1] : numbers[0]
    scale = hours && text =~ /min/i && text !~ /\d\s*h\b|hour/i ? 1 / 60.0 : 1
    [numbers[0] * scale, high * scale]
  end

  def deviation(range, actual)
    return "—" if range.nil? || actual.nil?

    low, high = range
    return "within" if actual >= low && actual <= high
    return format("−%d %%", ((1 - actual / low.to_f) * 100).round) if actual < low
    return "over" if high.zero?

    ratio = actual / high.to_f
    ratio >= 2 ? format("×%.1f", ratio) : format("+%d %%", ((ratio - 1) * 100).round)
  end

  def size_deviation(estimate, actual)
    return "—" if estimate.nil? || actual.nil?

    steps = size_index(actual) - size_index(estimate)
    return "within" if steps.zero?

    format("%+d size%s", steps, steps.abs == 1 ? "" : "s").sub("-", "−")
  end

  def data_comment(data)
    "#{DATA_PREFIX}#{JSON.generate(data).gsub('>', '\\u003e')} -->"
  end

  def read_data(text)
    json = text.to_s[/#{Regexp.escape(DATA_PREFIX)}(\{.*?\}) -->/m, 1]
    json && JSON.parse(json)
  rescue JSON::ParserError
    nil
  end

  # The body with this section in it: replaced between the markers when it is
  # there (prose around it stays), else inserted under its heading.
  def splice(body, section)
    body = body.to_s
    marked = /#{Regexp.escape(START_MARK)}.*?#{Regexp.escape(END_MARK)}/m
    return body.sub(marked) { section } if body =~ marked

    # The end marker was lost (a hand edit): replace up to the next section.
    if (start = body.index(START_MARK))
      rest = body[start..-1]
      stop = ([/^## /] + INSERT_BEFORE).map { |pattern| rest.index(pattern) }.compact.min
      return "#{body[0...start]}#{section}\n\n#{rest[stop..-1]}" if stop

      return "#{body[0...start]}#{section}\n"
    end

    block = "#{HEADING}\n\n#{section}"
    at = INSERT_BEFORE.map { |pattern| body.index(pattern) }.compact.first
    return "#{body[0...at]}#{block}\n\n#{body[at..-1]}" if at

    "#{body.rstrip}\n\n#{block}\n"
  end

  # --- git and GitHub -------------------------------------------------------

  def run(*cmd, input: nil)
    out, status = Open3.capture2(*cmd, stdin_data: input.to_s, err: File::NULL)
    status.success? ? out : nil
  rescue SystemCallError
    nil
  end

  def json_of(text)
    text && JSON.parse(text)
  rescue JSON::ParserError
    nil
  end

  def repo_root
    common = run("git", "rev-parse", "--path-format=absolute", "--git-common-dir").to_s.strip
    return File.dirname(common) if File.basename(common) == ".git"

    run("git", "rev-parse", "--show-toplevel").to_s.strip
  end

  def repo_args(repo)
    repo ? ["--repo", repo] : []
  end

  def commits_from_git(base)
    log = run("git", "log", "--format=%s%x1f%b%x1f%aI%x1e", "origin/#{base}..HEAD") or return []
    log.split("\x1e").map(&:strip).reject(&:empty?).map do |entry|
      headline, body, date = entry.split("\x1f")
      { "messageHeadline" => headline, "messageBody" => body.to_s, "authoredDate" => date }
    end
  end

  def diff_from_git(base)
    stat = run("git", "diff", "--shortstat", "origin/#{base}...HEAD").to_s
    { files: stat[/(\d+) files? changed/, 1].to_i, additions: stat[/(\d+) insertions?/, 1].to_i,
      deletions: stat[/(\d+) deletions?/, 1].to_i }
  end

  def review_rounds(nwo, number)
    heads = run("gh", "api", "--paginate", "repos/#{nwo}/pulls/#{number}/reviews", "--jq", ".[].commit_id")
    heads && heads.split.uniq.size
  end

  def thread_count(nwo, number)
    owner, name = nwo.split("/", 2)
    out = run("gh", "api", "graphql", "-f", "query=#{THREADS_QUERY}", "-f", "owner=#{owner}", "-f", "name=#{name}",
              "-F", "number=#{number}", "--jq", ".data.repository.pullRequest.reviewThreads.totalCount")
    out && out.strip =~ /\A\d+\z/ ? out.to_i : nil
  end

  # The estimate and where it came from: --estimate, the one this PR's body
  # carries from when the section was first written, else the issue's (the
  # plan in its body, or the latest comment with an Estimate table).
  def estimate_for(file:, pr:, issue:, repo:)
    if file
      found = File.exist?(file) && parse_estimate(File.read(file))
      name = File.basename(file)
      # /flow:lfg's own estimate lives in its deviation log; any other file is a plan.
      return [found, name == "implementation-notes.md" ? "made before the first edit (`#{name}`)" : "plan `#{name}`"] if found
    end
    carried = read_data(pr && pr["body"])
    if carried && carried["estimate"]
      est = carried["estimate"].each_with_object({}) { |(k, v), h| h[k.to_sym] = v unless k == "source" }
      return [est, carried["estimate"]["source"]]
    end
    return [nil, nil] unless issue

    data = json_of(run("gh", "issue", "view", issue.to_s, *repo_args(repo), "--json", "body,comments")) || {}
    from_comment = Array(data["comments"]).map { |c| parse_estimate(c["body"]) }.compact.last
    return [from_comment, "##{issue} (comment)"] if from_comment

    from_body = parse_estimate(data["body"])
    from_body ? [from_body, "plan ##{issue}"] : [nil, "none in ##{issue}"]
  end

  # --- the report -----------------------------------------------------------

  def measure(opts)
    pr = opts[:pr] && json_of(run("gh", "pr", "view", opts[:pr].to_s, *repo_args(opts[:repo]), "--json", PR_FIELDS))
    abort "effort: cannot read PR ##{opts[:pr]} with gh" if opts[:pr] && pr.nil?

    branch = opts[:branch] || (pr && pr["headRefName"]) || run("git", "branch", "--show-current").to_s.strip
    abort "effort: no branch to measure; pass --branch" if branch.empty?

    base = opts[:base] || (pr && pr["baseRefName"]) || "main"
    commits = pr ? Array(pr["commits"]) : commits_from_git(base)
    trailers = (commits.map { |c| c["messageBody"].to_s } + [pr && pr["body"].to_s])
               .join("\n").scan(TRAILER).flatten.uniq
    first = commits.map { |c| parse_time(c["authoredDate"]) }.compact.min
    till = opts[:until] || (pr && parse_time(pr["mergedAt"] || pr["closedAt"]))
    floor = opts[:since] || (first && first - 2 * 86_400)

    found = find_sessions(projects: projects_dir, repo_root: repo_root, branch: branch, bridge_ids: trailers,
                          explicit: opts[:sessions], floor: floor)
    picked = pick(found, branch: branch, since: opts[:since], till: till)

    issue = opts[:issue] || (pr && Array(pr["closingIssuesReferences"]).map { |i| i["number"] }.first)
    estimate, source = estimate_for(file: opts[:estimate], pr: pr, issue: issue, repo: opts[:repo])
    nwo = pr && pr["url"].to_s[%r{github\.com/([^/]+/[^/]+)/pull/}, 1]
    report(branch: branch, pr: pr, picked: picked, commits: commits, estimate: estimate, source: source,
           diff: pr ? { files: pr["changedFiles"], additions: pr["additions"], deletions: pr["deletions"] } : diff_from_git(base),
           rounds: nwo && review_rounds(nwo, pr["number"]), threads: nwo && thread_count(nwo, pr["number"]),
           unbranched: unbranched(found, branch: branch).size)
  end

  def report(branch:, pr:, picked:, commits:, estimate:, source:, diff:, rounds:, threads:, unbranched: 0)
    times = picked.flat_map { |entry| entry.rows.map(&:time) }.sort
    opened = pr && parse_time(pr["createdAt"])
    active = times.size > 1 ? active_seconds(picked.map(&:rows)) / 3600.0 : nil
    before = opened && active && active_seconds(picked.map(&:rows), before: opened) / 3600.0
    validations = verdicts(picked)
    merges = commits.count { |c| c["messageHeadline"].to_s =~ MERGE_HEADLINE }
    actual = {
      size: active && size_for(active), active_hours: active && active.round(2),
      active_before_pr_hours: before && before.round(2),
      active_after_pr_hours: before && (active - before).round(2),
      wall_hours: times.size > 1 ? ((times.last - times.first) / 3600.0).round(2) : nil,
      started_at: times.first && times.first.utc.iso8601, ended_at: times.last && times.last.utc.iso8601,
      validation_passes: picked.empty? ? nil : validations.size,
      verdicts: validations.each_with_object(Hash.new(0)) { |v, h| h[v] += 1 },
      review_rounds: rounds, threads: threads, files: diff[:files], additions: diff[:additions],
      deletions: diff[:deletions], commits: commits.size - merges, merges: merges, compactions: compactions(picked)
    }
    lines = token_lines(picked)
    {
      "v" => 1, "branch" => branch, "pr" => pr && pr["number"], "measured_at" => Time.now.utc.iso8601,
      "estimate" => estimate && stringify(estimate).merge("source" => source), "estimate_source" => source,
      "actual" => stringify(actual),
      "tokens" => lines.map do |(role, model), t|
        { "role" => role, "model" => model, "transcripts" => t[:files].size, "calls" => t[:calls], "input" => t[:input],
          "cache_write" => t[:cache_write], "cache_read" => t[:cache_read], "output" => t[:output] }
      end,
      "coverage" => { "sessions" => picked.count { |e| e.role == "main" }, "subagents" => picked.count { |e| e.role != "main" },
                      "unbranched" => unbranched }
    }
  end

  def stringify(hash)
    hash.each_with_object({}) { |(k, v), h| h[k.to_s] = v }
  end

  # --- Markdown -------------------------------------------------------------

  def tokens_text(count)
    return "0" if count.nil? || count.zero?
    return format("%.1f M", count / 1_000_000.0) if count >= 1_000_000
    return format("%d k", (count / 1000.0).round) if count >= 1000

    count.to_s
  end

  def hours_text(hours)
    return "not measured" if hours.nil?

    hours < 1 ? format("%d min", (hours * 60).round) : format("%.1f h", hours)
  end

  def range_text(range, unit = "")
    return "—" if range.nil?

    low, high = range.map { |n| n == n.round ? n.round : n }
    (low == high ? low.to_s : "#{low}–#{high}") + unit
  end

  def render(data)
    est = data["estimate"] || {}
    act = data["actual"]
    verdict_list = act["verdicts"].map { |v, n| "#{n} #{v}" }.join(" · ")
    passes = act["validation_passes"].nil? ? "not measured" : act["validation_passes"].to_s
    passes += " (#{verdict_list})" unless verdict_list.empty?
    files = act["files"] ? "#{act['files']} (+#{act['additions']} / −#{act['deletions']})" : "not measured"
    rows = [
      ["Size", est["size"] || "—", act["size"] || "not measured", size_deviation(est["size"], act["size"])],
      ["Active time", range_text(est["active_hours"], " h"), hours_text(act["active_hours"]),
       deviation(est["active_hours"], act["active_hours"])],
      ["Validation passes", range_text(est["validation_passes"]), passes,
       deviation(est["validation_passes"], act["validation_passes"])],
      ["Review rounds", range_text(est["review_rounds"]), act["review_rounds"] ? act["review_rounds"].to_s : "not measured",
       deviation(est["review_rounds"], act["review_rounds"])],
      ["Files", range_text(est["files"]), files, deviation(est["files"], act["files"])]
    ]
    out = [START_MARK, "| | Estimate | Actual | Deviation |", "|---|---|---|---|"]
    out.concat(rows.map { |r| "| #{r.join(' | ')} |" })
    out << "" << "Estimate: #{data['estimate_source'] || 'none'}."
    out << "" << time_text(act) << "" << token_table(data["tokens"]) << "" << footer(data)
    out << data_comment(data) << END_MARK
    out.join("\n")
  end

  def time_text(act)
    return "Time: not measured (no transcript on this machine covers this work)." if act["wall_hours"].nil?

    start = act["started_at"].sub("T", " ")[0, 16]
    stop = act["ended_at"].sub("T", " ")[0, 16]
    stop = stop[11..-1] if stop[0, 10] == start[0, 10]
    split = act["active_before_pr_hours"] &&
            ", #{hours_text(act['active_before_pr_hours'])} of it before the PR opened and " \
            "#{hours_text(act['active_after_pr_hours'])} after"
    "Wall clock #{hours_text(act['wall_hours'])} (#{start} → #{stop} UTC); active #{hours_text(act['active_hours'])}" \
      "#{split}. Active leaves out waiting on CI or a review bot and any gap over #{IDLE_SECONDS / 60} min."
  end

  def plural(count, word)
    "#{count} #{word}#{count == 1 ? '' : 's'}"
  end

  def token_table(tokens)
    return "Tokens: not measured." if tokens.empty?

    order = lambda do |t|
      rank = if t["role"] == "main" then 0
             elsif t["role"] == "advisor:main" then 2
             elsif t["role"].start_with?("advisor:") then 3
             else 1
             end
      [rank, t["role"], t["model"]]
    end
    body = tokens.sort_by(&order).map do |t|
      who = if t["role"] == "main"
              t["transcripts"] > 1 ? "Main session × #{t['transcripts']}" : "Main session"
            elsif t["role"].start_with?("advisor:")
              caller = t["role"].sub("advisor:", "")
              "Advisor, for #{caller == 'main' ? 'the main session' : "`#{caller}`"}"
            else
              "`#{t['role']}` × #{t['transcripts']}"
            end
      "| #{who} · `#{t['model']}` | #{t['calls']} | #{tokens_text(t['input'])} | #{tokens_text(t['cache_read'])} | " \
        "#{tokens_text(t['output'])} |"
    end
    sum = ->(key) { tokens.sum { |t| t[key] } }
    total = "| **Total** | #{sum.call('calls')} | #{tokens_text(sum.call('input'))} | " \
            "#{tokens_text(sum.call('cache_read'))} | #{tokens_text(sum.call('output'))} |"
    (["| Tokens | Calls | Input | of it cache reads | Output |", "|---|---|---|---|---|"] + body + [total]).join("\n")
  end

  def footer(data)
    act = data["actual"]
    cov = data["coverage"]
    facts = [plural(act["commits"], "commit") +
             (act["merges"].positive? ? " (+ #{plural(act['merges'], 'merge')} of the base)" : "")]
    facts << plural(act["threads"], "review thread") if act["threads"]
    facts << plural(act["compactions"], "context compaction") if act["compactions"].positive?
    facts << "measured from #{plural(cov['sessions'], 'session')} and #{plural(cov['subagents'], 'agent transcript')} " \
             "on this machine; work elsewhere is not in these numbers"
    if cov["unbranched"].to_i.positive?
      facts << "#{plural(cov['unbranched'], 'transcript')} name the branch but record no branch on their rows " \
               "(an older Claude Code): not counted; `--session <id> --since <time>` counts one"
    end
    facts.join(" · ") + "."
  end

  # --- CLI ------------------------------------------------------------------

  # "570", "#570", "PR570" — however the PR was typed.
  def pr_number(text)
    number = text.to_s[/\A(?:PR|#)?(\d+)\z/i, 1]
    raise OptionParser::InvalidArgument, text unless number

    number.to_i
  end

  def options(argv)
    opts = { sessions: [] }
    rest = OptionParser.new do |o|
      o.banner = "Usage: effort.rb [<pr>] [options]"
      o.on("--pr N") { |v| opts[:pr] = pr_number(v) }
      o.on("--issue N", Integer) { |v| opts[:issue] = v }
      o.on("--branch NAME") { |v| opts[:branch] = v }
      o.on("--base NAME") { |v| opts[:base] = v }
      o.on("--repo OWNER/NAME") { |v| opts[:repo] = v }
      o.on("--estimate FILE") { |v| opts[:estimate] = v }
      o.on("--session ID", "a session file's id, or a session_/cse_ id from a trailer") { |v| opts[:sessions] << v }
      o.on("--since TIME") { |v| opts[:since] = Time.parse(v) }
      o.on("--until TIME") { |v| opts[:until] = Time.parse(v) }
      o.on("--json") { opts[:json] = true }
      o.on("--write", "replace the PR body's section (needs --pr)") { opts[:write] = true }
    end.parse(argv)
    raise OptionParser::InvalidArgument, rest.join(" ") if rest.size > 1

    opts[:pr] ||= pr_number(rest.first) if rest.first
    opts
  end

  def main(argv)
    opts = begin
      options(argv)
    rescue OptionParser::ParseError => e
      abort "effort: #{e.message} (usage: effort.rb [<pr>] [--write] [--estimate FILE] …)"
    end
    abort "effort: --write needs a PR" if opts[:write] && !opts[:pr]
    data = measure(opts)
    return puts(JSON.pretty_generate(data)) if opts[:json]

    section = render(data)
    return puts("#{HEADING}\n\n#{section}") unless opts[:write]

    body = json_of(run("gh", "pr", "view", opts[:pr].to_s, *repo_args(opts[:repo]), "--json", "body"))
    abort "effort: cannot read PR ##{opts[:pr]}'s body" unless body
    updated = run("gh", "pr", "edit", opts[:pr].to_s, *repo_args(opts[:repo]), "--body-file", "-",
                  input: splice(body["body"], section))
    abort "effort: gh pr edit failed" unless updated
    puts "updated the #{HEADING.delete_prefix('## ')} section of PR ##{opts[:pr]}"
  end
end

FlowEffort.main(ARGV) if $PROGRAM_NAME == __FILE__
