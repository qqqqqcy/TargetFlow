import AppKit
import GRDB
import SwiftUI
import Vision
import XCTest

@testable import Dayflow

@MainActor
final class DayTimelineZoomTests: XCTestCase {
  func testContinuousBoundsAndNonfiniteValues() {
    for (input, expected) in [(-100.0, 25.0), (0, 25), (63.125, 63.125),
      (112.75, 112.75), (800, 800), (9999, 800), (.nan, 100), (.infinity, 100)]
    {
      XCTAssertEqual(DayTimelineZoom.normalized(input), expected)
    }
    XCTAssertEqual(DayTimelineZoom.hourHeight(for: 100), 168)
    XCTAssertEqual(DayTimelineZoom.hourHeight(for: 800), 1344)
  }

  func testIntegerPreferenceMigratesAndContinuousSelectionSurvivesRemount() throws {
    let defaults = try makeDefaults()
    defer { defaults.removePersistentDomain(forName: defaults.suite) }
    defaults.set(125, forKey: DayTimelineZoomState.storageKey)
    let zoom = DayTimelineZoomState(defaults: defaults)
    XCTAssertEqual(zoom.percent, 125)
    zoom.set(137.625)
    XCTAssertEqual(DayTimelineZoomState(defaults: defaults).percent, 137.625)
    defaults.set(-200, forKey: DayTimelineZoomState.storageKey)
    XCTAssertEqual(DayTimelineZoomState(defaults: defaults).percent, 25)
    defaults.set("corrupt", forKey: DayTimelineZoomState.storageKey)
    XCTAssertEqual(DayTimelineZoomState(defaults: defaults).percent, 100)
  }

  func testShortEventsStayWithinTimeIntervalsEvenAtExtremeDensities() {
    for percent in [25.0, 63.125, 100, 137.625, 800] {
      let height = DayTimelineZoom.hourHeight(for: percent)
      for minutes in [0.0, 0.25, 1, 3, 10, 60] {
        let card = DayTimelineZoom.cardHeight(minutes: minutes, hourHeight: height)
        XCTAssertGreaterThanOrEqual(card, 0)
        XCTAssertLessThanOrEqual(card, DayTimelineZoom.y(minutes: minutes, hourHeight: height))
        if minutes > 0 { XCTAssertGreaterThan(card, 0) }
      }
    }
    // At 800% a one-minute event has enough room for the unchanged 13pt title.
    XCTAssertGreaterThan(DayTimelineZoom.cardHeight(minutes: 1, hourHeight: 1344), 16)
  }

  func testAnchorUsesFocusAndClampsOnlyAtDayEdges() {
    XCTAssertEqual(DayTimelineZoom.anchoredOffset(840, from: 168, to: 336,
      contentHeight: 8064, viewportHeight: 400, focusY: 150), 1830, accuracy: 0.001)
    XCTAssertEqual(DayTimelineZoom.anchoredOffset(0, from: 168, to: 42,
      contentHeight: 1008, viewportHeight: 400, focusY: 150), 0)
    XCTAssertEqual(DayTimelineZoom.anchoredOffset(3632, from: 168, to: 42,
      contentHeight: 1008, viewportHeight: 400, focusY: 150), 608)
    XCTAssertEqual(DayTimelineZoom.anchoredOffset(100, from: 168, to: 42,
      contentHeight: 1008, viewportHeight: 3000, focusY: 150), 0)
  }

  func testNativeMagnifySequenceCommitsFocusBeforeEveryDisplay() async throws {
    let fixture = try makeHost(width: 500)
    defer { fixture.close() }
    await settle(fixture.host)
    let scroll = try XCTUnwrap(findCanvas(fixture.host))
    fixture.window.orderFront(nil)
    scroll.contentView.scroll(to: NSPoint(x: 0, y: 840))
    let focus: CGFloat = 150
    let focusHours = (840 + focus) / 168
    var displayedFrames = [String]()
    scroll.displayProbe = { contentHeight, offset, hourHeight in
      XCTAssertEqual(contentHeight, hourHeight * 24, accuracy: 0.01)
      XCTAssertEqual((offset + focus) / hourHeight, focusHours, accuracy: 0.001)
      XCTAssertEqual(fixture.lifecycle.hourMarker.minY, 6 * hourHeight, accuracy: 0.01)
      XCTAssertEqual(fixture.lifecycle.cardFrame.minY, 5 * hourHeight + 1, accuracy: 0.01)
      XCTAssertEqual(fixture.lifecycle.cardFrame.height,
        DayTimelineZoom.cardHeight(minutes: 10, hourHeight: hourHeight), accuracy: 0.01)
      displayedFrames.append("\(hourHeight),\(contentHeight),\(offset),\((offset + focus) / hourHeight),\(fixture.lifecycle.hourMarker.minY),\(fixture.lifecycle.cardFrame.minY),\(fixture.lifecycle.cardFrame.height)")
    }
    let document = try XCTUnwrap(scroll.documentView)
    let identity = ObjectIdentifier(document)
    var expected = 100.0
    let updates: [(NSEvent.Phase, CGFloat)] = [(.began, 0), (.changed, 0.13),
      (.changed, 0.07), (.changed, 0.19), (.changed, -0.16), (.changed, 0.025), (.ended, 0)]
    for (index, update) in updates.enumerated() {
      expected = DayTimelineZoom.normalized(expected * (1 + Double(update.1)))
      let event = magnifyEvent(scroll, phase: update.0, delta: update.1, focusY: focus)
      // Resolve the actual NSWindow content hit target, then use NSResponder's
      // native magnify chain exactly as a gesture over a hosted card does.
      let target = try dispatchMagnify(event, in: fixture.window)
      XCTAssertTrue(target.isDescendant(of: scroll))
      // No sleep/runloop/layout repair before these assertions or this display.
      XCTAssertEqual(fixture.zoom.percent, expected, accuracy: 0.0001)
      XCTAssertEqual(document.frame.height, 24 * DayTimelineZoom.hourHeight(for: expected), accuracy: 0.01)
      XCTAssertEqual((scroll.contentView.bounds.minY + focus)
        / DayTimelineZoom.hourHeight(for: expected), focusHours, accuracy: 0.001)
      XCTAssertEqual(ObjectIdentifier(scroll.documentView!), identity)
      XCTAssertEqual(fixture.lifecycle.hourMarker.minY,
        6 * DayTimelineZoom.hourHeight(for: expected), accuracy: 0.01)
      scroll.needsDisplay = true
      scroll.display()
      if index == 2 || index == 3 || index == 4 {
        try attachImage(fixture.host, name: "Native pinch intermediate \(index) (\(Int(expected))%)")
      }
    }
    XCTAssertGreaterThanOrEqual(displayedFrames.count, updates.count)
    let csv = "hourHeight,documentHeight,offset,focusHours,actualHourMarkerY,actualCardY,actualCardHeight\n" + displayedFrames.joined(separator: "\n")
    let attachment = XCTAttachment(string: csv)
    attachment.name = "Native pinch display-boundary geometry.csv"
    attachment.lifetime = .keepAlways
    add(attachment)
    scroll.displayProbe = nil
    await settle(fixture.host)
    XCTAssertEqual(fixture.lifecycle.appearances, 1, "Pinch must not remount the card subtree")
  }

