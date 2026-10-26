//
//  DistractionSummaryCard.swift
//  Dayflow
//
//  Summary block showing captured vs distracted time and a distraction pattern note
//

import SwiftUI

struct DistractionSummaryCard: View {
  @Environment(\.dayflowTheme) private var theme

  let totalCaptured: String
  let totalDistracted: String
  let distractedRatio: Double
  let patternTitle: String
  let patternDescription: String

  init(
    totalCaptured: String,
    totalDistracted: String,
    distractedRatio: Double,
    patternTitle: String = String(localized: "Main distraction pattern"),
    patternDescription: String
  ) {
    self.totalCaptured = totalCaptured
    self.totalDistracted = totalDistracted
    self.distractedRatio = distractedRatio
    self.patternTitle = patternTitle
    self.patternDescription = patternDescription
  }

  private enum Design {
    static let sectionSpacing: CGFloat = 16
    static let rowSpacing: CGFloat = 16
    static let statsSpacing: CGFloat = 24

    static let donutSize: CGFloat = 120
    static let donutInnerMaxSize: CGFloat = 120
    static let donutInnerBottomInset: CGFloat = 4.868

    static let labelFont = Font.system(size: 14, weight: .semibold)
    static let valueFont = Font.system(size: 20, weight: .semibold)
    static let patternTitleFont = Font.system(size: 12).weight(.bold)
    static let patternBodyFont = Font.system(size: 12)
  }

  var body: some View {
    let showPattern = !patternDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

    VStack(alignment: .center, spacing: showPattern ? Design.sectionSpacing : 0) {
      HStack(alignment: .center, spacing: Design.rowSpacing) {
        donut
        statsBlock
      }

      if showPattern {
        patternBlock
      }
    }
    .frame(maxWidth: .infinity, alignment: .center)
  }

  private var donut: some View {
    let clampedRatio = min(max(distractedRatio, 0), 1)
    let innerDiameter = Design.donutInnerMaxSize * sqrt(clampedRatio)
    let innerX = (Design.donutSize - innerDiameter) / 2
    let innerY = Design.donutSize - Design.donutInnerBottomInset - innerDiameter

    return ZStack(alignment: .topLeading) {
      Circle()
        .fill(theme.targetsTrackFill)
        .overlay(
          Circle()
            .stroke(theme.targetsTrackBorder, lineWidth: 1)
        )
        .frame(width: Design.donutSize, height: Design.donutSize)

      if innerDiameter > 0.5 {
        Circle()
          .fill(
            LinearGradient(
              stops: [
                .init(color: theme.statusDistracted.opacity(0.25), location: 0),
                .init(color: theme.statusDistracted.opacity(0.75), location: 0.78306),
                .init(color: theme.statusDistracted.opacity(0.75), location: 1),
              ],
              startPoint: .leading,
              endPoint: .trailing
            )
          )
          .frame(width: innerDiameter, height: innerDiameter)
          .rotationEffect(.degrees(90))
          .offset(x: innerX, y: innerY)
      }
    }
    .frame(width: Design.donutSize, height: Design.donutSize)
  }

  private var statsBlock: some View {
    VStack(alignment: .leading, spacing: Design.statsSpacing) {
      statText(
        title: String(localized: "Total time captured"),
        value: totalCaptured,
        color: theme.textMuted
      )

      statText(
        title: String(localized: "Total time distracted"),
        value: totalDistracted,
        color: theme.statusDistracted
      )
    }
    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
  }

  private func statText(title: String, value: String, color: Color) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(title)
        .font(Design.labelFont)
        .foregroundColor(color)
      Text(value)
        .font(Design.valueFont)
        .foregroundColor(color)
    }
    .fixedSize(horizontal: false, vertical: true)
    .lineSpacing(2)
  }

  private var patternBlock: some View {
    VStack(alignment: .leading, spacing: 2) {
      HStack(spacing: 2) {
        Image("DistractionSummaryIcon")
          .resizable()
          .frame(width: 16, height: 16)

        Text(patternTitle)
          .font(Design.patternTitleFont)
          .foregroundColor(theme.textPrimary)
      }

      Text(patternDescription)
        .font(Design.patternBodyFont)
        .foregroundColor(theme.textPrimary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

#Preview("Distraction Summary Card") {
  DistractionSummaryCard(
    totalCaptured: "8 hours 49 minutes",
    totalDistracted: "2 hours 7 minutes",
    distractedRatio: 0.24,
    patternDescription:
      "YouTube recommendations pull attention from one video to the next for extended periods."
  )
  .padding(24)
  .background(Color.white)
}
