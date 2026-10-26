//
//  DailyBriefGenerator.swift
//  Dayflow
//
//  Builds one day's Daily brief: gathers yesterday's cards and a screenshot per
//  card, fills in DailyBriefPrompt, runs `claude -p` (Opus) with web search, the
//  user's own connectors (read-only), and Dayflow's MCP server, then checks the
//  returned DailyBriefContent and copies the images it uses into the brief folder.
//
//  Everything here is synchronous and blocking; DailyBriefStore calls it from a
//  detached task.
//

import CoreGraphics
import Darwin
import Foundation
import ImageIO

/// What one brief run produced: the cleaned content plus numbers about the run.
struct DailyBriefGeneration: Sendable {
  var content: DailyBriefContent
  var stats: DailyBriefRunStats
}

enum DailyBriefGenerator {
  struct Input: Sendable {
    /// The logical day the brief is for, yyyy-MM-dd.
    let day: String
    /// The day whose activity it is built from (usually yesterday), yyyy-MM-dd.
    let sourceDay: String
    let trigger: String
    let overrideInstructions: String
    /// A full replacement for defaultPromptTemplate, with the same placeholders. nil or empty
    /// means use the default.
    let promptOverride: String?
    let feedbackEvents: [DailyBriefFeedbackEvent]
    let recentBriefs: [DailyBrief]
  }

  /// A failure with a short, plain message the brief can show as is.
  struct GenerationError: Error, LocalizedError {
    let message: String

    var errorDescription: String? { message }
  }

  static let model = "opus"
  static let runTimeoutSeconds: TimeInterval = 20 * 60
  /// More candidates than this are evenly sampled down, to keep the run's reading sane.
  static let maxCandidates = 60
  static let candidateMaxPixelSize = 1280
  static let feedbackDays = 21
  static let maxFeedbackLines = 30

  /// Dayflow's own MCP tools the brief may call without asking. The hook below also
  /// allows them, and blocks the ones that change data.
  static let dayflowReadTools = [
    "get_time_breakdown", "get_timeline", "get_activity_detail", "search_activities",
    "get_daily", "get_weekly", "list_categories", "get_status",
  ]

  /// The built-in prompt with its `{{PLACEHOLDERS}}` intact. The override editor starts from it.
  static let defaultPromptTemplate = DailyBriefPrompt.template

  /// Every placeholder the app fills in, for the override editor to list.
  static let placeholderNames = DailyBriefPrompt.placeholderNames

  // MARK: - Readiness

  private static let readinessLock = NSLock()
  private nonisolated(unsafe) static var claudeSupportsJSONSchema = false

  /// nil when the Claude CLI can run the brief; otherwise a plain sentence saying why not.
  /// A passing check is cached for the life of the process; a failing one is re-checked
  /// next time, so installing or updating Claude fixes it without a relaunch.
  static func claudeReadinessProblem() -> String? {
    readinessLock.lock()
    let alreadyChecked = claudeSupportsJSONSchema
    readinessLock.unlock()
    if alreadyChecked { return nil }

    let help = LoginShellRunner.run("claude --help", timeout: 20)
    let output = help.stdout + help.stderr
    if help.exitCode != 0 && !output.contains("--print") {
      return "Claude Code isn't installed on this Mac, so the brief can't run. "
        + "Install it with `npm install -g @anthropic-ai/claude-code`, then sign in."
    }
    guard output.contains("--json-schema") else {
      return
        "Your Claude Code is too old for the brief. Run `claude update` in Terminal, then try again."
    }

    readinessLock.lock()
    claudeSupportsJSONSchema = true
    readinessLock.unlock()
    return nil
  }

  // MARK: - Generate

