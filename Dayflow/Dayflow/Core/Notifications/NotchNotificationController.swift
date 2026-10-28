import AppKit
import Combine
import SwiftUI

/// Geometry uses the physical screen edge, including the area occupied by the camera.
struct NotchNotificationLayout {
  let screenFrame: CGRect
  let cameraWidth: CGFloat
  let cameraHeight: CGFloat
  let body: String

  init(
    screenFrame: CGRect, cameraWidth: CGFloat, cameraHeight: CGFloat, body: String = ""
  ) {
    self.screenFrame = screenFrame
    self.cameraWidth = cameraWidth
    self.cameraHeight = cameraHeight
    self.body = body
  }

  static let horizontalContentPadding: CGFloat = 24
  static let contentTopPadding: CGFloat = 8
  static let contentBottomPadding: CGFloat = 16
  static let blockSpacing: CGFloat = 12
  static let titleLineHeight: CGFloat = 19
  static let buttonLineHeight: CGFloat = 15
  static let topBarExtraHeight: CGFloat = 6
  private static let bodyFontSize: CGFloat = 13
  private static let bodyLineSpacing: CGFloat = 3
  private static let maxBodyLines = 3

  var compactSize: CGSize {
    CGSize(width: min(screenFrame.width, max(180, cameraWidth + 104)),
           height: max(32, cameraHeight) + Self.topBarExtraHeight)
  }

  var expandedSize: CGSize {
    CGSize(width: expandedWidth,
           height: max(32, cameraHeight) + Self.topBarExtraHeight + expandedContentHeight)
  }

  private var expandedWidth: CGFloat {
    min(screenFrame.width - 24, max(460, cameraWidth + 160))
  }

  private var expandedContentHeight: CGFloat {
    Self.contentTopPadding
      + Self.titleLineHeight
      + Self.blockSpacing
      + Self.measuredBodyHeight(body, width: expandedWidth - Self.horizontalContentPadding * 2)
      + Self.blockSpacing
      + Self.buttonLineHeight
      + Self.contentBottomPadding
  }

  /// Matches the three-line limit of the reminder body so the panel never grows past its content.
  static func measuredBodyHeight(_ body: String, width: CGFloat) -> CGFloat {
    guard !body.isEmpty, width > 0 else { return 0 }
    let font = NSFont.systemFont(ofSize: bodyFontSize)
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineSpacing = bodyLineSpacing
    let measured = (body as NSString).boundingRect(
      with: CGSize(width: width, height: CGFloat.greatestFiniteMagnitude),
      options: [.usesLineFragmentOrigin, .usesFontLeading],
      attributes: [.font: font, .paragraphStyle: paragraph])
    let lineHeight = ceil(font.ascender - font.descender + font.leading)
    let maximum =
      lineHeight * CGFloat(maxBodyLines) + bodyLineSpacing * CGFloat(maxBodyLines - 1)
    return min(ceil(measured.height), maximum)
  }

  func frame(expanded: Bool) -> CGRect {
    let size = expanded ? expandedSize : compactSize
    return CGRect(x: screenFrame.midX - size.width / 2,
                  y: screenFrame.maxY - size.height, width: size.width, height: size.height)
  }
}

@MainActor
final class NotchNotificationController: ObservableObject {
  static let shared = NotchNotificationController()

  @Published private(set) var body = ""
  @Published private(set) var isExpanded = false
  @Published private(set) var isPresented = false
  @Published private(set) var cameraHeight: CGFloat = 32
  private var panel: NotchNotificationPanel?
  private var layout: NotchNotificationLayout?
  private var lifecycle: Task<Void, Never>?
  private var screenObserver: NSObjectProtocol?

  init() {
    screenObserver = NotificationCenter.default.addObserver(
      forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
    ) { [weak self] _ in
      Task { @MainActor in self?.dismissImmediately() }
    }
  }

