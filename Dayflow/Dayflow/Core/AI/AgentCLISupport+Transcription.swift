import Foundation

extension AgentCLISupporting {
  // MARK: - Shared transcription output contract

  func parseSegments(from output: String, stderr: String) throws -> [SegmentMergeResponse
    .Segment]
  {
    // First try parsing without any modifications
    let basicCleaned =
      output
      .replacingOccurrences(of: "```json", with: "")
      .replacingOccurrences(of: "```", with: "")
      .trimmingCharacters(in: .whitespacesAndNewlines)

    // Strategy 1: Direct decode
    if let data = basicCleaned.data(using: .utf8),
      let parsed = try? JSONDecoder().decode(SegmentMergeResponse.self, from: data),
      !parsed.segments.isEmpty
    {
      return parsed.segments
    }

    // Strategy 2: Array decode
    if let data = basicCleaned.data(using: .utf8),
      let parsed = try? JSONDecoder().decode([SegmentMergeResponse.Segment].self, from: data),
      !parsed.isEmpty
    {
      return parsed
    }

    // Strategy 3: Brace extraction
    if let firstBrace = basicCleaned.firstIndex(of: "{"),
      let lastBrace = basicCleaned.lastIndex(of: "}"),
      firstBrace < lastBrace
    {
      let slice = String(basicCleaned[firstBrace...lastBrace])
      if let data = slice.data(using: .utf8),
        let parsed = try? JSONDecoder().decode(SegmentMergeResponse.self, from: data),
        !parsed.segments.isEmpty
      {
        return parsed.segments
      }
    }

    // Strategy 4 (fallback): Strip OSC escapes and retry brace extraction
    let oscCleaned = stripOSCEscapes(basicCleaned)
    if let firstBrace = oscCleaned.firstIndex(of: "{"),
      let lastBrace = oscCleaned.lastIndex(of: "}"),
      firstBrace < lastBrace
    {
      let slice = String(oscCleaned[firstBrace...lastBrace])
      if let data = slice.data(using: .utf8),
        let parsed = try? JSONDecoder().decode(SegmentMergeResponse.self, from: data),
        !parsed.segments.isEmpty
      {
        return parsed.segments
      }
    }

    // Surface CLI error messages to the user if available
    if let cliError = extractCLIError(stdout: output, stderr: stderr) {
      throw NSError(domain: "ChatCLI", code: -33, userInfo: [NSLocalizedDescriptionKey: cliError])
    }

    throw NSError(
      domain: "ChatCLI", code: -31,
      userInfo: [NSLocalizedDescriptionKey: "Failed to decode segments JSON"])
  }

}
