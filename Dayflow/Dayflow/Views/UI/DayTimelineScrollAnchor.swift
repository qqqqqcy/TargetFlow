import AppKit
import Combine
import QuartzCore
import SwiftUI

struct DayTimelineScrollRequest: Equatable {
  var id = UUID()
  let hours: CGFloat
  var viewportFraction: CGFloat = 0.25
}

/// Owns one native scroll view for the lifetime of the mounted day. Density and
/// offset are committed synchronously here, never in a next-runloop repair.
struct DayTimelineCanvasScrollView<Content: View>: NSViewRepresentable {
  let zoom: DayTimelineZoomState
  var navigationToken: String = ""
  var scrollRequest: DayTimelineScrollRequest?
  @ViewBuilder let content: () -> Content

  func makeNSView(context: Context) -> TimelineCanvasScrollView {
    TimelineCanvasScrollView(zoom: zoom)
  }

  func updateNSView(_ view: TimelineCanvasScrollView, context: Context) {
    let environment = context.environment
    view.update(navigationToken: navigationToken, scrollRequest: scrollRequest) {
      AnyView(content().environment(\.self, environment))
    }
  }

  static func dismantleNSView(_ view: TimelineCanvasScrollView, coordinator: ()) {
    view.detach()
  }
}

/// NSHostingView otherwise gets first refusal on magnify events over its cards.
/// Forward those events explicitly; scrollWheel remains AppKit's native path.
private final class TimelineCanvasHostingView: NSHostingView<AnyView> {
  weak var canvas: TimelineCanvasScrollView?
  override func magnify(with event: NSEvent) { canvas?.magnify(with: event) }
}

final class TimelineCanvasScrollView: NSScrollView {
  private let zoom: DayTimelineZoomState
  private let hosting = TimelineCanvasHostingView(rootView: AnyView(EmptyView()))
  private var subscription: AnyCancellable?
  private var makeContent: (() -> AnyView)?
  private var navigationToken: String?
  private var requestID: UUID?
  private var pendingScrollRequest: DayTimelineScrollRequest?
  private var renderedHourHeight: CGFloat
  private var gestureFocus: CGFloat?
  private var isPinching = false
  private var suppressUntilNextGesture = false
  private var suppressOldMomentum = false
  private var lastWheelEvent: NSEvent?
  private var isAttached = true
  private var isCommitting = false

  #if DEBUG
  /// Captured at AppKit's drawing boundary by the isolated regression host.
  var displayProbe: ((CGFloat, CGFloat, CGFloat) -> Void)?
  var wheelForwardingProbe: ((NSEvent) -> Void)?
  #endif

  init(zoom: DayTimelineZoomState) {
    self.zoom = zoom
    renderedHourHeight = DayTimelineZoom.hourHeight(for: zoom.percent)
    super.init(frame: .zero)
    drawsBackground = false
    hasVerticalScroller = false
    hasHorizontalScroller = false
    horizontalScrollElasticity = .none
    verticalScrollElasticity = .automatic
    allowsMagnification = false // We resize time geometry, never the rendered text.
    hosting.sizingOptions = []
    hosting.isFlipped = true
    hosting.canvas = self
    documentView = hosting
    subscription = zoom.changes.sink { [weak self] percent in
      self?.applyDensity(percent)
    }
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func update(navigationToken: String, scrollRequest: DayTimelineScrollRequest?,
    content: @escaping () -> AnyView)
  {
    if let previous = self.navigationToken, previous != navigationToken {
      suppressUntilNextGesture = isPinching
      finishGesture()
    }
    self.navigationToken = navigationToken
    makeContent = content
    commitGeometry(hourHeight: DayTimelineZoom.hourHeight(for: zoom.percent),
      offset: contentView.bounds.minY, layoutContent: false)
    if let scrollRequest, scrollRequest.id != requestID {
      pendingScrollRequest = scrollRequest
    }
    applyPendingScrollIfReady()
  }

  override func layout() {
    super.layout()
    guard !isCommitting, makeContent != nil else { return }
    let width = contentView.bounds.width
    if abs(hosting.frame.width - width) > 0.5 {
      commitGeometry(hourHeight: renderedHourHeight, offset: contentView.bounds.minY,
        layoutContent: false)
    }
    applyPendingScrollIfReady()
  }

  private func applyPendingScrollIfReady() {
    // A cold window can deliver its first request with a zero-sized viewport.
    // Keep it pending until layout provides the size needed for its time anchor.
    guard let request = pendingScrollRequest,
      contentView.bounds.width > 0, contentView.bounds.height > 0 else { return }
    pendingScrollRequest = nil
    requestID = request.id
    setOffset(request.hours * renderedHourHeight
      - request.viewportFraction * contentView.bounds.height)
  }

  override func magnify(with event: NSEvent) {
    guard isAttached, makeContent != nil else { return }
    if event.phase.contains(.began) {
      suppressUntilNextGesture = false
      stopPreviousScroll()
      suppressOldMomentum = true
      isPinching = true
    }
    guard !suppressUntilNextGesture else { return }
    if event.phase.contains(.cancelled) {
      // Retain the last displayed density; cancellation must not jump back.
      finishGesture()
      return
    }
    if !isPinching { isPinching = true }
    let location = contentView.convert(event.locationInWindow, from: nil)
    gestureFocus = min(contentView.bounds.height,
      max(0, location.y - contentView.bounds.minY))
    let delta = Double(event.magnification)
    if delta.isFinite, delta > -1, delta != 0 {
      zoom.setLive(zoom.percent * (1 + delta))
    }
    if event.phase.contains(.ended) || event.phase.isEmpty {
      finishGesture()
    }
  }

  override func scrollWheel(with event: NSEvent) {
    // A pinch owns its time focus. Late momentum from a previous pan must not
    // keep pulling that focus, including immediately after the pinch ends.
    guard !isPinching else { return }
    if !event.momentumPhase.isEmpty, suppressOldMomentum { return }
    if event.phase.contains(.began) || (event.phase.isEmpty && event.momentumPhase.isEmpty) {
      suppressOldMomentum = false
    }
    lastWheelEvent = event
    #if DEBUG
    wheelForwardingProbe?(event)
    #endif
    super.scrollWheel(with: event)
  }

  private func stopPreviousScroll() {
    guard let cg = lastWheelEvent?.cgEvent?.copy() else { return }
    // Cancel through AppKit's own scroll engine, retaining the source event's
    // device metadata. No custom pan integrator or private scrolling API.
    cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(CGScrollPhase.cancelled.rawValue))
    cg.setIntegerValueField(.scrollWheelEventMomentumPhase, value: 0)
    for field: CGEventField in [.scrollWheelEventDeltaAxis1, .scrollWheelEventDeltaAxis2,
      .scrollWheelEventPointDeltaAxis1, .scrollWheelEventPointDeltaAxis2,
      .scrollWheelEventFixedPtDeltaAxis1, .scrollWheelEventFixedPtDeltaAxis2]
    { cg.setIntegerValueField(field, value: 0) }
    if let cancellation = NSEvent(cgEvent: cg) { super.scrollWheel(with: cancellation) }
    lastWheelEvent = nil
  }

