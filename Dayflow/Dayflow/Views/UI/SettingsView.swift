//
//  SettingsView.swift
//  Dayflow
//
//  Settings groups on the shared modern canvas
//

import Foundation
import SwiftUI

struct SettingsView: View {
  private enum SettingsTab: String, CaseIterable, Identifiable {
    case storage
    case privacy
    case providers

    var id: String { rawValue }

    var title: String {
      switch self {
      case .storage: return "记录与提醒"
      case .privacy: return String(localized: "Privacy")
      case .providers: return String(localized: "Providers")
      }
    }

    var symbol: String {
      switch self {
      case .storage: return "record.circle"
      case .privacy: return "lock.shield"
      case .providers: return "server.rack"
      }
    }
  }

  @AppStorage(DayflowAppearance.storageKey) private var appearance: DayflowAppearance = .system
  @State private var selectedTab: SettingsTab = .storage
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  @Namespace private var sidebarSelectionNamespace

  @StateObject private var storageViewModel = StorageSettingsViewModel()
  @StateObject private var privacyViewModel = RecordingPrivacySettingsViewModel()
  @StateObject private var providersViewModel = ProvidersSettingsViewModel()

  var body: some View {
    contentWithSheets
  }

  private var contentWithSheets: some View {
    contentWithLifecycle
      .sheet(
        item: Binding(
          get: {
            providersViewModel.setupModalProvider.map {
              ProviderSetupWrapper(providerID: $0)
            }
          },
          set: { wrapper in
            if let wrapper {
              providersViewModel.setupModalProvider = wrapper.providerID
            } else {
              providersViewModel.cancelProviderSetup()
            }
          }
        )
      ) { wrapper in
        LLMProviderSetupView(
          providerType: wrapper.providerID,
          onBack: { providersViewModel.cancelProviderSetup() },
          onComplete: { configuredProviderID in
            let succeeded = providersViewModel.handleProviderSetupCompletion(configuredProviderID)
            if succeeded {
              providersViewModel.cancelProviderSetup()
            }
            return succeeded
          }
        )
        .frame(minWidth: 900, minHeight: 650)
      }
      .sheet(isPresented: $providersViewModel.isShowingLocalModelUpgradeSheet) {
        LocalModelUpgradeSheet(
          preset: .qwen3VL4B,
          initialEngine: providersViewModel.localEngine,
          initialBaseURL: providersViewModel.localBaseURL,
          initialModelId: providersViewModel.localModelId,
          initialAPIKey: providersViewModel.localAPIKey,
          onCancel: { providersViewModel.isShowingLocalModelUpgradeSheet = false },
          onUpgradeSuccess: { engine, baseURL, modelId, apiKey in
            providersViewModel.handleUpgradeSuccess(
              engine: engine, baseURL: baseURL, modelId: modelId, apiKey: apiKey)
            providersViewModel.isShowingLocalModelUpgradeSheet = false
          }
        )
        .frame(minWidth: 720, minHeight: 560)
      }
  }

  private var contentWithLifecycle: some View {
    GeometryReader { proxy in
      mainContent
        .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
    }
    .onAppear {
      providersViewModel.handleOnAppear()
      storageViewModel.refreshStorageIfNeeded(isStorageTab: selectedTab == .storage)
    }
    .onChange(of: selectedTab) { _, newValue in
      if newValue == .storage {
        storageViewModel.refreshStorageIfNeeded(isStorageTab: true)
      } else if newValue == .privacy {
        privacyViewModel.handleOnAppear()
      }
    }
    .onReceive(NotificationCenter.default.publisher(for: .openProvidersSettings)) { _ in
      guard selectedTab != .providers else { return }
      withAnimation(reduceMotion ? .easeOut(duration: 0.12) : DayflowMotion.selection) {
        selectedTab = .providers
      }
    }
  }

  private var mainContent: some View {
    VStack(alignment: .leading, spacing: DayflowLayout.sectionSpacing) {
      pageHeader
      navigationTabs
      settingsContent
    }
    .padding(.horizontal, DayflowLayout.pageHorizontalInset)
    .padding(.top, DayflowLayout.pageTopInset)
    .padding(.bottom, DayflowLayout.pageBottomInset)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .tint(SettingsStyle.primaryButtonFill)
  }