  func testGestureWritesOnceAndCancellationKeepsLastVisibleDensity() async throws {
    let fixture = try makeHost(width: 320)
    defer { fixture.close() }
    await settle(fixture.host)
    let scroll = try XCTUnwrap(findCanvas(fixture.host))
    fixture.defaults.writes = 0
    scroll.magnify(with: magnifyEvent(scroll, phase: .began, delta: 0, focusY: 100))
    for _ in 0..<20 {
      scroll.magnify(with: magnifyEvent(scroll, phase: .changed, delta: 0.013, focusY: 100))
    }
    XCTAssertEqual(fixture.defaults.writes, 0)
    let current = fixture.zoom.percent
    scroll.magnify(with: magnifyEvent(scroll, phase: .cancelled, delta: -0.9, focusY: 100))
    XCTAssertEqual(fixture.zoom.percent, current)
    XCTAssertEqual(fixture.defaults.writes, 1)
    XCTAssertEqual(DayTimelineZoomState(defaults: fixture.defaults).percent, current)
  }

  func testNativeScrollWheelAndMomentumKeepAppKitRoutingAfterPinch() async throws {
    let fixture = try makeHost(width: 320)
    defer { fixture.close() }
    await settle(fixture.host)
    let scroll = try XCTUnwrap(findCanvas(fixture.host))
    fixture.window.orderFront(nil)
    scroll.magnify(with: magnifyEvent(scroll, phase: .began, delta: 0.1, focusY: 120))
    scroll.magnify(with: magnifyEvent(scroll, phase: .ended, delta: 0, focusY: 120))
    let before = scroll.contentView.bounds.minY
    for phase: Int64 in [1, 2, 4] {
      let cg = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
        wheelCount: 1, wheel1: -40, wheel2: 0, wheel3: 0))
      cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
      cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
      positionWheel(cg, in: fixture.window, scroll: scroll)
      fixture.window.sendEvent(try XCTUnwrap(NSEvent(cgEvent: cg)))
      await settle(fixture.host)
    }
    let afterWheel = scroll.contentView.bounds.minY
    XCTAssertGreaterThan(afterWheel, before)
    var momentumForwarded = 0
    scroll.wheelForwardingProbe = { event in
      if !event.momentumPhase.isEmpty { momentumForwarded += 1 }
    }
    let baseline = NSScrollView(frame: scroll.frame)
    baseline.hasVerticalScroller = false
    baseline.hasHorizontalScroller = false
    let nativeDocument = FlippedDocument(frame: scroll.documentView!.frame)
    baseline.documentView = nativeDocument
    baseline.contentView.scroll(to: NSPoint(x: 0, y: afterWheel))
    for phase: Int64 in [1, 2, 3] {
      let cg = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
        wheelCount: 1, wheel1: -20, wheel2: 0, wheel3: 0))
      cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
      cg.setIntegerValueField(.scrollWheelEventMomentumPhase, value: phase)
      let event = try XCTUnwrap(NSEvent(cgEvent: cg))
      scroll.scrollWheel(with: event)
      baseline.scrollWheel(with: event)
      await settle(fixture.host)
      XCTAssertEqual(scroll.contentView.bounds.minY, baseline.contentView.bounds.minY, accuracy: 0.5)
    }
    XCTAssertEqual(momentumForwarded, 3)
    scroll.wheelForwardingProbe = nil
    XCTAssertEqual(fixture.zoom.percent, 110, accuracy: 0.001)
  }

  func testPinchStopsPreviousMomentumAndFreshNativePanStillWorks() async throws {
    let fixture = try makeHost(width: 320)
    defer { fixture.close() }
    await settle(fixture.host)
    let scroll = try XCTUnwrap(findCanvas(fixture.host))
    fixture.window.orderFront(nil)
    scroll.contentView.scroll(to: NSPoint(x: 0, y: 840))
    let wheel = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
      wheelCount: 1, wheel1: -40, wheel2: 0, wheel3: 0))
    wheel.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
    wheel.setIntegerValueField(.scrollWheelEventScrollPhase, value: 1)
    scroll.scrollWheel(with: try XCTUnwrap(NSEvent(cgEvent: wheel)))
    // Begin a pinch while the previous native smooth-pan event is still pending.
    scroll.magnify(with: magnifyEvent(scroll, phase: .began, delta: 0.13, focusY: 150))
    let focusHours = (scroll.contentView.bounds.minY + 150)
      / DayTimelineZoom.hourHeight(for: fixture.zoom.percent)
    var forwarded = 0
    scroll.wheelForwardingProbe = { _ in forwarded += 1 }
    let momentum = try XCTUnwrap(wheel.copy())
    momentum.setIntegerValueField(.scrollWheelEventScrollPhase, value: 0)
    momentum.setIntegerValueField(.scrollWheelEventMomentumPhase, value: 2)
    scroll.scrollWheel(with: try XCTUnwrap(NSEvent(cgEvent: momentum)))
    scroll.scrollWheel(with: try XCTUnwrap(NSEvent(cgEvent: wheel)))
    await settle(fixture.host)
    XCTAssertEqual((scroll.contentView.bounds.minY + 150)
      / DayTimelineZoom.hourHeight(for: fixture.zoom.percent), focusHours, accuracy: 0.001)
    XCTAssertEqual(forwarded, 0)
    scroll.magnify(with: magnifyEvent(scroll, phase: .ended, delta: 0, focusY: 150))
    scroll.scrollWheel(with: try XCTUnwrap(NSEvent(cgEvent: momentum)))
    XCTAssertEqual(forwarded, 0, "Late momentum from the old pan must stay suppressed")
    let before = scroll.contentView.bounds.minY
    scroll.scrollWheel(with: try XCTUnwrap(NSEvent(cgEvent: wheel)))
    await settle(fixture.host)
    XCTAssertGreaterThan(scroll.contentView.bounds.minY, before)
    XCTAssertEqual(forwarded, 1)
    scroll.wheelForwardingProbe = nil
  }

  func testBoundariesNavigationAndUnmountEndActiveGesture() async throws {
    let fixture = try makeHost(width: 320)
    defer { fixture.close() }
    await settle(fixture.host)
    let scroll = try XCTUnwrap(findCanvas(fixture.host))
    scroll.magnify(with: magnifyEvent(scroll, phase: .began, delta: 30, focusY: 200))
    XCTAssertEqual(fixture.zoom.percent, 800)
    scroll.magnify(with: magnifyEvent(scroll, phase: .changed, delta: -0.999, focusY: 200))
    XCTAssertEqual(fixture.zoom.percent, 25)
    XCTAssertEqual(scroll.documentView!.frame.height, 1008)
    XCTAssertGreaterThanOrEqual(scroll.contentView.bounds.minY, 0)
    fixture.lifecycle.token = "another-date"
    fixture.lifecycle.isEmpty = true
    fixture.host.rootView = fixture.root
    await settle(fixture.host)
    XCTAssertEqual(DayTimelineZoomState(defaults: fixture.defaults).percent, 25)
    scroll.magnify(with: magnifyEvent(scroll, phase: .changed, delta: 0.5, focusY: 100))
    XCTAssertEqual(fixture.zoom.percent, 25, "Old gesture cannot zoom a newly navigated date")
    scroll.magnify(with: magnifyEvent(scroll, phase: .began, delta: 0.2, focusY: 100))
    scroll.detach()
    let final = fixture.zoom.percent
    scroll.magnify(with: magnifyEvent(scroll, phase: .changed, delta: 1, focusY: 100))
    fixture.zoom.set(200)
    XCTAssertEqual(DayTimelineZoomState(defaults: fixture.defaults).percent, 200)
    XCTAssertEqual(final, 30)
    XCTAssertEqual(scroll.documentView!.frame.height, 24 * DayTimelineZoom.hourHeight(for: final))
  }

  func testCenterAnchoredButtonsAndNativeTodayRequest() async throws {
    let fixture = try makeHost(width: 320)
    defer { fixture.close() }
    await settle(fixture.host)
    let scroll = try XCTUnwrap(findCanvas(fixture.host))
    scroll.contentView.scroll(to: NSPoint(x: 0, y: 840))
    let center = scroll.contentView.bounds.height / 2
    let hours = (840 + center) / 168
    fixture.zoom.set(137.125)
    XCTAssertEqual((scroll.contentView.bounds.minY + center)
      / DayTimelineZoom.hourHeight(for: 137.125), hours, accuracy: 0.001)
    fixture.zoom.set(100)
    XCTAssertEqual(scroll.contentView.bounds.minY, 840, accuracy: 0.01)
    fixture.lifecycle.request = DayTimelineScrollRequest(hours: 9)
    fixture.host.rootView = fixture.root
    await settle(fixture.host)
    XCTAssertEqual(scroll.contentView.bounds.minY,
      9 * 168 - 0.25 * scroll.contentView.bounds.height, accuracy: 0.01)
  }

  func testResponsiveHeaderAndEnvironmentReachHostedContent() async throws {
    for width: CGFloat in [140, 320, 359, 360, 500] {
      let fixture = try makeHost(width: width)
      await settle(fixture.host)
      XCTAssertEqual(fixture.lifecycle.headerFrame.height, width >= 360 ? 36 : 68, accuracy: 0.5)
      XCTAssertGreaterThanOrEqual(fixture.lifecycle.controlsFrame.minX, 0)
      XCTAssertLessThanOrEqual(fixture.lifecycle.controlsFrame.maxX, width)
      XCTAssertFalse(fixture.lifecycle.navigationFrame.intersects(fixture.lifecycle.controlsFrame))
      XCTAssertEqual(fixture.lifecycle.receivedEnvironment, "Synthetic environment")
      XCTAssertFalse(fixture.lifecycle.receivedDarkTheme)
      fixture.close()
    }
  }

  func testShortEventCanBeReadAtHighZoomAndCardSelectionSurvivesZoom() async throws {
    let fixture = try makeHost(width: 500)
    defer { fixture.close() }
    await settle(fixture.host)
    fixture.window.orderFront(nil)
    fixture.zoom.set(800)
    let scroll = try XCTUnwrap(findCanvas(fixture.host))
    scroll.contentView.scroll(to: NSPoint(x: 0, y: 320 * 1344 / 60 - 100))
    await settle(fixture.host)
    let card = try XCTUnwrap(fixture.lifecycle.cardFrames[2])
    let point = scroll.documentView!.convert(NSPoint(x: card.midX, y: card.midY), to: nil)
    for type: NSEvent.EventType in [.leftMouseDown, .leftMouseUp] {
      let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point,
        modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: fixture.window.windowNumber, context: nil,
        eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
      NSApp.postEvent(event, atStart: false)
    }
    await settle(fixture.host)
    XCTAssertEqual(fixture.lifecycle.selected, 2)
    fixture.zoom.set(400)
    XCTAssertEqual(fixture.lifecycle.selected, 2)
    fixture.zoom.set(800)
    scroll.contentView.scroll(to: NSPoint(x: 0, y: 320 * 1344 / 60 - 100))
    await settle(fixture.host)
    XCTAssertEqual(fixture.lifecycle.appearances, 1)
    try attachImage(fixture.host, name: "Readable selected one-minute event at 800 percent")
  }

  func testColdMainWindowScrollsDayCanvasAfterEntrance() async throws {
    let fixture = try makeHost(width: 1351)
    defer { fixture.close() }
    let nowDate = Date()
    let day = nowDate.getDayInfoFor4AMBoundary().dayString
    let title = "Initial event visible"
    let recordID = try StorageManager.shared.timedWrite("seedInitialWindowEvent") { db in
      try db.execute(sql: """
        INSERT INTO timeline_cards(start,end,start_ts,end_ts,day,title,category,summary,detailed_summary)
        VALUES ('9:00 AM','9:10 AM',?,?,?,?,'Work','','')
        """, arguments: [Int(nowDate.addingTimeInterval(-900).timeIntervalSince1970),
          Int(nowDate.addingTimeInterval(-300).timeIntervalSince1970), day, title])
      return db.lastInsertedRowID
    }
    defer {
      try? StorageManager.shared.timedWrite("removeInitialWindowEvent") { db in
        try db.execute(sql: "DELETE FROM timeline_cards WHERE id = ?", arguments: [recordID])
      }
    }
    fixture.host.frame = NSRect(x: 0, y: 0, width: 1351, height: 813)
    fixture.window.setContentSize(NSSize(width: 1351, height: 813))
    fixture.host.rootView = AnyView(MainView()
      .environmentObject(CategoryStore.shared)
      .environmentObject(AppState.shared)
      .environment(\.dayflowTheme, .light)
      .environment(\.colorScheme, .light))
    fixture.window.orderFront(nil)
    try await Task.sleep(for: .seconds(2))
    fixture.host.layoutSubtreeIfNeeded()
    let scroll = try XCTUnwrap(findCanvas(fixture.host))
    let now = Calendar.current.dateComponents([.hour, .minute], from: Date())
    let hours = CGFloat(((now.hour! + 20) % 24) * 60 + now.minute!) / 60
    let maximum = max(0, scroll.documentView!.frame.height - scroll.contentView.bounds.height)
    let expected = min(maximum, max(0, hours * 168 - scroll.contentView.bounds.height / 2))
    XCTAssertEqual(scroll.contentView.bounds.minY, expected, accuracy: 1)
    let bitmap = try XCTUnwrap(fixture.host.bitmapImageRepForCachingDisplay(in: fixture.host.bounds))
    fixture.host.cacheDisplay(in: fixture.host.bounds, to: bitmap)
    let request = VNRecognizeTextRequest()
    request.recognitionLanguages = ["en-US"]
    request.usesLanguageCorrection = false
    let image = try XCTUnwrap(bitmap.cgImage)
    try VNImageRequestHandler(cgImage: image).perform([request])
    let recognized = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
    XCTAssertTrue(recognized.contains { $0.contains(title) },
      "The persisted event must appear on the first day view without switching modes: \(recognized)")
  }

  func testColdDayCanvasKeepsInitialScrollAfterWindowLayout() async throws {
    let fixture = try makeHost(width: 500)
    defer { fixture.close() }
    let probe = AsyncTimelineProbe()
    fixture.host.frame = .zero
    fixture.host.rootView = AnyView(DayCanvasInitialScrollFixture(zoom: fixture.zoom, probe: probe)
      .environmentObject(CategoryStore.shared)
      .environmentObject(AppState.shared)
      .environmentObject(RetryCoordinator())
      .environment(\.dayflowTheme, .light)
      .environment(\.colorScheme, .light))
    await settle(fixture.host)
    fixture.host.frame = NSRect(x: 0, y: 0, width: 500, height: 500)
    fixture.window.setContentSize(NSSize(width: 500, height: 500))
    await settle(fixture.host)
    let scroll = try XCTUnwrap(findCanvas(fixture.host))
    let now = Calendar.current.dateComponents([.hour, .minute], from: Date())
    let hours = CGFloat(((now.hour! + 20) % 24) * 60 + now.minute!) / 60
    let maximum = max(0, scroll.documentView!.frame.height - scroll.contentView.bounds.height)
    let expected = min(maximum, max(0, hours * 168 - scroll.contentView.bounds.height / 2))
    XCTAssertEqual(scroll.contentView.bounds.minY, expected, accuracy: 1)
  }

  func testParentScrollTickRevealsDayCanvasWhenItCancelsInitialScroll() async throws {
    let fixture = try makeHost(width: 500)
    defer { fixture.close() }
    let probe = AsyncTimelineProbe()
    fixture.host.rootView = AnyView(DayCanvasInitialScrollFixture(zoom: fixture.zoom, probe: probe)
      .environmentObject(CategoryStore.shared)
      .environmentObject(AppState.shared)
      .environmentObject(RetryCoordinator())
      .environment(\.dayflowTheme, .light)
      .environment(\.colorScheme, .light))
    fixture.window.orderFront(nil)
    fixture.host.layoutSubtreeIfNeeded()
    // Interrupt the 50ms initial scroll just as MainView's scroll tick can.
    try await Task.sleep(for: .milliseconds(10))
    let interrupt = try XCTUnwrap(probe.interruptInitialScroll)
    interrupt()
    await settle(fixture.host)

    // Wait for the reveal animation and window rendering to finish on slower hosts.
    var visiblePixels = 0
    for _ in 0..<40 {
      fixture.host.displayIfNeeded()
      let bitmap = try XCTUnwrap(fixture.host.bitmapImageRepForCachingDisplay(in: fixture.host.bounds))
      fixture.host.cacheDisplay(in: fixture.host.bounds, to: bitmap)
      visiblePixels = 0
      for y in stride(from: 0, to: bitmap.pixelsHigh, by: 2) {
        for x in stride(from: 0, to: bitmap.pixelsWide, by: 2) {
          if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
            min(color.redComponent, color.greenComponent, color.blueComponent) < 0.9 {
            visiblePixels += 1
          }
        }
      }
      if visiblePixels > 20 { break }
      try await Task.sleep(for: .milliseconds(50))
    }
    XCTAssertGreaterThan(visiblePixels, 20, "Hour labels must be visible after the initial scroll is interrupted")
  }

  func testAsyncEventsAndEntranceVisibilityRefreshWithoutNavigation() async throws {
    let fixture = try makeHost(width: 500)
    defer { fixture.close() }
    let probe = AsyncTimelineProbe()
    fixture.host.rootView = AnyView(AsyncTimelineFixture(zoom: fixture.zoom, probe: probe))
    await settle(fixture.host)
    let scroll = try XCTUnwrap(findCanvas(fixture.host))
    let document = try XCTUnwrap(scroll.documentView)

    probe.loadEvents?(["Loaded event"])
    await settle(fixture.host)
    XCTAssertEqual(probe.renderedTitle, "Loaded event")
    XCTAssertFalse(probe.renderedVisible)

    probe.revealEvents?()
    await settle(fixture.host)
    XCTAssertTrue(probe.renderedVisible, "Entrance state must update the hosted cards without navigation")
    XCTAssertTrue(scroll.documentView === document)
  }

  func testMountedDayAndWeekReloadAfterCommittedInsertAndSameIDUpdate() async throws {
    XCTAssertTrue(AppStoragePaths.isIsolated)
    let fixture = try makeHost(width: 900)
    defer { fixture.close() }
    let storage = StorageManager.shared
    let base = 1_801_000_020
    let date = Date(timeIntervalSince1970: Double(base))
    let policy = TimelineOutputPolicy()
    let batch: Int64 = try storage.timedWrite("mounted refresh fixture") { db in
      try db.execute(sql: "INSERT INTO analysis_batches(batch_start_ts,batch_end_ts) VALUES (?,?)", arguments: [base, base + 120])
      return db.lastInsertedRowID
    }
    defer { try? storage.timedWrite("mounted refresh cleanup") { db in
      try db.execute(sql: "DELETE FROM timeline_cards WHERE batch_id = ?", arguments: [batch])
      try db.execute(sql: "DELETE FROM analysis_batches WHERE id = ?", arguments: [batch])
    } }
    let probe = MountedRefreshProbe()
    fixture.host.rootView = AnyView(MountedRefreshFixture(date: date, zoom: fixture.zoom, probe: probe)
      .environmentObject(CategoryStore.shared).environmentObject(AppState.shared)
      .environmentObject(RetryCoordinator()).environment(\.dayflowTheme, .light))
    fixture.window.orderFront(nil)
    await settle(fixture.host)
    let scroll = try XCTUnwrap(findCanvas(fixture.host))
    let document = try XCTUnwrap(scroll.documentView)
    fixture.zoom.set(135)
    let shell = TimelineCardShell(startTimestamp: policy.formatTimestampForPrompt(base),
      endTimestamp: policy.formatTimestampForPrompt(base + 120), category: "Idle", subcategory: "",
      title: "Initial natural title", summary: "Initial summary", detailedSummary: "Evidence",
      distractions: nil, appSites: nil, evidenceKind: .inputInactive)
    let saved = try storage.replaceTimelineCardGroups([TimelineCardReplacementGroup(
      from: date, to: date.addingTimeInterval(120), cards: [shell])], batchId: batch,
      keepingNewerBatchesCardsStartingAfter: nil)
    try await Task.sleep(for: .milliseconds(350))
    XCTAssertTrue(probe.dayHasActivities)
    XCTAssertTrue(probe.weekHasActivities)
    let activity = try XCTUnwrap(TimelineActivityLoader.dayPayload(for: date, storageManager: storage, now: date)
      .activities.first(where: { $0.recordId == saved.insertedIds.first }))
    probe.select?(activity)
    await settle(fixture.host)
    try storage.updateTimelineCard(cardId: try XCTUnwrap(saved.insertedIds.first), title: "Updated natural title", category: nil)
    try await Task.sleep(for: .milliseconds(350))
    XCTAssertEqual(probe.daySelection?.title, "Updated natural title")
    XCTAssertEqual(probe.weekSelection?.title, "Updated natural title")
    XCTAssertEqual(probe.daySelection?.recordId, activity.recordId)
    XCTAssertEqual(probe.weekSelection?.recordId, activity.recordId)
    let idleBatch: Int64 = try storage.timedWrite("mounted idle continuation") { db in
      try db.execute(sql: "INSERT INTO analysis_batches(batch_start_ts,batch_end_ts) VALUES (?,?)", arguments: [base + 120, base + 180])
      return db.lastInsertedRowID
    }
    defer { try? storage.timedWrite("mounted idle continuation cleanup") { db in
      try db.execute(sql: "DELETE FROM timeline_cards WHERE batch_id = ?", arguments: [idleBatch])
      try db.execute(sql: "DELETE FROM analysis_batches WHERE id = ?", arguments: [idleBatch])
    } }
    let extended = TimelineCardShell(startTimestamp: policy.formatTimestampForPrompt(base),
      endTimestamp: policy.formatTimestampForPrompt(base + 180), category: "Idle", subcategory: "",
      title: "Idle", summary: "", detailedSummary: "", distractions: nil, appSites: nil,
      evidenceKind: .inputInactive)
    let idleResult = storage.saveIdleBatchCard(extended, startTs: base + 120, endTs: base + 180,
      batchId: idleBatch, extendingCardId: activity.recordId)
    XCTAssertEqual(idleResult.cardId, activity.recordId)
    try await Task.sleep(for: .milliseconds(350))
    XCTAssertEqual(Int(probe.daySelection?.endTime.timeIntervalSince1970 ?? 0), base + 180)
    XCTAssertEqual(Int(probe.weekSelection?.endTime.timeIntervalSince1970 ?? 0), base + 180)
    XCTAssertTrue(scroll.documentView === document)
    XCTAssertEqual(fixture.zoom.percent, 135)
    let noCommit = expectation(description: "failed transaction sends no commit")
    noCommit.isInverted = true
    let token = NotificationCenter.default.addObserver(forName: .timelineCardsDidCommit, object: nil, queue: nil) { _ in
      noCommit.fulfill()
    }
    defer { NotificationCenter.default.removeObserver(token) }
    XCTAssertThrowsError(try storage.replaceTimelineCardGroups([TimelineCardReplacementGroup(
      from: date, to: date, cards: [shell])], batchId: batch, keepingNewerBatchesCardsStartingAfter: nil))
    await fulfillment(of: [noCommit], timeout: 0.1)
    XCTAssertEqual(probe.daySelection?.title, "Updated natural title")
    XCTAssertEqual(probe.weekSelection?.title, "Updated natural title")
    probe.navigate?(date.addingTimeInterval(14 * 24 * 3600))
    try await Task.sleep(for: .milliseconds(350))
    XCTAssertFalse(probe.dayHasActivities)
    XCTAssertFalse(probe.weekHasActivities)
    XCTAssertNil(probe.daySelection)
    XCTAssertNil(probe.weekSelection)
  }

  func testMountedDayAndWeekRefreshWhenPendingBatchBecomesAnEvent() async throws {
    XCTAssertTrue(AppStoragePaths.isIsolated)
    let defaults = AppStoragePaths.defaults
    let original = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
    var arguments = original
    arguments[AnalysisPreferences.intervalKey] = 300
    defaults.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
    defer { defaults.setVolatileDomain(original, forName: UserDefaults.argumentDomain) }
    let fixture = try makeHost(width: 900)
    defer { fixture.close() }
    let base = 1_801_100_040
    // The selected timeline day follows the 4 AM boundary in the local time zone.
    let timelineDay = Date(timeIntervalSince1970: Double(base - 4 * 3600))
    let date = Calendar.current.startOfDay(for: timelineDay).addingTimeInterval(12 * 3600)
    let storage = StorageManager.shared
    let path = "mounted-minimum-\(UUID().uuidString)"
    let batches = try storage.timedWrite("mounted pending setup") { db -> [Int64] in
      var ids: [Int64] = []
      for (start, end) in [(0, 60), (120, 300)] {
        try db.execute(sql: "INSERT INTO analysis_batches(batch_start_ts,batch_end_ts) VALUES (?,?)", arguments: [base + start, base + end])
        ids.append(db.lastInsertedRowID)
      }
      for offset in [0, 60, 120, 180, 240, 300] {
        try db.execute(sql: "INSERT INTO screenshots(captured_at,file_path,frame_index,is_privacy_redacted) VALUES (?,?,?,0)", arguments: [base + offset, path, offset / 60])
        try db.execute(sql: "INSERT INTO batch_screenshots(batch_id,screenshot_id) VALUES (?,?)", arguments: [offset <= 60 ? ids[0] : ids[1], db.lastInsertedRowID])
      }
      return ids
    }
    defer { try? storage.timedWrite("mounted pending cleanup") { db in
      for id in batches {
        try db.execute(sql: "DELETE FROM timeline_cards WHERE batch_id = ?", arguments: [id])
        try db.execute(sql: "DELETE FROM observations WHERE batch_id = ?", arguments: [id])
        try db.execute(sql: "DELETE FROM batch_screenshots WHERE batch_id = ?", arguments: [id])
        try db.execute(sql: "DELETE FROM analysis_batches WHERE id = ?", arguments: [id])
      }
      try db.execute(sql: "DELETE FROM screenshots WHERE file_path = ?", arguments: [path])
    } }
    let probe = MountedRefreshProbe()
    fixture.host.rootView = AnyView(MountedRefreshFixture(date: date, zoom: fixture.zoom, probe: probe)
      .environmentObject(CategoryStore.shared).environmentObject(AppState.shared)
      .environmentObject(RetryCoordinator()).environment(\.dayflowTheme, .light))
    fixture.window.orderFront(nil)
    await settle(fixture.host)
    let scroll = try XCTUnwrap(findCanvas(fixture.host))
    let document = try XCTUnwrap(scroll.documentView)
    let connection = AIProviderConnection(name: "Stub", kind: .local, models: [AIConfiguredModel(id: "test")])
    let assignment = AIModelAssignment(connectionID: connection.id, modelID: "test")
    let config = AIConfiguration(connections: [connection], routes: [.timeline: .init(primary: assignment)])
    let policy = TimelineOutputPolicy()
    let service = LLMService(loadConfiguration: { config }, timelineGeneratorOverride: { _, context, _ in
      let continuing = !context.existingCards.isEmpty
      let card = ActivityCardData(startTime: policy.formatTimestampForPrompt(base), endTime: policy.formatTimestampForPrompt(base + (continuing ? 360 : 120)), category: "Idle", subcategory: "", title: continuing ? "Mounted completed event" : "Pending", summary: "Synthetic", detailedSummary: "Evidence", distractions: nil, appSites: nil)
      return ([card], [], nil, LLMCall(timestamp: nil, latency: nil, input: nil, output: nil))
    })
    func process(_ id: Int64) async throws -> ProcessedBatchResult {
      let result: Result<ProcessedBatchResult, Error> = await withCheckedContinuation { continuation in
        service.processBatch(id, progressHandler: nil) { continuation.resume(returning: $0) }
      }
      return try result.get()
    }
    let pending = try await process(batches[0])
    XCTAssertTrue(pending.cardIds.isEmpty)
    try await Task.sleep(for: .milliseconds(350))
    XCTAssertFalse(probe.dayHasActivities)
    XCTAssertFalse(probe.weekHasActivities)
    let published = try await process(batches[1])
    XCTAssertEqual(published.cardIds.count, 1)
    try await Task.sleep(for: .milliseconds(350))
    XCTAssertTrue(probe.dayHasActivities)
    XCTAssertTrue(probe.weekHasActivities)
    XCTAssertTrue(scroll.documentView === document)
  }

  func testGestureHelpIsBundledInChineseAndEnglish() throws {
    let translations = ["Zoom out day timeline": "缩小日时间线",
      "Zoom in day timeline": "放大日时间线", "Day timeline zoom": "日时间线缩放比例",
      "Reset day timeline zoom to 100%": "将日时间线缩放重置为100%",
      "Pinch to zoom the day timeline. Scroll with two fingers to move through time.":
        "双指捏合缩放日时间线，双指上下滚动浏览时间。"]
    for language in ["en", "zh-Hans"] {
      let path = try XCTUnwrap(Bundle.main.path(forResource: language, ofType: "lproj"))
      let bundle = try XCTUnwrap(Bundle(path: path))
      for (key, chinese) in translations {
        XCTAssertEqual(bundle.localizedString(forKey: key, value: nil, table: "Localizable"),
          language == "en" ? key : chinese)
      }
    }
  }

  private func makeDefaults() throws -> CountingDefaults {
    let suite = "DayTimelineCanvasTests.\(UUID().uuidString)"
    return try XCTUnwrap(CountingDefaults(suite: suite))
  }

  private func makeHost(width: CGFloat) throws -> Fixture {
    Fixture(defaults: try makeDefaults(), width: width)
  }

  private func settle(_ view: NSView) async {
    view.layoutSubtreeIfNeeded()
    try? await Task.sleep(for: .milliseconds(80))
    view.layoutSubtreeIfNeeded()
  }

  private func findCanvas(_ view: NSView) -> TimelineCanvasScrollView? {
    if let scroll = view as? TimelineCanvasScrollView { return scroll }
    return view.subviews.lazy.compactMap { self.findCanvas($0) }.first
  }

  private func positionWheel(_ event: CGEvent, in window: NSWindow, scroll: NSScrollView) {
    let clip = scroll.contentView
    let windowPoint = clip.convert(NSPoint(x: clip.bounds.midX, y: clip.bounds.midY), to: nil)
    let screen = window.convertPoint(toScreen: windowPoint)
    event.location = CGPoint(x: screen.x, y: (NSScreen.screens.first?.frame.maxY ?? 0) - screen.y)
  }

  private func dispatchMagnify(_ event: NSEvent, in window: NSWindow) throws -> NSView {
    let root = try XCTUnwrap(window.contentView)
    let point = root.superview?.convert(event.locationInWindow, from: nil) ?? event.locationInWindow
    let target = try XCTUnwrap(root.hitTest(point))
    target.magnify(with: event)
    return target
  }

  private func magnifyEvent(_ scroll: NSScrollView, phase: NSEvent.Phase,
    delta: CGFloat, focusY: CGFloat) -> NSEvent
  {
    let point = scroll.contentView.convert(NSPoint(x: 100,
      y: scroll.contentView.bounds.minY + focusY), to: nil)
    return SyntheticMagnifyEvent(phase: phase, delta: delta, point: point)
  }

  private func attachImage(_ view: NSView, name: String) throws {
    let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
    view.cacheDisplay(in: view.bounds, to: bitmap)
    let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}

