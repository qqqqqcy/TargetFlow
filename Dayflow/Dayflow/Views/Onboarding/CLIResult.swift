import Foundation

struct CLIResult {
  let stdout: String
  let stderr: String
  let exitCode: Int32
  let shellCommand: String?
  let environmentOverrides: [String: String]
}
