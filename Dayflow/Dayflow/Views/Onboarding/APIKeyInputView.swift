//
//  APIKeyInputView.swift
//  Dayflow
//
//  API key input component for Gemini setup
//

import SwiftUI

struct APIKeyInputView: View {
  @Binding var apiKey: String
  let title: String
  let subtitle: String
  let placeholder: String
  let onValidate: (String) -> Bool

  @State private var showPassword = false
  @State private var validationState: ValidationState = .none
  @FocusState private var isFocused: Bool

  enum ValidationState {
    case none
    case valid
    case invalid
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text(title)
        .font(.system(size: 16))
        .fontWeight(.semibold)
        .foregroundColor(SettingsStyle.text)

      Text(subtitle)
        .font(.system(size: 14))
        .foregroundColor(SettingsStyle.secondary)

      // Input field container
      VStack(alignment: .leading, spacing: 8) {
        HStack(spacing: 12) {
          Group {
            if showPassword {
              TextField(placeholder, text: $apiKey)
                .textFieldStyle(.plain)
            } else {
              SecureField(placeholder, text: $apiKey)
                .textFieldStyle(.plain)
            }
          }
          .font(.system(size: 13, design: .monospaced))
          .focused($isFocused)
          .onChange(of: apiKey) { _, newValue in
            let cleaned = cleanedAPIKey(newValue)
            guard cleaned == newValue else {
              apiKey = cleaned
              return
            }
            validateKey(cleaned)
          }

          Button(action: { showPassword.toggle() }) {
            Image(systemName: showPassword ? "eye.slash" : "eye")
              .font(.system(size: 14, weight: .medium))
              .foregroundColor(SettingsStyle.secondary)
          }
          .buttonStyle(.plain)
          .pointingHandCursor()

          // Validation indicator
          if validationState != .none {
            Image(
              systemName: validationState == .valid ? "checkmark.circle.fill" : "xmark.circle.fill"
            )
            .font(.system(size: 16))
            .foregroundColor(
              validationState == .valid
                ? SettingsStyle.statusGood : SettingsStyle.destructive
            )
            .transition(.scale.combined(with: .opacity))
          }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(SettingsStyle.surface)
        .cornerRadius(8)
        .overlay(
          RoundedRectangle(cornerRadius: 8)
            .stroke(borderColor, lineWidth: isFocused ? 2 : 1)
        )

        // Validation message
        if validationState == .invalid {
          Text("API key should be more than 10 characters")
            .font(.system(size: 12))
            .foregroundColor(SettingsStyle.destructive)
            .transition(.opacity)
        }
      }
      .animation(.easeOut(duration: 0.2), value: validationState)

      // Help text
      HStack(spacing: 4) {
        Image(systemName: "lock.shield.fill")
          .font(.system(size: 12))
          .foregroundColor(SettingsStyle.statusGood.opacity(0.7))

        Text(
          "Your API key is encrypted and stored in your macOS Keychain - never uploaded anywhere"
        )
        .font(.system(size: 12))
        .foregroundColor(SettingsStyle.secondary)
      }
    }
  }

  private var borderColor: Color {
    if isFocused {
      switch validationState {
      case .valid:
        return SettingsStyle.statusGood.opacity(0.6)
      case .invalid:
        return SettingsStyle.destructive.opacity(0.6)
      case .none:
        return SettingsStyle.ink.opacity(0.6)
      }
    } else {
      return SettingsStyle.editorBorder
    }
  }

  private func validateKey(_ key: String) {
    guard !key.isEmpty else {
      validationState = .none
      return
    }

    withAnimation(.easeOut(duration: 0.2)) {
      validationState = onValidate(key) ? .valid : .invalid
    }
  }

  private func cleanedAPIKey(_ key: String) -> String {
    key.components(separatedBy: .whitespacesAndNewlines).joined()
  }
}
