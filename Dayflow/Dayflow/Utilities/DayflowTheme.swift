//
//  DayflowTheme.swift
//  Dayflow
//
//  Shared blue-and-white palette for Target Flow. Views read
//  `@Environment(\.dayflowTheme)` so surfaces, controls and text remain
//  consistent in the system, light and dark appearances.
//

import SwiftUI

// MARK: - Appearance preference

/// User-facing appearance choice. Defaults to following the system.
enum DayflowAppearance: String, CaseIterable, Identifiable {
  case system
  case light
  case dark

  static let storageKey = "dayflowAppearance"

  var id: String { rawValue }

  var title: String {
    switch self {
    case .system: return String(localized: "System")
    case .light: return String(localized: "Light")
    case .dark: return String(localized: "Dark")
    }
  }

  func colorScheme(system: ColorScheme) -> ColorScheme {
    switch self {
    case .system: return system
    case .light: return .light
    case .dark: return .dark
    }
  }
}

/// Keep an explicit system scheme so switching back never passes nil to SwiftUI.
@MainActor
final class SystemAppearanceObserver: ObservableObject {
  @Published private(set) var colorScheme: ColorScheme
  private var observation: NSKeyValueObservation?

  init() {
    let app = NSApplication.shared
    colorScheme = Self.currentColorScheme
    observation = app.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
      Task { @MainActor [weak self] in
        self?.colorScheme = Self.currentColorScheme
      }
    }
  }

  static var currentColorScheme: ColorScheme {
    NSApplication.shared.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
      ? .dark : .light
  }
}

// MARK: - Theme tokens

struct DayflowTheme {
  let isDark: Bool

  // Window
  let windowBackground: AnyShapeStyle
  let windowBorder: Color

  // Main content panel (the big rounded card next to the sidebar)
  let panelFill: AnyShapeStyle
  let panelBorder: Color
  let panelShadow: Color
  let panelInnerGlow: Color
  /// Opaque approximation of the panel color, for fades that must hide content.
  let panelSolid: Color

  // Sidebar
  let sidebarSelectedFill: LinearGradient
  let sidebarSelectedBorder: Color
  let sidebarSelectedInnerGlow: Color
  let sidebarSelectedShadow: Color
  let sidebarLabel: Color
  let sidebarLabelActive: Color
  let sidebarIcon: Color
  let sidebarIconActive: Color

  // Text
  let textPrimary: Color
  let textSecondary: Color
  let textTertiary: Color
  let textMuted: Color
  let accent: Color
  let accentText: Color

  // Emphasized control (Pause, selected Day/Week segment)
  let controlFill: Color
  let controlBorder: Color
  let controlInnerGlow: Color
  let controlText: Color

  // Day/Week segmented container
  let segmentTrackFill: Color
  let segmentTrackBorder: Color
  let segmentInactiveText: Color

  // Small circular edit (pencil) button
  let editButtonFill: Color
  let editButtonBorder: Color
  let editButtonInnerGlow: Color

  // Category chips in the timeline header
  let chipFill: Color
  let chipBorder: Color
  let chipText: Color

  // Timeline grid
  let hourLabel: Color
  let hourLabelFuture: Color
  let hourLine: Color

  // Day timeline activity cards
  let cardFill: Color
  let cardBorder: Color
  let cardInnerGlow: Color
  let cardTitle: Color
  let cardTime: Color
  let cardFailedFill: Color

  // "Generating your next card…" card
  let generatingGradient: LinearGradient
  let pausedCardGradient: LinearGradient
  let pausedCardText: Color

  // Week timeline cards
  let weekCardFillOpacity: Double

  // Right panel (day summary)
  let rightPanelFill: Color
  let rightPanelBorder: Color
  let rightPanelShadow: Color
  let rightPanelDivider: Color