  static func generate(_ input: Input) throws -> DailyBriefGeneration {
    let runDirectory = try makeRunDirectory(for: input.day)
    defer { try? FileManager.default.removeItem(at: runDirectory) }
    let candidatesDirectory = runDirectory.appendingPathComponent("candidates", isDirectory: true)

    let categories = CategoryPersistence.loadPersistedCategories()
    let cards = nonIdleCards(
      StorageManager.shared.fetchTimelineCards(forDay: input.sourceDay), categories: categories)
    guard !cards.isEmpty else {
      throw GenerationError(message: "There's no activity from yesterday to build a brief from.")
    }

    let candidates = exportCandidates(for: cards, into: candidatesDirectory)
    let override = input.promptOverride?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let usesPromptOverride = !override.isEmpty
    var template = usesPromptOverride ? override : defaultPromptTemplate
    // A custom prompt without the slot still gets the user's extra instructions, at the end.
    if !template.contains("{{OVERRIDE_INSTRUCTIONS}}") {
      template += "\n\n{{OVERRIDE_INSTRUCTIONS}}"
    }
    let prompt = DailyBriefPrompt.build(
      template: template,
      values: [
        "USER_NAME": userName(),
        "TODAY_LONG": longDate(input.day),
        "YESTERDAY_LONG": longDate(input.sourceDay),
        "TIMEZONE": TimeZone.current.identifier,
        "YESTERDAY_CARDS": cardLines(cards),
        "CATEGORIES_WITH_DESCRIPTIONS": categoryLines(categories),
        "FEEDBACK_DAYS": String(feedbackDays),
        "FEEDBACK_SUMMARY": feedbackSummary(input.feedbackEvents),
        "RECENT_BRIEF_ITEMS": recentBriefItems(input.recentBriefs),
        "CANDIDATES_DIR": candidatesDirectory.path,
        "OVERRIDE_INSTRUCTIONS": DailyBriefPrompt.overrideInstructionsBlock(
          input.overrideInstructions),
      ])

    let options = try commandOptions(
      runDirectory: runDirectory, candidatesDirectory: candidatesDirectory)
    let run = try runStructuredClaude(
      prompt: prompt,
      options: options,
      workingDirectory: runDirectory,
      timeoutSeconds: runTimeoutSeconds,
      transcriptURL: DailyBriefStore.transcriptURL(for: input.day),
      tooLongMessage:
        "Claude took longer than 20 minutes on your brief, so Target Flow stopped it. Try again."
    )

    let content: DailyBriefContent
    do {
      content = try JSONDecoder().decode(DailyBriefContent.self, from: run.json)
    } catch {
      print("[DailyBrief] Could not decode the brief: \(error)")
      throw GenerationError(message: "Claude's answer came back in an unexpected shape. Try again.")
    }

    var stats = run.stats
    stats.cardCount = cards.count
    stats.candidateImageCount = candidates.count
    stats.promptCharacters = prompt.count
    stats.usedPromptOverride = usesPromptOverride
    stats.usedOverrideInstructions =
      !input.overrideInstructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

    let cleanedContent = cleaned(
      content, candidates: candidates, candidatesDirectory: candidatesDirectory, day: input.day)
    return DailyBriefGeneration(content: cleanedContent, stats: stats)
  }

  // MARK: - Run directory

  /// A fresh temp folder for this run. The path is fully resolved (/private/var/...)
  /// so Claude's permission rule for the candidates folder matches the files it reads.
  private static func makeRunDirectory(for day: String) throws -> URL {
    let base = FileManager.default.temporaryDirectory
      .appendingPathComponent("dayflow-daily-brief", isDirectory: true)
      .appendingPathComponent(day, isDirectory: true)
    let fileManager = FileManager.default
    try? fileManager.removeItem(at: base)
    do {
      try fileManager.createDirectory(
        at: base.appendingPathComponent("candidates", isDirectory: true),
        withIntermediateDirectories: true)
    } catch {
      throw GenerationError(message: "Target Flow couldn't create a temporary folder for the brief.")
    }
    return URL(fileURLWithPath: resolvedPath(base.path), isDirectory: true)
  }

  private static func resolvedPath(_ path: String) -> String {
    guard let resolved = realpath(path, nil) else { return path }
    defer { free(resolved) }
    return String(cString: resolved)
  }

  // MARK: - Cards

  private static func nonIdleCards(_ cards: [TimelineCard], categories: [TimelineCategory])
    -> [TimelineCard]
  {
    let idleNames = Set(categories.filter(\.isIdle).map { $0.name.lowercased() })
    return cards.filter { card in
      let category = card.category.trimmingCharacters(in: .whitespaces).lowercased()
      // "System" cards are failed-processing placeholders, not activity.
      return category != "idle" && category != "system" && !idleNames.contains(category)
    }
  }

  /// One compact line per card:
  /// `[cardId 123] 9:05 AM–10:20 AM · Work · Title — summary · apps: figma.com, slack`
  private static func cardLines(_ cards: [TimelineCard]) -> String {
    cards.map { card in
      var line = "[cardId \(card.recordId.map { String($0) } ?? "?")] "
      line += "\(card.startTimestamp)–\(card.endTimestamp) · \(card.category) · \(card.title)"
      let summary = card.summary.trimmingCharacters(in: .whitespacesAndNewlines)
      if !summary.isEmpty {
        line += " — " + String(summary.prefix(400))
      }
      let apps = [card.appSites?.primary, card.appSites?.secondary]
        .compactMap { $0?.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
      if !apps.isEmpty {
        line += " · apps: " + apps.joined(separator: ", ")
      }
      return line
    }
    .joined(separator: "\n")
  }

  private static func categoryLines(_ categories: [TimelineCategory]) -> String {
    let lines =
      categories
      .filter { !$0.isIdle }
      .sorted { $0.order < $1.order }
      .map { category -> String in
        let details = category.details.trimmingCharacters(in: .whitespacesAndNewlines)
        return "- \(category.name): " + (details.isEmpty ? "(no description)" : details)
      }
    return lines.isEmpty ? "No categories set up." : lines.joined(separator: "\n")
  }

  // MARK: - Candidate screenshots

  struct Candidate: Codable {
    let file: String
    let cardId: Int64
    let start: String
    let end: String
    let title: String
  }

  /// Writes the middle screenshot of each card as `<cardId>_<HHmm>.jpg`, plus index.json.
  private static func exportCandidates(for cards: [TimelineCard], into directory: URL)
    -> [Candidate]
  {
    let sampled = evenlySampled(cards.filter { $0.recordId != nil }, limit: maxCandidates)
    let timeFormatter = DateFormatter()
    timeFormatter.dateFormat = "HHmm"

    var candidates: [Candidate] = []
    for card in sampled {
      guard let cardId = card.recordId,
        let stored = StorageManager.shared.fetchTimelineCard(byId: cardId)
      else { continue }

      let screenshots = StorageManager.shared.fetchScreenshotsInTimeRange(
        startTs: stored.startTs, endTs: stored.endTs)
      guard !screenshots.isEmpty else { continue }
      let middle = screenshots[screenshots.count / 2]
      guard let image = FrameStore.shared.image(for: middle, maxPixelSize: candidateMaxPixelSize)
      else { continue }

      let start = Date(timeIntervalSince1970: TimeInterval(stored.startTs))
      let file = "\(cardId)_\(timeFormatter.string(from: start)).jpg"
      guard writeJPEG(image, to: directory.appendingPathComponent(file), quality: 0.8) else {
        continue
      }
      candidates.append(
        Candidate(
          file: file, cardId: cardId, start: card.startTimestamp, end: card.endTimestamp,
          title: card.title))
    }

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted]
    if let data = try? encoder.encode(candidates) {
      try? data.write(to: directory.appendingPathComponent("index.json"), options: .atomic)
    }
    return candidates
  }

