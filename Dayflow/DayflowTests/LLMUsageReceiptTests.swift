import XCTest

@testable import Dayflow

final class LLMUsageReceiptTests: XCTestCase {
  private func receipt(_ json: String, host: String = "openrouter.ai") -> LLMUsageReceipt {
    LLMUsageReceipt.parse(
      body: Data(json.utf8), headers: nil, requestURL: URL(string: "https://\(host)/v1/chat/completions"))
  }

  func testOpenRouterCostIncludesCacheAndReasoningWithoutAddingBreakdownAgain() {
    let value = receipt(#"{"usage":{"prompt_tokens":1000,"completion_tokens":200,"cost":0.0042,"prompt_tokens_details":{"cached_tokens":800},"completion_tokens_details":{"reasoning_tokens":150},"cost_details":{"upstream_inference_cost":0.003}}}"#)
    XCTAssertEqual(value.inputTokens, 1000)
    XCTAssertEqual(value.outputTokens, 200)
    XCTAssertEqual(value.costUSD, Decimal(string: "0.0042"))
    XCTAssertNil(receipt(#"{"usage":{"cost":12}}"#, host: "custom.example").costUSD)
  }

  func testMissingCostIsUnknownWhileExplicitZeroIsFree() {
    let unknown = receipt(#"{"usage":{"prompt_tokens":100,"completion_tokens":20}}"#)
    let free = receipt(#"{"usage":{"cost":0}}"#)
    XCTAssertNil(unknown.costUSD)
    XCTAssertEqual(free.costUSD, 0)
    var summary = LLMUsageSummary()
    summary.include(unknown)
    XCTAssertEqual(summary.costText, String(localized: "Total cost unknown"))
    summary.include(free)
    XCTAssertEqual(summary.pricedCalls, 1)
    XCTAssertEqual(summary.unpricedCalls, 1)
    XCTAssertTrue(summary.costText.contains(String(localized: "Total known cost")))
  }

  func testAmountsSumExactlyAndPersistAsDecimals() throws {
    var summary = LLMUsageSummary()
    for json in [#"{"total_cost_usd":0.1}"#, #"{"cost_usd":"0.2"}"#] {
      let value = receipt(json)
      let restored = try JSONDecoder().decode(
        LLMUsageReceipt.self, from: JSONEncoder().encode(value))
      summary.include(restored)
    }
    XCTAssertEqual(summary.costUSD, Decimal(string: "0.3"))
    XCTAssertEqual(summary.pricedCalls, 2)
    XCTAssertEqual(summary.unpricedCalls, 0)
    XCTAssertTrue(summary.costText.contains("US$0.3000"))
  }

  func testTinyPositiveCostsDoNotDisplayAsZero() {
    var summary = LLMUsageSummary()
    summary.include(receipt(#"{"total_cost_usd":0.00000001}"#))
    XCTAssertEqual(summary.costText, "\(String(localized: "Total cost")) < US$0.000001")
  }

  func testRejectsInvalidPricesAndTruncatedBodies() {
    for value in ["true", "-1", #""0.1invalid""#, #""NaN""#, "null"] {
      XCTAssertNil(receipt("{\"usage\":{\"cost\":\(value)}}").costUSD)
    }
    let truncated = receipt("<truncated llm body>\n{\"usage\":")
    XCTAssertNil(truncated.costUSD)
    XCTAssertNil(truncated.inputTokens)
  }

  func testAnthropicAndGeminiTokenConventions() {
    let anthropic = receipt(#"{"total_cost_usd":0.02,"usage":{"input_tokens":12,"cache_read_input_tokens":34,"cache_creation_input_tokens":40,"output_tokens":56}}"#)
    XCTAssertEqual(anthropic.inputTokens, 86)
    XCTAssertEqual(anthropic.outputTokens, 56)
    let gemini = receipt(#"{"usageMetadata":{"promptTokenCount":100,"cachedContentTokenCount":80,"candidatesTokenCount":20,"thoughtsTokenCount":30}}"#)
    XCTAssertEqual(gemini.inputTokens, 100)
    XCTAssertEqual(gemini.outputTokens, 50)
    XCTAssertNil(gemini.costUSD)
  }

  func testCLIHeadersPreserveCostAndCacheSemantics() {
    let claude = LLMUsageReceipt.parse(
      body: nil,
      headers: [
        "X-Usage-Input": "12", "x-usage-cached-input": "34",
        "x-usage-cache-creation-input": "40", "x-usage-output": "56",
        "x-usage-cost-usd": "0.003", "x-usage-input-includes-cache": "false",
      ], requestURL: nil)
    XCTAssertEqual(claude.inputTokens, 86)
    XCTAssertEqual(claude.costUSD, Decimal(string: "0.003"))
    let codex = LLMUsageReceipt.parse(
      body: nil,
      headers: [
        "x-usage-input": "100", "x-usage-cached-input": "80",
        "x-usage-output": "20", "x-usage-input-includes-cache": "true",
      ], requestURL: nil)
    XCTAssertEqual(codex.inputTokens, 100)
    XCTAssertNil(codex.costUSD)
  }

  func testCodexJSONLExtractsFinalAnswerAndUsage() {
    let raw = #"""
      {"type":"thread.started","thread_id":"example"}
      {"type":"item.completed","item":{"type":"reasoning","text":"Reasoning is not the answer."}}
      {"type":"item.completed","item":{"type":"agent_message","text":"I will inspect the screenshots."}}
      {"type":"item.completed","item":{"type":"agent_message","text":"{\"cards\":[]}"}}
      {"type":"turn.completed","usage":{"input_tokens":100,"cached_input_tokens":80,"output_tokens":20}}
      """#
    let parsed = ChatCLIProcessRunner().parseAssistant(tool: .codex, raw: raw)
    XCTAssertEqual(parsed.text, #"{"cards":[]}"#)
    XCTAssertEqual(parsed.usage?.input, 100)
    XCTAssertEqual(parsed.usage?.output, 20)
    XCTAssertEqual(parsed.usage?.inputIncludesCachedTokens, true)
    XCTAssertNil(parsed.usage?.costUSD)
  }

  func testClaudeCLIPriceSurvivesEnvelopeParsing() throws {
    let parsed = try XCTUnwrap(ChatCLIProcessRunner().parseClaudeJSONEnvelope(
      #"{"type":"result","result":"ok","total_cost_usd":0.0123,"usage":{"input_tokens":10,"output_tokens":20}}"#))
    XCTAssertEqual(parsed.text, "ok")
    XCTAssertEqual(parsed.usage?.costUSD, Decimal(string: "0.0123"))
  }
}
