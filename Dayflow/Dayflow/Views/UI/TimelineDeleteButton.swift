import SwiftUI

private enum TimelineDeleteButtonState: Equatable {
  case idle
  case confirming
  case deleting
}

struct TimelineDeleteButton: View {
  var activityID: String?
  var onDelete: (() -> Void)?
  var isEnabled = true
  @Environment(\.dayflowTheme) private var theme
  @State private var deleteButtonState: TimelineDeleteButtonState = .idle
  @State private var deleteResetTask: Task<Void, Never>?
  private var usesDarkChrome: Bool { theme.isDark }
  private var canDelete: Bool { isEnabled && onDelete != nil && deleteButtonState != .deleting }

  var body: some View {
    HStack {
      Spacer()
      deleteButton
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 3)
    .onChange(of: activityID) {
      deleteResetTask?.cancel()
      deleteButtonState = .idle
    }
    .onDisappear { deleteResetTask?.cancel() }
  }

  private var deleteButton: some View {
    let transition = AnyTransition.opacity.combined(with: .scale(scale: 0.5))
    let idleText = usesDarkChrome ? theme.accentText : Color(hex: "C05C54")
    let idleIconTextOpacity = 0.9
    let confirmBackground = Color(hex: "DF6055")
    let confirmStroke = Color(hex: "CB4E43")
    let isConfirmVisualState = deleteButtonState != .idle

    return Button(action: handleDeleteTap) {
      ZStack {
        if deleteButtonState == .deleting {
          ProgressView()
            .scaleEffect(0.55)
            .progressViewStyle(CircularProgressViewStyle(tint: .white))
            .transition(transition)
        } else if deleteButtonState == .confirming {
          Text("Confirm")
            .font(Font.custom("Figtree", size: 12).weight(.medium))
            .transition(transition)
        } else {
          Text("Delete")
            .font(Font.custom("Figtree", size: 12).weight(.medium))
            .transition(transition)
        }
      }
      .padding(.horizontal, isConfirmVisualState ? 9 : 0)
      .frame(height: 18)
      .foregroundColor(
        isConfirmVisualState
          ? .white
          : idleText.opacity(idleIconTextOpacity)
      )
      .background(
        RoundedRectangle(cornerRadius: 5, style: .continuous)
          .fill(isConfirmVisualState ? confirmBackground : Color.clear)
      )
      .overlay(
        RoundedRectangle(cornerRadius: 5, style: .continuous)
          .inset(by: 0.38)
          .stroke(
            isConfirmVisualState ? confirmStroke : .clear,
            lineWidth: 0.75
          )
      )
      // Keep the visual compact while expanding the click target.
      .contentShape(Rectangle().inset(by: -6))
    }
    .frame(height: 22, alignment: .center)
    .buttonStyle(.plain)
    .disabled(!canDelete)
    .hoverScaleEffect(enabled: canDelete, scale: 1.02)
    .pointingHandCursor(enabled: canDelete)
    .animation(.easeInOut(duration: 0.22), value: deleteButtonState)
    .accessibilityLabel(
      Text(
        deleteButtonState == .confirming
          ? String(localized: "Confirm delete activity card")
          : String(localized: "Delete activity card")
      )
    )
  }

  private func handleDeleteTap() {
    guard onDelete != nil, isEnabled else { return }

    deleteResetTask?.cancel()

    switch deleteButtonState {
    case .idle:
      withAnimation(.easeInOut(duration: 0.22)) {
        deleteButtonState = .confirming
      }
      deleteResetTask = Task {
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        guard !Task.isCancelled else { return }
        await MainActor.run {
          guard deleteButtonState == .confirming else { return }
          withAnimation(.easeInOut(duration: 0.22)) {
            deleteButtonState = .idle
          }
        }
      }
    case .confirming:
      withAnimation(.easeInOut(duration: 0.22)) {
        deleteButtonState = .deleting
      }
      onDelete?()
      deleteResetTask = Task {
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        guard !Task.isCancelled else { return }
        await MainActor.run {
          guard deleteButtonState == .deleting else { return }
          withAnimation(.easeInOut(duration: 0.22)) {
            deleteButtonState = .idle
          }
        }
      }
    case .deleting:
      break
    }
  }

}
