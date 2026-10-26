import SwiftUI

// MARK: - Settings design system

// Shared blue accents, neutral surfaces, and readable light/dark text.
enum SettingsStyle {
  static let sectionSpacing = DayflowLayout.sectionSpacing
  static let rowVerticalPadding: CGFloat = 13

  private static func adaptive(_ light: UInt32, _ dark: UInt32) -> Color {
    func color(_ hex: UInt32) -> NSColor {
      NSColor(
        red: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: 1)
    }
    return Color.dayflowAdaptive(light: color(light), dark: color(dark))
  }

  static let text = adaptive(0x202D43, 0xE7EDF8)
  static let secondary = adaptive(0x62728C, 0xB1BDD1)
  static let meta = adaptive(0x73839C, 0x94A3BB)
  static let divider = adaptive(0xE5EBF4, 0x303F57)
  static let subtleFill = adaptive(0xF1F5FB, 0x25334B)
  static let surface = adaptive(0xFFFFFF, 0x1D293D)
  static let canvas = adaptive(0xF6F8FB, 0x162235)
  static let editorFill = adaptive(0xF6F8FB, 0x152136)
  static let editorBorder = adaptive(0xDCE5F1, 0x3A4C69)
  static let ink = adaptive(0x2869EF, 0x82ADFF)
  static let primaryButtonFill = adaptive(0x2869EF, 0x2869EF)
  static let destructive = adaptive(0xB85050, 0xED9999)
  static let statusGood = adaptive(0x428471, 0x87C3AD)
  static let statusIdle = secondary
  static let statusWarn = adaptive(0x9A732D, 0xDBBB7B)
  static let statusBad = destructive
}

// MARK: - SettingsSection
//
// A section groups related preferences in a quiet, outlined surface.

struct SettingsSection<Content: View, Trailing: View>: View {
  let title: String
  let subtitle: String?
  let trailing: () -> Trailing
  let content: () -> Content

  init(
    title: String,
    subtitle: String? = nil,
    @ViewBuilder trailing: @escaping () -> Trailing,
    @ViewBuilder content: @escaping () -> Content
  ) {
    self.title = title
    self.subtitle = subtitle
    self.trailing = trailing
    self.content = content
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(alignment: .firstTextBaseline, spacing: 16) {
        VStack(alignment: .leading, spacing: 4) {
          Text(title)
            .font(.system(size: 17))
            .fontWeight(.semibold)
            .foregroundColor(SettingsStyle.text)
          if let subtitle {
            Text(subtitle)
              .font(.system(size: 12))
              .foregroundColor(SettingsStyle.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
        Spacer(minLength: 12)
        trailing()
      }
      .padding(.bottom, 14)

      content()
    }
    .padding(DayflowLayout.cardInset)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      SettingsStyle.surface,
      in: RoundedRectangle(cornerRadius: DayflowLayout.cardRadius, style: .continuous)
    )
    .overlay {
      RoundedRectangle(cornerRadius: DayflowLayout.cardRadius, style: .continuous)
        .strokeBorder(SettingsStyle.divider, lineWidth: 1)
    }
  }
}

extension SettingsSection where Trailing == EmptyView {
  init(title: String, subtitle: String? = nil, @ViewBuilder content: @escaping () -> Content) {
    self.init(title: title, subtitle: subtitle, trailing: { EmptyView() }, content: content)
  }
}

// MARK: - SettingsRow
//
// Label left, control right, optional subtitle under the label. If the row
// needs a full-width accessory (progress bar, expanded calendar), compose
// it manually — we intentionally keep this component minimal so every row
// on every tab has identical rhythm.

struct SettingsRow<Trailing: View>: View {
  let label: String
  let subtitle: String?
  let showsDivider: Bool
  let trailing: () -> Trailing

  init(
    label: String,
    subtitle: String? = nil,
    showsDivider: Bool = true,
    @ViewBuilder trailing: @escaping () -> Trailing
  ) {
    self.label = label
    self.subtitle = subtitle
    self.showsDivider = showsDivider
    self.trailing = trailing
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(alignment: .center, spacing: 16) {
        VStack(alignment: .leading, spacing: 3) {
          Text(label)
            .font(.system(size: 14))
            .fontWeight(.semibold)
            .foregroundColor(SettingsStyle.text)
            .fixedSize(horizontal: false, vertical: true)
          if let subtitle {
            Text(subtitle)
              .font(.system(size: 12))
              .foregroundColor(SettingsStyle.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
        Spacer(minLength: 12)
        trailing()
      }
      .padding(.vertical, SettingsStyle.rowVerticalPadding)

      if showsDivider {
        Rectangle()
          .fill(SettingsStyle.divider)
          .frame(height: 1)
      }
    }
  }
}

extension SettingsRow where Trailing == EmptyView {
  init(label: String, subtitle: String? = nil, showsDivider: Bool = true) {
    self.init(
      label: label, subtitle: subtitle, showsDivider: showsDivider, trailing: { EmptyView() })
  }
}

// MARK: - Buttons
//
// Primary actions use blue; secondary actions use an outlined surface;
// inline links share the same accent.

struct SettingsPrimaryButton: View {
  let title: String
  var systemImage: String? = nil
  var isLoading: Bool = false
  var isDisabled: Bool = false
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 8) {
        if isLoading {
          ProgressView()
            .controlSize(.small)
            .tint(.white)
        } else if let systemImage {
          Image(systemName: systemImage)
            .font(.system(size: 12, weight: .semibold))
        }
        Text(title)
          .font(.system(size: 13))
          .fontWeight(.semibold)
      }
      .foregroundColor(.white)
      .padding(.horizontal, DayflowLayout.buttonHorizontalInset)
      .frame(height: DayflowLayout.buttonHeight)
      .background(
        RoundedRectangle(cornerRadius: DayflowLayout.buttonRadius, style: .continuous)
          .fill(SettingsStyle.primaryButtonFill.opacity(isDisabled ? 0.4 : 1))
      )
    }
    .buttonStyle(SettingsButtonPressStyle())
    .disabled(isDisabled || isLoading)
    .pointingHandCursor()
  }
}

