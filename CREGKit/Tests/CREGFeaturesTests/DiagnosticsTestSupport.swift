import ComposableArchitecture
import Foundation
import Testing

@testable import CREGEngine
@testable import CREGFeatures

final class DiagnosticEventRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: [DiagnosticEvent] = []
  private let didRecord: @Sendable (DiagnosticEvent) -> Void

  init(
    didRecord: @escaping @Sendable (DiagnosticEvent) -> Void = { _ in }
  ) {
    self.didRecord = didRecord
  }

  var client: DiagnosticsClient {
    DiagnosticsClient { [self] event in
      lock.lock()
      storage.append(event)
      lock.unlock()
      didRecord(event)
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