  /// The latest reminder replaces the current one and stays expanded until dismissed.
  @discardableResult
  func show(body: String) -> Bool {
    guard let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
      ?? NSScreen.main else { return false }
    lifecycle?.cancel()
    let cameraWidth: CGFloat
    if screen.safeAreaInsets.top > 0,
      let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea
    {
      cameraWidth = max(0, right.minX - left.maxX)
    } else {
      cameraWidth = 0
    }
    let layout = NotchNotificationLayout(
      screenFrame: screen.frame, cameraWidth: cameraWidth,
      cameraHeight: screen.safeAreaInsets.top, body: body)
    self.layout = layout
    cameraHeight = max(32, layout.cameraHeight)
    self.body = body
    isExpanded = false
    isPresented = true
    let panel = self.panel ?? makePanel()
    self.panel = panel
    panel.setFrame(layout.frame(expanded: false), display: true)
    panel.orderFrontRegardless()
    lifecycle = Task { [weak self] in
      // Give the compact silhouette a frame before expanding out of the camera area.
      try? await Task.sleep(for: .milliseconds(120))
      guard !Task.isCancelled, let self else { return }
      self.expand()
    }
    return true
  }

  func dismiss() {
    guard isPresented else { return }
    lifecycle?.cancel()
    resize(expanded: false)
    lifecycle = Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(400))
      guard !Task.isCancelled else { return }
      self?.dismissImmediately()
    }
  }

  func dismissImmediately() {
    lifecycle?.cancel()
    lifecycle = nil
    isPresented = false
    isExpanded = false
    panel?.orderOut(nil)
  }

  func openEvents() {
    dismissImmediately()
    AppDelegate.pendingNotificationNavigationDestination = .events
    let showDockIcon = UserDefaults.standard.object(forKey: "showDockIcon") as? Bool ?? true
    if showDockIcon { NSApp.setActivationPolicy(.regular) }
    NSApp.unhide(nil)
    MainWindowController.shared.showMainWindow()
    NSApp.activate(ignoringOtherApps: true)
  }

  private func expand() {
    guard isPresented else { return }
    resize(expanded: true)
  }

  private func resize(expanded: Bool) {
    guard let panel, let layout else { return }
    let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.32)) {
      isExpanded = expanded
    }
    NSAnimationContext.runAnimationGroup { context in
      context.duration = reduceMotion ? 0 : 0.32
      context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
      panel.animator().setFrame(layout.frame(expanded: expanded), display: true)
    }
  }

  private func makePanel() -> NotchNotificationPanel {
    let panel = NotchNotificationPanel(
      contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered, defer: false)
    panel.isReleasedWhenClosed = false
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = true
    panel.level = .screenSaver
    panel.collectionBehavior = [
      .canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .canJoinAllApplications,
    ]
    panel.isFloatingPanel = true
    panel.hidesOnDeactivate = false
    panel.isMovableByWindowBackground = false
    // A plain container keeps NSHostingView's intrinsic-size updates from feeding
    // back into the animated window's content-size constraints.
    let container = NSView(frame: NSRect(origin: .zero, size: layout?.compactSize ?? .zero))
    let hosting = NSHostingView(rootView: NotchNotificationView(controller: self))
    hosting.sizingOptions = []
    hosting.frame = container.bounds
    hosting.autoresizingMask = [.width, .height]
    container.addSubview(hosting)
    panel.contentView = container
    return panel
  }
}

final class NotchNotificationPanel: NSPanel {
  // AppKit normally moves windows below the menu bar. This overlay must reach the
  // physical top edge so its black surface merges with the camera housing.
  override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
    frameRect
  }

  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }
}

/// A notch surface that flares into the physical top edge with inverted (concave)
/// top corners and rounded bottom corners. `UnevenRoundedRectangle` rounds all
/// corners outward, which makes the panel look detached from the screen edge.
struct NotchNotificationShape: Shape {
  var topCornerRadius: CGFloat = 8
  var bottomCornerRadius: CGFloat = 28

