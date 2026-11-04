#!/usr/bin/env ruby
# frozen_string_literal: true

# How hard is this change validated? Reads the repository's rigor file (named
# by the `- **Rigor:**` line of AGENTS.md → ## Workflow), classifies the change
# against it and prints one word: light, standard or critical.
#
#   light     no Fable validator: the repository's gates and the review bot
#   standard  one validator pass; notes fixed or rebutted, never re-run
#   critical  the full loop: notes fixed and re-validated, up to three rounds
#
# The change is the highest tier any changed path, added-line signal or PR
# label matches; a file no rule matches gets the file's `default`. Every
# unknown state (no Rigor line, a missing or invalid file, a git failure)
# prints `critical`, which is how flow validated before tiers existed: an error
# never lowers the bar. Exit 0 always, 2 for a usage error.
# Stdlib only, Ruby >= 2.6.
#
#   rigor.rb [--base <ref> | --files - | --since <sha>] [--labels a,b]
#            [--config <path>] [--root <dir>] [--json | --summary]
#
# --base   the whole change against the merge base (the default, origin/main)
# --files  planned paths on stdin, before any diff exists (no signals)
# --since  only this PR's own first-parent, non-merge commits after <sha>,
#          each against its parent; none at all prints light. finish-prs uses
#          it to ask whether code changed since the validator last judged.
#
# The rigor file:
#
#   version: 1
#   default: standard                  # light | standard | critical
#   critical:
#     paths:   ["app/services/payments/", "db/migrate/**"]
#     signals:                         # Ruby regexps on ADDED lines only
#       - "with_lock"                  # any file
#       - { pattern: "_cents\\b", paths: ["app/**"] }   # only in these files
#     labels:  ["risk:high"]
#   light:
#     paths:   ["docs/**", "**/*.md"]
#
# Globs are File.fnmatch with FNM_PATHNAME | FNM_EXTGLOB | FNM_DOTMATCH:
# `*` stays inside one directory, `**/` spans any number (zero included),
# `{a,b}` alternates, and `dir/` or `dir/**` means everything under dir.
# Renames match on both paths; deleted files match too. Signals and labels only
# ever raise a change.
#
# Where the configuration comes from: --base reads AGENTS.md and the rigor file
# at the merge base, --since at <sha> (`git cat-file`), so a change never
# chooses its own gate. A change that touches that rigor file, adds or removes
# a `**Rigor:**` line in that AGENTS.md, or leaves a Rigor line under
# ## Workflow that names another file or none (a heading moved above it), is
# critical (a `config` reason). --since compares the line at <sha> with HEAD's,
# so a Rigor line a merge of main changed counts once the PR adds a commit.
# When the base has no Rigor line, or lacks the file it names (first
# adoption), the working tree's configuration is read with a warning and the
# change is critical too: a fallback never lowers the bar. A Rigor path that is
# absolute or leaves the repository is critical. --files and an explicit
# --config read the working tree, as before.

require "json"
require "open3"
require "optparse"
require "pathname"
require "yaml"