@MainActor
private final class MountedRefreshProbe {
  var dayHasActivities = false
  var weekHasActivities = false
  var daySelection: TimelineActivity?
  var weekSelection: TimelineActivity?
  var select: ((TimelineActivity) -> Void)?
  var navigate: ((Date) -> Void)?
}

private struct MountedRefreshFixture: View {
  @State private var date: Date
  let zoom: DayTimelineZoomState
  let probe: MountedRefreshProbe
  init(date: Date, zoom: DayTimelineZoomState, probe: MountedRefreshProbe) {
    _date = State(initialValue: date)
    self.zoom = zoom
    self.probe = probe
  }
  @State private var daySelection: TimelineActivity?
  @State private var weekSelection: TimelineActivity?
  @State private var dayHasActivities = false
  @State private var weekHasActivities = false
  var body: some View {
    HStack {
      CanvasTimelineDataView(selectedDate: .constant(date), selectedActivity: $daySelection,
        scrollToNowTick: .constant(0), hasAnyActivities: $dayHasActivities, refreshTrigger: .constant(0),
        contentLeadingInset: 0, zoom: zoom, cardTextFontSize: 13, cardTextFontWeight: .medium,
        timeLabelFontSize: 10, cardIconLeadingInset: 8, cardIconTextSpacing: 6, cardFaviconSize: 18,
        cardFaviconVerticalOffset: 0, cardCompactDurationThreshold: 13, cardCompactVerticalPadding: 0,
        cardNormalVerticalPadding: 6, cardHoverScale: 1, cardPressedScale: 1)
      WeekTimelineGridView(selectedDate: .constant(date), selectedActivity: $weekSelection,
        hasAnyActivities: $weekHasActivities, refreshTrigger: .constant(0), weekRange: .containing(date),
        onSelectActivity: { weekSelection = $0 }, onClearSelection: { weekSelection = nil })
    }
    .onAppear {
      probe.select = { activity in daySelection = activity; weekSelection = activity }
      probe.navigate = { date = $0 }
    }
    .onChange(of: dayHasActivities) { probe.dayHasActivities = dayHasActivities }
    .onChange(of: weekHasActivities) { probe.weekHasActivities = weekHasActivities }
    .onChange(of: daySelection?.title) { probe.daySelection = daySelection }
    .onChange(of: weekSelection?.title) { probe.weekSelection = weekSelection }
    .onChange(of: daySelection?.endTime) { probe.daySelection = daySelection }
    .onChange(of: weekSelection?.endTime) { probe.weekSelection = weekSelection }
  }
}