  func path(in rect: CGRect) -> Path {
    let top = min(topCornerRadius, rect.width / 2, rect.height / 2)
    let bottom = min(bottomCornerRadius, rect.width / 2 - top)
    var path = Path()
    path.move(to: CGPoint(x: rect.minX, y: rect.minY))
    path.addQuadCurve(
      to: CGPoint(x: rect.minX + top, y: rect.minY + top),
      control: CGPoint(x: rect.minX + top, y: rect.minY))
    path.addLine(to: CGPoint(x: rect.minX + top, y: rect.maxY - bottom))
    path.addQuadCurve(
      to: CGPoint(x: rect.minX + top + bottom, y: rect.maxY),
      control: CGPoint(x: rect.minX + top, y: rect.maxY))
    path.addLine(to: CGPoint(x: rect.maxX - top - bottom, y: rect.maxY))
    path.addQuadCurve(
      to: CGPoint(x: rect.maxX - top, y: rect.maxY - bottom),
      control: CGPoint(x: rect.maxX - top, y: rect.maxY))
    path.addLine(to: CGPoint(x: rect.maxX - top, y: rect.minY + top))
    path.addQuadCurve(
      to: CGPoint(x: rect.maxX, y: rect.minY),
      control: CGPoint(x: rect.maxX - top, y: rect.minY))
    path.closeSubpath()
    return path
  }
}

private struct NotchNotificationView: View {
  @ObservedObject var controller: NotchNotificationController
  // The notch always uses a black surface, including when the app is in light mode.
  private let accent = DayflowTheme.dark.accent

  var body: some View {
    VStack(spacing: 0) {
      // Keep all text below the physical camera. Only the two status marks flank it.
      HStack {
        Image("TargetFlowLogo")
          .renderingMode(.template)
          .resizable()
          .scaledToFit()
          .frame(width: 22, height: 22)
          .foregroundStyle(accent)
          .accessibilityHidden(true)
        Spacer(minLength: 0)
        Circle().fill(accent).frame(width: 7, height: 7)
      }
      .padding(.horizontal, 22)
      .frame(height: controller.cameraHeight + NotchNotificationLayout.topBarExtraHeight)

      if controller.isExpanded {
        VStack(alignment: .leading, spacing: NotchNotificationLayout.blockSpacing) {
          HStack {
            Text(String(localized: "Return to your current goal"))
              .font(.system(size: 16, weight: .semibold))
            Spacer()
            Text("Target Flow")
              .font(.system(size: 11, weight: .medium))
              .foregroundStyle(.white.opacity(0.5))
          }
          Text(controller.body)
            .font(.system(size: 13))
            .foregroundStyle(.white.opacity(0.85))
            .lineSpacing(3)
            .lineLimit(3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel(controller.body)
          HStack {
            Button(action: controller.openEvents) {
              Label(String(localized: "View Events & Goals"), systemImage: "arrow.up.right")
            }
            .buttonStyle(.plain)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(accent)
            Spacer()
            Button(String(localized: "Collapse"), action: controller.dismiss)
              .buttonStyle(.plain)
              .font(.system(size: 12))
              .foregroundStyle(.white.opacity(0.6))
          }
        }
        .padding(.horizontal, NotchNotificationLayout.horizontalContentPadding)
        .padding(.top, NotchNotificationLayout.contentTopPadding)
        .padding(.bottom, NotchNotificationLayout.contentBottomPadding)
        .transition(.opacity)
      }
      Spacer(minLength: 0)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .foregroundStyle(.white)
    .background(.black)
    .clipShape(NotchNotificationShape())
    .contentShape(Rectangle())
    .accessibilityElement(children: .contain)
    .accessibilityLabel(String(localized: "Current goal reminder"))
    .preferredColorScheme(.dark)
  }
}
