//
//  DailyBriefRangeSummaryView.swift
//  Dayflow
//
//  The "editorial letter" summary of everything completed in a range
//  (Figma "Everything you completed · Editorial letter" / "Dusk"). It can be
//  exported as a PNG or copied as plain text for a performance review.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct DailyBriefRangeSummaryView: View {
  @ObservedObject private var store = DailyBriefStore.shared
  @Environment(\.dayflowTheme) private var theme
  let range: DailyBriefSummaryRange

  /// Project images, loaded up front so ImageRenderer (which can't wait for
  /// async loads) draws them in the export too.
  @State private var images: [String: CGImage] = [:]
  @State private var didCopy = false

  private var summary: DailyBriefRangeSummary? { store.summaries[range] }
  private var style: DailyBriefLetterStyle { theme.isDark ? .dusk : .frosted }

  var body: some View {
    ScrollView {
      VStack(spacing: 0) {
        if let summary {
          DailyBriefSummaryLetter(summary: summary, images: images, style: style)
            .overlay(alignment: .topTrailing) {
              toolbar(summary)
                .padding(.top, 34)
                .padding(.trailing, 28)
            }
        } else {
          missingSummary
        }
      }
      .frame(maxWidth: DailyBriefSummaryLetter.width)
      .frame(maxWidth: .infinity)
      .padding(.top, 54)
      .padding(.bottom, 40)
      .padding(.horizontal, 24)
    }
    .task(id: summary?.generatedAt) {
      await loadImages()
    }
  }

  // MARK: Toolbar

  private func toolbar(_ summary: DailyBriefRangeSummary) -> some View {
    HStack(spacing: 8) {
      Button {
        copyText(summary)
      } label: {
        DailyBriefRoutePill(
          title: didCopy ? "Copied" : "Copy text",
          systemImage: didCopy ? "checkmark" : "doc.on.doc",
          isProminent: false,
          onLight: style == .frosted)
      }
      .buttonStyle(.plain)
      .pointingHandCursor()

      Button(action: regenerate) {
        DailyBriefRoutePill(
          title: "Regenerate", systemImage: "arrow.clockwise", isProminent: false,
          onLight: style == .frosted)
      }
      .buttonStyle(.plain)
      .pointingHandCursor()

      Button {
        exportImage(summary)
      } label: {
        DailyBriefRoutePill(title: "Export image")
      }
      .buttonStyle(.plain)
      .pointingHandCursor()

      DailyBriefRouteCloseButton(color: style.secondaryText) {
        store.route = .completedHistory
      }
    }
  }

  private var missingSummary: some View {
    VStack(spacing: 12) {
      Text("No summary for \(range.label.lowercased()) yet")
        .font(.custom("InstrumentSerif-Regular", size: 26))
        .foregroundStyle(.white)
      Button(action: regenerate) {
        DailyBriefRoutePill(title: "Summarize \(range.label.lowercased())")
      }
      .buttonStyle(.plain)
      .pointingHandCursor()
    }
    .padding(.top, 120)
  }

  // MARK: Actions

  private func regenerate() {
    store.summarize(range)
    // The completed page shows the "Summarizing…" animation and comes back here when done.
    store.route = .completedHistory
  }

  private func copyText(_ summary: DailyBriefRangeSummary) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(Self.plainText(summary), forType: .string)
    AnalyticsService.shared.capture("daily_brief_summary_copied", ["range": range.rawValue])
    didCopy = true
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
      didCopy = false
    }
  }

  private func exportImage(_ summary: DailyBriefRangeSummary) {
    let letter = DailyBriefSummaryLetter(summary: summary, images: images, style: style)
      .frame(width: DailyBriefSummaryLetter.width)
    let renderer = ImageRenderer(content: letter)
    renderer.scale = 2
    guard let cgImage = renderer.cgImage,
      let pngData = NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:])
    else {
      print("[DailyBrief] Failed to render the summary image")
      return
    }

    let panel = NSSavePanel()
    panel.allowedContentTypes = [.png]
    panel.nameFieldStringValue = "Target Flow – \(range.label).png"
    panel.canCreateDirectories = true
    guard panel.runModal() == .OK, let url = panel.url else { return }

    do {
      try pngData.write(to: url, options: .atomic)
      AnalyticsService.shared.capture("daily_brief_summary_exported", ["range": range.rawValue])
    } catch {
      print("[DailyBrief] Failed to save the summary image: \(error)")
    }
  }

  private func loadImages() async {
    guard let summary else { return }
    let files = summary.projects.compactMap(\.imageFile)
    let loaded = await Task.detached(priority: .userInitiated) {
      var result: [String: CGImage] = [:]
      for file in files {
        let url = DailyBriefStore.rootDirectory().appendingPathComponent(file)
        if let image = DailyBriefFileImage.loadThumbnail(url) {
          result[file] = image
        }
      }
      return result
    }.value
    images = loaded
  }

  /// The summary as plain text, for pasting into a review doc.
  static func plainText(_ summary: DailyBriefRangeSummary) -> String {
    var lines: [String] = []
    lines.append("\(summary.range.label) (\(DailyBriefSummaryLetter.dateSpan(summary)))")
    lines.append("")
    lines.append(summary.overview)

    if !summary.milestones.isEmpty {
      lines.append("")
      lines.append("Milestones")
      lines.append(contentsOf: summary.milestones.map { "- \($0)" })
    }

    for project in summary.projects {
      lines.append("")
      lines.append(project.title)
      lines.append(contentsOf: project.bullets.map { "- \($0)" })
      if let impact = project.impact, !impact.isEmpty {
        lines.append("Impact: \(impact)")
      }
    }
    return lines.joined(separator: "\n")
  }
}

// MARK: - Letter style

