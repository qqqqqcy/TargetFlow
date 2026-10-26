import AppKit
import Combine
import SwiftUI

/// Geometry uses the physical screen edge, including the area occupied by the camera.
struct NotchNotificationLayout {
  let screenFrame: CGRect
  let cameraWidth: CGFloat
  let cameraHeight: CGFloat

  var compactSize: CGSize {
    CGSize(width: min(screenFrame.width, max(180, cameraWidth + 104)),
           height: max(32, cameraHeight) + 6)
  }

  var expandedSize: CGSize {
    CGSize(width: min(screenFrame.width - 24, max(460, cameraWidth + 160)),
           height: max(32, cameraHeight) + 174)
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
  private var isHovering = false
  private var isRetracting = false
  private var screenObserver: NSObjectProtocol?

  private init() {
    screenObserver = NotificationCenter.default.addObserver(
      forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
    ) { [weak self] _ in
      Task { @MainActor in self?.dismissImmediately() }
    }
  }

  /// The latest reminder replaces the current one and receives a fresh reading interval.
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
      cameraHeight: screen.safeAreaInsets.top)
    self.layout = layout
    cameraHeight = max(32, layout.cameraHeight)
    self.body = body
    isHovering = false
    isRetracting = false
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
      self.scheduleRetraction(after: .seconds(12))
    }
    return true
  }

  func hover(_ hovering: Bool) {
    guard isPresented, !isRetracting, isHovering != hovering else { return }
    isHovering = hovering
    if hovering {
      lifecycle?.cancel()
      expand()
    } else {
      scheduleRetraction(after: .seconds(5))
    }
  }

  func dismiss() {
    guard isPresented else { return }
    lifecycle?.cancel()
    isRetracting = true
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
    isHovering = false
    isRetracting = false
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

  private func scheduleRetraction(after delay: Duration) {
    lifecycle?.cancel()
    lifecycle = Task { [weak self] in
      try? await Task.sleep(for: delay)
      guard !Task.isCancelled, let self, !self.isHovering else { return }
      self.dismiss()
    }
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
      .frame(height: controller.cameraHeight + 6)

      if controller.isExpanded {
        VStack(alignment: .leading, spacing: 12) {
          HStack {
            Text("回到当前目标")
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
              Label("查看事件与目标", systemImage: "arrow.up.right")
            }
            .buttonStyle(.plain)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(accent)
            Spacer()
            Button("收起", action: controller.dismiss)
              .buttonStyle(.plain)
              .font(.system(size: 12))
              .foregroundStyle(.white.opacity(0.6))
          }
        }
        .padding(.horizontal, 24)
        .padding(.top, 8)
        .padding(.bottom, 22)
        .transition(.opacity)
      }
      Spacer(minLength: 0)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .foregroundStyle(.white)
    .background(.black)
    .clipShape(UnevenRoundedRectangle(
      topLeadingRadius: 8, bottomLeadingRadius: 28,
      bottomTrailingRadius: 28, topTrailingRadius: 8))
    .contentShape(Rectangle())
    .onHover(perform: controller.hover)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("当前目标提醒")
    .preferredColorScheme(.dark)
  }
}
