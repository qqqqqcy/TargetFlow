//
//  OnboardingFlow.swift
//  Dayflow
//

import Foundation
import ScreenCaptureKit
import SwiftUI

// Window manager removed - no longer needed!

struct OnboardingFlow: View {
  @AppStorage("onboardingStep", store: AppStoragePaths.defaults) private var savedStepRawValue = 0
  @State private var step: OnboardingStep = OnboardingStepMigration.restoredStep()
  @AppStorage("didOnboard", store: AppStoragePaths.defaults) private var didOnboard = false
  @AppStorage("onboardingSelectedProviderID", store: AppStoragePaths.defaults) private var selectedProviderIDRawValue =
    LLMProviderID.gemini.rawValue

  private var selectedProviderID: LLMProviderID {
    let provider = LLMProviderID(rawValue: selectedProviderIDRawValue) ?? .gemini
    return provider == .dayflow ? .gemini : provider
  }

  private var onboardingFilledSegments: Int {
    switch step {
    case .llmSetup: return 1
    case .screen: return 2
    default: return 0
    }
  }

  private var showsProgressRing: Bool {
    step != .introVideo && step != .llmSelection
  }

  @ViewBuilder
  var body: some View {
    ZStack(alignment: .bottomLeading) {
      // NO NESTING! Just render the appropriate view directly - NO GROUP!
      switch step {
      case .introVideo, .roleSelection, .referral, .personalGoal, .completion:
        // Historical values remain decodable, but never display excluded screens.
        Color.clear.onAppear { setStep(step.normalizedForSetup) }

      case .llmSelection:
        ProviderSelectionView(
          onSelect: { providerID in
            guard providerID != .dayflow else { return }
            selectedProviderIDRawValue = providerID.rawValue

            advance()
          }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)

      case .llmSetup:
        // COMPLETELY STANDALONE - no parent constraints!
        LLMProviderSetupView(
          providerType: selectedProviderID,
          onBack: {
            setStep(.llmSelection)
          },
          onComplete: { configuredProviderID in
            guard saveRouting(primary: configuredProviderID) else {
              return false
            }
            // Keep the stored selection in sync if the user switched CLI tools mid-setup
            selectedProviderIDRawValue = configuredProviderID.rawValue
            advance()
            return true
          }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)

      case .screen:
        ScreenRecordingPermissionView(
          onBack: {
            setStep(.llmSetup)
          },
          onNext: { advance() }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      }

      // Progress ring — bottom-left, always in tree (opacity toggle preserves @State)
      ProgressRingView(totalSegments: 3, filledSegments: onboardingFilledSegments)
        .opacity(showsProgressRing ? 1 : 0)
        .animation(.easeInOut(duration: 0.3), value: showsProgressRing)
        .padding(.leading, 0)
        .padding(.bottom, 0)
        .allowsHitTesting(false)
    }
    .animation(.easeInOut(duration: 0.5), value: step)
    .onAppear {
      restoreSavedStep()
    }
    .background {
      // Background at parent level - fills entire window!
      OnboardingBackdrop()
    }
    .preferredColorScheme(.light)
  }

  private func saveRouting(primary providerID: LLMProviderID) -> Bool {
    guard providerID != .dayflow else { return false }
    do {
      try LLMProviderRoutingStore.save(LLMProviderRouting(primary: providerID))
      return true
    } catch {
      return false
    }
  }

  private func restoreSavedStep() {
    let migratedValue = OnboardingStepMigration.migrateIfNeeded()
    if migratedValue != savedStepRawValue {
      savedStepRawValue = migratedValue
    }
    if let savedStep = OnboardingStep(rawValue: migratedValue) {
      step = savedStep
    }
  }

  private func setStep(_ newStep: OnboardingStep) {
    step = newStep
    savedStepRawValue = newStep.rawValue
  }

  private func advance() {
    switch step {
    case .llmSelection:
      setStep(.llmSetup)
    case .llmSetup:
      setStep(.screen)
    case .screen:
      // Finish directly after permission; no tour, sample cards, or promotion.
      guard CGPreflightScreenCaptureAccess() else { return }
      didOnboard = true
      savedStepRawValue = OnboardingStep.llmSelection.rawValue
      Task { @MainActor in
        AppState.shared.setRecording(true)
      }
    default:
      setStep(step.normalizedForSetup)
    }
  }
}

/// Wizard step order
enum OnboardingStep: Int, CaseIterable {
  // Keep historical raw values stable so saved onboarding steps can be migrated.
  case introVideo = 0
  case roleSelection = 1
  case referral = 2
  case llmSelection = 3
  case llmSetup = 4
  case screen = 5
  case personalGoal = 6
  case completion = 7

  var normalizedForSetup: OnboardingStep {
    switch self {
    case .introVideo, .roleSelection, .referral: return .llmSelection
    case .personalGoal, .completion: return .screen
    case .llmSelection, .llmSetup, .screen: return self
    }
  }
}

enum OnboardingStepMigration {
  static let schemaVersionKey = "onboardingStepSchemaVersion"
  private static let onboardingStepKey = "onboardingStep"
  static let currentVersion = 7

