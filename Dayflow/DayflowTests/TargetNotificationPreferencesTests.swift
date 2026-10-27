import AVFoundation
import XCTest

@testable import Dayflow

final class TargetNotificationPreferencesTests: XCTestCase {
  func testNewInstallAndInvalidPreferencesKeepAudibleNotchDefaults() {
    let suite = "TargetNotificationPreferencesTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    XCTAssertEqual(TargetPreferences.notificationStyle(defaults: defaults), .notch)
    XCTAssertTrue(TargetPreferences.soundEnabled(defaults: defaults))
    XCTAssertEqual(TargetPreferences.reminderSound(defaults: defaults), .gemCollect)
    defaults.set("removed-style", forKey: TargetPreferences.notificationStyleKey)
    defaults.set("missing-sound", forKey: TargetPreferences.reminderSoundKey)
    XCTAssertEqual(TargetPreferences.notificationStyle(defaults: defaults), .notch)
    XCTAssertEqual(TargetPreferences.reminderSound(defaults: defaults), .gemCollect)
  }

  func testNoticeStyleSoundAndMutePersistIndependently() {
    let suite = "TargetNotificationPreferencesTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set("notice", forKey: TargetPreferences.notificationStyleKey)
    defaults.set("secret-chime", forKey: TargetPreferences.reminderSoundKey)
    defaults.set(false, forKey: TargetPreferences.soundEnabledKey)
    let reloaded = UserDefaults(suiteName: suite)!
    XCTAssertEqual(TargetPreferences.notificationStyle(defaults: reloaded), .notice)
    XCTAssertEqual(TargetPreferences.reminderSound(defaults: reloaded), .secretChime)
    XCTAssertFalse(TargetPreferences.soundEnabled(defaults: reloaded))
  }

  func testEverySelectableNotchSoundIsBundledDecodableAndShort() throws {
    XCTAssertEqual(TargetReminderSound.allCases.count, 8)
    for sound in TargetReminderSound.allCases {
      let url = try XCTUnwrap(sound.url, "Missing bundled sound: \(sound.filename)")
      let player = try AVAudioPlayer(contentsOf: url)
      XCTAssertTrue(player.prepareToPlay(), sound.filename)
      XCTAssertGreaterThan(player.duration, 0, sound.filename)
      // Reminder game audio should remain brief.
      XCTAssertLessThan(player.duration, 30, sound.filename)
      XCTAssertEqual(url.lastPathComponent, sound.filename)
    }
  }

  @MainActor
  func testNoticeUsesSystemSoundAndExistingClickRoutingIdentifier() {
    let request = NotificationService.targetNoticeRequest(
      identifier: "goal.card", body: "继续当前目标")
    XCTAssertEqual(request.identifier, "target.deviation.goal.card")
    XCTAssertEqual(request.content.title, String(localized: "Current goal reminder"))
    XCTAssertEqual(request.content.body, "继续当前目标")
    XCTAssertEqual(request.content.sound, .default)
    XCTAssertNil(request.trigger)
  }
}