  // Today's targets header
  let targetsFill: Color
  let targetsBorder: Color
  let targetsTrackFill: Color
  let targetsTrackBorder: Color
  let targetsBubbleFill: Color
  let targetsBubbleBorder: Color
  let targetsInactiveTrack: Color
  let targetsInactiveFill: Color

  // Summary cards (Total focus time, Longest focus, Distractions)
  let summaryCardFill: Color
  let summaryCardBorder: Color
  let summaryCardShadow: Color
  let summaryCardInnerGlow: Color
  let summaryValue: Color

  // Donut chart
  let donutRingBackground: Color
  let donutCenterFill: Color
  let donutShadow: Color
  let legendSwatchOpacity: Double

  // Secondary button (Copy timeline, Cancel)
  let secondaryButtonFill: Color
  let secondaryButtonBorder: Color
  let secondaryButtonText: Color

  // Primary button (Confirm, Continue)
  let primaryButtonFill: Color
  let primaryButtonBorder: Color
  let primaryButtonInnerGlow: Color
  let primaryButtonText: Color

  // Floating editors / popovers
  let popoverFill: Color
  let popoverBorder: Color

  // Day goal sheet
  let sheetOverlay: Color
  let sheetCardFill: Color
  let sheetCardBorder: Color
  let sheetFocusHeader: Color
  let sheetDistractionHeader: Color
  let sheetFocusStatText: Color
  let sheetDistractionStatText: Color
  let sheetPanelFill: Color
  let sheetPanelBorder: Color
  let sheetInnerBoxFill: Color
  let sheetInnerBoxBorder: Color
  let sheetFooterFill: Color
  let sheetWheelGradient: LinearGradient
  let sheetWheelBorder: Color
  let sheetWheelDimText: Color

  // Daily view
  let dailyGridFill: Color
  let dailyGridBorder: Color
  let dailyTotalsFill: Color
  let dailyEmptyCell: Color
  let dailyDistractionTrack: Color
  let dailyDistractionTrackBorder: Color
  let dailyStatValue: Color
  let standupCardGradient: LinearGradient
  let standupCardBorder: Color
  let standupBlockersFill: Color
  let standupBlockersBorder: Color

  // Standard text field / input
  let inputFill: Color
  let inputBorder: Color

  // Chat
  let chatBackground: AnyShapeStyle
  let chatSoftAccentFill: Color
  let chatSoftAccentBorder: Color
  let chatSidePanelFill: Color
  let chatSidePanelHeaderFill: Color
  let chatCodeFill: Color
}

// MARK: - Blue-and-white palettes

extension DayflowTheme {
  static let brandBlue = Color(hex: "2869EF")
  static let light = palette(isDark: false)
  static let dark = palette(isDark: true)
  // Keep the upstream style-preview API compatible with the active palette.
  static let lightBefore = light
  static let darkBefore = dark

  var sidebarBackground: Color { isDark ? Color(hex: "163F91") : Self.brandBlue }
  var surfaceFill: Color { rightPanelFill }
  var surfaceMuted: Color { isDark ? Color(hex: "202D43") : Color(hex: "F6F8FB") }
  var separator: Color { rightPanelDivider }
  var accentSoft: Color { isDark ? Color(hex: "213A60") : Color(hex: "EDF3FF") }
  var accentBorder: Color { isDark ? Color(hex: "385889") : Color(hex: "DCE8FF") }
  var statusFocused: Color { accent }
  var statusNeutral: Color { isDark ? Color(hex: "A7B5CB") : Color(hex: "6E7B90") }
  var statusDistracted: Color { isDark ? Color(hex: "E9A29C") : Color(hex: "AF625B") }

