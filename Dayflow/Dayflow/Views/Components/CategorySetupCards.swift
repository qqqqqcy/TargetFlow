import SwiftUI
import UniformTypeIdentifiers

struct EditableCategoryCard: View {
  enum Field: Hashable {
    case name
    case description
  }

  let category: TimelineCategory
  let isEditing: Bool
  @Binding var draftName: String
  @Binding var draftDetails: String
  var onStartEdit: () -> Void
  var onSave: () -> Void
  var onDelete: () -> Void

  @EnvironmentObject private var categoryStore: CategoryStore
  @Environment(\.dayflowTheme) private var theme
  @FocusState private var focusedField: Field?

  var body: some View {
    Group {
      if isEditing {
        editingView
          .onAppear {
            focusedField = .name
          }
          .onDisappear {
            focusedField = nil
          }
      } else {
        displayView
      }
    }
  }

  @ViewBuilder
  private var targetToggle: some View {
    if !category.isSystem && !category.isIdle {
      Toggle(
        "当前目标",
        isOn: Binding(
          get: { category.isCurrentTarget },
          set: { categoryStore.setCurrentTarget($0, for: category.id) }
        )
      )
      .toggleStyle(DayflowToggleStyle())
      .controlSize(.small)
      .font(.system(size: 12))
      .tint(theme.accent)
      .foregroundStyle(theme.textSecondary)
      .fixedSize()
      .accessibilityLabel("将\(category.name)设为当前目标")
    }
  }

  private var editingView: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 10) {
        TextField("事件名称", text: $draftName)
          .font(.system(size: 13, weight: .semibold))
          .textFieldStyle(.plain)
          .foregroundStyle(theme.textPrimary)
          .submitLabel(.next)
          .focused($focusedField, equals: .name)
          .onSubmit { focusedField = .description }

        Button {
          focusedField = nil
          onSave()
        } label: {
          Image(systemName: "checkmark")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(theme.accent)
            .frame(width: 28, height: 28)
            .background(theme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .accessibilityLabel("保存事件")
      }

      ZStack(alignment: .topLeading) {
        if draftDetails.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          Text("描述要推进的具体事情，例如完成登录页，允许查阅 SwiftUI 文档。")
            .font(.system(size: 12))
            .foregroundStyle(theme.textMuted)
            .padding(10)
            .allowsHitTesting(false)
        }
        TextEditor(text: $draftDetails)
          .font(.system(size: 12))
          .foregroundStyle(theme.textPrimary)
          .scrollContentBackground(.hidden)
          .padding(6)
          .frame(minHeight: 70)
          .focused($focusedField, equals: .description)
          .accessibilityLabel("事件说明")
      }
      .background(theme.inputFill, in: RoundedRectangle(cornerRadius: 8))
      .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.inputBorder, lineWidth: 1))

      targetToggle
    }
    .padding(14)
    .background(theme.rightPanelFill, in: RoundedRectangle(cornerRadius: 10))
    .overlay(RoundedRectangle(cornerRadius: 10).stroke(theme.accent.opacity(0.45), lineWidth: 1))
  }

  private var displayView: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .top, spacing: 10) {
        Circle()
          .fill(Color(hex: category.colorHex).opacity(0.7))
          .frame(width: 7, height: 7)
          .padding(.top, 5)

        VStack(alignment: .leading, spacing: 6) {
          Text(category.name)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(theme.textPrimary)
          Text(
            category.details.isEmpty
              ? String(localized: "补充事件说明，帮助识别实际在做的事情。")
              : category.details
          )
          .font(.system(size: 12))
          .foregroundStyle(theme.textSecondary)
          .lineSpacing(3)
          .lineLimit(3)
          .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture {
          if !category.isSystem { onStartEdit() }
        }
        .pointingHandCursor(enabled: !category.isSystem)
      }

      HStack(spacing: 8) {
        targetToggle
        Spacer(minLength: 0)
        if !category.isSystem {
          Button(action: onStartEdit) {
            Image(systemName: "pencil")
              .frame(width: DayflowLayout.buttonHeight, height: DayflowLayout.buttonHeight)
              .background(
                theme.chipFill, in: RoundedRectangle(cornerRadius: DayflowLayout.buttonRadius))
          }
          .foregroundStyle(theme.textSecondary)
          .accessibilityLabel("编辑事件")

          Button(action: onDelete) {
            Image(systemName: "trash")
              .frame(width: DayflowLayout.buttonHeight, height: DayflowLayout.buttonHeight)
              .background(
                theme.chipFill, in: RoundedRectangle(cornerRadius: DayflowLayout.buttonRadius))
          }
          .foregroundStyle(theme.textTertiary)
          .accessibilityLabel("删除事件")
        }
      }
      .font(.system(size: 12))
      .buttonStyle(.plain)
      .pointingHandCursor()
    }
    .padding(14)
    .background(theme.rightPanelFill, in: RoundedRectangle(cornerRadius: 10))
    .overlay(
      RoundedRectangle(cornerRadius: 10)
        .stroke(
          category.isCurrentTarget ? theme.accent.opacity(0.3) : theme.rightPanelBorder,
          lineWidth: 1)
    )
  }
}

struct ColorAssignmentCard: View {
  let category: TimelineCategory
  var showDetails: Bool = true
  var onColorDrop: (String) -> Void

  @Environment(\.dayflowTheme) private var theme
  @State private var isTargeted = false

  private func colorSwatch(_ hex: String) -> some View {
    let color = Color(hex: hex.isEmpty ? "#E5E7EB" : hex)
    return Rectangle()
      .foregroundColor(.clear)
      .frame(width: 18, height: 18)
      .background(color)
      .cornerRadius(6)
      .shadow(color: Color.black.opacity(0.18), radius: 3, x: 0, y: 1)
      .overlay(
        RoundedRectangle(cornerRadius: 6)
          .inset(by: 0.75)
          .stroke(.white, lineWidth: 1.5)
      )
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(alignment: .center, spacing: 14) {
        colorSwatch(category.colorHex)

        VStack(alignment: .leading, spacing: 4) {
          Text(category.name)
            .font(Font.system(size: 12).weight(.bold))
            .foregroundColor(theme.textPrimary)

          if showDetails
            && !category.details.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          {
            Text(category.details)
              .font(Font.system(size: 12).weight(.medium))
              .foregroundColor(
                theme.textSecondary
              )
              .lineLimit(2)
          }
        }

        Spacer()
      }
    }
    .padding(.horizontal, 20)
    .padding(.vertical, 16)
    .frame(maxWidth: .infinity, alignment: .center)
    .background(theme.rightPanelFill)
    .overlay(
      RoundedRectangle(cornerRadius: 8)
        .stroke(
          isTargeted ? theme.accent : theme.rightPanelBorder,
          lineWidth: isTargeted ? 1.5 : 1)
    )
    .cornerRadius(8)

    .contentShape(Rectangle())
    .onDrop(of: [UTType.plainText], isTargeted: $isTargeted) { providers in
      guard let provider = providers.first else { return false }
      provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { item, _ in
        let value: String? = {
          if let data = item as? Data { return String(data: data, encoding: .utf8) }
          if let string = item as? String { return string }
          if let ns = item as? NSString { return ns as String }
          return nil
        }()
        if let hex = value {
          DispatchQueue.main.async {
            onColorDrop(hex)
          }
        }
      }
      return true
    }
  }
}