  private func applyDensity(_ percent: Double) {
    guard isAttached, makeContent != nil else { return }
    let height = DayTimelineZoom.hourHeight(for: percent)
    let focus = gestureFocus ?? pointerFocusOrCenter()
    let offset = DayTimelineZoom.anchoredOffset(contentView.bounds.minY,
      from: renderedHourHeight, to: height, contentHeight: 24 * height,
      viewportHeight: contentView.bounds.height, focusY: focus)
    commitGeometry(hourHeight: height, offset: offset)
  }

  private func pointerFocusOrCenter() -> CGFloat {
    if let window, window.isVisible {
      let point = contentView.convert(window.mouseLocationOutsideOfEventStream, from: nil)
      if contentView.bounds.contains(point) { return point.y - contentView.bounds.minY }
    }
    return contentView.bounds.height / 2
  }

  private func commitGeometry(hourHeight: CGFloat, offset: CGFloat, layoutContent: Bool = true) {
    guard let makeContent, !isCommitting else { return }
    isCommitting = true
    defer { isCommitting = false }
    // AppKit draws after this event/update returns. Both the hosting layout and
    // clip origin settle inside one transaction; no async offset correction exists.
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    var transaction = Transaction(animation: nil)
    transaction.disablesAnimations = true
    withTransaction(transaction) {
      hosting.rootView = makeContent()
      hosting.frame = NSRect(x: 0, y: 0,
        width: contentView.bounds.width, height: 24 * hourHeight)
      // SwiftUI owns layout during representable updates. Forcing this nested
      // hosting view to lay out there creates a graph cycle on a cold window.
      // Native pinch events still settle content synchronously before drawing.
      if layoutContent { hosting.layoutSubtreeIfNeeded() }
      renderedHourHeight = hourHeight
      setOffset(offset)
    }
    CATransaction.commit()
  }

  private func setOffset(_ offset: CGFloat) {
    let maximum = max(0, hosting.frame.height - contentView.bounds.height)
    contentView.scroll(to: NSPoint(x: 0, y: min(maximum, max(0, offset))))
    reflectScrolledClipView(contentView)
  }

  private func finishGesture() {
    if isPinching { zoom.commit() }
    isPinching = false
    gestureFocus = nil
  }

  func detach() {
    finishGesture()
    isAttached = false
    subscription = nil
    hosting.canvas = nil
    hosting.rootView = AnyView(EmptyView())
    makeContent = nil
    pendingScrollRequest = nil
  }

  override func viewWillDraw() {
    super.viewWillDraw()
    #if DEBUG
    displayProbe?(hosting.frame.height, contentView.bounds.minY, renderedHourHeight)
    #endif
  }
}
