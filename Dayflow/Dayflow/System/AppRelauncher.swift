import Foundation

/// Wait for the old process to exit before asking Launch Services to open the app.
enum AppRelauncher {
  static func schedule(
    applicationURL: URL = Bundle.main.bundleURL,
    processIdentifier: Int32 = ProcessInfo.processInfo.processIdentifier
  ) throws {
    let helper = Process()
    helper.executableURL = URL(fileURLWithPath: "/bin/sh")
    // Pass paths as arguments: app names can contain spaces or shell metacharacters.
    // Give up if termination was cancelled, rather than opening a second instance.
    helper.arguments = [
      "-c",
      """
      attempts=0
      while /bin/kill -0 "$1" 2>/dev/null; do
        attempts=$((attempts + 1))
        [ "$attempts" -lt 150 ] || exit 1
        /bin/sleep 0.2
      done
      exec /usr/bin/open "$2"
      """,
      "targetflow-relaunch", String(processIdentifier), applicationURL.path,
    ]
    helper.standardInput = FileHandle.nullDevice
    helper.standardOutput = FileHandle.nullDevice
    helper.standardError = FileHandle.nullDevice
    try helper.run()
  }
}
