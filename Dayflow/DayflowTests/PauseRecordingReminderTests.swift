import XCTest
import UserNotifications
@testable import Dayflow

@MainActor
final class PauseRecordingReminderTests: XCTestCase {
  func testPausedAutomaticStylesAreSilentButExplicitPreviewIsAllowed() async throws {
    for style in TargetNotificationStyle.allCases {
      let fixture = DeliveryFixture(recording: false, style: style)
      let sent = try await fixture.service.notifyTargetDeviation(identifier: "old", body: "Goal")
      XCTAssertFalse(sent)
      XCTAssertEqual(fixture.authorizations, 0)
      XCTAssertTrue(fixture.added.isEmpty)
      XCTAssertEqual(fixture.shown, 0)
      XCTAssertEqual(fixture.played, 0)
      let preview = try await fixture.service.sendTargetTestNotification()
      XCTAssertTrue(preview)
      XCTAssertEqual(fixture.shown, style == .notch ? 1 : 0)
      XCTAssertEqual(fixture.played, style == .notch ? 1 : 0)
      if style == .notice {
        XCTAssertTrue(fixture.service.canPresentTargetNotice(identifier: fixture.added[0].identifier))
      }
    }
  }

  func testAuthorizationWaitingCannotReviveAfterRapidPauseResume() async throws {
    for resume in [false, true] {
      let fixture = DeliveryFixture()
      let gate = AsyncGate()
      fixture.authorizationGate = gate
      let task = Task { try await fixture.service.notifyTargetDeviation(identifier: "old", body: "Goal") }
      await fulfillment(of: [gate.started], timeout: 2)
      fixture.pause()
      if resume { fixture.state.setRecording(true) }
      gate.finish()
      let sent = try await task.value
      XCTAssertFalse(sent)
      XCTAssertTrue(fixture.added.isEmpty)
      XCTAssertEqual(fixture.played, 0)
    }
  }

  func testAddWaitingIsRemovedAndCannotPresentAfterPauseOrRapidResume() async throws {
    for resume in [false, true] {
      let fixture = DeliveryFixture()
      let gate = AsyncGate()
      fixture.addGate = gate
      let task = Task { try await fixture.service.notifyTargetDeviation(identifier: "old", body: "Goal") }
      await fulfillment(of: [gate.started], timeout: 2)
      let identifier = try XCTUnwrap(fixture.added.first?.identifier)
      XCTAssertTrue(fixture.service.canPresentTargetNotice(identifier: identifier))
      fixture.pause()
      if resume { fixture.state.setRecording(true) }
      XCTAssertFalse(fixture.service.canPresentTargetNotice(identifier: identifier))
      gate.finish()
      let sent = try await task.value
      XCTAssertFalse(sent)
      XCTAssertTrue(fixture.removed.contains(identifier))
      fixture.addGate = nil
      if resume {
        let fresh = try await fixture.service.notifyTargetDeviation(identifier: "fresh", body: "Goal")
        XCTAssertTrue(fresh)
        XCTAssertTrue(fixture.service.canPresentTargetNotice(identifier: fixture.added.last!.identifier))
      }
    }
  }

  func testPauseImmediatelyDismissesNotchAndStopsItsSound() async throws {
    let fixture = DeliveryFixture(style: .notch)
    let sent = try await fixture.service.notifyTargetDeviation(identifier: "notch", body: "Goal")
    XCTAssertTrue(sent)
    XCTAssertEqual(fixture.shown, 1)
    XCTAssertEqual(fixture.played, 1)
    fixture.pause()
    XCTAssertEqual(fixture.dismissed, 1)
    XCTAssertEqual(fixture.stopped, 1)
    let suppressed = try await fixture.service.notifyTargetDeviation(identifier: "paused", body: "Goal")
    XCTAssertFalse(suppressed)
    XCTAssertEqual(fixture.shown, 1)
    XCTAssertEqual(fixture.played, 1)
    fixture.state.setRecording(true)
    let fresh = try await fixture.service.notifyTargetDeviation(identifier: "new", body: "Goal")
    XCTAssertTrue(fresh)
    XCTAssertEqual(fixture.shown, 2)
  }

