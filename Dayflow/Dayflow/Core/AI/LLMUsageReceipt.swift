import CoreFoundation
import Foundation

/// A receipt from a provider response. Missing prices remain unknown, never zero.
struct LLMUsageReceipt: Codable, Sendable {
  let inputTokens: Int?
  let outputTokens: Int?
  let costUSD: Decimal?

  static func parse(
    body: Data?, headers: [String: String]?, requestURL: URL?
  ) -> LLMUsageReceipt {
    let object = body.flatMap {
      (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any]
    }
    let usage = object?["usage"] as? [String: Any]
    let gemini = object?["usageMetadata"] as? [String: Any]
    let normalizedHeaders = (headers ?? [:]).reduce(into: [String: String]()) {
      $0[$1.key.lowercased()] = $1.value
    }

    func count(_ value: Any?) -> Int? {
      guard let decimal = amount(value), decimal <= Decimal(Int.max),
        decimal == Decimal(NSDecimalNumber(decimal: decimal).intValue)
      else { return nil }
      return NSDecimalNumber(decimal: decimal).intValue
    }

    var input = count(usage?["prompt_tokens"] ?? usage?["input_tokens"])
      ?? count(gemini?["promptTokenCount"])
      ?? count(normalizedHeaders["x-usage-input"])
    // Anthropic reports cache tokens separately from input_tokens.
    if usage?["cache_read_input_tokens"] != nil || usage?["cache_creation_input_tokens"] != nil {
      let total = Decimal(input ?? 0)
        + Decimal(count(usage?["cache_read_input_tokens"]) ?? 0)
        + Decimal(count(usage?["cache_creation_input_tokens"]) ?? 0)
      input = count(total.description)
    }
    if usage == nil, input != nil,
      normalizedHeaders["x-usage-input-includes-cache"] == "false"
    {
      let total = Decimal(input ?? 0)
        + Decimal(count(normalizedHeaders["x-usage-cached-input"]) ?? 0)
        + Decimal(count(normalizedHeaders["x-usage-cache-creation-input"]) ?? 0)
      input = count(total.description)
    }
    var output = count(usage?["completion_tokens"] ?? usage?["output_tokens"])
      ?? count(normalizedHeaders["x-usage-output"])
    if let candidates = count(gemini?["candidatesTokenCount"]) {
      output = count((Decimal(candidates) + Decimal(count(gemini?["thoughtsTokenCount"]) ?? 0)).description)
    }

    var cost = amount(object?["total_cost_usd"])
      ?? amount(object?["cost_usd"])
      ?? amount(usage?["cost_usd"])
      ?? amount(normalizedHeaders["x-usage-cost-usd"])
    // OpenRouter documents usage.cost in USD. Do not assume other APIs' units.
    if cost == nil && requestURL?.host?.lowercased() == "openrouter.ai" {
      cost = amount(usage?["cost"])
    }
    return LLMUsageReceipt(inputTokens: input, outputTokens: output, costUSD: cost)
  }

  private static func amount(_ value: Any?) -> Decimal? {
    let text: String
    if let number = value as? NSNumber {
      guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
      text = number.stringValue
    } else if let string = value as? String {
      text = string
    } else {
      return nil
    }
    guard text.range(
      of: #"^[+]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?$"#,
      options: .regularExpression
    ) != nil else { return nil }
    guard let value = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")),
      !value.isNaN, value >= 0
    else { return nil }
    return value
  }
}

struct LLMUsageSummary: Sendable {
  var costUSD: Decimal = 0
  var pricedCalls = 0
  var unpricedCalls = 0
  var inputTokens: Decimal = 0
  var outputTokens: Decimal = 0

  mutating func include(_ receipt: LLMUsageReceipt) {
    inputTokens += Decimal(receipt.inputTokens ?? 0)
    outputTokens += Decimal(receipt.outputTokens ?? 0)
    if let cost = receipt.costUSD {
      costUSD += cost
      pricedCalls += 1
    } else {
      unpricedCalls += 1
    }
  }

  var costText: String {
    guard pricedCalls > 0 else {
      return unpricedCalls > 0 ? "累计费用未知" : "累计费用 US$0.0000"
    }
    let label = "累计\(unpricedCalls > 0 ? "已知" : "")费用"
    if costUSD > 0 && costUSD < Decimal(string: "0.000001")! {
      return "\(label) < US$0.000001"
    }
    let formatter = NumberFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.minimumFractionDigits = 4
    formatter.maximumFractionDigits = 6
    let amount = formatter.string(from: NSDecimalNumber(decimal: costUSD)) ?? "0"
    return "\(label) US$\(amount)"
  }

  var detailText: String {
    "应用内累计调用：已返回费用 \(pricedCalls) 次，未返回费用 \(unpricedCalls) 次。\n"
      + "已记录输入 \(inputTokens) tokens，输出 \(outputTokens) tokens。\n"
      + "仅累计接口明确返回的美元费用，包含重试；未返回用量或价格的调用不按零费用计算。订阅制 CLI 的用量不代表额外账单。"
  }
}
