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

  func testEverySelectableSoundIsBundledDecodableAndShortEnoughForSystemNotices() throws {
    XCTAssertEqual(TargetReminderSound.allCases.count, 8)
    for sound in TargetReminderSound.allCases {
      let url = try XCTUnwrap(sound.url, "Missing bundled sound: \(sound.filename)")
      let player = try AVAudioPlayer(contentsOf: url)
      XCTAssertTrue(player.prepareToPlay(), sound.filename)
      XCTAssertGreaterThan(player.duration, 0, sound.filename)
      // UNNotificationSound only accepts custom sounds shorter than 30 seconds.
      XCTAssertLessThan(player.duration, 30, sound.filename)
      XCTAssertEqual(url.lastPathComponent, sound.filename)
    }
  }

  @MainActor
  func testNoticeContainsSelectedSoundAndExistingClickRoutingIdentifier() throws {
    for sound in TargetReminderSound.allCases {
      let request = NotificationService.targetNoticeRequest(
        identifier: "goal.card", body: "继续当前目标", soundEnabled: true, sound: sound)
      XCTAssertEqual(request.identifier, "target.deviation.goal.card")
      XCTAssertEqual(request.content.title, "当前目标提醒")
      XCTAssertEqual(request.content.body, "继续当前目标")
      XCTAssertNotNil(request.content.sound)
      XCTAssertNil(request.trigger)
    }
    let silent = NotificationService.targetNoticeRequest(
      identifier: "silent", body: "无声提醒", soundEnabled: false, sound: .gemCollect)
    XCTAssertNil(silent.content.sound)
  }
}