  private static func palette(isDark: Bool) -> DayflowTheme {
    let canvas = Color(hex: isDark ? "131E30" : "F6F8FB")
    let surface = Color(hex: isDark ? "1B283D" : "FFFFFF")
    let inset = Color(hex: isDark ? "202D43" : "F6F8FB")
    let line = Color(hex: isDark ? "314059" : "E9EDF3")
    let primary = Color(hex: isDark ? "EDF3FC" : "202B3D")
    let secondary = Color(hex: isDark ? "B6C3D7" : "65748B")
    let muted = Color(hex: isDark ? "93A5BF" : "7A899F")
    let blue = Color(hex: isDark ? "79A7FF" : "2869EF")
    let blueSoft = Color(hex: isDark ? "213A60" : "EDF3FF")
    let blueLine = Color(hex: isDark ? "385889" : "DCE8FF")
    let shell = Color(hex: isDark ? "163F91" : "2869EF")
    let distraction = Color(hex: isDark ? "E9A29C" : "AF625B")

    return DayflowTheme(
      isDark: isDark,
      windowBackground: AnyShapeStyle(shell),
      windowBorder: shell,
      panelFill: AnyShapeStyle(canvas),
      panelBorder: .clear,
      panelShadow: Color.black.opacity(isDark ? 0.12 : 0.03),
      panelInnerGlow: .clear,
      panelSolid: canvas,

      sidebarSelectedFill: LinearGradient(colors: [canvas, canvas], startPoint: .top, endPoint: .bottom),
      sidebarSelectedBorder: .clear,
      sidebarSelectedInnerGlow: .clear,
      sidebarSelectedShadow: .clear,
      sidebarLabel: Color.white.opacity(0.85),
      sidebarLabelActive: blue,
      sidebarIcon: Color.white.opacity(0.85),
      sidebarIconActive: blue,

      textPrimary: primary,
      textSecondary: secondary,
      textTertiary: muted,
      textMuted: muted,
      accent: blue,
      accentText: blue,

      controlFill: brandBlue,
      controlBorder: brandBlue,
      controlInnerGlow: .clear,
      controlText: .white,
      segmentTrackFill: inset,
      segmentTrackBorder: line,
      segmentInactiveText: secondary,
      editButtonFill: brandBlue,
      editButtonBorder: brandBlue,
      editButtonInnerGlow: .clear,
      chipFill: blueSoft,
      chipBorder: blueLine,
      chipText: blue,

      hourLabel: muted,
      hourLabelFuture: muted.opacity(0.7),
      hourLine: line,
      cardFill: inset,
      cardBorder: line,
      cardInnerGlow: .clear,
      cardTitle: primary,
      cardTime: muted,
      cardFailedFill: Color(hex: isDark ? "402E38" : "FAEDEA"),
      generatingGradient: LinearGradient(
        colors: [blueSoft, inset], startPoint: .leading, endPoint: .trailing),
      pausedCardGradient: LinearGradient(
        colors: [inset, inset], startPoint: .leading, endPoint: .trailing),
      pausedCardText: secondary,
      weekCardFillOpacity: isDark ? 0.24 : 0.11,

      rightPanelFill: surface,
      rightPanelBorder: line,
      rightPanelShadow: Color.black.opacity(isDark ? 0.12 : 0.025),
      rightPanelDivider: line,
      targetsFill: surface,
      targetsBorder: line,
      targetsTrackFill: blueSoft,
      targetsTrackBorder: blueLine,
      targetsBubbleFill: surface,
      targetsBubbleBorder: blueLine,
      targetsInactiveTrack: inset,
      targetsInactiveFill: inset,
      summaryCardFill: surface,
      summaryCardBorder: line,
      summaryCardShadow: Color.black.opacity(isDark ? 0.08 : 0.025),
      summaryCardInnerGlow: .clear,
      summaryValue: blue,
      donutRingBackground: line,
      donutCenterFill: surface,
      donutShadow: Color.black.opacity(0.06),
      legendSwatchOpacity: isDark ? 0.7 : 0.6,

      secondaryButtonFill: surface,
      secondaryButtonBorder: line,
      secondaryButtonText: secondary,
      primaryButtonFill: brandBlue,
      primaryButtonBorder: brandBlue,
      primaryButtonInnerGlow: .clear,
      primaryButtonText: .white,
      popoverFill: surface,
      popoverBorder: line,

      sheetOverlay: Color.black.opacity(isDark ? 0.4 : 0.16),
      sheetCardFill: surface,
      sheetCardBorder: line,
      sheetFocusHeader: blue,
      sheetDistractionHeader: distraction,
      sheetFocusStatText: blue,
      sheetDistractionStatText: distraction,
      sheetPanelFill: inset,
      sheetPanelBorder: line,
      sheetInnerBoxFill: surface,
      sheetInnerBoxBorder: line,
      sheetFooterFill: surface,
      sheetWheelGradient: LinearGradient(
        colors: [inset, surface, surface, inset], startPoint: .top, endPoint: .bottom),
      sheetWheelBorder: line,
      sheetWheelDimText: muted,

      dailyGridFill: surface,
      dailyGridBorder: line,
      dailyTotalsFill: inset,
      dailyEmptyCell: line,
      dailyDistractionTrack: inset,
      dailyDistractionTrackBorder: line,
      dailyStatValue: secondary,
      standupCardGradient: LinearGradient(
        colors: [surface, surface], startPoint: .leading, endPoint: .trailing),
      standupCardBorder: line,
      standupBlockersFill: inset,
      standupBlockersBorder: line,
      inputFill: surface,
      inputBorder: line,

      chatBackground: AnyShapeStyle(Color.clear),
      chatSoftAccentFill: blueSoft,
      chatSoftAccentBorder: blueLine,
      chatSidePanelFill: surface,
      chatSidePanelHeaderFill: inset,
      chatCodeFill: inset
    )
  }
}