  func testDelayedCleanupPreservesNewGenerationPreviewAndOtherNotifications() async throws {
    let fixture = DeliveryFixture()
    _ = try await fixture.service.notifyTargetDeviation(identifier: "old", body: "Goal")
    let old = fixture.added[0].identifier
    _ = try await fixture.service.notifyTargetDeviation(identifier: "delivered-only", body: "Goal")
    let deliveredOld = fixture.added.last!.identifier
    let gate = AsyncGate()
    fixture.pendingGate = gate
    fixture.pause()
    await fulfillment(of: [gate.started], timeout: 2)
    fixture.state.setRecording(true)
    _ = try await fixture.service.notifyTargetDeviation(identifier: "new", body: "Goal")
    let fresh = fixture.added.last!.identifier
    _ = try await fixture.service.sendTargetTestNotification()
    let preview = fixture.added.last!.identifier
    fixture.pending = [old, fresh, preview, "unrelated", "target.deviation.legacy"]
    fixture.delivered = [deliveredOld, fresh, preview, "other-delivered"]
    gate.finish()
    await fulfillment(of: [fixture.cleanupFinished], timeout: 2)
    XCTAssertTrue(fixture.removed.contains(old))
    XCTAssertTrue(fixture.removed.contains(deliveredOld))
    XCTAssertFalse(fixture.removed.contains("other-delivered"))
    XCTAssertTrue(fixture.removed.contains("target.deviation.legacy"))
    XCTAssertFalse(fixture.removed.contains(fresh))
    XCTAssertFalse(fixture.removed.contains(preview))
    XCTAssertFalse(fixture.removed.contains("unrelated"))
  }

  func testForegroundEligibilityRejectsOldGenerationAndNonTargetNotices() async throws {
    let fixture = DeliveryFixture()
    _ = try await fixture.service.notifyTargetDeviation(identifier: "old", body: "Goal")
    let old = fixture.added[0].identifier
    XCTAssertTrue(fixture.service.canPresentTargetNotice(identifier: old))
    XCTAssertFalse(fixture.service.canPresentTargetNotice(identifier: "other"))
    fixture.state.setRecording(false)
    XCTAssertFalse(fixture.service.canPresentTargetNotice(identifier: old))
    fixture.state.setRecording(true)
    XCTAssertFalse(fixture.service.canPresentTargetNotice(identifier: old))
  }

  func testModelLateReturnSavesAssessmentWithoutReminderOrDedupAdvance() async throws {
    for resume in [false, true] {
      let fixture = try EvaluationFixture()
      defer { fixture.cleanUp() }
      let gate = AsyncGate()
      fixture.modelGate = gate
      let store = fixture.store()
      store.enqueue(cardIDs: [1])
      await fulfillment(of: [gate.started], timeout: 2)
      fixture.state.setRecording(false)
      if resume { fixture.state.setRecording(true) }
      gate.finish()
      await store.waitForEvaluations()
      XCTAssertEqual(store.assessments[1]?.alignment, .severe)
      XCTAssertEqual(fixture.storage.saved.count, 1)
      XCTAssertEqual(fixture.notifications, 0)
      XCTAssertNil(fixture.defaults.object(forKey: "target.lastNotifiedEnd"))
      fixture.state.setRecording(true)
      // Retrying cached work after resuming must not replay the old interval.
      store.enqueue(cardIDs: [1])
      await store.waitForEvaluations()
      XCTAssertEqual(fixture.notifications, 0)
      fixture.modelGate = nil
      fixture.storage.card = EvaluationFixture.card(id: 2, end: Date().addingTimeInterval(2))
      store.enqueue(cardIDs: [2])
      await store.waitForEvaluations()
      XCTAssertEqual(fixture.notifications, 1)
      XCTAssertNotNil(fixture.defaults.object(forKey: "target.lastNotifiedEnd"))
    }
  }

  func testPausedEvaluationAndQueuedWorkDoNotAccumulateReminders() async throws {
    let fixture = try EvaluationFixture()
    defer { fixture.cleanUp() }
    fixture.state.setRecording(false)
    let store = fixture.store()
    store.enqueue(cardIDs: [1])
    await store.waitForEvaluations()
    XCTAssertEqual(store.assessments[1]?.alignment, .severe)
    XCTAssertEqual(fixture.modelCalls, 1)
    XCTAssertEqual(fixture.notifications, 0)
    fixture.state.setRecording(true)
    store.retryPendingEvaluations()
    await store.waitForEvaluations()
    XCTAssertEqual(fixture.modelCalls, 1)
    XCTAssertEqual(fixture.notifications, 0)
    XCTAssertNil(fixture.defaults.object(forKey: "target.lastNotifiedEnd"))
  }

