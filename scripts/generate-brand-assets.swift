import Foundation
import AppKit
import AVFoundation
import CoreVideo

// Regenerate with: swift scripts/generate-brand-assets.swift
// Primary icon only: swift scripts/generate-brand-assets.swift --icons-only
// Menu bar icons only: swift scripts/generate-brand-assets.swift --menu-icons-only
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let assets = root.appendingPathComponent("Dayflow/Dayflow/Assets.xcassets")
let fm = FileManager.default
let cyan = NSColor(srgbRed: 0.35, green: 0.92, blue: 0.85, alpha: 1)
let navy = NSColor(srgbRed: 0.08, green: 0.11, blue: 0.24, alpha: 1)

func png(_ size: NSSize, at url: URL, draw: () -> Void) throws {
  let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
  NSGraphicsContext.current!.imageInterpolation = .high
  draw()
  NSGraphicsContext.restoreGraphicsState()
  try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
  try bitmap.representation(using: .png, properties: [:])!.write(to: url)
}

func text(_ value: String, at point: NSPoint, size: CGFloat, color: NSColor, weight: NSFont.Weight = .semibold) {
  (value as NSString).draw(at: point, withAttributes: [
    .font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color,
  ])
}

/// The mark stays recognizable at 16px: an open target and a trajectory into its center.
func mark(in rect: NSRect, color: NSColor = cyan, active: Bool = true) {
  NSGraphicsContext.saveGraphicsState()
  let transform = AffineTransform(
    m11: rect.width / 1024, m12: 0, m21: 0, m22: rect.height / 1024,
    tX: rect.minX, tY: rect.minY)
  (transform as NSAffineTransform).concat()
  let ring = NSBezierPath()
  ring.appendArc(withCenter: NSPoint(x: 512, y: 512), radius: 286, startAngle: 48, endAngle: 360)
  ring.lineWidth = 66
  ring.lineCapStyle = .round
  color.setStroke()
  ring.stroke()

  let inner = NSBezierPath()
  inner.appendArc(withCenter: NSPoint(x: 512, y: 512), radius: 158, startAngle: 68, endAngle: 354)
  inner.lineWidth = 54
  inner.lineCapStyle = .round
  color.withAlphaComponent(active ? 0.55 : 0.35).setStroke()
  inner.stroke()

  let trajectory = NSBezierPath()
  trajectory.move(to: NSPoint(x: 817, y: 813))
  trajectory.curve(to: NSPoint(x: 512, y: 512), controlPoint1: NSPoint(x: 715, y: 817), controlPoint2: NSPoint(x: 640, y: 626))
  trajectory.lineWidth = 64
  trajectory.lineCapStyle = .round
  NSColor.white.setStroke()
  trajectory.stroke()
  (active ? NSColor(srgbRed: 1, green: 0.79, blue: 0.41, alpha: 1) : color).setFill()
  NSBezierPath(ovalIn: NSRect(x: 460, y: 460, width: 104, height: 104)).fill()
  NSGraphicsContext.restoreGraphicsState()
}

// Keep the generated master as the source for every app-icon rendition.
let appIconSourceURL = root.appendingPathComponent("docs/images/target-flow-icon-source.png")
guard let appIconSource = NSImage(contentsOf: appIconSourceURL) else {
  fatalError("Missing app icon master: \(appIconSourceURL.path)")
}

func appIcon(in rect: NSRect) {
  appIconSource.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
}

func imageSet(_ name: String, filename: String, size: NSSize, template: Bool = false, draw: () -> Void) throws {
  let directory = assets.appendingPathComponent(name + ".imageset")
  try png(size, at: directory.appendingPathComponent(filename), draw: draw)
  var contents: [String: Any] = [
    "images": [["filename": filename, "idiom": "universal"]],
    "info": ["author": "xcode", "version": 1],
  ]
  if template { contents["properties"] = ["template-rendering-intent": "template"] }
  try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
    .write(to: directory.appendingPathComponent("Contents.json"))
}

