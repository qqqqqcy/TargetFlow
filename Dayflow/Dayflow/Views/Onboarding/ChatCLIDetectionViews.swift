import AppKit
import Foundation
import SwiftUI

struct CLIDetectionReport {
  let state: CLIDetectionState
  let resolvedPath: String?
  let stdout: String?
  let stderr: String?
}

struct CLIDetector {
  /// Detect if a CLI tool is installed by running `tool --version` via login shell.
  /// This replicates exactly what happens when user types in Terminal.app.
  static func detect(tool: CLITool) async -> CLIDetectionReport {
    if tool == .codex, let resolution = CodexExecutableResolver.shared.resolve() {
      return CLIDetectionReport(
        state: .installed(version: resolution.versionSummary),
        resolvedPath: resolution.executableURL.path,
        stdout: resolution.versionSummary,
        stderr: nil
      )
    }

    let result = LoginShellRunner.run("\(tool.executableName) --version", timeout: 10)

    if result.exitCode == 0 {
      let trimmed = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
      let firstLine = trimmed.components(separatedBy: .newlines).first ?? trimmed
      let summary = firstLine.isEmpty ? "\(tool.shortName) detected" : firstLine
      return CLIDetectionReport(
        state: .installed(version: summary), resolvedPath: tool.executableName,
        stdout: result.stdout, stderr: result.stderr)
    }

    if result.exitCode == 127 || result.stderr.contains("command not found") {
      return CLIDetectionReport(
        state: .notFound, resolvedPath: nil, stdout: result.stdout, stderr: result.stderr)
    }

    let message = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
    let resolvedPath = tool == .codex ? nil : tool.executableName
    if message.isEmpty {
      return CLIDetectionReport(
        state: .failed(message: String(localized: "Exit code \(result.exitCode)")),
        resolvedPath: resolvedPath,
        stdout: result.stdout, stderr: result.stderr)
    }
    return CLIDetectionReport(
      state: .failed(message: message), resolvedPath: resolvedPath, stdout: result.stdout,
      stderr: result.stderr)
  }

  /// Check if a CLI tool is installed (simple boolean check)
  static func isInstalled(_ tool: CLITool) -> Bool {
    LoginShellRunner.isInstalled(tool.executableName)
  }

  /// Run an arbitrary debug command via login shell
  static func runDebugCommand(_ command: String) -> CLIResult {
    let result = LoginShellRunner.run(command, timeout: 30)
    return CLIResult(
      stdout: result.stdout,
      stderr: result.stderr,
      exitCode: result.exitCode,
      shellCommand: command,
      environmentOverrides: [:]
    )
  }
}

struct ChatCLIDetectionStepView: View {
  let codexStatus: CLIDetectionState
  let codexReport: CLIDetectionReport?
  let claudeStatus: CLIDetectionState
  let claudeReport: CLIDetectionReport?
  let isChecking: Bool
  let onRetry: () -> Void
  let onInstall: (CLITool) -> Void
  let selectedTool: CLITool?
  let onSelectTool: (CLITool) -> Void

  let accentColor = SettingsStyle.primaryButtonFill

  var body: some View {
    VStack(alignment: .leading, spacing: 24) {
      Text(
        "Target Flow can talk to ChatGPT (via the Codex CLI) or Claude Code. You only need one installed and signed in on this Mac. After installing, run `codex auth` or `claude login` in Terminal to connect it to your account."
      )
      .font(.system(size: 16))
      .foregroundColor(SettingsStyle.text)

      HStack(alignment: .top, spacing: 18) {
        ChatCLIToolStatusRow(
          tool: .codex,
          status: codexStatus,
          onInstall: { onInstall(.codex) }
        )
        ChatCLIToolStatusRow(
          tool: .claude,
          status: claudeStatus,
          onInstall: { onInstall(.claude) }
        )
      }

      Text(
        "Tip: Once both are installed, you can choose which provider Target Flow uses from Settings → AI Provider."
      )
      .font(.system(size: 16))
      .foregroundColor(SettingsStyle.text)

      VStack(alignment: .leading, spacing: 8) {
        VStack(alignment: .leading, spacing: 14) {
          Text("Choose which provider Target Flow should use")
            .font(.system(size: 14))
            .fontWeight(.medium)
            .foregroundColor(SettingsStyle.text)
          HStack(spacing: 12) {
            ForEach(CLITool.allCases, id: \.self) { tool in
              selectionButton(for: tool)
            }
          }
        }
        .padding(16)
        .frame(maxWidth: 516)
        .background(SettingsStyle.surface)
        .cornerRadius(12)
        .overlay(
          RoundedRectangle(cornerRadius: 12)
            .stroke(SettingsStyle.divider, lineWidth: 1)
        )

        DayflowSurfaceButton(
          action: {
            if !isChecking {
              onRetry()
            }
          },
          content: {
            HStack(spacing: 4) {
              if isChecking {
                ProgressView().scaleEffect(0.6).frame(width: 16, height: 16)
              } else {
                Image(systemName: "arrow.clockwise")
                  .font(.system(size: 13, weight: .semibold))
                  .frame(width: 16, height: 16)
              }
              Text(isChecking ? String(localized: "Checking…") : String(localized: "Check"))
                .font(.system(size: 14))
                .fontWeight(.medium)
            }
          },
          background: SettingsStyle.primaryButtonFill,
          foreground: Color.white,
          borderColor: SettingsStyle.primaryButtonFill,
          cornerRadius: 9,
          horizontalPadding: 24,
          verticalPadding: 8,
          fixedHeight: 41,
          showOverlayStroke: false,
          innerGlowColor: Color.clear
        )
        .disabled(isChecking)
      }
    }
  }