@MainActor
private final class AsyncTimelineProbe {
  var loadEvents: (([String]) -> Void)?
  var interruptInitialScroll: (() -> Void)?
  var revealEvents: (() -> Void)?
  var renderedTitle = ""
  var renderedVisible = false
}

private struct DayCanvasInitialScrollFixture: View {
  let zoom: DayTimelineZoomState
  let probe: AsyncTimelineProbe
  @State private var tick = 0

  var body: some View {
    CanvasTimelineDataView(
      selectedDate: .constant(timelineDisplayDate(from: Date())),
      selectedActivity: .constant(nil), scrollToNowTick: $tick,
      hasAnyActivities: .constant(false), refreshTrigger: .constant(0),
      contentLeadingInset: 0, zoom: zoom,
      cardTextFontSize: 13, cardTextFontWeight: .medium, timeLabelFontSize: 10,
      cardIconLeadingInset: 8, cardIconTextSpacing: 6, cardFaviconSize: 18,
      cardFaviconVerticalOffset: 0, cardCompactDurationThreshold: 13,
      cardCompactVerticalPadding: 0, cardNormalVerticalPadding: 6,
      cardHoverScale: 1, cardPressedScale: 1)
      .background(Color.white)
      .onAppear { probe.interruptInitialScroll = { tick &+= 1 } }
  }
}