  @discardableResult
  static func migrateIfNeeded(defaults: UserDefaults = AppStoragePaths.defaults) -> Int {
    let storedVersion = defaults.integer(forKey: schemaVersionKey)
    let rawValue = defaults.integer(forKey: onboardingStepKey)

    var migratedValue = rawValue

    // v0 → v1: reorder steps
    if storedVersion < 1 {
      migratedValue = migrateV0toV1(migratedValue)
    }

    // v1 → v2: welcome/howItWorks replaced by introVideo/roleSelection/preferences
    // Old v1: welcome=0, howItWorks=1, llmSelection=2, llmSetup=3, categories=4, screen=5, completion=6
    // New v2: introVideo=0, roleSelection=1, preferences=2, llmSelection=3, llmSetup=4, categories=5, screen=6, completion=7
    if storedVersion < 2 {
      migratedValue = migrateV1toV2(migratedValue)
    }

    // v2 → v3: insert referral after role selection
    // Old v2: introVideo=0, roleSelection=1, preferences=2, llmSelection=3, llmSetup=4, categories=5, screen=6, completion=7
    // New v3: introVideo=0, roleSelection=1, referral=2, preferences=3, llmSelection=4, llmSetup=5, categories=6, screen=7, completion=8
    if storedVersion < 3 {
      migratedValue = migrateV2toV3(migratedValue)
    }

    // v3 → v4: insert categoryColors after categories
    // Old v3: introVideo=0, roleSelection=1, referral=2, preferences=3, llmSelection=4, llmSetup=5, categories=6, screen=7, completion=8
    // New v4: introVideo=0, roleSelection=1, referral=2, preferences=3, llmSelection=4, llmSetup=5, categories=6, categoryColors=7, screen=8, completion=9
    if storedVersion < 4 {
      migratedValue = migrateV3toV4(migratedValue)
    }

    // v4 → v5: insert downloadReason after roleSelection
    // Old v4: introVideo=0, roleSelection=1, referral=2, preferences=3, llmSelection=4, llmSetup=5, categories=6, categoryColors=7, screen=8, completion=9
    // New v5: introVideo=0, roleSelection=1, downloadReason=2, referral=3, preferences=4, llmSelection=5, llmSetup=6, categories=7, categoryColors=8, screen=9, completion=10
    if storedVersion < 5 {
      migratedValue = migrateV4toV5(migratedValue)
    }

    // v5 → v6: remove downloadReason, preferences, categories and categoryColors; insert personalGoal after screen
    // Old v5: introVideo=0, roleSelection=1, downloadReason=2, referral=3, preferences=4, llmSelection=5, llmSetup=6, categories=7, categoryColors=8, screen=9, completion=10
    // New v6: introVideo=0, roleSelection=1, referral=2, llmSelection=3, llmSetup=4, screen=5, personalGoal=6, completion=7
    if storedVersion < 6 {
      migratedValue = migrateV5toV6(migratedValue)
    }

    // v7 keeps the old raw values while removing the non-setup screens.
    migratedValue = (OnboardingStep(rawValue: migratedValue)?.normalizedForSetup ?? .llmSelection)
      .rawValue
    if defaults.string(forKey: "onboardingSelectedProviderID") == LLMProviderID.dayflow.rawValue {
      defaults.set(LLMProviderID.gemini.rawValue, forKey: "onboardingSelectedProviderID")
      // Hosted setup did not configure a BYOK provider. Require a fresh selection.
      migratedValue = OnboardingStep.llmSelection.rawValue
    }
    if rawValue != migratedValue {
      defaults.set(migratedValue, forKey: onboardingStepKey)
    }
    if storedVersion < currentVersion {
      defaults.set(currentVersion, forKey: schemaVersionKey)
    }
    return migratedValue
  }

  static func restoredStep(defaults: UserDefaults = AppStoragePaths.defaults) -> OnboardingStep {
    OnboardingStep(rawValue: migrateIfNeeded(defaults: defaults)) ?? .llmSelection
  }

  static func migrateV0toV1(_ rawValue: Int) -> Int {
    switch rawValue {
    case 0: return 0  // welcome
    case 1: return 1  // how it works
    case 2: return 5  // legacy screen step moves after categories
    case 3: return 2  // llm selection
    case 4: return 3  // llm setup
    case 5: return 4  // categories
    case 6: return 6  // completion
    default: return 0
    }
  }

  static func migrateV1toV2(_ rawValue: Int) -> Int {
    switch rawValue {
    case 0: return 0  // welcome → introVideo (restart from beginning)
    case 1: return 0  // howItWorks → introVideo (restart from beginning)
    case 2: return 3  // llmSelection → llmSelection
    case 3: return 4  // llmSetup → llmSetup
    case 4: return 5  // categories → categories
    case 5: return 6  // screen → screen
    case 6: return 7  // completion → completion
    default: return 0
    }
  }

  static func migrateV2toV3(_ rawValue: Int) -> Int {
    switch rawValue {
    case 0: return 0  // introVideo → introVideo
    case 1: return 1  // roleSelection → roleSelection
    case 2: return 3  // preferences → preferences
    case 3: return 4  // llmSelection → llmSelection
    case 4: return 5  // llmSetup → llmSetup
    case 5: return 6  // categories → categories
    case 6: return 7  // screen → screen
    case 7: return 8  // completion → completion
    default: return 0
    }
  }

  static func migrateV3toV4(_ rawValue: Int) -> Int {
    switch rawValue {
    case 0...6: return rawValue  // unchanged through categories
    case 7: return 8  // screen → screen
    case 8: return 9  // completion → completion
    default: return 0
    }
  }

  static func migrateV4toV5(_ rawValue: Int) -> Int {
    switch rawValue {
    case 0...1: return rawValue  // unchanged through roleSelection
    case 2...9: return rawValue + 1  // steps after roleSelection shift forward
    default: return 0
    }
  }

  static func migrateV5toV6(_ rawValue: Int) -> Int {
    switch rawValue {
    case 0...1: return rawValue  // introVideo, roleSelection unchanged
    case 2...3: return 2  // downloadReason, referral → referral
    case 4...5: return 3  // preferences, llmSelection → llmSelection
    case 6: return 4  // llmSetup → llmSetup
    case 7...9: return 5  // categories, categoryColors, screen → screen
    case 10: return 6  // completion → personalGoal (the new step right after screen)
    default: return 0
    }
  }
}
