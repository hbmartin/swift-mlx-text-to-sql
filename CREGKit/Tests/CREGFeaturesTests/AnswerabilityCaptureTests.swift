import Foundation
import Testing
import ZIPFoundation

@testable import CREGEngine
@testable import CREGFeatures

private actor CaptureSchemaRecorder {
  private(set) var schemas: [String] = []

  func record(_ schema: String) {
    schemas.append(schema)
  }
}

private actor CaptureJudgeGate {
  private var callCount = 0
  private var startWaiters: [CheckedContinuation<Void, Never>] = []
  private var releaseContinuation: CheckedContinuation<Void, Never>?

  func judge() async -> ScopeVerdictRecord? {
    callCount += 1
    let waiters = startWaiters
    startWaiters.removeAll()
    for waiter in waiters { waiter.resume() }
    await withCheckedContinuation { continuation in
      releaseContinuation = continuation
    }
    return ScopeVerdictRecord(verdict: .likelyAnswerableModelFailed)
  }

  func waitUntilStarted() async {
    guard callCount == 0 else { return }
    await withCheckedContinuation { continuation in
      startWaiters.append(continuation)
    }
  }

  func release() {
    releaseContinuation?.resume()
    releaseContinuation = nil
  }

  var calls: Int { callCount }
}

private actor CaptureFailureCounter {
  private(set) var calls = 0

  func fail() -> ScopeVerdictRecord? {
    calls += 1
    return nil
  }
}

@Suite(.serialized) struct AnswerabilityCaptureTests {
  @Test func manifestHashesTheSchemaUsedForEveryVerdict() async throws {
    let schema = "properties(property_id, name)\nleases(has_renewal_option)"
    let recorder = CaptureSchemaRecorder()
    let client = ScopeDiagnosisClient(
      schemaPrompt: { schema },
      policyVersion: "scope-verdict-test-v1",
      judgeWithSchema: { _, suppliedSchema in
        await recorder.record(suppliedSchema)
        return ScopeVerdictRecord(verdict: .likelyAnswerableModelFailed)
      })

    let captureURL = await AnswerabilityCapture.run(
      client: client,
      capturedAt: Date(timeIntervalSince1970: 1))
    let url = try #require(captureURL)
    defer { try? FileManager.default.removeItem(at: url) }

    let archive = try Archive(url: url, accessMode: .read)
    let entry = try #require(archive["manifest.json"])
    var manifestData = Data()
    _ = try archive.extract(entry) { manifestData.append($0) }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let manifest = try decoder.decode(
      AnswerabilityCapture.Manifest.self,
      from: manifestData)

    #expect(
      manifest.schemaPromptSHA256
        == PreparedFollowUpIntegrity.sha256(Data(schema.utf8)))
    #expect(manifest.scopeVerdictPolicyVersion == "scope-verdict-test-v1")
    #expect(manifest.itemCount == 87)
    #expect(manifest.judgedCount == 87)
    let recordedSchemas = await recorder.schemas
    #expect(
      recordedSchemas == Array(repeating: schema, count: manifest.judgedCount))
  }

  @Test func cancellationDiscardsPartialCaptureAndStopsJudging() async {
    let gate = CaptureJudgeGate()
    let client = ScopeDiagnosisClient(
      schemaPrompt: { "properties(property_id, name)" },
      policyVersion: "scope-verdict-test-v1",
      judgeWithSchema: { _, _ in await gate.judge() })
    let task = Task {
      await AnswerabilityCapture.run(
        client: client,
        capturedAt: Date(timeIntervalSince1970: 1))
    }

    await gate.waitUntilStarted()
    task.cancel()
    await gate.release()

    let result = await task.value
    let calls = await gate.calls
    #expect(result == nil)
    #expect(calls == 1)
  }

  @Test func oneMissingVerdictDiscardsTheWholeCapture() async {
    let counter = CaptureFailureCounter()
    let client = ScopeDiagnosisClient(
      schemaPrompt: { "properties(property_id, name)" },
      policyVersion: "scope-verdict-test-v1",
      judgeWithSchema: { _, _ in await counter.fail() })

    let result = await AnswerabilityCapture.run(
      client: client,
      capturedAt: Date(timeIntervalSince1970: 1))

    #expect(result == nil)
    #expect(await counter.calls == 1)
  }
}
