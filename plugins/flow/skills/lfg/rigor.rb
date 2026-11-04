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
#   rigor.rb [--base <ref>] [--files -] [--labels a,b] [--config <path>]
#            [--root <dir>] [--json | --summary]
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

require "json"
require "open3"
require "optparse"
require "yaml"

module FlowRigor
  TIERS = %w[light standard critical].freeze
  FALLBACK = "critical"
  FLAGS = File::FNM_PATHNAME | File::FNM_EXTGLOB | File::FNM_DOTMATCH
  SECTION_KEYS = %w[paths signals labels].freeze
  MAX_UNTRACKED_BYTES = 1_000_000
  SHOWN = 2

  class ConfigError < StandardError; end
  class GitError < StandardError; end

  Change = Struct.new(:path, :old_path, :added)
  SignalRule = Struct.new(:source, :regexp, :scope)
  Result = Struct.new(:tier, :default, :config, :reasons, :warnings)

  module_function

  def classify(root:, base: "origin/main", files: nil, labels: [], config: nil)
    warnings = []
    config_path = config || config_path_from_agents(root)
    unless config_path
      raise ConfigError, "no Rigor line in AGENTS.md → ## Workflow"
    end

    rules = load_config(File.expand_path(config_path, root))
    changes =
      if files
        warnings << "signals not checked: planned files have no diff yet"
        files.map { |path| Change.new(path, nil, []) }
      else
        collect_changes(root, base)
      end
    reasons = reasons_for(rules, changes, labels)
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

    in_workflow = false
    File.foreach(agents) do |line|
      if line.start_with?("## ")
        in_workflow = line.strip.casecmp?("## Workflow")
        next
      end
      next unless in_workflow

      found = line[/\A\s*[-*]\s+\*\*Rigor:\*\*\s*`?([^`\s]+)`?/, 1]
      return found if found
    end
    nil
  end

  def load_config(path)
    raise ConfigError, "#{path}: no such file" unless File.file?(path)

    data = YAML.safe_load(File.read(path), permitted_classes: [], aliases: false)
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
  def collect_changes(root, base)
    merge_base = git(root, "merge-base", base, "HEAD").strip
    changes = name_status(git_paths(root, "diff", "-M", "--name-status", "-z", merge_base)).map do |path, old_path|
      Change.new(path, old_path, added_lines(git(root, "diff", "-U0", "--no-color", "--no-ext-diff", merge_base, "--", path)))
    end
    name_list(git_paths(root, "ls-files", "--others", "--exclude-standard", "-z")).each do |path|
      changes << Change.new(path, nil, untracked_lines(File.join(root, path)))
    end
    changes.sort_by(&:path)
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

  # Everything before the first hunk is header; after it, a `+` line is added
  # content, even one that reads `+++ b/other`.
  def added_lines(diff)
    in_hunk = false
    diff.each_line.each_with_object([]) do |line, added|
      if line.start_with?("@@")
        in_hunk = true
      elsif in_hunk && line.start_with?("+")
        added << line[1..-1].chomp
      end
    end
  end

  # Only the first MAX_UNTRACKED_BYTES of a new file are searched for signals:
  # a generated blob that size is not where a lock or an amount is added.
  def untracked_lines(full)
    return [] unless File.file?(full)

    text = File.binread(full, MAX_UNTRACKED_BYTES)
    return [] if text.nil? || text.include?("\0")

    text.force_encoding(Encoding::UTF_8).scrub.lines.map(&:chomp)
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
      opts.banner = "usage: rigor.rb [--base <ref>] [--files -] [--labels a,b] [--config <path>] [--root <dir>] [--json | --summary]"
      opts.on("--base REF") { |value| options[:base] = value }
      opts.on("--files SOURCE") { |value| options[:files] = value }
      opts.on("--labels LIST") { |value| options[:labels] = value.split(",").map(&:strip).reject(&:empty?) }
      opts.on("--config PATH") { |value| options[:config] = value }
      opts.on("--root DIR") { |value| options[:root] = value }
      opts.on("--json") { options[:format] = :json }
      opts.on("--summary") { options[:format] = :summary }
    end
    begin
      parser.parse!(argv)
      raise OptionParser::InvalidArgument, "--files takes - (paths on stdin)" if options[:files] && options[:files] != "-"
      raise OptionParser::NeedlessArgument, argv.join(" ") unless argv.empty?
    rescue OptionParser::ParseError => e
      warn "rigor.rb: #{e.message}"
      warn parser.banner
      exit 2
    end

    result =
      begin
        files = options[:files] ? $stdin.read.split("\n").map(&:strip).reject(&:empty?) : nil
        classify(root: options[:root] || repo_root, base: options[:base], files: files,
                 labels: options[:labels], config: options[:config])
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