  private static func evenlySampled<T>(_ items: [T], limit: Int) -> [T] {
    guard items.count > limit else { return items }
    return (0..<limit).map { items[$0 * items.count / limit] }
  }

  private static func writeJPEG(_ image: CGImage, to url: URL, quality: CGFloat) -> Bool {
    guard
      let destination = CGImageDestinationCreateWithURL(
        url as CFURL, "public.jpeg" as CFString, 1, nil)
    else { return false }
    CGImageDestinationAddImage(
      destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
    return CGImageDestinationFinalize(destination)
  }

  // MARK: - Prompt pieces

  /// The Mac account's first name, since Dayflow doesn't ask for one.
  private static func userName() -> String {
    let fullName = NSFullUserName().trimmingCharacters(in: .whitespacesAndNewlines)
    let firstName = fullName.split(separator: " ").first.map(String.init) ?? ""
    return firstName.isEmpty ? "the user" : firstName
  }

  /// "2026-10-22" -> "Thursday, October 22, 2026"
  private static func longDate(_ day: String) -> String {
    guard let date = DateFormatter.yyyyMMdd.date(from: day) else { return day }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US")
    formatter.dateFormat = "EEEE, MMMM d, yyyy"
    return formatter.string(from: date)
  }

  private static func feedbackSummary(_ events: [DailyBriefFeedbackEvent]) -> String {
    let cutoff = Date().addingTimeInterval(-Double(feedbackDays) * 24 * 60 * 60)
    let recent = events.filter { $0.at >= cutoff }.sorted { $0.at < $1.at }
    guard !recent.isEmpty else { return "No feedback yet." }

    var lines = ["Counts by section:"]
    let bySection = Dictionary(grouping: recent, by: \.section)
    for section in bySection.keys.sorted() {
      let counts = Dictionary(grouping: bySection[section] ?? [], by: \.action.rawValue)
        .map { "\($0.key) \($0.value.count)" }
        .sorted()
        .joined(separator: ", ")
      lines.append("- \(section): \(counts)")
    }

    lines.append("")
    lines.append("Latest actions:")
    for event in recent.suffix(maxFeedbackLines) {
      lines.append(
        "- \(event.day) · \(event.section) · \(event.action.rawValue) · \"\(event.itemTitle)\"")
    }
    return lines.joined(separator: "\n")
  }

  private static func recentBriefItems(_ briefs: [DailyBrief]) -> String {
    var blocks: [String] = []
    for brief in briefs.sorted(by: { $0.day > $1.day }) {
      let content = brief.content
      var lines: [String] = []
      for item in content.docket ?? [] {
        lines.append("- docket: \(item.title)")
      }
      for item in content.keepTracking ?? [] {
        lines.append("- keep_tracking: \(item.label) — \(item.status)")
      }
      for item in content.completedYesterday ?? [] {
        lines.append("- completed_yesterday: \(item.title)")
      }
      for item in content.teamDecisions ?? [] {
        lines.append("- team_decisions: \(item.decision)")
      }
      for item in content.relatedReading ?? [] {
        lines.append("- related_reading: \(item.title) (\(item.url))")
      }
      for item in content.industryNews ?? [] {
        lines.append("- industry_news: \(item.headline) (\(item.url))")
      }
      for item in content.siteSeeing ?? [] {
        lines.append("- site_seeing: \(item.caption ?? item.file)")
      }
      guard !lines.isEmpty else { continue }
      blocks.append("#### \(brief.day)\n" + lines.joined(separator: "\n"))
    }
    return blocks.isEmpty ? "None yet." : blocks.joined(separator: "\n\n")
  }

  // MARK: - Command

  private static func commandOptions(runDirectory: URL, candidatesDirectory: URL) throws
    -> ClaudeCLIStructuredOutputOptions
  {
    let hookURL = runDirectory.appendingPathComponent("read_only_hook.sh")
    do {
      try readOnlyHookScript.write(to: hookURL, atomically: true, encoding: .utf8)
    } catch {
      throw GenerationError(message: "Target Flow couldn't prepare the brief's safety check.")
    }

    // Every MCP tool call goes through the read-only hook first.
    let hook: [String: Any] = [
      "matcher": "mcp__.*",
      "hooks": [["type": "command", "command": "/bin/sh '\(hookURL.path)'"]],
    ]
    let settings: [String: Any] = ["hooks": ["PreToolUse": [hook]]]

    // Claude permission rules use // for absolute paths; / is project-relative.
    var allowedTools = ["WebSearch", "WebFetch", "Read(/\(candidatesDirectory.path)/**)"]
    allowedTools += dayflowReadTools.map { "mcp__dayflow__\($0)" }

    return ClaudeCLIStructuredOutputOptions(
      tools: "Read,WebSearch,WebFetch",
      jsonSchema: jsonString(contentSchema),
      name: "dayflow-daily-brief",
      allowedTools: allowedTools,
      mcpConfigPath: dayflowMCPConfigPath(in: runDirectory),
      settingsJSON: jsonString(settings),
      loadsUserMCPServers: true
    )
  }

  /// Writes an `--mcp-config` file that adds Dayflow's bundled MCP server, or nil
  /// when the bundled CLI is missing (e.g. some debug builds).
  private static func dayflowMCPConfigPath(in runDirectory: URL) -> String? {
    // Same path as AgentClientRegistration.cliPath, which is main-actor isolated.
    let cliPath = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/dayflow").path
    guard FileManager.default.isExecutableFile(atPath: cliPath) else { return nil }

    let server: [String: Any] = ["command": cliPath, "args": ["mcp"]]
    let config: [String: Any] = ["mcpServers": ["dayflow": server]]
    let url = runDirectory.appendingPathComponent("mcp.json")
    do {
      try jsonString(config).write(to: url, atomically: true, encoding: .utf8)
      return url.path
    } catch {
      return nil
    }
  }

  /// PreToolUse hook that keeps MCP tools read-only. It reads the hook JSON on
  /// stdin, takes the tool's own name (after the last "__"), and splits it into
  /// words. Dayflow's server is allowed except its write tools. Other tools are
  /// denied when any word is a write verb, allowed when a word is a read verb,
  /// and denied otherwise. Deny is exit 2 with the reason on stderr; allow prints
  /// an explicit allow so connector reads don't stall on a permission prompt.
  static let readOnlyHookScript = #"""
    #!/bin/sh
    # Target Flow Daily brief: keeps MCP tools (the user's connectors) read-only.

    input=$(cat | tr '\n' ' ')
    tool=$(printf '%s' "$input" \
      | grep -o '"tool_name"[[:space:]]*:[[:space:]]*"[^"]*"' \
      | head -n 1 \
      | sed 's/.*:[[:space:]]*"\([^"]*\)"$/\1/')

    deny() {
      echo "Target Flow's daily brief can only read from your tools, so $tool was blocked." >&2
      exit 2
    }

    allow() {
      printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow"}}'
      exit 0
    }

    [ -n "$tool" ] || deny

    lower=$(printf '%s' "$tool" | tr '[:upper:]' '[:lower:]')

    # Target Flow's own server: everything except the tools that change data.
    case "$lower" in
      mcp__dayflow__create_category | mcp__dayflow__delete_category | \
      mcp__dayflow__update_category | mcp__dayflow__delete_activity | \
      mcp__dayflow__update_activity | mcp__dayflow__set_day_goal)
        deny ;;
      mcp__dayflow__*)
        allow ;;
    esac

    # Other tools: split the name after the last "__" into words,
    # breaking on camelCase and punctuation ("sendMessage" -> "send message").
    short=${tool##*__}
    words=$(printf '%s' "$short" \
      | sed 's/\([a-z0-9]\)\([A-Z]\)/\1 \2/g' \
      | tr '[:upper:]' '[:lower:]' \
      | tr -c 'a-z0-9' ' ')

    for word in $words; do
      case "$word" in
        send | post | create | update | delete | write | edit | remove | add | reply | \
        archive | move | upload | set | schedule | invite | comment | react | mark | \
        publish | share | assign | close | merge | approve | draft | submit | cancel | \
        rename | transfer | pay | run | execute | exec | insert | replace | append | \
        patch | put | save | import | apply | trigger | respond | accept | decline | \
        complete | resolve | star | follow | subscribe | label | tag | forward | \
        duplicate | restore | revert | deploy | kill | start | stop | enable | disable | \
        toggle | unsubscribe | unfollow | pin | unpin | snooze | mute)
          deny ;;
      esac
    done

    for word in $words; do
      case "$word" in
        get | list | search | read | fetch | query | find | view | retrieve | describe | \
        lookup | download)
          allow ;;
      esac
    done

    deny

    """#

  // MARK: - Schema

  private static let stringSchema: [String: Any] = ["type": "string"]

  private static func arraySchema(_ items: [String: Any]) -> [String: Any] {
    ["type": "array", "items": items]
  }

  private static func objectSchema(_ properties: [String: Any], required: [String])
    -> [String: Any]
  {
    [
      "type": "object",
      "properties": properties,
      "required": required,
      "additionalProperties": false,
    ]
  }

  /// JSON Schema for DailyBriefContent. Every section is optional; `order` is required.
  /// `imageFile` on completed items is filled in by the app, so it isn't offered here.
  static var contentSchema: [String: Any] {
    let person = objectSchema(["name": stringSchema, "note": stringSchema], required: ["name"])
    let link = objectSchema(
      ["title": stringSchema, "url": stringSchema, "app": stringSchema], required: ["title"])

    let docketItem = objectSchema(
      [
        "title": stringSchema,
        "detail": stringSchema,
        "due": stringSchema,
        "people": arraySchema(person),
        "links": arraySchema(link),
      ], required: ["title"])
    let trackingItem = objectSchema(
      [
        "label": stringSchema,
        "status": stringSchema,
        "app": stringSchema,
        "asOf": stringSchema,
        "url": stringSchema,
      ], required: ["label", "status"])
    let completedItem = objectSchema(
      [
        "project": stringSchema,
        "title": stringSchema,
        "apps": arraySchema(stringSchema),
        "cardId": ["type": "integer"],
      ], required: ["title"])
    let decisionItem = objectSchema(
      [
        "decision": stringSchema,
        "date": stringSchema,
        "people": arraySchema(stringSchema),
        "place": stringSchema,
        "app": stringSchema,
        "url": stringSchema,
      ], required: ["decision"])
    let readingItem = objectSchema(
      [
        "title": stringSchema,
        "source": stringSchema,
        "url": stringSchema,
        "reason": stringSchema,
        "imageUrl": stringSchema,
      ], required: ["title", "url"])
    let newsItem = objectSchema(
      [
        "headline": stringSchema,
        "source": stringSchema,
        "url": stringSchema,
        "published": stringSchema,
      ], required: ["headline", "url"])
    let siteSeeingItem = objectSchema(
      ["file": stringSchema, "caption": stringSchema], required: ["file"])

    let sectionNames = DailyBriefSectionKind.allCases.map(\.rawValue)
    return objectSchema(
      [
        "order": arraySchema(["type": "string", "enum": sectionNames]),
        "docket": arraySchema(docketItem),
        "keep_tracking": arraySchema(trackingItem),
        "completed_yesterday": arraySchema(completedItem),
        "team_decisions": arraySchema(decisionItem),
        "related_reading_intro": stringSchema,
        "related_reading": arraySchema(readingItem),
        "industry_news": arraySchema(newsItem),
        "site_seeing": arraySchema(siteSeeingItem),
      ], required: ["order"])
  }

  static func jsonString(_ object: Any) -> String {
    guard
      let data = try? JSONSerialization.data(
        withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]),
      let string = String(data: data, encoding: .utf8)
    else { return "{}" }
    return string
  }

  // MARK: - Running Claude

  struct StructuredClaudeResult {
    /// The JSON the model produced.
    let json: Data
    /// Model, cost, tokens, turns, and tool calls. The caller fills in the rest.
    let stats: DailyBriefRunStats
  }

  /// Runs `claude -p` with a structured-output profile and returns the JSON the
  /// model produced (the envelope's `structured_output`, or JSON found in `result`).
  /// Throws GenerationError with a plain message on any failure.
  static func runStructuredClaude(
    prompt: String,
    options: ClaudeCLIStructuredOutputOptions,
    workingDirectory: URL,
    timeoutSeconds: TimeInterval,
    transcriptURL: URL? = nil,
    tooLongMessage: String
  ) throws -> StructuredClaudeResult {
    let runner = ChatCLIProcessRunner()
    let run: ChatCLIRunResult
    do {
      run = try runner.run(
        tool: .claude,
        prompt: prompt,
        workingDirectory: workingDirectory,
        model: model,
        claudeProfile: .structuredOutput(options),
        timeoutSeconds: timeoutSeconds
      )
    } catch let error as NSError where error.domain == "ChatCLI" && error.code == -3 {
      throw GenerationError(message: tooLongMessage)
    } catch {
      throw GenerationError(message: friendlyMessage(for: error.localizedDescription))
    }

    let events = outputEvents(in: run.rawStdout, runner: runner)
    if let transcriptURL {
      writeTranscript(prompt: prompt, events: events, run: run, to: transcriptURL)
    }
    let envelope = events.last { $0["type"] as? String == "result" }
    let isError = (envelope?["is_error"] as? Bool) == true
    let subtype = envelope?["subtype"] as? String ?? ""

    if let envelope, !isError, subtype == "success" || subtype.isEmpty {
      if let structured = envelope["structured_output"],
        JSONSerialization.isValidJSONObject(structured),
        let data = try? JSONSerialization.data(withJSONObject: structured)
      {
        return StructuredClaudeResult(
          json: data, stats: runStats(envelope: envelope, events: events))
      }
      if let text = envelope["result"] as? String,
        let data = jsonObjectData(in: text, runner: runner)
      {
        return StructuredClaudeResult(
          json: data, stats: runStats(envelope: envelope, events: events))
      }
    }

    let resultText = envelope?["result"] as? String ?? ""
    print(
      "[DailyBrief] Claude run failed. exit=\(run.exitCode) subtype=\(subtype) "
        + "result=\(resultText.prefix(500)) stderr=\(run.stderr.suffix(500))")

    if subtype == "error_max_turns" {
      throw GenerationError(message: "Claude ran out of steps before finishing. Try again.")
    }
    if subtype.contains("structured_output") {
      throw GenerationError(message: "Claude's answer came back in an unexpected shape. Try again.")
    }
    let rawMessage =
      [resultText, run.stderr, run.stdout]
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .first { !$0.isEmpty } ?? ""
    throw GenerationError(message: friendlyMessage(for: rawMessage))
  }

  /// The events in Claude's JSON output (a single result object, or with --verbose an
  /// array of every event), even with login-shell noise around it. Empty when there's
  /// no result event.
  private static func outputEvents(in rawStdout: String, runner: ChatCLIProcessRunner)
    -> [[String: Any]]
  {
    let trimmed = rawStdout.trimmingCharacters(in: .whitespacesAndNewlines)
    for candidate in [trimmed] + runner.balancedJSONValues(in: trimmed) {
      guard let data = candidate.data(using: .utf8),
        let json = try? JSONSerialization.jsonObject(with: data)
      else { continue }
      let events = (json as? [[String: Any]]) ?? [json as? [String: Any]].compactMap { $0 }
      if events.contains(where: { $0["type"] as? String == "result" }) {
        return events
      }
    }
    return []
  }

  // MARK: - Transcript

  /// Saves the whole run as readable text (prompt, every message, tool call, and
  /// tool result, then the final result) for the footer's Transcript button.
  /// Written for failed runs too, since those are the ones worth reading.
  private static func writeTranscript(
    prompt: String, events: [[String: Any]], run: ChatCLIRunResult, to url: URL
  ) {
    var sections: [String] = ["# Prompt\n\n" + prompt]

    if events.isEmpty {
      // No parseable events, so show what the CLI printed instead.
      sections.append("# Raw output\n\n" + run.rawStdout)
    }

    for event in events {
      switch event["type"] as? String {
      case "system":
        var lines = ["# Session started"]
        if let model = event["model"] as? String { lines.append("model: \(model)") }
        if let tools = event["tools"] as? [String] {
          lines.append("tools: " + tools.joined(separator: ", "))
        }
        if let servers = event["mcp_servers"] as? [[String: Any]] {
          let names = servers.map { "\($0["name"] ?? "?") (\($0["status"] ?? "?"))" }
          lines.append("connectors: " + names.joined(separator: ", "))
        }
        sections.append(lines.joined(separator: "\n"))

      case "assistant":
        let message = event["message"] as? [String: Any]
        for block in message?["content"] as? [[String: Any]] ?? [] {
          switch block["type"] as? String {
          case "text":
            sections.append("## Claude\n\n" + (block["text"] as? String ?? ""))
          case "thinking":
            sections.append("## Claude (thinking)\n\n" + (block["thinking"] as? String ?? ""))
          case "tool_use":
            let name = block["name"] as? String ?? "?"
            sections.append("## Tool call: \(name)\n\n" + prettyJSON(block["input"] ?? [:]))
          default:
            continue
          }
        }

      case "user":
        let message = event["message"] as? [String: Any]
        for block in message?["content"] as? [[String: Any]] ?? [] {
          guard block["type"] as? String == "tool_result" else { continue }
          let heading = (block["is_error"] as? Bool) == true ? "## Tool error" : "## Tool result"
          sections.append(heading + "\n\n" + toolResultText(block["content"]))
        }

      case "result":
        var lines = ["# Result"]
        if let subtype = event["subtype"] as? String { lines.append("subtype: \(subtype)") }
        if let structured = event["structured_output"] {
          lines.append("\n" + prettyJSON(structured))
        } else if let text = event["result"] as? String {
          lines.append("\n" + text)
        }
        sections.append(lines.joined(separator: "\n"))

      default:
        continue
      }
    }

    let stderr = run.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
    if !stderr.isEmpty {
      sections.append("# stderr\n\n" + stderr)
    }

    let text = sections.joined(separator: "\n\n---\n\n") + "\n"
    try? FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? text.write(to: url, atomically: true, encoding: .utf8)
  }

  /// Tool results are either a string or a list of content blocks.
  private static func toolResultText(_ content: Any?) -> String {
    if let text = content as? String { return text }
    let blocks = content as? [[String: Any]] ?? []
    return blocks.map { block in
      if let text = block["text"] as? String { return text }
      return "[\(block["type"] as? String ?? "unknown") block]"
    }
    .joined(separator: "\n")
  }

  private static func prettyJSON(_ value: Any) -> String {
    guard JSONSerialization.isValidJSONObject(value),
      let data = try? JSONSerialization.data(
        withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
      let string = String(data: data, encoding: .utf8)
    else { return String(describing: value) }
    return string
  }

  /// Cost, tokens, turns, model, and tool-call counts from the result envelope and
  /// the --verbose event stream.
  private static func runStats(envelope: [String: Any], events: [[String: Any]])
    -> DailyBriefRunStats
  {
    var stats = DailyBriefRunStats()
    stats.costUSD = (envelope["total_cost_usd"] as? NSNumber)?.doubleValue
    stats.numTurns = (envelope["num_turns"] as? NSNumber)?.intValue
    if let usage = envelope["usage"] as? [String: Any] {
      stats.inputTokens = (usage["input_tokens"] as? NSNumber)?.intValue
      stats.outputTokens = (usage["output_tokens"] as? NSNumber)?.intValue
      stats.cacheReadTokens = (usage["cache_read_input_tokens"] as? NSNumber)?.intValue
    }

    // modelUsage is keyed by full model id; the one that wrote the most is the main model.
    func outputTokens(_ usage: Any) -> Int {
      ((usage as? [String: Any])?["outputTokens"] as? NSNumber)?.intValue ?? 0
    }
    let modelUsage = envelope["modelUsage"] as? [String: Any] ?? [:]
    let mainModel = modelUsage.max(by: { outputTokens($0.value) < outputTokens($1.value) })
    let initEvent = events.first(where: { $0["type"] as? String == "system" })
    stats.model = mainModel?.key ?? (initEvent?["model"] as? String) ?? model

    var toolCalls: [String: Int] = [:]
    for event in events where event["type"] as? String == "assistant" {
      let message = event["message"] as? [String: Any]
      for block in message?["content"] as? [[String: Any]] ?? [] {
        // StructuredOutput is how the CLI returns the answer, not a real tool call.
        guard block["type"] as? String == "tool_use", let name = block["name"] as? String,
          name != "StructuredOutput"
        else {
          continue
        }
        toolCalls[name, default: 0] += 1
      }
    }
    stats.toolCalls = toolCalls.isEmpty ? nil : toolCalls
    return stats
  }

  /// The first JSON object in model text, ignoring ``` fences and prose around it.
  private static func jsonObjectData(in text: String, runner: ChatCLIProcessRunner) -> Data? {
    let cleaned =
      text
      .replacingOccurrences(of: "```json", with: "")
      .replacingOccurrences(of: "```", with: "")
    for candidate in runner.balancedJSONValues(in: cleaned) where candidate.hasPrefix("{") {
      if let data = candidate.data(using: .utf8),
        (try? JSONSerialization.jsonObject(with: data)) is [String: Any]
      {
        return data
      }
    }
    return nil
  }

  /// Turns raw CLI output into one plain sentence, using the timeline's failure patterns.
  static func friendlyMessage(for raw: String) -> String {
    let error = NSError(
      domain: "DailyBrief", code: 0, userInfo: [NSLocalizedDescriptionKey: raw])
    switch TimelineFailureClassifier.classify(error).kind {
    case .usageLimitHit:
      return "Claude hit its usage limit. Try again after it resets."
    case .providerLoginExpired:
      return "Claude isn't signed in. Open Terminal, run `claude`, then type /login."
    case .cliNotInstalled:
      return "Target Flow couldn't find Claude Code on this Mac."
    case .outOfCredits, .apiKeyProblem, .accountBlocked:
      return "Claude's account has a billing or API key problem, so the brief couldn't run."
    case .modelMisconfigured:
      return "Your Claude account can't use the Opus model the brief needs."
    case .transient:
      return "Target Flow couldn't reach Claude. Try again in a bit."
    case .modelFlaky:
      return "Claude's answer came back in an unexpected shape. Try again."
    default:
      return "Claude couldn't finish the brief. Try again."
    }
  }

  // MARK: - Clean up the model's answer

  /// Trims text, drops empty or unlinkable items, keeps only real screenshots, and
  /// copies the images the brief shows into `<day>/images/`.
  private static func cleaned(
    _ content: DailyBriefContent, candidates: [Candidate], candidatesDirectory: URL, day: String
  ) -> DailyBriefContent {
    let imagesDirectory = DailyBriefStore.briefDirectory(for: day)
      .appendingPathComponent("images", isDirectory: true)
    let candidateFiles = Set(candidates.map(\.file))
    var copiedFiles: Set<String> = []

    // Old images stay until replaced, so the brief on screen during a retry keeps its pictures.
    try? FileManager.default.createDirectory(at: imagesDirectory, withIntermediateDirectories: true)

    /// Copies a candidate into images/ and returns "images/<file>", or nil on failure.
    func copyCandidate(_ file: String) -> String? {
      if !copiedFiles.contains(file) {
        let source = candidatesDirectory.appendingPathComponent(file)
        let destination = imagesDirectory.appendingPathComponent(file)
        do {
          if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
          }
          try FileManager.default.copyItem(at: source, to: destination)
        } catch {
          print("[DailyBrief] Failed to copy \(file): \(error)")
          return nil
        }
        copiedFiles.insert(file)
      }
      return "images/\(file)"
    }

    var result = DailyBriefContent(order: [])

    result.docket = nonEmpty(
      (content.docket ?? []).compactMap { item -> DailyBriefDocketItem? in
        guard let title = clean(item.title) else { return nil }
        let people = (item.people ?? []).compactMap { person -> DailyBriefPerson? in
          guard let name = clean(person.name) else { return nil }
          return DailyBriefPerson(name: name, note: clean(person.note))
        }
        let links = (item.links ?? []).compactMap { link -> DailyBriefLink? in
          guard let title = clean(link.title) else { return nil }
          return DailyBriefLink(title: title, url: webURL(link.url), app: cleanApp(link.app))
        }
        return DailyBriefDocketItem(
          title: title, detail: clean(item.detail), due: clean(item.due),
          people: nonEmpty(people), links: nonEmpty(links))
      })

    result.keepTracking = nonEmpty(
      (content.keepTracking ?? []).compactMap { item -> DailyBriefTrackingItem? in
        guard let label = clean(item.label), let status = clean(item.status) else { return nil }
        return DailyBriefTrackingItem(
          label: label, status: status, app: cleanApp(item.app), asOf: clean(item.asOf),
          url: webURL(item.url))
      })

    result.completedYesterday = nonEmpty(
      (content.completedYesterday ?? []).compactMap { item -> DailyBriefCompletedItem? in
        guard let title = clean(item.title) else { return nil }
        let candidate = candidates.first { $0.cardId == item.cardId }
        let apps = (item.apps ?? []).compactMap { cleanApp($0) }
        return DailyBriefCompletedItem(
          project: clean(item.project), title: title, apps: nonEmpty(apps),
          cardId: candidate?.cardId, imageFile: candidate.flatMap { copyCandidate($0.file) })
      })

    result.teamDecisions = nonEmpty(
      (content.teamDecisions ?? []).compactMap { item -> DailyBriefDecisionItem? in
        guard let decision = clean(item.decision) else { return nil }
        let people = (item.people ?? []).compactMap { clean($0) }
        return DailyBriefDecisionItem(
          decision: decision, date: clean(item.date), people: nonEmpty(people),
          place: clean(item.place), app: cleanApp(item.app), url: webURL(item.url))
      })

    result.relatedReading = nonEmpty(
      (content.relatedReading ?? []).compactMap { item -> DailyBriefReadingItem? in
        guard let title = clean(item.title), let url = webURL(item.url) else { return nil }
        return DailyBriefReadingItem(
          title: title, source: clean(item.source), url: url, reason: clean(item.reason),
          imageUrl: webURL(item.imageUrl))
      })
    result.relatedReadingIntro =
      result.relatedReading == nil ? nil : clean(content.relatedReadingIntro)

    result.industryNews = nonEmpty(
      (content.industryNews ?? []).compactMap { item -> DailyBriefNewsItem? in
        guard let headline = clean(item.headline), let url = webURL(item.url) else { return nil }
        return DailyBriefNewsItem(
          headline: headline, source: clean(item.source), url: url,
          published: clean(item.published))
      })

    var seenSiteSeeingFiles: Set<String> = []
    result.siteSeeing = nonEmpty(
      (content.siteSeeing ?? []).compactMap { item -> DailyBriefSiteSeeingItem? in
        // The model may echo a path; only the file name has to match a candidate.
        guard let raw = clean(item.file) else { return nil }
        let file = (raw as NSString).lastPathComponent
        guard candidateFiles.contains(file), !seenSiteSeeingFiles.contains(file),
          let copied = copyCandidate(file)
        else { return nil }
        seenSiteSeeingFiles.insert(file)
        return DailyBriefSiteSeeingItem(file: copied, caption: clean(item.caption))
      })

    var order: [String] = []
    for name in content.order {
      let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
      if let kind = DailyBriefSectionKind(rawValue: trimmed), result.hasItems(kind),
        !order.contains(trimmed)
      {
        order.append(trimmed)
      }
    }
    result.order = order
    return result
  }

  private static func clean(_ text: String?) -> String? {
    guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty
    else { return nil }
    return trimmed
  }

  private static func cleanApp(_ app: String?) -> String? {
    clean(app)?.lowercased()
  }

  /// The URL when it's a real http(s) link, otherwise nil.
  private static func webURL(_ text: String?) -> String? {
    guard let trimmed = clean(text), let url = URL(string: trimmed),
      let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
      url.host != nil
    else { return nil }
    return trimmed
  }

  private static func nonEmpty<T>(_ items: [T]) -> [T]? {
    items.isEmpty ? nil : items
  }
}