private struct AsyncTimelineFixture: View {
  let zoom: DayTimelineZoomState
  let probe: AsyncTimelineProbe
  @State private var events: [String] = []
  @State private var visible = false

  var body: some View {
    DayTimelineCanvasScrollView(zoom: zoom) {
      VStack {
        ForEach(events, id: \.self) { title in
          AsyncEventRenderProbe(title: title, visible: visible, probe: probe)
            .frame(height: 30)
        }
      }
    }
    .onAppear {
      probe.loadEvents = { events = $0 }
      probe.revealEvents = { visible = true }
    }
  }
}

private struct AsyncEventRenderProbe: NSViewRepresentable {
  let title: String
  let visible: Bool
  let probe: AsyncTimelineProbe

  func makeNSView(context: Context) -> NSTextField {
    NSTextField(labelWithString: title)
  }

  func updateNSView(_ view: NSTextField, context: Context) {
    view.stringValue = title
    view.alphaValue = visible ? 1 : 0
    probe.renderedTitle = view.stringValue
    probe.renderedVisible = view.alphaValue == 1
  }
}

private final class FlippedDocument: NSView {
  override var isFlipped: Bool { true }
}

private final class CountingDefaults: UserDefaults {
  let suite: String
  var writes = 0
  init?(suite: String) { self.suite = suite; super.init(suiteName: suite) }
  override func set(_ value: Any?, forKey key: String) {
    if key == DayTimelineZoomState.storageKey { writes += 1 }
    super.set(value, forKey: key)
  }
}