  func isToolAvailable(_ tool: CLITool) -> Bool {
    switch tool {
    case .codex:
      if codexStatus.isInstalled { return true }
      return codexReport?.resolvedPath != nil
    case .claude:
      if claudeStatus.isInstalled { return true }
      return claudeReport?.resolvedPath != nil
    }
  }

  @ViewBuilder
  func selectionButton(for tool: CLITool) -> some View {
    let enabled = isToolAvailable(tool)
    Button(action: {
      onSelectTool(tool)
    }) {
      HStack(spacing: 12) {
        Image(systemName: selectedTool == tool ? "largecircle.fill.circle" : "circle")
          .font(.system(size: 22, weight: .regular))
          .frame(width: 24, height: 24)
          .foregroundColor(selectedTool == tool ? accentColor : SettingsStyle.editorBorder)
        VStack(alignment: .leading, spacing: 4) {
          Text(tool.shortName)
            .font(.system(size: 16))
            .fontWeight(.semibold)
            .foregroundColor(SettingsStyle.text)
          Text(enabled ? String(localized: "Ready to use") : String(localized: "Install to enable"))
            .font(.system(size: 12))
            .foregroundColor(SettingsStyle.secondary)
        }
      }
      .padding(.horizontal, 14)
      .padding(.vertical, 12)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        RoundedRectangle(cornerRadius: 12)
          .fill(SettingsStyle.surface)
      )
      .overlay(
        RoundedRectangle(cornerRadius: 12)
          .stroke(SettingsStyle.divider, lineWidth: 1)
      )
    }
    .buttonStyle(.plain)
    .pointingHandCursor()
  }
}

struct ChatCLIToolStatusRow: View {
  let tool: CLITool
  let status: CLIDetectionState
  let onInstall: () -> Void

  let accentColor = SettingsStyle.primaryButtonFill

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      // Icon and title row
      HStack(spacing: 12) {
        Image(tool.logoAssetName)
          .resizable()
          .aspectRatio(contentMode: .fit)
          .frame(width: 32, height: 32)

        Text(tool.shortName)
          .font(.system(size: 16))
          .fontWeight(.semibold)
          .foregroundColor(SettingsStyle.text)

        Spacer(minLength: 8)

        statusView
      }

      // Install button if needed
      if shouldShowInstallButton {
        DayflowSurfaceButton(
          action: onInstall,
          content: {
            HStack(spacing: 6) {
              Image(systemName: "arrow.down.circle.fill").font(.system(size: 11, weight: .semibold))
              Text(installLabel)
                .font(.system(size: 12))
                .fontWeight(.semibold)
            }
          },
          background: SettingsStyle.surface,
          foreground: accentColor,
          borderColor: accentColor.opacity(0.35),
          cornerRadius: 6,
          horizontalPadding: 12,
          verticalPadding: 6,
          showOverlayStroke: true
        )
      }
    }
    .padding(14)
    .background(SettingsStyle.surface)
    .cornerRadius(12)
    .overlay(
      RoundedRectangle(cornerRadius: 12)
        .stroke(SettingsStyle.divider, lineWidth: 1)
    )
  }

  @ViewBuilder
  var statusView: some View {
    switch status {
    case .checking, .unknown:
      HStack(spacing: 5) {
        ProgressView().scaleEffect(0.5)
        Text(status.statusLabel)
          .font(.system(size: 12))
          .fontWeight(.semibold)
          .foregroundColor(SettingsStyle.secondary)
      }
      .padding(.horizontal, 8)
      .padding(.vertical, 4)
      .background(SettingsStyle.secondary.opacity(0.08))
      .cornerRadius(20)
    case .installed:
      Text(status.statusLabel)
        .font(.system(size: 12))
        .fontWeight(.semibold)
        .foregroundColor(SettingsStyle.statusGood)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(SettingsStyle.statusGood.opacity(0.1))
        .cornerRadius(20)
    case .notFound:
      Text(status.statusLabel)
        .font(.system(size: 11))
        .fontWeight(.semibold)
        .foregroundColor(SettingsStyle.destructive)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(SettingsStyle.destructive.opacity(0.1))
        .cornerRadius(999)
    case .failed:
      Text(status.statusLabel)
        .font(.system(size: 11))
        .fontWeight(.semibold)
        .foregroundColor(SettingsStyle.statusWarn)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(SettingsStyle.statusWarn.opacity(0.18))
        .cornerRadius(999)
    }
  }

  var shouldShowInstallButton: Bool {
    switch status {
    case .notFound, .failed:
      return tool.installURL != nil
    default:
      return false
    }
  }

  var installLabel: String {
    switch status {
    case .failed:
      return String(localized: "Setup guide")
    default:
      return String(localized: "Install")
    }
  }
}