func menuBarIcons() throws {
  // A solid target and arrow match the new app icon and stay crisp at menu-bar size.
  for active in [false, true] {
    try imageSet(active ? "MenuBarOnIcon" : "MenuBarOffIcon", filename: "target-flow-menu.png",
      size: NSSize(width: 88, height: 72), template: true) {
        NSColor.black.setStroke()
        NSColor.black.setFill()
        let ring = NSBezierPath()
        ring.appendArc(withCenter: NSPoint(x: 35, y: 35), radius: 24,
          startAngle: 72, endAngle: 378)
        ring.lineWidth = 12
        ring.stroke()
        NSBezierPath(ovalIn: NSRect(x: 26, y: 26, width: 18, height: 18)).fill()
        let shaft = NSBezierPath()
        shaft.move(to: NSPoint(x: 35, y: 35))
        shaft.line(to: NSPoint(x: 55, y: 55))
        shaft.lineWidth = 8
        shaft.stroke()
        let arrow = NSBezierPath()
        arrow.move(to: NSPoint(x: 47, y: 51))
        arrow.line(to: NSPoint(x: 47, y: 61))
        arrow.line(to: NSPoint(x: 59, y: 72))
        arrow.line(to: NSPoint(x: 61, y: 61))
        arrow.line(to: NSPoint(x: 72, y: 59))
        arrow.line(to: NSPoint(x: 61, y: 47))
        arrow.line(to: NSPoint(x: 51, y: 47))
        arrow.close()
        arrow.fill()
        if active {
          NSColor.black.setFill()
          NSBezierPath(ovalIn: NSRect(x: 77, y: 5, width: 9, height: 9)).fill()
        }
      }
  }
}

if CommandLine.arguments.contains("--menu-icons-only") {
  try menuBarIcons()
  print("Generated menu bar target-and-arrow icons.")
  exit(0)
}

