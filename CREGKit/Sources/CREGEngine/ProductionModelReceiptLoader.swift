import CREGCore
import CryptoKit
import Foundation

public enum ProductionModelReceiptLoader {
  private struct Receipt: Decodable {
    var schemaVersion: Int
    var modelKey: String
    var repository: String
    var revision: String
    var directorySHA256: String
    var fileCount: Int
    var sourceManifestSHA256: String

    enum CodingKeys: String, CodingKey {
      case schemaVersion = "schema_version"
      case modelKey = "model_key"
      case repository, revision
      case directorySHA256 = "directory_sha256"
      case fileCount = "file_count"
      case sourceManifestSHA256 = "source_manifest_sha256"
    }
  }

  public static func validate(
    manifestURL: URL,
    receiptURL: URL,
    modelDirectory: URL,
    production: ProductionGenerationConfiguration,
    diagnostics: DiagnosticsClient = .noop
  ) throws {
    let started = ContinuousClock.now
    diagnostics.info(
      category: .configuration,
      code: "production_receipt_verification_started",
      summary: "Production model receipt verification started.",
      context: ["model_key": production.model.key])
    do {
      let receipt = try validateContents(
        manifestURL: manifestURL,
        receiptURL: receiptURL,
        modelDirectory: modelDirectory,
        production: production)
      diagnostics.info(
        category: .configuration,
        code: "production_receipt_verified",
        summary: "Production model receipt verification succeeded.",
        context: [
          "model_key": production.model.key,
          "file_count": String(receipt.fileCount),
          "elapsed_ms": milliseconds(started.duration(to: .now).microseconds),
        ])
    } catch {
      diagnostics.record(
        DiagnosticEvent(
          level: .error,
          category: .configuration,
          code: "production_receipt_verification_failed",
          summary: "Production model receipt verification failed.",
          details: DiagnosticDetails.describe(error),
          context: [
            "model_key": production.model.key,
            "elapsed_ms": milliseconds(started.duration(to: .now).microseconds),
          ]))
      throw error
    }
  }

  private static func validateContents(
    manifestURL: URL,
    receiptURL: URL,
    modelDirectory: URL,
    production: ProductionGenerationConfiguration
  ) throws -> Receipt {
    var isDirectory: ObjCBool = false
    guard
      FileManager.default.fileExists(
        atPath: modelDirectory.path, isDirectory: &isDirectory),
      isDirectory.boolValue
    else { throw ModelManifestError.missingReceipt }
    let manifestData = try Data(contentsOf: manifestURL)
    let receipt = try JSONDecoder().decode(
      Receipt.self, from: Data(contentsOf: receiptURL))
    let manifestDigest = SHA256.hash(data: manifestData)
      .map { String(format: "%02x", $0) }
      .joined()
    guard receipt.schemaVersion == 1 else {
      throw ModelManifestError.receiptMismatch("schema_version must be 1")
    }
    guard receipt.modelKey == production.model.key,
      receipt.repository == production.model.repository,
      receipt.revision == production.model.revision,
      receipt.sourceManifestSHA256 == manifestDigest
    else {
      throw ModelManifestError.receiptMismatch(
        "model identity or source-manifest hash disagrees")
    }
    guard receipt.fileCount > 0,
      receipt.directorySHA256.count == 64,
      receipt.directorySHA256.allSatisfy(\.isHexDigit)
    else {
      throw ModelManifestError.receiptMismatch(
        "directory digest or file count is invalid")
    }
    return receipt
  }

  private static func milliseconds(_ microseconds: Int64) -> String {
    String(format: "%.1f", Double(microseconds) / 1_000)
  }
}
