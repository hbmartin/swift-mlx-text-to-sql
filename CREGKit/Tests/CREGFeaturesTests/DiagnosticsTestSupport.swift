import ComposableArchitecture
import Foundation
import Testing

@testable import CREGEngine
@testable import CREGFeatures

func testSQLGenClient(
  schemaPrompt: @escaping @Sendable () throws -> String = { "test schema" },
  generate:
    @escaping @Sendable (SQLGenerationRequest) async throws
    -> SQLGeneration
) -> SQLGenClient {
  SQLGenClient(schemaPrompt: schemaPrompt, generate: generate)
}

final class DiagnosticEventRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: [DiagnosticEvent] = []

  var client: DiagnosticsClient {
    DiagnosticsClient { [self] event in
      lock.lock()
      storage.append(event)
      lock.unlock()
    }
  }

  var events: [DiagnosticEvent] {
    lock.lock()
    defer { lock.unlock() }
    return storage
  }
}

enum DiagnosticsTestError: LocalizedError, Sendable {
  case failed(String)

  var errorDescription: String? {
    switch self {
    case .failed(let message): message
    }
  }
}
