import XCTest

@testable import Dayflow

final class ModelExecutionHistoryTests: XCTestCase {
  func testReportedModelsComeOnlyFromExplicitEnvelopeFields() {
    let raw = #"""
      shell banner
      [{"type":"system","subtype":"init","model":"resolved-model","session_id":"private-session"},
       {"type":"assistant","message":{"model":"message-model","content":[{"text":"{\"model\":\"invented\"}"}]}},
       {"type":"result","modelUsage":{"usage-model":{}},"result":"model: invented"}]
      """#
    let metadata = CLIReportedExecutionMetadata.parse(raw)
    XCTAssertEqual(Set(metadata.models), ["resolved-model", "message-model", "usage-model"])
    XCTAssertNil(metadata.reasoning)
    XCTAssertTrue(CLIReportedExecutionMetadata.parse(#"{"model":"untyped"}"#).models.isEmpty)
    XCTAssertTrue(CLIReportedExecutionMetadata.parse(#"{"type":"item.completed","item":{"model":"tool-output"}}"#).models.isEmpty)
  }

  func testAbsentReasoningIsUnknownEvenWhenThinkingTextAppears() {
    let raw = #"""
      {"type":"item.completed","item":{"type":"reasoning","text":"thinking hard"}}
      {"type":"turn.completed","model":"resolved","usage":{}}
      """#
    let metadata = CLIReportedExecutionMetadata.parse(raw)
    XCTAssertNil(metadata.reasoning)
    XCTAssertEqual(metadata.models, ["resolved"])
    XCTAssertEqual(CLIReportedExecutionMetadata.parse(#"{"type":"init","effort":"high"}"#).reasoning, "high")
  }

  func testBoundedPersistedHistoryAndConcurrentUpdates() throws {
    let suite = "ModelExecutionHistoryTests-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let history = ModelExecutionHistory(defaults: defaults)
    DispatchQueue.concurrentPerform(iterations: 80) { index in
      history.record(
        provider: "codex", requestedModel: String(repeating: "m", count: 600),
        requestedReasoning: "high", startedAt: Date(timeIntervalSince1970: Double(index)),
        finishedAt: Date(timeIntervalSince1970: Double(index)), outcome: .succeeded)
    }
    let reloaded = ModelExecutionHistory(defaults: defaults).records
    XCTAssertEqual(reloaded.count, 50)
    XCTAssertEqual(reloaded.first?.finishedAt, Date(timeIntervalSince1970: 79))
    XCTAssertEqual(reloaded.last?.finishedAt, Date(timeIntervalSince1970: 30))
    XCTAssertEqual(reloaded.first?.requestedModel?.count, 256)
    XCTAssertTrue(reloaded.allSatisfy { $0.reportedModels.isEmpty && $0.reportedReasoning == nil })
    let data = try XCTUnwrap(defaults.data(forKey: ModelExecutionHistory.storageKey))
    let encoded = String(decoding: data, as: UTF8.self)
    for forbidden in ["prompt", "stdout", "stderr", "session", "response"] {
      XCTAssertFalse(encoded.contains(forbidden))
    }
    history.clear()
    XCTAssertTrue(history.records.isEmpty)
  }

  func testStreamingFailureIsRecordedWithoutErrorContent() {
    let metadata = StreamingExecutionMetadata()
    metadata.observe(line: #"{"type":"system","subtype":"init","model":"actual"}"#)
    metadata.observe(line: #"{"type":"result","is_error":true,"result":"private response"}"#)
    metadata.finish(exitCode: 0, failed: false)
    XCTAssertTrue(metadata.snapshot().failed)
    XCTAssertEqual(metadata.snapshot().failureCode, "cli_error")
    XCTAssertEqual(metadata.snapshot().models, ["actual"])
  }

  func testCustomCLIArgumentsRoundTripThroughShell() throws {
    let value = "custom model'\"; $(printf injected) `printf injected` \\ \nmore"
    let runner = ChatCLIProcessRunner()
    for parts in [
      runner.buildClaudeCommandParts(prompt: "hello", imagePaths: [], model: value,
        reasoningEffort: value, disableTools: true),
      runner.buildClaudeStreamingCommandParts(prompt: "hello", model: value,
        reasoningEffort: value, sessionId: nil),
    ] {
      for flag in ["--model", "--effort"] {
        let index = try XCTUnwrap(parts.firstIndex(of: flag))
        XCTAssertEqual(try shellValue(parts[index + 1]), value)
      }
    }
    let assignment = try shellValue(ChatCLIProcessRunner.codexReasoningArgument(value))
    let literal = String(assignment.dropFirst("model_reasoning_effort=".count))
    XCTAssertEqual(try JSONDecoder().decode(String.self, from: Data(literal.utf8)), value)
  }

  private func shellValue(_ escaped: String) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", "printf '%s' \(escaped)"]
    let pipe = Pipe()
    process.standardOutput = pipe
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    XCTAssertEqual(process.terminationStatus, 0)
    return String(decoding: data, as: UTF8.self)
  }
}
