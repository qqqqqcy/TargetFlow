import Foundation

struct ScreenshotBatch {
  let screenshots: [Screenshot]
  let start: Int
  let end: Int

  var duration: TimeInterval { TimeInterval(end - start) }
}

enum ScreenshotBatcher {
  // A fixed floor also allows retrying one-minute batches after switching to 15 minutes.
  static let minimumDuration: TimeInterval = 60

  static func batches(
    from screenshots: [Screenshot], targetDuration: TimeInterval, maxGap: TimeInterval,
    continuingFrom: Int? = nil
  ) -> [ScreenshotBatch] {
    let ordered = screenshots.sorted { $0.capturedAt < $1.capturedAt }
    var batches: [ScreenshotBatch] = []
    var bucket: [Screenshot] = []
    var carry = continuingFrom

    func appendBucket() {
      guard let first = bucket.first, let last = bucket.last else { return }
      batches.append(ScreenshotBatch(screenshots: bucket, start: first.capturedAt, end: last.capturedAt))
    }

    for screenshot in ordered {
      if let previous = bucket.last {
        let stop = TimelineCaptureBoundaries.shared.continuity(from: previous.capturedAt, to: screenshot.capturedAt)
        let gap = screenshot.capturedAt - previous.capturedAt
        let crossesDay = previous.capturedDate.getDayInfoFor4AMBoundary().dayString
          != screenshot.capturedDate.getDayInfoFor4AMBoundary().dayString
        let continuous: Bool
        if previous.isPrivacyRedacted != screenshot.isPrivacyRedacted {
          // Privacy transitions remain in the batch and are split by the evidence policy.
          continuous = stop != false && gap > 0 && TimeInterval(gap) <= maxGap
        } else if previous.isPrivacyRedacted {
          continuous = TimeInterval(gap) <= maxGap
            && TimelineEvidencePolicy.captureContinues(history: bucket, next: screenshot,
              recordedContinuity: stop, privacy: true)
        } else {
          continuous = TimeInterval(gap) <= maxGap
            && TimelineEvidencePolicy.captureContinues(history: bucket, next: screenshot, recordedContinuity: stop)
        }
        if crossesDay || !continuous {
          appendBucket()
          bucket = []
          carry = nil
        }
      }
      bucket.append(screenshot)
      // Include the frame that reaches the target. Closing before it could leave
      // every batch just below the minimum when capture timestamps have jitter.
      if let first = bucket.first,
        TimeInterval(screenshot.capturedAt - first.capturedAt) >= minimumDuration,
        TimeInterval(screenshot.capturedAt - (carry ?? first.capturedAt)) >= targetDuration
      {
        appendBucket()
        bucket = []
        carry = nil
      }
    }
    // Keep the unfinished trailing bucket unassigned until more frames arrive.
    return batches
  }
}
