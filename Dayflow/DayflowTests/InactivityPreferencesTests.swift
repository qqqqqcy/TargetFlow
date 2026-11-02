import XCTest
@testable import Dayflow

final class InactivityPreferencesTests: XCTestCase {
  private func withDefaults(_ body: (UserDefaults) throws -> Void) rethrows {
    let suite = "InactivityPreferencesTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    try body(defaults)
  }

  func testDefaultAndExactAllowedOptions() {
    withDefaults { defaults in
      XCTAssertEqual(InactivityPreferences.thresholdSeconds(in: defaults), 300)
      XCTAssertEqual(InactivityPreferences.defaultThreshold, 300)
      XCTAssertEqual(InactivityPreferences.thresholdOptions, [300, 600, 900])
    }
  }

  func testEveryOptionPersistsAndInvalidSetterPreservesSelection() {
    withDefaults { defaults in
      for seconds in InactivityPreferences.thresholdOptions {
        InactivityPreferences.setThresholdSeconds(seconds, in: defaults)
        XCTAssertEqual(defaults.integer(forKey: InactivityPreferences.thresholdKey), seconds)
        XCTAssertEqual(InactivityPreferences.thresholdSeconds(in: defaults), seconds)
      }
      InactivityPreferences.setThresholdSeconds(720, in: defaults)
      XCTAssertEqual(InactivityPreferences.thresholdSeconds(in: defaults), 900)
    }
  }

  func testPersistenceAcrossDefaultsInstances() {
    let suite = "InactivityPersistence.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    InactivityPreferences.setThresholdSeconds(600, in: defaults)
    XCTAssertEqual(InactivityPreferences.thresholdSeconds(in: UserDefaults(suiteName: suite)!), 600)
  }

  func testMalformedStoredValuesFallBackWithoutCoercion() {
    withDefaults { defaults in
      for malformed: Any in [0, -1, 720, 900.5, "900", "invalid", true, [900], ["seconds": 900]] {
        defaults.set(malformed, forKey: InactivityPreferences.thresholdKey)
        XCTAssertEqual(InactivityPreferences.thresholdSeconds(in: defaults), 300, "\(malformed)")
      }
      defaults.removeObject(forKey: InactivityPreferences.thresholdKey)
      XCTAssertEqual(InactivityPreferences.thresholdSeconds(in: defaults), 300)
    }
  }

  func testMetadataSnapshotSurvivesPersistenceAndLegacyDecoding() throws {
    let legacy = Data("""
      {"classifierVersion":"legacy","inputCoverageRatio":1,"coveredSeconds":300,
       "batchDurationSeconds":300,"largestUncoveredGapSeconds":0,"screenshotCount":6,
       "sampledIdleScreenshotCount":6,"averageIdleSecondsAtCapture":500,
       "maxIdleSecondsAtCapture":600,"mergedWithPreviousIdle":false,"skippedLLM":true}
      """.utf8)
    var metadata = try JSONDecoder().decode(IdleCardMetadata.self, from: legacy)
    XCTAssertNil(metadata.inactivityThresholdSeconds)
    for threshold in InactivityPreferences.thresholdOptions {
      metadata.inactivityThresholdSeconds = threshold
      let restored = try JSONDecoder().decode(IdleCardMetadata.self, from: JSONEncoder().encode(metadata))
      XCTAssertEqual(restored.inactivityThresholdSeconds, threshold)
      let card = IdleBatchClassifier.makeIdleCard(from: Date(timeIntervalSince1970: 0),
        to: Date(timeIntervalSince1970: 300), metadata: restored)
      XCTAssertTrue(card.summary.contains("\(threshold / 60)"))
      XCTAssertTrue(card.detailedSummary.contains("\(threshold / 60)"))
    }
  }

  func testThresholdAndCardGenerationIntervalAreIndependent() {
    withDefaults { defaults in
      AnalysisPreferences.setInterval(60, in: defaults)
      InactivityPreferences.setThresholdSeconds(900, in: defaults)
      XCTAssertEqual(AnalysisPreferences.interval(in: defaults), 60)
      AnalysisPreferences.setInterval(600, in: defaults)
      XCTAssertEqual(InactivityPreferences.thresholdSeconds(in: defaults), 900)
    }
  }
}