module FlowRigor
  TIERS = %w[light standard critical].freeze
  FALLBACK = "critical"
  FLAGS = File::FNM_PATHNAME | File::FNM_EXTGLOB | File::FNM_DOTMATCH
  SECTION_KEYS = %w[paths signals labels].freeze
  MAX_UNTRACKED_BYTES = 1_000_000
  SHOWN = 2
  RIGOR_LINE = /\A\s*[-*]\s+\*\*Rigor:\*\*\s*`?([^`\s]+)`?/.freeze
  RIGOR_EDIT = /\*\*Rigor:\*\*/.freeze

  class ConfigError < StandardError; end
  class GitError < StandardError; end

  Change = Struct.new(:path, :old_path, :added, :unscanned, :removed)
  # What a change must not touch: the rigor file paths and the AGENTS.md whose
  # Rigor line was read (toplevel-relative), the working-tree file read in a
  # fallback, and whether the Rigor line the change leaves names another file
  # (or none), as a heading moved above it would.
  Guard = Struct.new(:paths, :agents, :fallback, :moved)
  SignalRule = Struct.new(:source, :regexp, :scope)
  Result = Struct.new(:tier, :default, :config, :reasons, :warnings)

  module_function

  # `since:` answers a different question: did this PR's own commits since a
  # validated sha change anything above light? Merges are not its own work and
  # labels have not changed, so neither counts; no commits at all is light.
  def classify(root:, base: "origin/main", files: nil, labels: [], config: nil, since: nil)
    warnings = []
    guard = nil
    if files
      config_path, rules = working_tree_config(root, config)
      warnings << "signals not checked: planned files have no diff yet"
      changes = files.map { |path| Change.new(path, nil, []) }
    else
      top = git(root, "rev-parse", "--show-toplevel").strip
      ref = since ? resolve_commit(top, since) : git(top, "merge-base", base, "HEAD").strip
      if config
        config_path, rules = working_tree_config(root, config)
      else
        config_path, rules, guard = config_at(root, top, ref, warnings, since ? "HEAD" : nil)
      end
      changes = since ? collect_commits(top, ref) : collect_changes(top, ref)
    end
    if since && changes.empty?
      return Result.new("light", rules[:default], config_path,
                        [{ tier: "light", kind: "none", match: "no commits of this PR since #{since}", file: nil }], warnings)
    end

    reasons = reasons_for(rules, changes, since ? [] : labels) + config_reasons(guard, changes)
    tier = reasons.map { |reason| TIERS.index(reason[:tier]) }.max
    Result.new(TIERS[tier], rules[:default], config_path, reasons, warnings)
  rescue StandardError => e
    fallback(e.message, warnings)
  end

  def fallback(message, warnings = [])
    Result.new(FALLBACK, nil, nil, [{ tier: FALLBACK, kind: "fallback", match: message, file: nil }],
               warnings + ["#{message} → #{FALLBACK}"])
  end

  # --- the rigor file --------------------------------------------------------

  def config_path_from_agents(root)
    agents = File.join(root, "AGENTS.md")
    return nil unless File.file?(agents)

    rigor_line(File.read(agents).force_encoding(Encoding::UTF_8).scrub)
  end

  def rigor_line(text)
    in_workflow = false
    text.each_line do |line|
      if line.start_with?("## ")
        in_workflow = line.strip.casecmp?("## Workflow")
        next
      end
      next unless in_workflow

      found = line[RIGOR_LINE, 1]
      return found if found
    end
    nil
  end

  # --files and an explicit --config: the working tree, as before tiers had a base.
  def working_tree_config(root, config)
    config_path = config || config_path_from_agents(root)
    raise ConfigError, "no Rigor line in AGENTS.md → ## Workflow" unless config_path

    [config_path, load_config(File.expand_path(config_path, root))]
  end

  # The configuration at `ref` (the merge base, or the --since sha). Without a
  # Rigor line there, or without the file it names, the working tree's is read
  # and the guard marks it a fallback, which classifies as critical. A git
  # failure raises, and so prints critical; only a missing blob falls back.
  # `after` is where the change ends: HEAD for --since, nil for the working tree.
  def config_at(root, top, ref, warnings, after)
    prefix = git(root, "rev-parse", "--show-prefix").strip
    agents = repo_path(prefix, "AGENTS.md")
    short = ref[0, 12]
    agents_text = blob(top, ref, agents)
    line = agents_text && rigor_line(agents_text)
    if line
      rel = repo_path(prefix, line)
      text = blob(top, ref, rel)
      if text
        moved = rigor_path(after_line(root, top, agents, after)) != rigor_path(line)
        return [line, parse_config(text, "#{line} at #{short}"), Guard.new([rel], agents, nil, moved)]
      end

      warnings << "#{line} is missing at #{short}: reading the working tree's configuration → #{FALLBACK}"
    else
      warnings << "no Rigor line in AGENTS.md at #{short}: reading the working tree's configuration → #{FALLBACK}"
    end

    config_path, rules = working_tree_config(root, nil)
    fallback = repo_path(prefix, config_path)
    [config_path, rules, Guard.new([fallback], agents, fallback, false)]
  end

  def after_line(root, top, agents, after)
    return config_path_from_agents(root) unless after

    text = blob(top, after, agents)
    text && rigor_line(text)
  end

  def rigor_path(line)
    line && Pathname.new(line).cleanpath.to_s
  end

  # A Rigor path as git names it: toplevel-relative, from the root's prefix.
  # An absolute path, or one that leaves the repository, has no blob at a sha.
  def repo_path(prefix, path)
    raise ConfigError, "#{path}: outside the repository" if path.start_with?("/")

    joined = Pathname.new("#{prefix}#{path}").cleanpath.to_s
    raise ConfigError, "#{path}: outside the repository" if joined == ".." || joined.start_with?("../")

    joined
  end

  # The text of `path` at `ref`, or nil when there is no file there.
  def blob(top, ref, path)
    _, _, status = Open3.capture3("git", "-C", top, "cat-file", "-e", "#{ref}:#{path}")
    return nil unless status.success?
    return nil unless git(top, "cat-file", "-t", "#{ref}:#{path}").strip == "blob"

    git(top, "cat-file", "blob", "#{ref}:#{path}")
  end

  def load_config(path)
    raise ConfigError, "#{path}: no such file" unless File.file?(path)

    parse_config(File.read(path), path)
  end

  def parse_config(text, path)
    data = YAML.safe_load(text, permitted_classes: [], aliases: false)
    raise ConfigError, "#{path}: not a mapping" unless data.is_a?(Hash)
    raise ConfigError, "#{path}: version #{data['version'].inspect}, want 1" unless data["version"] == 1
    unless TIERS.include?(data["default"])
      raise ConfigError, "#{path}: default #{data['default'].inspect} is not one of #{TIERS.join(', ')}"
    end

    unknown = data.keys - %w[version default] - TIERS
    raise ConfigError, "#{path}: unknown keys #{unknown.join(', ')}" unless unknown.empty?

    rules = { default: data["default"] }
    TIERS.each { |tier| rules[tier] = section(data[tier], tier, path) }
    rules
  rescue Psych::Exception => e
    raise ConfigError, "#{path}: #{e.message}"
  end

  def section(raw, tier, path)
    raw ||= {}
    raise ConfigError, "#{path}: #{tier} is not a mapping" unless raw.is_a?(Hash)

    unknown = raw.keys - SECTION_KEYS
    raise ConfigError, "#{path}: #{tier} has unknown keys #{unknown.join(', ')}" unless unknown.empty?

    {
      paths: strings(raw["paths"], "#{tier}.paths", path),
      labels: strings(raw["labels"], "#{tier}.labels", path),
      signals: Array(raw["signals"]).map { |entry| signal(entry, tier, path) }
    }
  end

  def strings(raw, name, path)
    list = raw.nil? ? [] : raw
    unless list.is_a?(Array) && list.all? { |item| item.is_a?(String) && !item.empty? }
      raise ConfigError, "#{path}: #{name} must be a list of non-empty strings"
    end

    list
  end

  def signal(entry, tier, path)
    pattern, scope =
      case entry
      when String then [entry, []]
      when Hash
        unknown = entry.keys - %w[pattern paths]
        raise ConfigError, "#{path}: #{tier}.signals entry has unknown keys #{unknown.join(', ')}" unless unknown.empty?

        [entry["pattern"], strings(entry["paths"], "#{tier}.signals paths", path)]
      end
    raise ConfigError, "#{path}: #{tier}.signals entries are a regexp string or {pattern:, paths:}" unless pattern.is_a?(String) && !pattern.empty?

    SignalRule.new(pattern, Regexp.new(pattern), scope)
  rescue RegexpError => e
    raise ConfigError, "#{path}: bad signal #{pattern.inspect}: #{e.message}"
  end

  # --- the change ------------------------------------------------------------

  # Output is read as UTF-8 with invalid bytes replaced, so a Latin-1 file is
  # read, not a crash. Paths are pathspec literals: no glob or magic in a name.
  def git(root, *args)
    out, err, status = Open3.capture3("git", "-C", root, "--literal-pathspecs", "-c", "core.quotePath=false", *args)
    raise GitError, "git #{args.join(' ')}: #{err.strip}" unless status.success?

    out.force_encoding(Encoding::UTF_8).scrub
  end

  # Committed, staged, unstaged and untracked work against the merge base:
  # `git diff <merge-base>` compares the commit with the working tree. Added
  # lines come from one diff per path, never from parsing a combined patch's
  # headers, which git quotes or pads for some names and which an added line
  # can imitate.
  # Paths are toplevel-relative, so every git call runs at the toplevel, even
  # when the caller's root is a subdirectory. A rename is diffed on both paths
  # with -M, so only the lines it really adds count.
  def collect_changes(top, merge_base)
    changes = name_status(git_paths(top, "diff", "-M", "--name-status", "-z", merge_base)).map do |path, old_path|
      paths = [old_path, path].compact
      diff_change(path, old_path, git(top, "diff", "-M", "-U0", "--no-color", "--no-ext-diff", merge_base, "--", *paths))
    end
    name_list(git_paths(top, "ls-files", "--others", "--exclude-standard", "-z")).each do |path|
      lines, unscanned = untracked_lines(File.join(top, path))
      changes << Change.new(path, nil, lines, unscanned, [])
    end
    changes.sort_by(&:path)
  end

  def resolve_commit(top, since)
    git(top, "rev-parse", "--verify", "--quiet", "#{since}^{commit}").strip
  end

  # Each first-parent, non-merge commit since `sha`, diffed against its own
  # parent: exactly what the PR wrote, never what a merge of main brought in.
  def collect_commits(top, sha)
    commits = git(top, "rev-list", "--first-parent", "--no-merges", "#{sha}..HEAD").split
    commits.flat_map do |commit|
      name_status(git_paths(top, "diff", "-M", "--name-status", "-z", "#{commit}^", commit)).map do |path, old_path|
        paths = [old_path, path].compact
        diff_change(path, old_path, git(top, "diff", "-M", "-U0", "--no-color", "--no-ext-diff", "#{commit}^", commit, "--", *paths))
      end
    end.sort_by(&:path)
  end

  def diff_change(path, old_path, diff)
    added, removed = diff_lines(diff)
    Change.new(path, old_path, added, false, removed)
  end

  # A path that is not UTF-8 cannot be matched or diffed reliably: critical.
  def git_paths(root, *args)
    out, err, status = Open3.capture3("git", "-C", root, *args)
    raise GitError, "git #{args.join(' ')}: #{err.strip}" unless status.success?

    out.force_encoding(Encoding::UTF_8)
    raise GitError, "a changed path is not UTF-8" unless out.valid_encoding?

    out
  end

  def name_list(raw)
    raw.split("\0").reject(&:empty?)
  end

  def name_status(raw)
    fields = raw.split("\0")
    entries = []
    until fields.empty?
      status = fields.shift
      if status.start_with?("R", "C")
        old_path = fields.shift
        entries << [fields.shift, old_path]
      else
        entries << [fields.shift, nil]
      end
    end
    entries
  end

  # A file section's header runs from `diff --git` to its first hunk; after
  # that, a `+` line is added content, even one that reads `+++ b/other`. With
  # -U0 every content line starts with `+` or `-`, so a line that starts with
  # `diff --git` is always the next section (a rename below the similarity
  # threshold prints two). Returns [added, removed].
  def diff_lines(diff)
    in_hunk = false
    added = []
    removed = []
    diff.each_line do |line|
      if line.start_with?("diff --git ")
        in_hunk = false
      elsif line.start_with?("@@")
        in_hunk = true
      elsif in_hunk && line.start_with?("+")
        added << line[1..-1].chomp
      elsif in_hunk && line.start_with?("-")
        removed << line[1..-1].chomp
      end
    end
    [added, removed]
  end

  # A new text file is searched up to MAX_UNTRACKED_BYTES. A larger one is not
  # searched at all and makes the change critical: an unread signal must never
  # lower the tier. A binary file (a NUL in its first bytes) has no lines.
  # Returns [lines, unscanned].
  def untracked_lines(full)
    return [[], false] unless File.file?(full)

    text = File.binread(full, MAX_UNTRACKED_BYTES + 1)
    return [[], false] if text.nil? || text.include?("\0")
    return [[], true] if text.bytesize > MAX_UNTRACKED_BYTES

    [text.force_encoding(Encoding::UTF_8).scrub.lines.map(&:chomp), false]
  end

  # --- classification --------------------------------------------------------

  def glob_match?(pattern, path)
    glob =
      if pattern == "**" then "**/*"
      elsif pattern.end_with?("/") then "#{pattern}**/*"
      elsif pattern.end_with?("/**") then "#{pattern[0..-3]}**/*"
      else pattern
      end
    File.fnmatch?(glob, path, FLAGS)
  end

  def reasons_for(rules, changes, labels)
    reasons = []
    changes.each do |change|
      reasons << path_reason(rules, change)
      if change.unscanned
        reasons << { tier: FALLBACK, kind: "unscanned", match: "over #{MAX_UNTRACKED_BYTES} bytes, signals not searched", file: change.path }
      end
      rules_by_tier(rules).each do |tier, rule|
        rule[:signals].each do |signal|
          next unless signal.scope.empty? || signal.scope.any? { |glob| glob_match?(glob, change.path) }
          next unless change.added.any? { |line| signal.regexp.match?(line) }

          reasons << { tier: tier, kind: "signal", match: signal.source, file: change.path }
        end
      end
    end
    rules_by_tier(rules).each do |tier, rule|
      (rule[:labels] & labels).each { |label| reasons << { tier: tier, kind: "label", match: label, file: nil } }
    end
    reasons << { tier: rules[:default], kind: "default", match: "no changed files", file: nil } if changes.empty?
    reasons
  end

  # A change to the gate itself is reviewed hardest: the rigor file that was
  # read (either path of a rename, or a deletion), an added or removed Rigor
  # line in that AGENTS.md, or a configuration read from the working tree.
  def config_reasons(guard, changes)
    return [] unless guard

    reasons = []
    reasons << { tier: FALLBACK, kind: "config", match: "Rigor line", file: guard.agents } if guard.moved
    if guard.fallback
      reasons << { tier: FALLBACK, kind: "config", match: "read from the working tree", file: guard.fallback }
    end
    changes.each do |change|
      candidates = [change.path, change.old_path].compact
      hit = guard.paths.find { |path| candidates.include?(path) }
      reasons << { tier: FALLBACK, kind: "config", match: "rigor file", file: hit } if hit
      next unless candidates.include?(guard.agents)
      next unless (change.added + Array(change.removed)).any? { |line| RIGOR_EDIT.match?(line) }

      reasons << { tier: FALLBACK, kind: "config", match: "Rigor line", file: guard.agents }
    end
    reasons.uniq
  end

  def rules_by_tier(rules)
    TIERS.map { |tier| [tier, rules[tier]] }
  end

  def path_reason(rules, change)
    candidates = [change.path, change.old_path].compact
    TIERS.reverse_each do |tier|
      rules[tier][:paths].each do |glob|
        hit = candidates.find { |path| glob_match?(glob, path) }
        return { tier: tier, kind: "path", match: glob, file: hit } if hit
      end
    end
    { tier: rules[:default], kind: "default", match: "no rule matched", file: change.path }
  end

  # --- output ----------------------------------------------------------------

  def summary(result)
    winning = result.reasons.select { |reason| reason[:tier] == result.tier }
    parts = winning.first(SHOWN).map { |reason| describe(reason) }
    parts << "+#{winning.size - SHOWN} more" if winning.size > SHOWN
    "Rigor: #{result.tier} — #{parts.join(', ')}"
  end

  def describe(reason)
    case reason[:kind]
    when "fallback" then "fallback: #{reason[:match]}"
    when "label" then "label #{reason[:match]}"
    when "default" then reason[:file] ? "default (#{reason[:file]})" : "default (#{reason[:match]})"
    else "#{reason[:kind]} #{reason[:match]} (#{reason[:file]})"
    end
  end

  def to_json(result)
    JSON.pretty_generate(
      "tier" => result.tier, "default" => result.default, "config" => result.config,
      "reasons" => result.reasons.map { |reason| reason.map { |key, value| [key.to_s, value] }.to_h },
      "warnings" => result.warnings
    )
  end

  def repo_root
    out, status = Open3.capture2e("git", "rev-parse", "--show-toplevel")
    status.success? ? out.strip : Dir.pwd
  rescue StandardError
    Dir.pwd
  end

  def main(argv)
    options = { base: "origin/main", labels: [], format: :word }
    parser = OptionParser.new do |opts|
      opts.banner = "usage: rigor.rb [--base <ref> | --files - | --since <sha>] [--labels a,b] [--config <path>] [--root <dir>] [--json | --summary]"
      opts.on("--base REF") { |value| options[:base] = value }
      opts.on("--files SOURCE") { |value| options[:files] = value }
      opts.on("--since SHA") { |value| options[:since] = value }
      opts.on("--labels LIST") { |value| options[:labels] = value.split(",").map(&:strip).reject(&:empty?) }
      opts.on("--config PATH") { |value| options[:config] = value }
      opts.on("--root DIR") { |value| options[:root] = value }
      opts.on("--json") { options[:format] = :json }
      opts.on("--summary") { options[:format] = :summary }
    end
    begin
      parser.parse!(argv)
      raise OptionParser::InvalidArgument, "--files takes - (paths on stdin)" if options[:files] && options[:files] != "-"
      raise OptionParser::InvalidArgument, "--since and --files exclude each other" if options[:files] && options[:since]
      raise OptionParser::NeedlessArgument, argv.join(" ") unless argv.empty?
    rescue OptionParser::ParseError => e
      warn "rigor.rb: #{e.message}"
      warn parser.banner
      exit 2
    rescue StandardError => e
      # An argument the parser cannot even read (invalid bytes under a UTF-8 locale)
      # is not a usage error the caller can fix: fall back like any failure.
      warn "rigor.rb: cannot read the arguments: #{e.message} → #{FALLBACK}"
      puts render(fallback("cannot read the arguments"), options[:format])
      exit 0
    end

    result =
      begin
        files = options[:files] ? $stdin.each_line.map(&:chomp).reject(&:empty?) : nil
        classify(root: options[:root] || repo_root, base: options[:base], files: files,
                 labels: options[:labels], config: options[:config], since: options[:since])
      rescue StandardError => e
        fallback(e.message)
      end
    output =
      begin
        render(result, options[:format])
      rescue StandardError => e
        result = fallback("cannot print the result: #{e.message}")
        render(result, options[:format])
      end
    result.warnings.each { |line| warn "rigor.rb: #{line}" }
    puts output
    exit 0
  end

  def render(result, format)
    case format
    when :json then to_json(result)
    when :summary then summary(result)
    else result.tier
    end
  end
end

FlowRigor.main(ARGV) if $PROGRAM_NAME == __FILE__