  func testSenderLateSuccessDoesNotAdvanceDedupAfterPauseResume() async throws {
    let fixture = try EvaluationFixture()
    defer { fixture.cleanUp() }
    let gate = AsyncGate()
    fixture.senderGate = gate
    let store = fixture.store()
    store.enqueue(cardIDs: [1])
    await fulfillment(of: [gate.started], timeout: 2)
    fixture.state.setRecording(false)
    fixture.state.setRecording(true)
    gate.finish()
    await store.waitForEvaluations()
    XCTAssertFalse(fixture.lastSenderEligibility)
    XCTAssertNil(fixture.defaults.object(forKey: "target.lastNotifiedEnd"))
    XCTAssertNotNil(store.assessments[1])
  }

  func testRecordingEntrypointsInvalidateRemindersAndTimedExpiryResumes() {
    let fixture = DeliveryFixture(style: .notch)
    let appState = AppState(automaticReminders: fixture.state,
      pauseReminders: { fixture.service.pauseAutomaticReminders() })
    let pauseManager = PauseManager(appState: appState, observeWake: false)
    appState.setRecording(true)
    let initial = fixture.state.generation
    pauseManager.pause(for: .timed(minutes: 0))
    XCTAssertFalse(fixture.state.allows(initial))
    XCTAssertEqual(fixture.dismissed, 1)
    XCTAssertEqual(fixture.stopped, 1)
    pauseManager.checkAndResumeIfExpired()
    XCTAssertTrue(appState.isRecording)
    XCTAssertTrue(fixture.state.isRecording)
    XCTAssertFalse(pauseManager.isPaused)
    let resumed = fixture.state.generation
    pauseManager.pause(for: .indefinite)
    XCTAssertFalse(fixture.state.allows(resumed))
    pauseManager.resume()
    XCTAssertTrue(fixture.state.isRecording)
    appState.setRecording(false)
    XCTAssertFalse(fixture.state.isRecording)
    XCTAssertEqual(fixture.dismissed, 3)
    XCTAssertEqual(fixture.stopped, 3)
    // This isolated AppState never enables preference persistence.
  }

  func testInitialLaunchActivationPreservesRecentEventEligibility() {
    let state = AutomaticReminderState(isRecording: false)
    let appState = AppState(automaticReminders: state, pauseReminders: {})
    appState.isRecording = false // AppDelegate's pre-recorder startup assignment.
    appState.setRecording(true) // Restore the saved active preference.
    XCTAssertTrue(state.allows(state.generation, eventEnd: Date().addingTimeInterval(-30)))
    let stopped = AutomaticReminderState(isRecording: false)
    stopped.setRecording(false) // Explicit saved stop, rather than the launch placeholder.
    stopped.setRecording(true)
    XCTAssertFalse(stopped.allows(stopped.generation, eventEnd: Date().addingTimeInterval(-30)))
  }

  func testRepeatedRecordingWritesDoNotInvalidateCurrentWork() {
    let state = AutomaticReminderState(isRecording: true)
    let generation = state.generation
    state.setRecording(true)
    XCTAssertTrue(state.allows(generation))
    state.setRecording(false)
    state.setRecording(true, now: Date(timeIntervalSince1970: 100))
    XCTAssertFalse(state.allows(generation))
    XCTAssertFalse(state.allows(state.generation, eventEnd: Date(timeIntervalSince1970: 100)))
    XCTAssertTrue(state.allows(state.generation, eventEnd: Date(timeIntervalSince1970: 101)))
  }
}

@MainActor
private final class AsyncGate {
  let started = XCTestExpectation(description: "async boundary entered")
  private var continuation: CheckedContinuation<Void, Never>?
  func wait() async {
    await withCheckedContinuation {
      continuation = $0
      started.fulfill()
    }
  }
  func finish() { continuation?.resume(); continuation = nil }
}