struct SettingsSecondaryButton: View {
  let title: String
  var systemImage: String? = nil
  var isDisabled: Bool = false
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 6) {
        if let systemImage {
          Image(systemName: systemImage)
            .font(.system(size: 11, weight: .semibold))
        }
        Text(title)
          .font(.system(size: 13))
          .fontWeight(.semibold)
      }
      .foregroundColor(SettingsStyle.secondary.opacity(isDisabled ? 0.4 : 1))
      .padding(.horizontal, DayflowLayout.buttonHorizontalInset)
      .frame(height: DayflowLayout.buttonHeight)
      .background(
        RoundedRectangle(cornerRadius: DayflowLayout.buttonRadius, style: .continuous)
          .fill(SettingsStyle.surface.opacity(isDisabled ? 0.4 : 1))
      )
      .overlay {
        RoundedRectangle(cornerRadius: DayflowLayout.buttonRadius, style: .continuous)
          .strokeBorder(SettingsStyle.divider, lineWidth: 1)
      }
    }
    .buttonStyle(SettingsButtonPressStyle())
    .disabled(isDisabled)
    .pointingHandCursor()
  }
}

struct SettingsLinkButton: View {
  let title: String
  var systemImage: String? = "arrow.up.right"
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 5) {
        Text(title)
          .font(.system(size: 13))
          .fontWeight(.semibold)
        if let systemImage {
          Image(systemName: systemImage)
            .font(.system(size: 11, weight: .semibold))
        }
      }
      .foregroundColor(SettingsStyle.ink)
    }
    .buttonStyle(.plain)
    .pointingHandCursor()
  }
}

private struct SettingsButtonPressStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .opacity(configuration.isPressed ? 0.85 : 1)
      .scaleEffect(configuration.isPressed ? 0.98 : 1)
      .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
  }
}

// MARK: - SettingsStatusDot
//
// A 6pt colored dot + 13pt label. Every status in settings reads through
// this component. If something needs a status indicator and can't fit one
// of these four states, the copy is wrong — not the component.

struct SettingsStatusDot: View {
  enum State {
    case good, idle, warn, bad
  }

  let state: State
  let label: String

  private var color: Color {
    switch state {
    case .good: return SettingsStyle.statusGood
    case .idle: return SettingsStyle.secondary
    case .warn: return SettingsStyle.statusWarn
    case .bad: return SettingsStyle.statusBad
    }
  }

  var body: some View {
    HStack(spacing: 7) {
      Circle()
        .fill(color)
        .frame(width: 8, height: 8)
      Text(label)
        .font(.system(size: 13))
        .fontWeight(.semibold)
        .foregroundColor(color)
    }
  }
}

// MARK: - SettingsToggle
//
// The standard on/off control for a settings row. Rendered at ~70% of
// native size so the switch reads as a control, not a billboard — on a
// row with a tight label + subtitle, the full-size NSSwitch visually
// outweighs its own label, which is backwards. Anchored to `.trailing`
// so the scaled switch hugs the right edge of the row cleanly.

struct SettingsToggle: View {
  @Binding var isOn: Bool

  var body: some View {
    Toggle("", isOn: $isOn)
      .toggleStyle(DayflowToggleStyle())
      .tint(SettingsStyle.primaryButtonFill)
      .labelsHidden()
      .scaleEffect(0.72, anchor: .trailing)
      .pointingHandCursor()
  }
}

// MARK: - SettingsBadge
//
// Compact accent and neutral badges for provider roles and connection state.

struct SettingsBadge: View {
  let text: String
  var isAccent: Bool = false

  var body: some View {
    Text(text)
      .font(.system(size: 10))
      .fontWeight(.bold)
      .kerning(0.6)
      .foregroundColor(isAccent ? SettingsStyle.ink : SettingsStyle.secondary)
      .padding(.horizontal, 7)
      .padding(.vertical, 3)
      .background(
        RoundedRectangle(cornerRadius: 4, style: .continuous)
          .fill(isAccent ? SettingsStyle.ink.opacity(0.1) : SettingsStyle.subtleFill)
      )
  }
}

// MARK: - SettingsMetadata
//
// The standard right-rail text treatment. Use this anywhere the trailing
// view is informational text (counts, sizes, percentages, timestamps) so
// every bit of right-rail metadata reads the same.

struct SettingsMetadata: View {
  let text: String
  var body: some View {
    Text(text)
      .font(.system(size: 13))
      .foregroundColor(SettingsStyle.secondary)
  }
}
