import AppKit
import XCTest

@testable import Dayflow

final class NotchNotificationTests: XCTestCase {
  @MainActor
  func testPanelReachesPhysicalScreenEdgeWithoutTakingKeyboardFocus() throws {
    let screen = try XCTUnwrap(NSScreen.main)
    let panel = NotchNotificationPanel(
      contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered, defer: false)
    defer { panel.close() }
    panel.isReleasedWhenClosed = false
    let layout = NotchNotificationLayout(
      screenFrame: screen.frame, cameraWidth: 200, cameraHeight: screen.safeAreaInsets.top)
    for expanded in [false, true] {
      panel.setFrame(layout.frame(expanded: expanded), display: false)
      XCTAssertEqual(panel.frame.maxY, screen.frame.maxY)
      XCTAssertEqual(panel.frame.midX, screen.frame.midX)
    }
    XCTAssertFalse(panel.canBecomeKey)
    XCTAssertFalse(panel.canBecomeMain)
  }
  @MainActor
  func testPointerExitDuringRetractionCannotRestartTheDismissalTimer() async throws {
    let controller = NotchNotificationController.shared
    defer { controller.dismissImmediately() }
    XCTAssertTrue(controller.show(body: "回到目标"))
    controller.hover(true)
    XCTAssertTrue(controller.isExpanded)
    controller.dismiss()
    controller.hover(false)
    controller.hover(true)
    XCTAssertFalse(controller.isExpanded)
    try await Task.sleep(for: .milliseconds(650))
    XCTAssertFalse(controller.isPresented)
  }

  @MainActor
  func testNewReminderSurvivesThePreviousRemindersRetraction() async throws {
    let controller = NotchNotificationController.shared
    defer { controller.dismissImmediately() }
    XCTAssertTrue(controller.show(body: "旧提醒"))
    controller.dismiss()
    XCTAssertTrue(controller.show(body: "最新建议"))
    try await Task.sleep(for: .milliseconds(650))
    XCTAssertTrue(controller.isPresented)
    XCTAssertTrue(controller.isExpanded)
    XCTAssertEqual(controller.body, "最新建议")
  }

  func testNotchedDisplayKeepsBothStatesAttachedToCameraEdge() {
    let layout = NotchNotificationLayout(
      screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
      cameraWidth: 210, cameraHeight: 32)
    let compact = layout.frame(expanded: false)
    let expanded = layout.frame(expanded: true)
    XCTAssertEqual(compact.maxY, 982)
    XCTAssertEqual(expanded.maxY, 982)
    XCTAssertEqual(compact.midX, 756)
    XCTAssertEqual(expanded.midX, 756)
    XCTAssertGreaterThan(compact.width, 210)
    XCTAssertGreaterThan(expanded.width, compact.width)
    XCTAssertGreaterThan(expanded.height, compact.height)
  }

  func testExternalDisplayUsesItsOwnOriginAndPhysicalTopNotVisibleFrame() {
    let layout = NotchNotificationLayout(
      screenFrame: CGRect(x: -1920, y: 250, width: 1920, height: 1080),
      cameraWidth: 0, cameraHeight: 0)
    for expanded in [false, true] {
      let frame = layout.frame(expanded: expanded)
      XCTAssertEqual(frame.midX, -960)
      XCTAssertEqual(frame.maxY, 1330)
      XCTAssertTrue(layout.screenFrame.contains(frame))
    }
    XCTAssertGreaterThanOrEqual(layout.compactSize.height, 32)
  }

  func testExpandedHeightFollowsReminderCopyInsteadOfLeavingBottomSpace() {
    let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
    let shortLayout = NotchNotificationLayout(
      screenFrame: screen, cameraWidth: 210, cameraHeight: 32, body: "从一个具体的小步骤继续。")
    let longLayout = NotchNotificationLayout(
      screenFrame: screen, cameraWidth: 210, cameraHeight: 32,
      body: "You spent 18 minutes on news unrelated to “Prepare for interviews.” Start with one concrete step: write the context, actions, and results of a performance optimization case.")

    XCTAssertLessThan(shortLayout.expandedSize.height, longLayout.expandedSize.height)
    XCTAssertGreaterThan(shortLayout.expandedSize.height, shortLayout.compactSize.height)
    XCTAssertLessThan(longLayout.expandedSize.height, 32 + 174)
  }

  func testMeasuredBodyHeightCapsAtThreeLines() {
    let narrow = NotchNotificationLayout.measuredBodyHeight(
      String(repeating: "A long reminder sentence that wraps. ", count: 12), width: 360)
    let threeLines = NotchNotificationLayout.measuredBodyHeight(
      "You spent 18 minutes on news unrelated to “Prepare for interviews.” Start with one concrete step: write the context, actions, and results of a performance optimization case.",
      width: 412)
    XCTAssertEqual(narrow, threeLines)
  }

  func testLargeCameraAndNarrowScreenFitWithoutCoveringStatusMarks() {
    let layout = NotchNotificationLayout(
      screenFrame: CGRect(x: 100, y: -900, width: 600, height: 900),
      cameraWidth: 350, cameraHeight: 38)
    XCTAssertGreaterThanOrEqual(layout.compactSize.width - 350, 104)
    XCTAssertGreaterThanOrEqual(layout.expandedSize.width - 350, 104)
    XCTAssertGreaterThanOrEqual(layout.compactSize.height, 38)
    XCTAssertTrue(layout.screenFrame.contains(layout.frame(expanded: true)))
  }
}
