//
//  ScreenRecordingPermissionView.swift
//  Dayflow
//
//  Screen recording permission request using idiomatic ScreenCaptureKit approach
//

import AppKit
import Combine
import CoreGraphics
import SwiftUI

private struct LeftColumnSizeKey: PreferenceKey {
  static var defaultValue: CGSize = .zero
  static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
    value = nextValue()
  }
}

struct ScreenRecordingPermissionView: View {
  var onBack: () -> Void
  var onNext: () -> Void

  @State private var permissionState: PermissionState = .notRequested
  @State private var isCheckingPermission = false
  @State private var initiatedFlow = false
  @State private var leftColumnSize: CGSize = .zero
  @State private var restartError: String?
  private let permissionPoll = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

  enum PermissionState {
    case notRequested
    case granted
    case needsAction  // requested or settings opened, awaiting quit & reopen / toggle
  }

  private let brownAccent = Color(hex: "492304")
  private let privacyTextColor = Color(hex: "89380E")

  var body: some View {
    GeometryReader { geo in
      ZStack(alignment: .bottomTrailing) {
        content(size: geo.size)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .onPreferenceChange(LeftColumnSizeKey.self) { leftColumnSize = $0 }
    }
    .onAppear(perform: refreshPermission)
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification))
    { _ in refreshPermission() }
    .onReceive(permissionPoll) { _ in
      if NSApp.isActive { refreshPermission() }
    }
    .onDisappear {
      AppDelegate.allowTermination = false
    }
    .alert("无法重新打开 Target Flow", isPresented: Binding(
      get: { restartError != nil },
      set: { if !$0 { restartError = nil } }
    )) {
      Button("好", role: .cancel) { restartError = nil }
    } message: {
      Text(restartError ?? "请退出应用后，从访达重新打开。")
    }
  }

  // Margins and column gap scale with window size (12 : 7 : 11 ratio from the design mock);
  // the image never grows taller than the left column, extra space flows into the gaps
  private func layoutMetrics(size: CGSize) -> (
    leading: CGFloat, gap: CGFloat, trailing: CGFloat, imageWidth: CGFloat, imageHeight: CGFloat
  ) {
    let aspect: CGFloat = 4.0 / 3.0
    let leftW = leftColumnSize.width > 0 ? leftColumnSize.width : min(374, size.width * 0.4)
    var imgW = max(0, size.width * 0.70 - leftW)
    var imgH = imgW / aspect
    // Match the left column's height (fallback ≈ its natural height before measurement lands)
    let columnHeight = leftColumnSize.height > 0 ? leftColumnSize.height : 300
    let heightCap = min(max(0, size.height - 70), columnHeight)
    if imgH > heightCap {
      imgH = heightCap
      imgW = imgH * aspect
    }
    let free = max(0, size.width - leftW - imgW)
    return (free * 12 / 30, free * 7 / 30, free * 11 / 30, imgW, imgH)
  }

  @ViewBuilder
  private func content(size: CGSize) -> some View {
    let metrics = layoutMetrics(size: size)
    HStack(alignment: .center, spacing: metrics.gap) {
      // Left side — text and controls
      VStack(alignment: .leading, spacing: 10) {
        Text("Last step!")
          .font(.custom("Figtree-Bold", size: 16))
          .foregroundColor(Color(hex: "F96E00"))

        Text("Permission")
          .font(.custom("InstrumentSerif-Regular", size: 28))
          .foregroundColor(.black)

        Text("Target Flow 需要屏幕录制权限来生成时间线。")
          .font(.custom("Figtree-Medium", size: 14))
          .foregroundColor(Color(hex: "5B5B5B"))
          .fixedSize(horizontal: false, vertical: true)

        // Privacy info box
        VStack(alignment: .leading, spacing: 10) {
          HStack(alignment: .top, spacing: 8) {
            Image(systemName: "shield.fill")
              .font(.system(size: 14))
              .foregroundColor(privacyTextColor)
            Text("Target Flow 将录制内容保存在本机。")
              .font(.custom("Figtree-Bold", size: 14))
              .foregroundColor(privacyTextColor)
              .fixedSize(horizontal: false, vertical: true)
          }

          Text(
            "使用本地 AI 时，分析可在设备上进行；选择云端提供商时，分析所需的数据会发送到该提供商。"
          )
          .font(.custom("Figtree-Medium", size: 14))
          .foregroundColor(privacyTextColor)

          Text("你可以随时暂停或关闭 Target Flow。")
            .font(.custom("Figtree-Medium", size: 14))
            .foregroundColor(privacyTextColor)
        }
        .padding(16)
        .frame(maxWidth: 351, alignment: .leading)
        .background(Color.white.opacity(0.3))
        .cornerRadius(5)
        .overlay(
          RoundedRectangle(cornerRadius: 5)
            .stroke(Color(red: 0.8, green: 0.278, blue: 0).opacity(0.15), lineWidth: 1)
        )
        .shadow(
          color: Color(red: 0.725, green: 0.608, blue: 0.482).opacity(0.3), radius: 4, x: 0, y: 0)

        // State-based messaging
        Group {
          switch permissionState {
          case .notRequested:
            EmptyView()
          case .granted:
            Text("✓ Permission granted! Click Next to continue.")
              .font(.custom("Figtree", size: 14))
              .foregroundColor(.green)
          case .needsAction:
            Text("尚未检测到录屏权限。请在系统设置中开启；如果开关已开启，点击‘退出并重新打开’让授权生效。")
              .font(.custom("Figtree", size: 14))
              .foregroundColor(.orange)
          }
        }

        // Action buttons
        Group {
          switch permissionState {
          case .notRequested:
            Button(action: requestPermission) {
              HStack(spacing: 6) {
                if isCheckingPermission {
                  ProgressView()
                    .scaleEffect(0.7)
                    .progressViewStyle(CircularProgressViewStyle())
                }
                Text(
                  isCheckingPermission
                    ? String(localized: "Checking...") : String(localized: "Open System Settings")
                )
                .font(.custom("Figtree-SemiBold", size: 12))
                .tracking(-0.48)
                .foregroundColor(brownAccent)
              }
              .padding(.horizontal, 12)
              .frame(height: 36)
            }
            .buttonStyle(.plain)
            .background(Capsule().fill(Color(hex: "FFC9A8")))
            .disabled(isCheckingPermission)
          case .needsAction:
            HStack {
              HStack(spacing: 12) {
                Button(action: openSystemSettings) {
                  Text("Open System Settings")
                    .font(.custom("Figtree-SemiBold", size: 12))
                    .tracking(-0.48)
                    .foregroundColor(brownAccent)
                    .padding(.horizontal, 12)
                    .frame(height: 36)
                }
                .buttonStyle(.plain)
                .background(Capsule().fill(Color(hex: "FFC9A8")))

                Button(action: quitAndReopen) {
                  Text("Quit and Reopen")
                    .font(.custom("Figtree-SemiBold", size: 12))
                    .tracking(-0.48)
                    .foregroundColor(brownAccent)
                    .padding(.horizontal, 12)
                    .frame(height: 36)
                }
                .buttonStyle(.plain)
                .background(Capsule().fill(Color.white.opacity(0.69)))
                .overlay(
                  Capsule()
                    .stroke(Color(hex: "D9D9D9"), lineWidth: 1)
                )
              }
            }
          case .granted:
            EmptyView()
          }
        }
      }
      .frame(maxWidth: 374)
      .background(
        GeometryReader { proxy in
          Color.clear.preference(key: LeftColumnSizeKey.self, value: proxy.size)
        }
      )

      VStack(alignment: .leading, spacing: 18) {
        Label("屏幕与系统音频录制", systemImage: "display")
          .font(.title3.bold())
        Text("系统设置 → 隐私与安全性 → 屏幕与系统音频录制")
        Text("在列表中找到 Target Flow（或 TargetFlow），开启右侧开关。这里不需要辅助功能权限。")
        Text("如果没有找到，点击列表下方的 +，选择当前应用：")
        Text(Bundle.main.bundleURL.path)
          .font(.system(size: 12, design: .monospaced))
          .textSelection(.enabled)
        Button("在访达中显示 Target Flow") {
          NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
        }
        Text("授权后返回此窗口；若系统要求重新启动，请退出后重新打开应用。")
      }
      .foregroundColor(brownAccent)
      .padding(24)
      .frame(width: max(300, metrics.imageWidth), alignment: .leading)
      .background(Color.white.opacity(0.7))
      .cornerRadius(12)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    .padding(.leading, metrics.leading)
    .padding(.trailing, metrics.trailing)
    .padding(.top, 30)
    .padding(.bottom, 40)

    // Navigation buttons — bottom right
    HStack(spacing: 15) {
      DayflowSurfaceButton(
        action: onBack,
        content: { Text("Back").font(.custom("Figtree-Medium", size: 14)).tracking(-0.48) },
        background: .white,
        foreground: Color(hex: "B6B6B6"),
        borderColor: Color(hex: "B6B6B6"),
        cornerRadius: 200,
        horizontalPadding: 32,
        verticalPadding: 0,
        fixedHeight: 44,
        showShadow: false
      )
      DayflowSurfaceButton(
        action: {
          refreshPermission()
          if permissionState == .granted { onNext() }
        },
        content: {
          HStack(spacing: 6) {
            Text("Next").font(.custom("Figtree-Medium", size: 14)).tracking(-0.48)
            Image(systemName: "chevron.right").font(.system(size: 12, weight: .medium))
          }
          .padding(.leading, 4)
        },
        background: permissionState == .granted
          ? Color(hex: "FF9F6F")
          : Color(hex: "FF9F6F").opacity(0.3),
        foreground: .white,
        borderColor: Color(hex: "F4C8B1"),
        cornerRadius: 200,
        horizontalPadding: 32,
        verticalPadding: 0,
        fixedHeight: 44,
        showOverlayStroke: false,
        innerGlowColor: Color(hex: "FFDCCB").opacity(0.9)
      )
      .disabled(permissionState != .granted)
    }
    .padding(.trailing, 60)
    .padding(.bottom, 40)
  }

  private func refreshPermission() {
    let granted = ScreenRecordingPermissionNotice.isGranted
    // Revocation must also disable Next, including after a previously successful check.
    permissionState = granted ? .granted : (initiatedFlow ? .needsAction : .notRequested)
    AppDelegate.allowTermination = !granted
  }

  private func requestPermission() {
    guard !isCheckingPermission else { return }
    isCheckingPermission = true
    defer { isCheckingPermission = false }
    initiatedFlow = true
    _ = CGRequestScreenCaptureAccess()
    refreshPermission()
    if permissionState != .granted { openSystemSettings() }
  }

  private func openSystemSettings() {
    initiatedFlow = true
    refreshPermission()
    ScreenRecordingPermissionNotice.openSystemSettings()
  }

  private func quitAndReopen() {
    do {
      try AppRelauncher.schedule()
      AppDelegate.permitTermination(reason: "screen_permission_quit_and_reopen")
      NSApp.terminate(nil)
    } catch {
      restartError = "无法启动重启助手：\(error.localizedDescription)。请退出应用后，从访达重新打开。"
    }
  }
}
