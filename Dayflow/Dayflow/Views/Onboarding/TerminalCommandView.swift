//
//  TerminalCommandView.swift
//  Dayflow
//
//  Terminal command display with copy functionality
//

import AppKit
import SwiftUI

struct TerminalCommandView: View {
  let title: String
  let subtitle: String
  let command: String

  @State private var isCopied = false
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(title)
        .font(.system(size: 16))
        .fontWeight(.semibold)
        .foregroundColor(SettingsStyle.text)

      Text(subtitle)
        .font(.system(size: 14))
        .foregroundColor(SettingsStyle.secondary)

      // Command block with trailing copy button (overlay for tight right alignment)
      ZStack(alignment: .leading) {
        // Command text area
        Text(command)
          .font(.system(size: 13, design: .monospaced))
          .foregroundColor(SettingsStyle.text)
          .textSelection(.enabled)
          .padding(.horizontal, 16)
          .padding(.vertical, 14)
          .padding(.trailing, 120)  // reserve space so text doesn't sit under the button
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .overlay(alignment: .trailing) {
        DayflowSurfaceButton(
          action: copyCommand,
          content: {
            HStack(spacing: 6) {
              Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 12, weight: .medium))
              Text(isCopied ? String(localized: "Copied") : String(localized: "Copy"))
                .font(.system(size: 13))
                .fontWeight(.medium)
            }
            .foregroundColor(
              isCopied ? SettingsStyle.statusGood : SettingsStyle.secondary)
          },
          background: SettingsStyle.surface,
          foreground: SettingsStyle.text,
          borderColor: SettingsStyle.editorBorder,
          cornerRadius: 6,
          horizontalPadding: 14,
          verticalPadding: 10,
          showShadow: false
        )
        .padding(.trailing, 6)
        .padding(.vertical, 6)
      }
      .background(SettingsStyle.canvas)
      .cornerRadius(8)
      .overlay(
        RoundedRectangle(cornerRadius: 8)
          .stroke(SettingsStyle.divider, lineWidth: 1)
      )
    }
  }

  private func copyCommand() {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(command, forType: .string)

    // Track copy (without sending command content)
    AnalyticsService.shared.capture(
      "terminal_command_copied",
      [
        "title": title
      ])

    withAnimation(.easeInOut(duration: 0.2)) {
      isCopied = true
    }

    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
      withAnimation(.easeInOut(duration: 0.2)) {
        isCopied = false
      }
    }
  }
}