let iconDirectory = assets.appendingPathComponent("TargetFlowAppIcon.appiconset")
var iconEntries: [[String: String]] = []
for points in [16, 32, 128, 256, 512] {
  for scale in [1, 2] {
    let pixels = points * scale
    let filename = "target-flow-\(points)@\(scale)x.png"
    try png(NSSize(width: pixels, height: pixels), at: iconDirectory.appendingPathComponent(filename)) {
      appIcon(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
    }
    iconEntries.append(["filename": filename, "idiom": "mac", "size": "\(points)x\(points)", "scale": "\(scale)x"])
  }
}
try JSONSerialization.data(withJSONObject: ["images": iconEntries, "info": ["author": "xcode", "version": 1]],
  options: [.prettyPrinted, .sortedKeys]).write(to: iconDirectory.appendingPathComponent("Contents.json"))

try imageSet("TargetFlowLogoMainApp", filename: "target-flow-badge.png", size: NSSize(width: 512, height: 512)) {
  appIcon(in: NSRect(x: 0, y: 0, width: 512, height: 512))
}
try imageSet("Favicons/TargetFlowFavicon", filename: "target-flow-favicon.png", size: NSSize(width: 128, height: 128)) {
  appIcon(in: NSRect(x: 0, y: 0, width: 128, height: 128))
}
if CommandLine.arguments.contains("--icons-only") {
  let preview = root.appendingPathComponent("docs/images/target-flow-icon.png")
  if fm.fileExists(atPath: preview.path) { try fm.removeItem(at: preview) }
  try fm.copyItem(at: iconDirectory.appendingPathComponent("target-flow-512@2x.png"), to: preview)
  print("Generated app icon sizes, main-app badge, favicon, and documentation preview.")
  exit(0)
}

// TargetFlowLogo is a standalone vector asset; keep its SVG and catalog metadata intact.
try imageSet("TargetFlowLaunch", filename: "target-flow-launch.png", size: NSSize(width: 560, height: 640)) {
  appIcon(in: NSRect(x: 80, y: 160, width: 400, height: 400))
  text("Target Flow", at: NSPoint(x: 102, y: 82), size: 64, color: .white)
}
try menuBarIcons()

// A neutral permission illustration avoids baking the old product into a system screenshot.
try imageSet("ScreenRecordingPermissions", filename: "target-flow-screen-recording.png", size: NSSize(width: 1000, height: 620)) {
  let panel = NSBezierPath(roundedRect: NSRect(x: 6, y: 6, width: 988, height: 608), xRadius: 30, yRadius: 30)
  NSColor(srgbRed: 0.96, green: 0.97, blue: 0.99, alpha: 1).setFill()
  panel.fill()
  text("Screen Recording", at: NSPoint(x: 54, y: 535), size: 32, color: navy)
  text("Allow Target Flow to capture your screen", at: NSPoint(x: 54, y: 480), size: 24, color: NSColor(srgbRed: 0.35, green: 0.39, blue: 0.47, alpha: 1))
  NSColor.white.setFill()
  NSBezierPath(roundedRect: NSRect(x: 38, y: 300, width: 924, height: 140), xRadius: 20, yRadius: 20).fill()
  appIcon(in: NSRect(x: 57, y: 320, width: 100, height: 100))
  text("Target Flow", at: NSPoint(x: 182, y: 350), size: 32, color: navy)
  cyan.setFill()
  NSBezierPath(roundedRect: NSRect(x: 805, y: 342, width: 110, height: 58), xRadius: 29, yRadius: 29).fill()
  NSColor.white.setFill()
  NSBezierPath(ovalIn: NSRect(x: 860, y: 348, width: 46, height: 46)).fill()
  text("You can pause recording at any time.", at: NSPoint(x: 54, y: 195), size: 25, color: navy)
  text("Recordings stay on your Mac.", at: NSPoint(x: 54, y: 145), size: 25, color: navy)
}
try imageSet("TreemapPreview", filename: "target-flow-activity-preview.png", size: NSSize(width: 1200, height: 760)) {
  navy.setFill()
  NSBezierPath(rect: NSRect(x: 0, y: 0, width: 1200, height: 760)).fill()
  text("Target Flow", at: NSPoint(x: 50, y: 670), size: 44, color: .white)
  text("Your time, with direction.", at: NSPoint(x: 50, y: 618), size: 24, color: .lightGray)
  for (rect, label, color) in [
    (NSRect(x: 50, y: 55, width: 650, height: 510), "Focused work", cyan),
    (NSRect(x: 720, y: 285, width: 430, height: 280), "Research", NSColor(srgbRed: 0.61, green: 0.58, blue: 0.96, alpha: 1)),
    (NSRect(x: 720, y: 55, width: 430, height: 210), "Personal", NSColor(srgbRed: 1, green: 0.79, blue: 0.41, alpha: 1)),
  ] {
    color.withAlphaComponent(0.85).setFill()
    NSBezierPath(roundedRect: rect, xRadius: 22, yRadius: 22).fill()
    text(label, at: NSPoint(x: rect.minX + 26, y: rect.maxY - 62), size: 30, color: navy)
  }
}

// Original onboarding and timeline artwork contains no upstream logos or screenshots.
try imageSet("TargetFlowSplash", filename: "target-flow-splash.png", size: NSSize(width: 1200, height: 700)) {
  let background = NSBezierPath(rect: NSRect(x: 0, y: 0, width: 1200, height: 700))
  NSGradient(starting: NSColor(srgbRed: 0.24, green: 0.29, blue: 0.52, alpha: 1), ending: navy)!
    .draw(in: background, angle: -65)
  appIcon(in: NSRect(x: 435, y: 270, width: 330, height: 330))
  text("Target Flow", at: NSPoint(x: 386, y: 190), size: 76, color: .white)
  text("Your time, with direction.", at: NSPoint(x: 402, y: 125), size: 32, color: cyan)
}
for name in ["OnboardingTimeline", "WeeklyCalendarPreview", "WeeklyPreview"] {
  try imageSet(name, filename: "target-flow-timeline.png", size: NSSize(width: 1200, height: 760)) {
    let canvas = NSRect(x: 0, y: 0, width: 1200, height: 760)
    NSColor(srgbRed: 0.95, green: 0.96, blue: 0.99, alpha: 1).setFill()
    NSBezierPath(roundedRect: canvas, xRadius: 28, yRadius: 28).fill()
    appIcon(in: NSRect(x: 34, y: 645, width: 80, height: 80))
    text("Target Flow", at: NSPoint(x: 132, y: 666), size: 34, color: navy)
    text("Timeline", at: NSPoint(x: 54, y: 590), size: 27, color: navy)
    for (index, label) in ["Build something meaningful", "Research and learn", "Review your progress"].enumerated() {
      let y = CGFloat(420 - index * 150)
      text("\(9 + index):00", at: NSPoint(x: 54, y: y + 65), size: 22, color: .gray)
      let rect = NSRect(x: 160, y: y, width: 980, height: 120)
      let color = index == 1 ? NSColor(srgbRed: 0.64, green: 0.61, blue: 0.92, alpha: 1) : cyan
      color.withAlphaComponent(0.22).setFill()
      NSBezierPath(roundedRect: rect, xRadius: 14, yRadius: 14).fill()
      color.setFill()
      NSBezierPath(roundedRect: NSRect(x: 160, y: y, width: 7, height: 120), xRadius: 3, yRadius: 3).fill()
      text(label, at: NSPoint(x: 190, y: y + 65), size: 28, color: navy)
      text("A clear record of the work that moves you forward.", at: NSPoint(x: 190, y: y + 27), size: 21, color: .gray)
    }
  }
}

// Short, original intro replaces the upstream promotional video in retained legacy views.
func introVideo(at url: URL) throws {
  if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
  let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
  let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
    AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 960, AVVideoHeightKey: 600,
  ])
  let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
    kCVPixelBufferWidthKey as String: 960, kCVPixelBufferHeightKey as String: 600,
    kCVPixelBufferCGImageCompatibilityKey as String: true,
    kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
  ])
  writer.add(input)
  guard writer.startWriting() else { throw writer.error! }
  writer.startSession(atSourceTime: .zero)
  for frame in 0..<90 {
    while !input.isReadyForMoreMediaData {
      if writer.status == .failed { throw writer.error! }
      Thread.sleep(forTimeInterval: 0.005)
    }
    var buffer: CVPixelBuffer?
    CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
    let pixels = buffer!
    CVPixelBufferLockBaseAddress(pixels, [])
    let context = CGContext(data: CVPixelBufferGetBaseAddress(pixels), width: 960, height: 600,
      bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pixels),
      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    navy.setFill()
    NSBezierPath(rect: NSRect(x: 0, y: 0, width: 960, height: 600)).fill()
    let pulse = 1 + 0.025 * sin(Double(frame) / 90 * .pi * 2)
    let side = 340 * pulse
    mark(in: NSRect(x: (960 - side) / 2, y: 205 - (side - 340) / 2, width: side, height: side))
    text("Target Flow", at: NSPoint(x: 312, y: 122), size: 60, color: .white)
    text("Your time, with direction.", at: NSPoint(x: 318, y: 72), size: 28, color: cyan)
    NSGraphicsContext.restoreGraphicsState()
    CVPixelBufferUnlockBaseAddress(pixels, [])
    guard adaptor.append(pixels, withPresentationTime: CMTime(value: Int64(frame), timescale: 30)) else {
      throw writer.error!
    }
  }
  input.markAsFinished()
  let finished = DispatchSemaphore(value: 0)
  writer.finishWriting { finished.signal() }
  finished.wait()
  guard writer.status == .completed else { throw writer.error! }
}
let videos = root.appendingPathComponent("Dayflow/Dayflow/Videos")
try introVideo(at: videos.appendingPathComponent("TargetFlowAnimation.mp4"))
let onboardingVideo = videos.appendingPathComponent("TargetFlowOnboarding.mp4")
if fm.fileExists(atPath: onboardingVideo.path) { try fm.removeItem(at: onboardingVideo) }
try fm.copyItem(at: videos.appendingPathComponent("TargetFlowAnimation.mp4"), to: onboardingVideo)
// Keep the documentation preview and archived plugin artwork in sync.
let docs = root.appendingPathComponent("docs/images")
try fm.createDirectory(at: docs, withIntermediateDirectories: true)
for (source, destination) in [
  (iconDirectory.appendingPathComponent("target-flow-512@2x.png"), docs.appendingPathComponent("target-flow-icon.png")),
  (assets.appendingPathComponent("TargetFlowSplash.imageset/target-flow-splash.png"), docs.appendingPathComponent("target-flow-header.png")),
  (docs.appendingPathComponent("target-flow-icon.svg"), root.appendingPathComponent("plugins/dayflow/assets/icon.svg")),
  (docs.appendingPathComponent("target-flow-icon.svg"), root.appendingPathComponent("plugins/dayflow/assets/icon-dark.svg")),
] {
  if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
  try fm.copyItem(at: source, to: destination)
}
print("Generated Target Flow icon sizes, marks, launch artwork, menu icons, illustrations, and intro videos.")