// MARK: - Environment plumbing

private struct DayflowThemeKey: EnvironmentKey {
  static let defaultValue = DayflowTheme.light
}

extension EnvironmentValues {
  var dayflowTheme: DayflowTheme {
    get { self[DayflowThemeKey.self] }
    set { self[DayflowThemeKey.self] = newValue }
  }
}

/// Resolves the theme from the effective color scheme and injects it.
/// Attach once at the root of a window; every descendant reads
/// `@Environment(\.dayflowTheme)`.
private struct DayflowThemeResolver: ViewModifier {
  @Environment(\.colorScheme) private var colorScheme
  @ObservedObject private var preview = StylePreview.shared

  func body(content: Content) -> some View {
    content.environment(
      \.dayflowTheme,
      colorScheme == .dark
        ? (preview.showAfter ? .dark : .darkBefore)
        : (preview.showAfter ? .light : .lightBefore))
  }
}

extension View {
  func resolveDayflowTheme() -> some View {
    modifier(DayflowThemeResolver())
  }

  /// Forces a subtree to a specific theme regardless of the system appearance.
  /// Used by onboarding, which is designed light-only.
  func dayflowTheme(_ theme: DayflowTheme) -> some View {
    environment(\.dayflowTheme, theme)
      .environment(\.colorScheme, theme.isDark ? .dark : .light)
  }
}

// MARK: - Adaptive colors

extension Color {
  /// A color that resolves per appearance (light / dark) automatically, for
  /// static design tokens like `SettingsStyle` that can't read the environment.
  static func dayflowAdaptive(light: NSColor, dark: NSColor) -> Color {
    Color(
      nsColor: NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return isDark ? dark : light
      }
    )
  }
}

// MARK: - Shared shapes

/// Optional inset glow for shared controls: a soft stroke drawn
/// just inside the shape's edge.
struct InnerGlow<S: InsettableShape>: View {
  let shape: S
  let color: Color
  var radius: CGFloat = 4
  /// Stroke width of the glow band; defaults to `radius`.
  var spread: CGFloat? = nil
  /// Softness of the band's edges; defaults to `radius`.
  var blur: CGFloat? = nil

  var body: some View {
    shape
      .strokeBorder(color, lineWidth: spread ?? radius)
      .blur(radius: blur ?? radius)
      .clipShape(shape)
      .allowsHitTesting(false)
  }
}
