//
//  LLMTypes.swift
//  Dayflow
//

import Foundation

struct ActivityGenerationContext {
  let batchObservations: [Observation]
  let existingCards: [ActivityCardData]  // Cards that overlap with current analysis window
  let currentTime: Date  // Current time to prevent future timestamps
  let categories: [LLMCategoryDescriptor]
  let hasPreviousCardWithinFiveMinutes: Bool
}

enum LLMProviderID: String, Codable, CaseIterable {
  case dayflow
  case gemini
  case chatGPT = "chatgpt"
  case claude
  case openAICompatible = "openai_compatible"
  case local

  var analyticsName: String {
    switch self {
    case .dayflow:
      return "dayflow"
    case .gemini:
      return "gemini"
    case .chatGPT, .claude:
      return "chat_cli"
    case .openAICompatible:
      return "openai_compatible"
    case .local:
      return "ollama"
    }
  }
}

enum LLMProviderSetupPreferencesError: Error {
  case writeVerificationFailed
}

enum LLMProviderSetupPreferences {
  static func isComplete(
    _ providerID: LLMProviderID,
    in defaults: UserDefaults = AppStoragePaths.defaults
  ) -> Bool {
    defaults.bool(forKey: completionKey(for: providerID))
  }

  static func markComplete(
    _ providerID: LLMProviderID,
    in defaults: UserDefaults = AppStoragePaths.defaults
  ) throws {
    let key = completionKey(for: providerID)
    let previousValue = defaults.object(forKey: key)
    defaults.set(true, forKey: key)
    guard isComplete(providerID, in: defaults) else {
      if let previousValue {
        defaults.set(previousValue, forKey: key)
      } else {
        defaults.removeObject(forKey: key)
      }
      throw LLMProviderSetupPreferencesError.writeVerificationFailed
    }
  }

  private static func completionKey(for providerID: LLMProviderID) -> String {
    "\(providerID.rawValue)SetupComplete"
  }
}

struct BatchingConfig {
  let targetDuration: TimeInterval
  let maxGap: TimeInterval
  let cardLookbackDuration: TimeInterval

  static var standard: BatchingConfig {
    BatchingConfig(
      targetDuration: AnalysisPreferences.interval,
      maxGap: 2 * 60,  // Split batches if gap exceeds 2 minutes
      cardLookbackDuration: 45 * 60  // Preserve context across frequent updates
    )
  }
}

struct AppSites: Codable {
  let primary: String?
  let secondary: String?
}

struct ActivityCardData: Codable {
  let startTime: String
  let endTime: String
  let category: String
  let subcategory: String
  let title: String
  let summary: String
  let detailedSummary: String
  let distractions: [Distraction]?
  let appSites: AppSites?
}

// Distraction is defined in StorageManager.swift
// LLMCall is defined in StorageManager.swift