/// NSEvent does not expose a public magnify-event factory. Override its public
/// readings, then invoke the production NSResponder entrance, without private APIs.
private final class SyntheticMagnifyEvent: NSEvent {
  private let eventPhase: NSEvent.Phase
  private let delta: CGFloat
  private let point: NSPoint
  init(phase: NSEvent.Phase, delta: CGFloat, point: NSPoint) {
    eventPhase = phase; self.delta = delta; self.point = point
    super.init()
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  override var type: NSEvent.EventType { .magnify }
  override var phase: NSEvent.Phase { eventPhase }
  override var magnification: CGFloat { delta }
  override var locationInWindow: NSPoint { point }
}

@MainActor
private final class Fixture {
  let defaults: CountingDefaults
  let zoom: DayTimelineZoomState
  let lifecycle = FixtureEnvironment()
  let width: CGFloat
  let window: NSWindow
  let host: NSHostingView<AnyView>
  var root: AnyView {
    AnyView(ZoomFixture(zoom: zoom, viewportWidth: width)
      .environmentObject(lifecycle)
      .environment(\.dayflowTheme, .light)
      .environment(\.colorScheme, .light))
  }
  init(defaults: CountingDefaults, width: CGFloat) {
    self.defaults = defaults
    self.width = width
    zoom = DayTimelineZoomState(defaults: defaults)
    host = NSHostingView(rootView: AnyView(EmptyView()))
    host.sizingOptions = []
    host.frame = NSRect(x: 0, y: 0, width: width, height: 500)
    window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    host.rootView = root
  }
  func close() {
    window.close()
    defaults.removePersistentDomain(forName: defaults.suite)
  }
}

private final class FixtureEnvironment: ObservableObject {
  let title = "Synthetic environment"
  var token = "synthetic-date"
  var request: DayTimelineScrollRequest?
  @Published var selected: Int?
  var isEmpty = false
  var appearances = 0
  var receivedEnvironment = ""
  var receivedDarkTheme = true
  var headerFrame = CGRect.zero
  var navigationFrame = CGRect.zero
  var controlsFrame = CGRect.zero
  var hourMarker = CGRect.zero
  var cardFrame = CGRect.zero
  var cardFrames: [Int: CGRect] = [:]
}

private struct ZoomFixture: View {
  @ObservedObject var zoom: DayTimelineZoomState
  @EnvironmentObject private var fixture: FixtureEnvironment
  @Environment(\.dayflowTheme) private var theme
  let viewportWidth: CGFloat
  var body: some View {
    VStack(spacing: 8) {
      DayTimelineHeaderLayout {
        Text("Synthetic day · 04:00–04:00")
          .font(.system(size: 12))
          .frame(maxWidth: .infinity, alignment: .leading)
          .frame(height: 36)
          .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("zoomFixture")) } action: {
            fixture.navigationFrame = $0
          }
        DayTimelineZoomControls(zoom: zoom)
          .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("zoomFixture")) } action: {
            fixture.controlsFrame = $0
          }
      }
      .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("zoomFixture")) } action: {
        fixture.headerFrame = $0
      }
      DayTimelineCanvasScrollView(zoom: zoom, navigationToken: fixture.token,
        scrollRequest: fixture.request) {
        SyntheticTimeline(zoom: zoom, viewportWidth: viewportWidth)
      }
    }
    .foregroundStyle(theme.textPrimary)
    .background(theme.panelSolid)
    .coordinateSpace(name: "zoomFixture")
  }
}

