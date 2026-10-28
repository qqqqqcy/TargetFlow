import Foundation

enum LocalModelPreset: String, CaseIterable, Codable {
  case qwen3VL4B = "qwen3_vl_4b"
  case qwen25VL3B = "qwen25_vl_3b"

  static let recommended: LocalModelPreset = .qwen3VL4B

  func modelId(for engine: LocalEngine) -> String {
    switch (self, engine) {
    case (.qwen3VL4B, .lmstudio):
      return "Qwen3-VL-4B-Instruct"
    case (.qwen25VL3B, .lmstudio):
      return "qwen2.5-vl-3b-instruct"
    case (.qwen3VL4B, _):
      return "qwen3-vl:4b"
    case (.qwen25VL3B, _):
      return "qwen2.5vl:3b"
    }
  }

}

enum LocalModelPreferences {
  static func defaultModelId(for engine: LocalEngine) -> String {
    LocalModelPreset.recommended.modelId(for: engine)
  }
}