@MainActor
private final class DeliveryFixture {
  let state: AutomaticReminderState
  let style: TargetNotificationStyle
  var authorizationGate: AsyncGate?
  var addGate: AsyncGate?
  var pendingGate: AsyncGate?
  var pending: [String] = []
  var delivered: [String] = []
  var added: [UNNotificationRequest] = []
  var removed: [String] = []
  var authorizations = 0
  var shown = 0
  var played = 0
  var dismissed = 0
  var stopped = 0
  let cleanupFinished = XCTestExpectation(description: "cleanup finished")
  lazy var service = NotificationService(automaticReminders: state, delivery: .init(
    authorization: { self.authorizations += 1; await self.authorizationGate?.wait(); return .authorized },
    add: { self.added.append($0); await self.addGate?.wait() },
    notificationIdentifiers: { await self.pendingGate?.wait(); return self.pending + self.delivered },
    remove: { self.removed.append(contentsOf: $0); self.cleanupFinished.fulfill() },
    showNotch: { _ in self.shown += 1; return true },
    dismissNotch: { self.dismissed += 1 },
    playSound: { self.played += 1 },
    stopSound: { self.stopped += 1 },
    style: { self.style }))
  init(recording: Bool = true, style: TargetNotificationStyle = .notice) {
    state = AutomaticReminderState(isRecording: recording)
    self.style = style
  }
  func pause() {
    state.setRecording(false)
    service.pauseAutomaticReminders()
  }
}

@MainActor
private final class EvaluationFixture {
  let suite = "PauseRecordingReminderTests.\(UUID().uuidString)"
  let defaults: UserDefaults
  let storage = PauseMemoryStorage()
  let state = AutomaticReminderState(isRecording: true)
  var modelGate: AsyncGate?
  var senderGate: AsyncGate?
  var notifications = 0
  var modelCalls = 0
  var lastSenderEligibility = true
  init() throws {
    defaults = UserDefaults(suiteName: suite)!
    defaults.set(true, forKey: TargetPreferences.alertsEnabledKey)
    let target = FocusTarget(id: UUID(), text: "Implement login", startedAt: Date().addingTimeInterval(-3600))
    defaults.set(try JSONEncoder().encode(target), forKey: "target.current")
    storage.card = Self.card(id: 1, end: Date().addingTimeInterval(-1))
  }
  func cleanUp() { defaults.removePersistentDomain(forName: suite) }
  func store() -> TargetStore {
    TargetStore(defaults: defaults, storage: storage, automaticReminders: state,
      notify: { _, _, allowed in
        if let gate = self.senderGate {
          await gate.wait()
          self.lastSenderEligibility = allowed()
          return true // Adversarial late success must still not advance the store watermark.
        }
        guard allowed() else { return false }
        self.notifications += 1
        return true
      }, generate: { _ in
        self.modelCalls += 1
        await self.modelGate?.wait()
        return #"{"alignment":"severe","reason":"Unrelated activity","reminder":"Return to login"}"#
      })
  }
  static func card(id: Int64, end: Date) -> TimelineCardWithTimestamps {
    let end = Int(end.timeIntervalSince1970)
    return TimelineCardWithTimestamps(id: id, startTimestamp: "10:00 AM", endTimestamp: "10:05 AM",
      startTs: end - 300, endTs: end, category: "Work", subcategory: "", title: "Other activity",
      summary: "Unrelated", detailedSummary: "Unrelated", day: "2026-10-30", distractions: nil,
      videoSummaryURL: nil, evidenceKind: .visible)
  }
}

private final class PauseMemoryStorage: TargetStorage {
  var card: TimelineCardWithTimestamps?
  var saved: [TargetAssessment] = []
  func fetchObservationsByTimeRange(from: Date, to: Date) -> [Observation] { [] }
  func fetchTargetAssessments() throws -> [TargetAssessment] { saved }
  func targetCandidateCardIDs(since date: Date) throws -> [Int64] { card.map { [$0.id] } ?? [] }
  func fetchTimelineCard(byId id: Int64) -> TimelineCardWithTimestamps? { card?.id == id ? card : nil }
  func saveTargetAssessment(_ assessment: TargetAssessment, card: TimelineCardWithTimestamps) throws -> Bool {
    saved.append(assessment)
    return true
  }
}
