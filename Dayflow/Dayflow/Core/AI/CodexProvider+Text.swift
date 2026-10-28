import Foundation

extension CodexProvider {
  func generateText(
    prompt: String,
    model: String,
    reasoningEffort: String? = nil,
    disableTools: Bool = true
  ) async throws -> (text: String, log: LLMCall) {
    let callStart = Date()
    let ctx = makeCtx(
      batchId: nil, operation: "generateText", model: model, startedAt: callStart)

    let run: ChatCLIRunResult
    do {
      run = try await Task.detached {
        try self.runAndScrub(
          prompt: prompt,
          model: model,
          reasoningEffort: reasoningEffort,
          disableTools: disableTools
        )
      }.value
    } catch {
      let nsErr = error as NSError
      let partialOut = nsErr.userInfo["partialStdout"] as? String
      let partialErr = nsErr.userInfo["partialStderr"] as? String
      logFailure(
        ctx: ctx, finishedAt: Date(), error: error, stdout: partialOut, stderr: partialErr)
      throw error
    }

    guard run.exitCode == 0 else {
      let errorMessage = run.failureMessage(toolName: "Codex CLI")
      let error = NSError(
        domain: "CodexProvider", code: Int(run.exitCode),
        userInfo: [NSLocalizedDescriptionKey: errorMessage])
      logFailure(
        ctx: ctx, finishedAt: run.finishedAt, error: error, stdout: run.stdout, stderr: run.stderr,
        run: run)
      throw error
    }

    logSuccess(
      ctx: ctx, finishedAt: run.finishedAt, stdout: run.stdout, stderr: run.stderr,
      responseHeaders: tokenHeaders(from: run.usage))

    let thinking = runner.parseThinkingFromOutput(run.rawStdout)
    let log = makeLLMCall(start: callStart, end: run.finishedAt, input: prompt, output: run.stdout)
    let text = run.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    if let thinking, !thinking.isEmpty {
      return ("---THINKING---\n\(thinking)\n---END_THINKING---\n\(text)", log)
    }
    return (text, log)
  }
}
