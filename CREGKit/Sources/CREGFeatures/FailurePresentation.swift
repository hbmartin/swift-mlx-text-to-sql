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
  /// The single mapping from a Turn Failure's typed reason to user copy.
  /// Every sentence here is written by a human; the engine ships data only.
  /// Copy never implies user error for causes the user cannot fix — "try
  /// rephrasing" appears nowhere, because for a genuine scope miss it is
  /// advice that can never work.
  public static func turnFailure(
    _ reason: TurnFailureReason,
    diagnostic: String? = nil
  ) -> FailurePresentation {
    let code: String
    let title: String
    let message: String
    switch reason {
    case .timedOut:
      code = "turn_timed_out"
      title = "Answer timed out"
      message = "That answer took too long. Please try again."
    case .cancelled:
      code = "turn_cancelled"
      title = "Answer cancelled"
      message = "That answer was cancelled. Ask again whenever you're ready."
    case .databaseUnavailable:
      code = "turn_database_unavailable"
      title = "Portfolio data unavailable"
      message =
        "CREG couldn't access the portfolio database safely. Reinstall CREG; if the problem continues, contact support."
    case .generationFailed:
      code = "turn_generation_failed"
      title = "Model couldn't run"
      message =
        "The SQL model couldn't produce a query for this question. Try again; if the problem continues, reinstall CREG."
    case .generationExhausted:
      code = "turn_generation_exhausted"
      title = "No valid query"
      message =
        "CREG tried several ways to query the portfolio for this and none held up."
    case .noCandidateSelected:
      code = "turn_no_candidate_selected"
      title = "No trustworthy answer"
      message =
        "CREG's attempts didn't agree on an answer it could stand behind."
    case .languageServiceFailed:
      code = "turn_language_service_failed"
      title = "Language service failed"
      message =
        "The on-device language service couldn't finish this step. Try again."
    case .starterQueryUnavailable:
      code = "turn_starter_query_unavailable"
      title = "Starter query unavailable"
      message = "That built-in portfolio query is temporarily unavailable."
    case .pipelineUnavailable(let userMessage):
      code = "turn_pipeline_unavailable"
      title = "SQL model unavailable"
      message = userMessage
        ?? "CREG's SQL model isn't available right now, so this question couldn't run."
    case .unexpected:
      code = "turn_unexpected_failure"
      title = "Unable to answer"
      message = "Something went wrong while answering. Please try again."
    }
    return FailurePresentation(
      code: code,
      title: title,
      message: message,
      diagnostic: diagnostic ?? reason.label)
  }
}

extension ScopeVerdictRecord {
  /// The human-written coverage sentence rendered beneath a Turn Failure.
  /// The FM only picked the bucket; `missingSubject` is the one FM-supplied
  /// phrase and it is rendered solely for `inDomainButNotTracked`, after the
  /// deterministic schema-coverage guard upstream (ADR 0010).
  public var userNotice: String {
    switch verdict {
    case .outsideRealEstate:
      return
        "This looks outside CREG's commercial real estate portfolio, so the data here can't answer it."
    case .inDomainButNotTracked:
      if let missingSubject, !missingSubject.isEmpty {
        return "The portfolio doesn't track \(missingSubject)."
      }
      return "The portfolio doesn't track the information this needs."
    case .needsDataNotInSnapshot:
      return
        "This needs data beyond the portfolio snapshot — CREG covers recorded history up to its as-of date."
    case .likelyAnswerableModelFailed:
      return
        "The portfolio should be able to answer this — asking again is worth a try."
    }
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
      case .missingRuntimeContract:
        code = "production_runtime_contract_missing"
        message =
          "This build is missing its SQL runtime compatibility contract. Rebuild and reinstall CREG."
      case .unsupportedRuntimeContract:
        code = "production_runtime_contract_unsupported"
        message =
          "This build’s SQL runtime and model configuration are incompatible. Install a newer build."
      case .runtimeProvenanceMismatch:
        code = "production_runtime_provenance_mismatch"
        message =
          "This build’s SQL model does not match its executable. Rebuild and reinstall CREG."
      }
    } else if let contractError = error as? ModelRuntimeContractInfoError {
      switch contractError {
      case .missing, .invalidSourceRevision:
        code = "production_runtime_contract_missing"
        message =
          "This build is missing valid SQL runtime provenance. Rebuild and reinstall CREG."
      case .unsupportedVersion:
        code = "production_runtime_contract_unsupported"
        message =
          "This build’s SQL runtime contract is unsupported. Install a newer build."
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
        "CREG couldn’t load your saved conversation. You can continue, but this conversation may not be saved."
    case .messageSave, .eventSave:
      title = "Conversation not saved"
      message =
        "Your conversation is still visible, but CREG couldn’t save it. Try again after restarting the app."
    case .export:
      title = "Export failed"
      message = "CREG couldn’t export this conversation. Please try again."
    case .conversationCreate:
      title = "New chat failed"
      message = "CREG couldn’t create a new conversation. Please try again."
    case .rename:
      title = "Rename not saved"
      message = "CREG couldn’t save the new conversation title. Please try again."
    case .delete:
      title = "Delete failed"
      message = "CREG couldn’t delete that conversation. Please try again."
    case .search:
      title = "Search unavailable"
      message = "CREG couldn’t search your conversations. Please try again."
    case .feedbackSave:
      title = "Feedback not saved"
      message = "CREG couldn’t save your answer feedback. Please try again."
    case .supportBundle:
      title = "Support bundle failed"
      message = "CREG couldn’t assemble the support bundle. Please try again."
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
  case conversationCreate
  case rename
  case delete
  case search
  case feedbackSave
  case supportBundle

  var code: String {
    switch self {
    case .load: "history_load_failed"
    case .messageSave: "history_message_save_failed"
    case .eventSave: "history_event_save_failed"
    case .export: "history_export_failed"
    case .conversationCreate: "history_conversation_create_failed"
    case .rename: "history_rename_failed"
    case .delete: "history_delete_failed"
    case .search: "history_search_failed"
    case .feedbackSave: "history_feedback_save_failed"
    case .supportBundle: "support_bundle_failed"
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
          "max_tokens": String(configuration.maxTokens),
          "runtime_policy_version": configuration.runtimePolicyVersion ?? "legacy",
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
