//
//  AnalysisModels.swift
//  Dayflow
//
//  Created on 5/1/2025.
//

import Foundation

/// Represents a screenshot capture from the database (new - replaces video chunks)
struct Screenshot: Codable, Sendable {
  let id: Int64
  let capturedAt: Int  // Unix timestamp (instant of capture)
  /// HEVC segment file (or a legacy .jpg for rows written before segments existed).
  let filePath: String
  /// Share of the segment's bytes attributed to this frame; nil until the segment is finalized.
  let fileSize: Int64?
  let idleSecondsAtCapture: Int?
  /// False for older records whose privacy status is unknown.
  let isPrivacyRedacted: Bool
  let isDeleted: Bool
  /// Frame position inside the segment. nil means `filePath` is a standalone JPEG.
  let frameIndex: Int?

  init(
    id: Int64,
    capturedAt: Int,
    filePath: String,
    fileSize: Int64?,
    idleSecondsAtCapture: Int?,
    isDeleted: Bool,
    frameIndex: Int? = nil,
    isPrivacyRedacted: Bool = false
  ) {
    self.id = id
    self.capturedAt = capturedAt
    self.filePath = filePath
    self.fileSize = fileSize
    self.idleSecondsAtCapture = idleSecondsAtCapture
    self.isDeleted = isDeleted
    self.frameIndex = frameIndex
    self.isPrivacyRedacted = isPrivacyRedacted
  }

  enum CodingKeys: String, CodingKey {
    case id, capturedAt, filePath, fileSize, idleSecondsAtCapture, isDeleted, frameIndex, isPrivacyRedacted
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(Int64.self, forKey: .id)
    capturedAt = try container.decode(Int.self, forKey: .capturedAt)
    filePath = try container.decode(String.self, forKey: .filePath)
    fileSize = try container.decodeIfPresent(Int64.self, forKey: .fileSize)
    idleSecondsAtCapture = try container.decodeIfPresent(Int.self, forKey: .idleSecondsAtCapture)
    isDeleted = try container.decode(Bool.self, forKey: .isDeleted)
    frameIndex = try container.decodeIfPresent(Int.self, forKey: .frameIndex)
    isPrivacyRedacted = try container.decodeIfPresent(Bool.self, forKey: .isPrivacyRedacted) ?? false
  }

  var fileURL: URL {
    URL(fileURLWithPath: filePath)
  }

  var capturedDate: Date {
    Date(timeIntervalSince1970: TimeInterval(capturedAt))
  }
}
