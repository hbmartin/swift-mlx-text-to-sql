import CREGEngine
import ComposableArchitecture
import Foundation

/// User-facing recovery copy plus a stable developer diagnostic kept outside
/// the normal UI unless Developer Mode is enabled.
public struct FailurePresentation: Error, Sendable, Equatable {
  public var code: String
  public var title: String
  public var message: String
  public var diagnostic: String

  public init(
    code: String,
    title: String,
    message: String,
    diagnostic: String
  ) {
    self.code = code
    self.title = title
    self.message = message
    self.diagnostic = diagnostic
  }

  public func technicalDetails(developerMode: Bool) -> String? {
    guard developerMode else { return nil }
    return "[\(code)] \(diagnostic)"
  }
}

extension FailurePresentation {
  public static func productionConfiguration(
    _ error: any Error
  ) -> FailurePresentation {
    let code: String
    let message: String

    if let manifestError = error as? ModelManifestError {
      switch manifestError {
      case .missing:
        code = "production_manifest_missing"
        message =
          "This build is missing its SQL model manifest. Rebuild and reinstall CREG."
      case .missingReceipt:
        code = "production_receipt_missing"
        message =
          "This build is missing its verified SQL model receipt. Rebuild and reinstall CREG."
      case .receiptMismatch:
        code = "production_receipt_mismatch"
        message =
          "This build’s SQL model does not match its release receipt. Rebuild and reinstall CREG."
      case .productionSelectionPending:
        code = "production_selection_pending"
        message =
          "This build does not contain a verified SQL model selection. Install a completed production build."
      case .unknownProductionModel:
        code = "production_model_unknown"
        message =
          "This build refers to an unknown SQL model. Rebuild and reinstall CREG."
      case .invalidProductionConfiguration:
        code = "production_configuration_invalid"
        message =
          "This build contains an invalid SQL model configuration. Rebuild and reinstall CREG."
      }
    } else if error is DecodingError {
      code = "production_manifest_incompatible"
      message =
        "This build contains an incompatible model configuration for the SQL model. Rebuild and reinstall CREG."
    } else if (error as NSError).domain == NSCocoaErrorDomain {
      code = "production_manifest_unreadable"
      message =
        "CREG couldn’t read a bundled SQL model file. Reinstall the app; if the problem continues, install a fresh production build."
    } else {
      code = "production_bootstrap_unexpected"
      message =
        "CREG couldn’t initialize its bundled SQL model. Restart the app; if the problem continues, contact support with Developer Mode details."
    }

    return FailurePresentation(
      code: code,
      title: "SQL model unavailable",
      message: message,
      diagnostic: DiagnosticDetails.describe(error))
  }

  static func history(
    operation: HistoryFailureOperation,
    error: any Error
  ) -> FailurePresentation {
    let title: String
    let message: String
    switch operation {
    case .load:
      title = "History unavailable"
      message =
        "CREG couldn’t load your saved conversation. You can continue, but this session may not be saved."
    case .messageSave, .eventSave:
      title = "Conversation not saved"
      message =
        "Your conversation is still visible, but CREG couldn’t save it. Try again after restarting the app."
    case .export:
      title = "Export failed"
      message = "CREG couldn’t export this session. Please try again."
    }
    return FailurePresentation(
      code: operation.code,
      title: title,
      message: message,
      diagnostic: DiagnosticDetails.describe(error))
  }
}

enum HistoryFailureOperation: String, Sendable {
  case load
  case messageSave
  case eventSave
  case export

  var code: String {
    switch self {
    case .load: "history_load_failed"
    case .messageSave: "history_message_save_failed"
    case .eventSave: "history_event_save_failed"
    case .export: "history_export_failed"
    }
  }
}

public enum ProductionModelBootstrap {
  public static func load(
    diagnostics: DiagnosticsClient,
    _ loader: () throws -> ProductionGenerationConfiguration
  ) -> Result<ProductionGenerationConfiguration, FailurePresentation> {
    do {
      let configuration = try loader()
      diagnostics.record(DiagnosticEvent(
        level: .info,
        category: .configuration,
        code: "production_configuration_loaded",
        summary: "The production SQL model configuration loaded.",
        context: [
          "model_key": configuration.model.key,
          "revision": configuration.model.revision,
          "quantization": configuration.model.quantization,
          "gcd": configuration.gcd.rawValue,
        ]))
      return .success(configuration)
    } catch {
      let failure = FailurePresentation.productionConfiguration(error)
      diagnostics.record(DiagnosticEvent(
        level: .error,
        category: .configuration,
        code: failure.code,
        summary: "The production SQL model configuration could not be loaded.",
        details: failure.diagnostic))
      return .failure(failure)
    }
  }
}

extension DiagnosticsClient: DependencyKey {
  public static var testValue: DiagnosticsClient { .noop }
  public static var liveValue: DiagnosticsClient { .live }
}

extension DependencyValues {
  public var diagnostics: DiagnosticsClient {
    get { self[DiagnosticsClient.self] }
    set { self[DiagnosticsClient.self] = newValue }
  }
}