  private var pageHeader: some View {
    HStack(alignment: .center, spacing: 16) {
      VStack(alignment: .leading, spacing: 6) {
        Text("Settings")
          .font(.system(size: 25, weight: .bold))
          .foregroundStyle(SettingsStyle.text)
        Text("按你的节奏记录，掌控数据与提醒。")
          .font(.system(size: 12))
          .foregroundStyle(SettingsStyle.secondary)
      }

      Spacer(minLength: 16)

      Menu {
        Picker("Light/Dark mode", selection: $appearance) {
          ForEach(DayflowAppearance.allCases) { option in
            Text(option.title).tag(option)
          }
        }
      } label: {
        Label(appearance.title, systemImage: "circle.lefthalf.filled")
          .font(.system(size: 12, weight: .medium))
          .foregroundStyle(SettingsStyle.secondary)
          .padding(.horizontal, 12)
          .padding(.vertical, 8)
          .background(SettingsStyle.surface, in: RoundedRectangle(cornerRadius: 8))
          .overlay {
            RoundedRectangle(cornerRadius: 8)
              .strokeBorder(SettingsStyle.divider, lineWidth: 1)
          }
      }
      .menuStyle(.borderlessButton)
      .menuIndicator(.hidden)
      .fixedSize()
      .accessibilityLabel("Light/Dark mode")
      .help("跟随系统，或选择浅色与深色外观")
    }
  }

  private var navigationTabs: some View {
    HStack(spacing: 6) {
      ForEach(SettingsTab.allCases) { tab in
        Button {
          withAnimation(reduceMotion ? .easeOut(duration: 0.12) : DayflowMotion.selection) {
            selectedTab = tab
          }
        } label: {
          Label(tab.title, systemImage: tab.symbol)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(selectedTab == tab ? SettingsStyle.ink : SettingsStyle.secondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .background {
              if selectedTab == tab {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                  .fill(SettingsStyle.surface)
                  .overlay {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                      .strokeBorder(SettingsStyle.divider, lineWidth: 1)
                  }
                  .matchedGeometryEffect(id: "sidebarSelection", in: sidebarSelectionNamespace)
              }
            }
        }
        .buttonStyle(SettingsSidebarButtonStyle())
        .pointingHandCursor()
        .accessibilityAddTraits(selectedTab == tab ? [.isSelected] : [])
      }
      Spacer(minLength: 0)
    }
    .padding(4)
    .background(SettingsStyle.subtleFill, in: RoundedRectangle(cornerRadius: 12))
  }

  private var settingsContent: some View {
    ZStack(alignment: .topLeading) {
      Group {
        if selectedTab == .privacy {
          tabContent
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
          ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: SettingsStyle.sectionSpacing) {
              tabContent
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 8)
          }
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
      }
      .id(selectedTab)
      .transition(DayflowMotion.transition(reduceMotion: reduceMotion))
    }
    .clipped()
    .animation(reduceMotion ? .easeOut(duration: 0.12) : DayflowMotion.content, value: selectedTab)
  }

  @ViewBuilder
  private var tabContent: some View {
    Group {
      switch selectedTab {
      case .storage:
        SettingsStorageTabView(viewModel: storageViewModel)
        TargetNotificationSettingsView()
      case .privacy:
        SettingsRecordingPrivacyTabView(viewModel: privacyViewModel)
      case .providers:
        SettingsProvidersTabView(viewModel: providersViewModel)
      }
    }
  }
}

private struct ProviderSetupWrapper: Identifiable {
  let providerID: LLMProviderID

  var id: String { providerID.rawValue }
}

struct SettingsView_Previews: PreviewProvider {
  static var previews: some View {
    SettingsView()
      .frame(width: 1400, height: 860)
  }
}

private struct SettingsSidebarButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
      .dayflowPressScale(
        configuration.isPressed,
        pressedScale: 0.98,
        animation: .spring(response: 0.25, dampingFraction: 0.7)
      )
  }
}