/// Light ("Frosted") and dark ("Dusk") looks for the letter card.
enum DailyBriefLetterStyle: Equatable {
  case frosted
  case dusk

  var background: LinearGradient {
    switch self {
    case .frosted:
      return LinearGradient(
        colors: [Color(hex: "EEF2F7"), Color(hex: "FBEFEC")], startPoint: .top, endPoint: .bottom)
    case .dusk:
      return LinearGradient(
        colors: [Color(hex: "2C2C42"), Color(hex: "35303F")], startPoint: .top, endPoint: .bottom)
    }
  }

  var primaryText: Color { self == .dusk ? Color.white.opacity(0.92) : Color(hex: "2B2B2B") }
  var secondaryText: Color { self == .dusk ? Color.white.opacity(0.65) : Color(hex: "6B6B6B") }
  var label: Color { self == .dusk ? Color(hex: "F2A57E") : Color(hex: "C2531E") }
  var boxFill: Color { self == .dusk ? Color.white.opacity(0.08) : Color.white.opacity(0.75) }
  var boxBorder: Color { self == .dusk ? Color.white.opacity(0.06) : Color.white }
  var divider: Color { self == .dusk ? Color.white.opacity(0.12) : Color.black.opacity(0.08) }
}

// MARK: - Letter

/// The summary itself, without buttons. Used on screen and for "Export image".
struct DailyBriefSummaryLetter: View {
  static let width: CGFloat = 790

  let summary: DailyBriefRangeSummary
  let images: [String: CGImage]
  let style: DailyBriefLetterStyle

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Text(Self.dateSpan(summary).uppercased())
        .font(.custom("Figtree", size: 12).weight(.medium))
        .tracking(1.2)
        .foregroundStyle(style.secondaryText)
        .padding(.bottom, 40)

      Text(summary.range.label)
        .font(.custom("InstrumentSerif-Regular", size: 28))
        .foregroundStyle(style.primaryText)
        .padding(.bottom, 8)

      Text(summary.overview)
        .font(.custom("Figtree", size: 14))
        .lineSpacing(3)
        .foregroundStyle(style.primaryText)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.bottom, 18)

      if !summary.milestones.isEmpty {
        milestones
          .padding(.bottom, 28)
      }

      if !summary.projects.isEmpty {
        Rectangle()
          .fill(style.divider)
          .frame(height: 1)
          .padding(.bottom, 30)

        VStack(alignment: .leading, spacing: 40) {
          ForEach(Array(summary.projects.enumerated()), id: \.offset) { _, project in
            projectBlock(project)
          }
        }
      }
    }
    .padding(.horizontal, 64)
    .padding(.top, 44)
    .padding(.bottom, 52)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(style.background)
    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .strokeBorder(style.boxBorder.opacity(0.6), lineWidth: 1)
    )
    .shadow(color: .black.opacity(0.25), radius: 30, x: 0, y: 12)
  }

  /// "Sep 28 – Oct 20"
  static func dateSpan(_ summary: DailyBriefRangeSummary) -> String {
    let start = DailyBriefDates.shortText(summary.startDay) ?? summary.startDay
    let end = DailyBriefDates.shortText(summary.endDay) ?? summary.endDay
    return "\(start) – \(end)"
  }

  private var milestones: some View {
    VStack(alignment: .leading, spacing: 6) {
      sectionLabel("Milestones")
      ForEach(summary.milestones, id: \.self) { milestone in
        Text(milestone)
          .font(.custom("Figtree", size: 14))
          .foregroundStyle(style.primaryText)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(RoundedRectangle(cornerRadius: 6).fill(style.boxFill))
  }

  private func projectBlock(_ project: DailyBriefSummaryProject) -> some View {
    HStack(alignment: .top, spacing: 28) {
      projectImage(project)
        .frame(width: 136, height: 96)

      VStack(alignment: .leading, spacing: 10) {
        Text(project.title)
          .font(.custom("InstrumentSerif-Regular", size: 23))
          .foregroundStyle(style.primaryText)
          .fixedSize(horizontal: false, vertical: true)

        VStack(alignment: .leading, spacing: 5) {
          ForEach(project.bullets, id: \.self) { bullet in
            HStack(alignment: .firstTextBaseline, spacing: 10) {
              Text("–")
                .foregroundStyle(style.secondaryText)
              Text(bullet)
                .foregroundStyle(style.primaryText)
                .fixedSize(horizontal: false, vertical: true)
            }
            .font(.custom("Figtree", size: 14))
          }
        }

        if let impact = project.impact, !impact.isEmpty {
          VStack(alignment: .leading, spacing: 8) {
            sectionLabel("Impact")
            Text(impact)
              .font(.custom("Figtree", size: 14))
              .foregroundStyle(style.primaryText)
              .fixedSize(horizontal: false, vertical: true)
          }
          .padding(.horizontal, 12)
          .padding(.vertical, 12)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(RoundedRectangle(cornerRadius: 10).fill(style.boxFill))
          .padding(.top, 6)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  @ViewBuilder
  private func projectImage(_ project: DailyBriefSummaryProject) -> some View {
    let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
    if let file = project.imageFile, let image = images[file] {
      Image(decorative: image, scale: 1)
        .resizable()
        .aspectRatio(contentMode: .fill)
        .frame(width: 136, height: 96)
        .clipShape(shape)
    } else {
      // No image: a soft tint keeps the column aligned across projects.
      shape.fill(DailyBriefPalette.documentTint(for: project.title).linear)
    }
  }

  private func sectionLabel(_ title: String) -> some View {
    Text(title.uppercased())
      .font(.custom("Figtree", size: 11).weight(.semibold))
      .tracking(1.1)
      .foregroundStyle(style.label)
  }
}
