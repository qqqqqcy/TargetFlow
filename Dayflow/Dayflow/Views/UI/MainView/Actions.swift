import AppKit
import Foundation
import SwiftUI

extension MainView {
  func handleCategoryChange(to category: TimelineCategory, for activity: TimelineActivity) {
    let newName = category.name.trimmingCharacters(in: .whitespacesAndNewlines)

    // Optimistically update the selected activity so the UI reflects the change immediately.
    selectedActivity = activity.withCategory(newName)

    // Ask the timeline list to refresh so other cards stay in sync.
    refreshActivitiesTrigger &+= 1

    guard let recordId = activity.recordId else { return }

    // Persist the change off the main actor to avoid blocking UI interactions.
    Task.detached(priority: .userInitiated) {
      StorageManager.shared.updateTimelineCardCategory(cardId: recordId, category: newName)
    }
  }

  func handleTitleChange(to newTitle: String, for activity: TimelineActivity) {
    let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }

    // Optimistically update the selected activity so the UI reflects the change immediately.
    selectedActivity = activity.withTitle(trimmed)

    // Ask the timeline list to refresh so other cards stay in sync.
    refreshActivitiesTrigger &+= 1

    guard let recordId = activity.recordId else { return }

    // Persist the change off the main actor to avoid blocking UI interactions.
    Task.detached(priority: .userInitiated) {
      StorageManager.shared.updateTimelineCardTitle(cardId: recordId, title: trimmed)
    }
  }

  func loadWeeklyTrackedMinutes(trigger: String = "unspecified") {
    let requestedWeekRange = timelineWeekRange
    let requestedWeekStartDay = dayString(requestedWeekRange.weekStart)
    timelinePerfLog(
      "weeklyTrackedMinutes.schedule trigger=\(trigger) week=\(requestedWeekStartDay)"
    )

    Task.detached(priority: .userInitiated) {
      let fetchStart = CFAbsoluteTimeGetCurrent()
      let minutes = StorageManager.shared.fetchTotalMinutesTracked(
        from: requestedWeekRange.weekStart,
        to: requestedWeekRange.weekEnd
      )
      let fetchMs = Int((CFAbsoluteTimeGetCurrent() - fetchStart) * 1000)

      await MainActor.run {
        let currentWeekRange = timelineWeekRange
        guard currentWeekRange == requestedWeekRange else {
          let currentWeekStartDay = dayString(currentWeekRange.weekStart)
          timelinePerfLog(
            "weeklyTrackedMinutes.discardStale trigger=\(trigger) requestedWeek=\(requestedWeekStartDay) currentWeek=\(currentWeekStartDay) fetch_ms=\(fetchMs)"
          )
          return
        }

        let commitStart = CFAbsoluteTimeGetCurrent()
        weeklyTrackedMinutes = minutes
        let commitMs = Int((CFAbsoluteTimeGetCurrent() - commitStart) * 1000)
        timelinePerfLog(
          "weeklyTrackedMinutes.complete trigger=\(trigger) week=\(requestedWeekStartDay) minutes=\(Int(minutes.rounded())) fetch_ms=\(fetchMs) commit_ms=\(commitMs)"
        )
      }
    }
  }

  func copyTimelineToClipboard() {
    guard copyTimelineState != .copying else { return }

    copyTimelineTask?.cancel()

    withAnimation(.snappy(duration: 0.3)) {
      copyTimelineState = .copying
    }

    copyTimelineTask = Task {
      defer {
        Task { @MainActor in
          if copyTimelineState == .copying {
            withAnimation(.snappy(duration: 0.3)) {
              copyTimelineState = .idle
            }
          }
          copyTimelineTask = nil
        }
      }

      let clipboardText: String

      switch timelineMode {
      case .day:
        let timelineDate = timelineDisplayDate(from: selectedDate, now: Date())
        let day = dayString(timelineDate)
        let cards = StorageManager.shared.fetchTimelineCards(forDay: day)
        clipboardText = TimelineClipboardFormatter.makeClipboardText(
          for: timelineDate,
          cards: cards
        )

      case .week:
        let weekRange = timelineWeekRange
        let cards = StorageManager.shared.fetchTimelineCardsByTimeRange(
          from: weekRange.weekStart,
          to: weekRange.weekEnd
        )
        clipboardText = TimelineClipboardFormatter.makeClipboardText(
          for: weekRange,
          cards: cards
        )
      }

      guard !Task.isCancelled else { return }

      await MainActor.run {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(clipboardText, forType: .string)

        withAnimation(.snappy(duration: 0.3)) {
          copyTimelineState = .copied
        }
      }

      try? await Task.sleep(nanoseconds: 2_000_000_000)
      guard !Task.isCancelled else { return }

      await MainActor.run {
        withAnimation(.snappy(duration: 0.3)) {
          copyTimelineState = .idle
        }
      }
    }
  }

  func handleTimelineDelete() {
    guard let activity = selectedActivity,
      let recordId = activity.recordId
    else { return }

    deleteTimelineTask?.cancel()
    let selectedActivityId = activity.id
    let selectedDay = dayString(selectedDate)

    var requestedProps: [String: Any] = [
      "timeline_selected_day": selectedDay,
      "activity_record_id": Int(recordId),
      "activity_title": activity.title,
      "activity_has_video_summary": activity.videoSummaryURL != nil,
    ]
    if let batchId = activity.batchId {
      requestedProps["activity_batch_id"] = Int(batchId)
    }

    deleteTimelineTask = Task.detached(priority: .userInitiated) {
      defer {
        Task { @MainActor in
          deleteTimelineTask = nil
        }
      }

      let deletedVideoPath = StorageManager.shared.deleteTimelineCard(recordId: recordId)
      guard !Task.isCancelled else { return }

      if let deletedVideoPath {
        if let fileURL = URL(string: deletedVideoPath), fileURL.isFileURL {
          try? FileManager.default.removeItem(at: fileURL)
        } else {
          try? FileManager.default.removeItem(atPath: deletedVideoPath)
        }
      }

      await MainActor.run {
        if selectedActivity?.id == selectedActivityId {
          clearTimelineSelection()
        }
        refreshActivitiesTrigger &+= 1
      }

      var deletedProps: [String: Any] = [
        "timeline_selected_day": selectedDay,
        "activity_record_id": Int(recordId),
        "activity_title": activity.title,
        "deleted_video_summary": deletedVideoPath != nil,
      ]
      if let batchId = activity.batchId {
        deletedProps["activity_batch_id"] = Int(batchId)
      }
    }
  }

}