private struct SyntheticTimeline: View {
  @ObservedObject var zoom: DayTimelineZoomState
  @EnvironmentObject private var fixture: FixtureEnvironment
  @Environment(\.dayflowTheme) private var theme
  let viewportWidth: CGFloat
  private var height: CGFloat { DayTimelineZoom.hourHeight(for: zoom.percent) }
  var body: some View {
    ZStack(alignment: .topLeading) {
      theme.panelSolid
      ForEach(0..<24) { hour in
        Text("\((hour + 4) % 24):00")
          .font(.system(size: 10))
          .foregroundStyle(theme.hourLabel)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(alignment: .bottom) { theme.hourLine.frame(height: 0.5) }
          .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("canvasContent")) } action: {
            if hour == 6 { fixture.hourMarker = $0 }
          }
          .offset(y: CGFloat(hour) * height)
      }
      ForEach(0..<(fixture.isEmpty ? 0 : 3), id: \.self) { index in
        let minutes = index == 2 ? 1.0 : 10.0
        CanvasActivityCard(
          title: ["Plan update", "Review result", "One-minute event"][index],
          time: index == 2 ? "09:20–09:21" : "09:00–09:10",
          height: DayTimelineZoom.cardHeight(minutes: minutes, hourHeight: height),
          durationMinutes: minutes,
          style: CanvasActivityCardStyle(text: theme.cardTitle, time: theme.cardTime,
            accent: theme.accent, isIdle: false),
          isSelected: fixture.selected == index, isSystemCategory: false, isBackupGenerated: false,
          onTap: { fixture.selected = index }, faviconPrimaryRaw: nil, faviconSecondaryRaw: nil,
          faviconPrimaryHost: nil, faviconSecondaryHost: nil, statusLine: nil,
          failureCount: 0, fontSize: 13, fontWeight: .medium,
          iconLeadingInset: 8, iconTextSpacing: 6, faviconSize: 18,
          faviconVerticalOffset: 0, compactDurationThreshold: 13,
          compactVerticalPadding: 0, normalVerticalPadding: 6,
          hoverScale: 1, pressedScale: 1)
          .frame(width: max(0, viewportWidth - 60))
          .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("canvasContent")) } action: {
            fixture.cardFrames[index] = $0
            if index == 0 { fixture.cardFrame = $0 }
          }
          .offset(x: 60, y: DayTimelineZoom.y(minutes: Double(300 + 10 * index), hourHeight: height) + 1)
      }
    }
    .frame(height: 24 * height)
    .coordinateSpace(name: "canvasContent")
    .onAppear {
      fixture.appearances += 1
      fixture.receivedEnvironment = fixture.title
      fixture.receivedDarkTheme = theme.isDark
    }
  }
}
