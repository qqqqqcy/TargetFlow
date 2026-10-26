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
    from screenshots: [Screenshot], targetDuration: TimeInterval, maxGap: TimeInterval
  ) -> [ScreenshotBatch] {
    let ordered = screenshots.sorted { $0.capturedAt < $1.capturedAt }
    var batches: [ScreenshotBatch] = []
    var bucket: [Screenshot] = []

    func appendBucket() {
      guard let first = bucket.first, let last = bucket.last else { return }
      batches.append(ScreenshotBatch(screenshots: bucket, start: first.capturedAt, end: last.capturedAt))
    }

    for screenshot in ordered {
      if let previous = bucket.last,
        TimeInterval(screenshot.capturedAt - previous.capturedAt) > maxGap
      {
        appendBucket()
        bucket = []
      }
      bucket.append(screenshot)
      // Include the frame that reaches the target. Closing before it could leave
      // every batch just below the minimum when capture timestamps have jitter.
      if let first = bucket.first,
        TimeInterval(screenshot.capturedAt - first.capturedAt) >= targetDuration
      {
        appendBucket()
        bucket = []
      }
    }
    // Keep the unfinished trailing bucket unassigned until more frames arrive.
    return batches
  }
}
