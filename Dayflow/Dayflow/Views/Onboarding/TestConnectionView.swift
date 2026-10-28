//
//  TestConnectionView.swift
//  Dayflow
//
//  Test connection button for Gemini API
//

import SwiftUI

struct TestConnectionView: View {
  let apiKeyOverride: String?
  let model: GeminiModel
  let onTestComplete: ((Bool) -> Void)?

  @State private var isTesting = false
  @State private var testResult: TestResult?

  init(
    apiKey: String? = nil,
    model: GeminiModel,
    onTestComplete: ((Bool) -> Void)? = nil
  ) {
    self.apiKeyOverride = apiKey
    self.model = model
    self.onTestComplete = onTestComplete
  }

  enum TestResult {
    case success(String)
    case failure(String)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      SettingsPrimaryButton(
        title: isTesting ? String(localized: "Testing…") : String(localized: "Test connection"),
        systemImage: "bolt.fill",
        isLoading: isTesting,
        action: testConnection
      )

      if let result = testResult {
        SettingsStatusDot(
          state: result.isSuccess ? .good : .bad,
          label: result.message
        )
      }
    }
  }

  private func testConnection() {
    guard !isTesting else { return }

    let override =
      apiKeyOverride?
      .components(separatedBy: .whitespacesAndNewlines).joined() ?? ""
    let storedKey =
      LocalProviderCredentialStore.shared.retrieve(for: "gemini")?
      .components(separatedBy: .whitespacesAndNewlines).joined() ?? ""
    let apiKey = override.isEmpty ? storedKey : override
    guard !apiKey.isEmpty else {
      testResult = .failure(String(localized: "No API key found. Enter your API key first."))
      onTestComplete?(false)
      return
    }

    isTesting = true
    testResult = nil

    Task {
      do {
        _ = try await GeminiAPIHelper.shared.testConnection(
          apiKey: apiKey,
          preference: GeminiModelPreference(primary: model)
        )
        await MainActor.run {
          testResult = .success(String(localized: "Connection successful."))
          isTesting = false
          onTestComplete?(true)
        }
      } catch GeminiAPIHelper.APIError.rateLimited(_, _) {
        await MainActor.run {
          testResult = .success(
            String(localized: "API key works, but Gemini is rate limited right now."))
          isTesting = false
          onTestComplete?(true)
        }
      } catch {
        await MainActor.run {
          testResult = .failure(error.localizedDescription)
          isTesting = false
          onTestComplete?(false)
        }
      }
    }
  }
}

extension TestConnectionView.TestResult {
  var isSuccess: Bool {
    switch self {
    case .success: return true
    case .failure: return false
    }
  }

  var message: String {
    switch self {
    case .success(let msg): return msg
    case .failure(let msg): return msg
    }
  }
}
