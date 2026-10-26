//
//  DailyBriefRangeSummarizer.swift
//  Dayflow
//
//  "Everything you completed": turns the completed items saved in past briefs
//  into a review-ready summary for a range (last 7 days, quarter to date...).
//  One `claude -p` call with no tools; synchronous and blocking.
//

import Foundation

enum DailyBriefRangeSummarizer {
  static let timeoutSeconds: TimeInterval = 5 * 60

  /// What the model returns; mapped onto DailyBriefRangeSummary.
  private struct Output: Decodable {
    struct Project: Decodable {
      var title: String
      var bullets: [String]
      var impact: String?
      var imageEntryIndex: Int?
    }

    var overview: String
    var milestones: [String]
    var projects: [Project]
  }

  static func summarize(
    range: DailyBriefSummaryRange,
    entries: [DailyBriefCompletedEntry],
    startDay: String,
    endDay: String
  ) throws -> DailyBriefRangeSummary {
    guard !entries.isEmpty else {
      throw DailyBriefGenerator.GenerationError(
        message: "No completed work saved in this range yet.")
    }

    // Oldest first reads more naturally as a story of the period.
    let ordered = entries.sorted { $0.day < $1.day }
    let options = ClaudeCLIStructuredOutputOptions(
      tools: "",
      jsonSchema: DailyBriefGenerator.jsonString(schema),
      name: "dayflow-daily-brief-summary"
    )
    let run = try DailyBriefGenerator.runStructuredClaude(
      prompt: prompt(entries: ordered, range: range, startDay: startDay, endDay: endDay),
      options: options,
      workingDirectory: FileManager.default.temporaryDirectory,
      timeoutSeconds: timeoutSeconds,
      tooLongMessage: "Claude took too long on the summary, so Target Flow stopped it. Try again."
    )

    let output: Output
    do {
      output = try JSONDecoder().decode(Output.self, from: run.json)
    } catch {
      print("[DailyBrief] Could not decode the range summary: \(error)")
      throw DailyBriefGenerator.GenerationError(
        message: "Claude's summary came back in an unexpected shape. Try again.")
    }

    let projects = output.projects.compactMap { project -> DailyBriefSummaryProject? in
      let title = project.title.trimmingCharacters(in: .whitespacesAndNewlines)
      let bullets = project.bullets
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
      guard !title.isEmpty, !bullets.isEmpty else { return nil }
      let impact = project.impact?.trimmingCharacters(in: .whitespacesAndNewlines)
      return DailyBriefSummaryProject(
        title: title,
        bullets: bullets,
        impact: (impact?.isEmpty ?? true) ? nil : impact,
        imageFile: imageFile(forEntryIndex: project.imageEntryIndex, in: ordered)
      )
    }

    return DailyBriefRangeSummary(
      range: range,
      startDay: startDay,
      endDay: endDay,
      generatedAt: Date(),
      overview: output.overview.trimmingCharacters(in: .whitespacesAndNewlines),
      milestones: output.milestones
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty },
      projects: projects
    )
  }

  /// "<briefDay>/<images/file.jpg>", relative to DailyBriefStore.rootDirectory().
  private static func imageFile(forEntryIndex index: Int?, in entries: [DailyBriefCompletedEntry])
    -> String?
  {
    guard let index, entries.indices.contains(index),
      let file = entries[index].item.imageFile
    else { return nil }
    return "\(entries[index].briefDay)/\(file)"
  }

  // MARK: - Prompt

  private static func prompt(
    entries: [DailyBriefCompletedEntry], range: DailyBriefSummaryRange, startDay: String,
    endDay: String
  ) -> String {
    let lines = entries.enumerated().map { index, entry -> String in
      var line = "[\(index)] \(entry.day)"
      if let project = entry.item.project, !project.isEmpty {
        line += " · \(project)"
      }
      line += " · \(entry.item.title)"
      if let apps = entry.item.apps, !apps.isEmpty {
        line += " · apps: " + apps.joined(separator: ", ")
      }
      if entry.item.imageFile != nil {
        line += " · (has screenshot)"
      }
      return line
    }

    return """
      Here is everything a Target Flow user completed from \(startDay) to \(endDay) \
      (\(range.label.lowercased())), one line per accomplishment: [index] day · project · what they did · apps.

      \(lines.joined(separator: "\n"))

      Write a crisp summary of what they accomplished in this period, the kind they could paste into \
      a performance review or a weekly update.

      - `overview`: 2–3 sentences on the shape of the period: the main projects and what moved.
      - `milestones`: the 3–6 most significant accomplishments, one line each, most important first.
      - `projects`: group the entries by project or area. For each, a short `title`, 2–6 `bullets` \
      of concrete things they did (merge repeats, keep real names of features, docs, and people), an \
      optional one-sentence `impact` only when the entries support it, and optionally \
      `imageEntryIndex`: the index of one entry marked "(has screenshot)" that best illustrates the project.

      Be concrete and plain. No hype, no filler, no exclamation marks. Only claim what the entries \
      support; don't invent metrics, outcomes, or people. Write in second person ("You shipped...").
      """
  }

  // MARK: - Schema

  private static var schema: [String: Any] {
    let stringArray: [String: Any] = ["type": "array", "items": ["type": "string"]]
    let project: [String: Any] = [
      "type": "object",
      "properties": [
        "title": ["type": "string"],
        "bullets": stringArray,
        "impact": ["type": "string"],
        "imageEntryIndex": ["type": "integer"],
      ] as [String: Any],
      "required": ["title", "bullets"],
      "additionalProperties": false,
    ]
    return [
      "type": "object",
      "properties": [
        "overview": ["type": "string"],
        "milestones": stringArray,
        "projects": ["type": "array", "items": project] as [String: Any],
      ] as [String: Any],
      "required": ["overview", "milestones", "projects"],
      "additionalProperties": false,
    ]
  }
}
