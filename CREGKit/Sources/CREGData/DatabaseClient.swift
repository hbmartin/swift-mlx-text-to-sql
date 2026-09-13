import CREGCore
import CryptoKit
import Foundation
import GRDB
import SQLite3

private final class SQLiteAuthorizerState: @unchecked Sendable {
  private let lock = NSLock()
  private var isCapturing = false
  private var capturedReads: [SQLSourceRead] = []

  func beginCapture() {
    lock.withLock {
      isCapturing = true
      capturedReads.removeAll(keepingCapacity: true)
    }
  }

  func finishCapture() -> [SQLSourceRead] {
    lock.withLock {
      isCapturing = false
      var seen: Set<SQLSourceRead> = []
      let reads = capturedReads.filter { seen.insert($0).inserted }
      capturedReads.removeAll(keepingCapacity: true)
      return reads
    }
  }

  func cancelCapture() {
    lock.withLock {
      isCapturing = false
      capturedReads.removeAll(keepingCapacity: true)
    }
  }

  func authorize(
    action: Int32,
    first: UnsafePointer<CChar>?,
    second: UnsafePointer<CChar>?,
    third: UnsafePointer<CChar>?,
    fourth: UnsafePointer<CChar>?
  ) -> Int32 {
    switch action {
    case SQLITE_SELECT, SQLITE_FUNCTION, SQLITE_RECURSIVE,
      SQLITE_TRANSACTION, SQLITE_SAVEPOINT:
      return SQLITE_OK
    case SQLITE_READ:
      if let table = Self.string(first) {
        let column = Self.string(second).flatMap { $0.isEmpty ? nil : $0 }
        let read = SQLSourceRead(
          table: table.lowercased(),
          column: column?.lowercased(),
          database: Self.string(third)?.lowercased(),
          scope: Self.string(fourth)?.lowercased())
        lock.withLock {
          if isCapturing { capturedReads.append(read) }
        }
      }
      return SQLITE_OK
    default:
      return SQLITE_DENY
    }
  }

  private static func string(_ value: UnsafePointer<CChar>?) -> String? {
    value.map { String(cString: $0) }
  }
}

/// Read-only access to the bundled portfolio database.
public struct DatabaseClient: Sendable {
  /// Stable identity of the exact read-only portfolio snapshot.
  public var fingerprint: String
  /// Prepares SQL without stepping it. The supplied bytes are never rewritten.
  public var validate: @Sendable (_ sql: String) async throws -> SQLValidationReport
  /// Executes a SELECT and returns the (possibly row-capped) result table.
  public var execute: @Sendable (_ sql: String) async throws -> QueryResult

  public init(
    fingerprint: String,
    validate: @escaping @Sendable (_ sql: String) async throws
      -> SQLValidationReport = { _ in SQLValidationReport() },
    execute: @escaping @Sendable (_ sql: String) async throws -> QueryResult
  ) {
    self.fingerprint = fingerprint
    self.validate = validate
    self.execute = execute
  }
}

/// A typed startup failure used when the read-only portfolio database cannot
/// be opened. Classification must never depend on parsing localized text.
public struct PortfolioDatabaseUnavailableError:
  Error, CustomStringConvertible, LocalizedError, Sendable
{
  public var diagnostic: String

  public init(diagnostic: String) {
    self.diagnostic = diagnostic
  }

  public var description: String { diagnostic }
  public var errorDescription: String? { diagnostic }
}

extension DatabaseClient {
  /// Maximum rows returned to the UI before truncation. Python evaluation
  /// uses 10,000 (`eval.ex.ROW_CAP`); schema-v3 policy calibration excludes
  /// results above this 500-row production cap from voting and digest parity.
  public static let defaultRowCap = 500

  public static func unavailableBundledPortfolioDatabase(
    diagnostic: String
  ) -> DatabaseClient {
    let issue = SQLValidationIssue(
      kind: .databaseUnavailable,
      disposition: .terminal,
      message: diagnostic)
    return DatabaseClient(
      fingerprint: "unavailable-portfolio-database",
      validate: { _ in SQLValidationReport(issue: issue) },
      execute: { _ in
        throw PortfolioDatabaseUnavailableError(diagnostic: diagnostic)
      })
  }

  /// Opens `url` read-only and installs a deny-all-but-SELECT SQLite
  /// authorizer as the second line of defense behind the read-only
  /// connection (PRD §6). Grammar-constrained decoding is the first line.
  public static func live(url: URL, rowCap: Int = defaultRowCap) throws -> DatabaseClient {
    let databaseFingerprint = try PreparedFollowUpIntegrity.sha256(
      contentsOf: url)
    var configuration = Configuration()
    configuration.readonly = true
    let authorizer = SQLiteAuthorizerState()
    configuration.prepareDatabase { db in
      let rc = sqlite3_set_authorizer(
        db.sqliteConnection,
        { context, action, first, second, third, fourth in
          guard let context else { return SQLITE_DENY }
          return Unmanaged<SQLiteAuthorizerState>.fromOpaque(context)
            .takeUnretainedValue()
            .authorize(
              action: action,
              first: first,
              second: second,
              third: third,
              fourth: fourth)
        },
        Unmanaged.passUnretained(authorizer).toOpaque()
      )
      guard rc == SQLITE_OK else {
        throw DatabaseError(
          resultCode: ResultCode(rawValue: rc),
          message: "could not install authorizer")
      }
    }
    let queue = try DatabaseQueue(path: url.path, configuration: configuration)
    return DatabaseClient(
      fingerprint: databaseFingerprint,
      validate: { sql in
        let start = ContinuousClock.now
        do {
          try await queue.read { db in
            _ = try db.makeStatement(sql: sql)
          }
          return SQLValidationReport(
            elapsedMicroseconds: start.duration(to: .now).microseconds)
        } catch {
          return SQLValidationReport(
            issue: SQLValidationIssue.classify(error),
            elapsedMicroseconds: start.duration(to: .now).microseconds)
        }
      },
      execute: { sql in
        let start = ContinuousClock.now
        return try await queue.read { db in
          authorizer.beginCapture()
          let statement: Statement
          do {
            statement = try db.makeStatement(sql: sql)
          } catch {
            authorizer.cancelCapture()
            throw error
          }
          let reads = authorizer.finishCapture()
          let columns = statement.columnNames
          let directOrigins = (0..<columns.count).map { index -> SQLSourceColumn? in
            guard
              let tablePointer = sqlite3_column_table_name(
                statement.sqliteStatement, Int32(index)),
              let columnPointer = sqlite3_column_origin_name(
                statement.sqliteStatement, Int32(index))
            else { return nil }
            return SQLSourceColumn(
              table: String(cString: tablePointer).lowercased(),
              column: String(cString: columnPointer).lowercased())
          }
          let lineage = SQLQueryAnalyzer.lineage(
            sql: sql,
            outputColumnNames: columns,
            directOrigins: directOrigins,
            reads: reads)
          var rows: [[SQLValue]] = []
          var isTruncated = false
          let cursor = try Row.fetchCursor(statement)
          while let row = try cursor.next() {
            if rows.count >= rowCap {
              isTruncated = true
              break
            }
            // GRDB's DatabaseValue TEXT conversion uses a C-string path that
            // truncates at embedded NUL. Read the raw sqlite3 bytes instead so
            // Swift and Python share the same replacement-decoding contract.
            rows.append((0..<row.count).map {
              SQLValue(statement: statement.sqliteStatement, column: Int32($0))
            })
          }
          let elapsed = start.duration(to: .now)
          return QueryResult(
            columns: columns,
            rows: rows,
            lineage: lineage,
            isTruncated: isTruncated,
            elapsedMicroseconds: elapsed.microseconds
          )
        }
      })
  }
}

extension SQLValidationIssue {
  package static func classify(_ error: any Error) -> SQLValidationIssue {
    let message = String(describing: error)
    if error is CancellationError {
      return SQLValidationIssue(
        kind: .interrupted,
        disposition: .terminal,
        message: message)
    }
    if error is PortfolioDatabaseUnavailableError {
      return SQLValidationIssue(
        kind: .databaseUnavailable,
        disposition: .terminal,
        message: message)
    }
    guard let databaseError = error as? DatabaseError else {
      return SQLValidationIssue(
        kind: .unknown,
        disposition: .repairable,
        message: message)
    }
    switch databaseError.extendedResultCode.primaryResultCode.rawValue {
    case SQLITE_AUTH, SQLITE_PERM, SQLITE_READONLY:
      return SQLValidationIssue(
        kind: .authorization,
        disposition: .terminal,
        message: message)
    case SQLITE_CORRUPT, SQLITE_NOTADB:
      return SQLValidationIssue(
        kind: .databaseCorrupt,
        disposition: .terminal,
        message: message)
    case SQLITE_CANTOPEN, SQLITE_IOERR, SQLITE_FULL:
      return SQLValidationIssue(
        kind: .databaseUnavailable,
        disposition: .terminal,
        message: message)
    case SQLITE_INTERRUPT, SQLITE_ABORT:
      return SQLValidationIssue(
        kind: .interrupted,
        disposition: .terminal,
        message: message)
    default:
      let lowercased = message.lowercased()
      return SQLValidationIssue(
        kind: lowercased.contains("syntax") ? .syntax : .binding,
        disposition: .repairable,
        message: message)
    }
  }
}

extension SQLValue {
  init(statement: OpaquePointer, column: Int32) {
    switch sqlite3_column_type(statement, column) {
    case SQLITE_NULL:
      self = .null
    case SQLITE_INTEGER:
      self = .integer(sqlite3_column_int64(statement, column))
    case SQLITE_FLOAT:
      self = .real(sqlite3_column_double(statement, column))
    case SQLITE_TEXT:
      let count = Int(sqlite3_column_bytes(statement, column))
      guard count > 0, let pointer = sqlite3_column_text(statement, column) else {
        self = .text("")
        return
      }
      self = .text(String(
        decoding: UnsafeBufferPointer(start: pointer, count: count),
        as: UTF8.self))
    case SQLITE_BLOB:
      let count = Int(sqlite3_column_bytes(statement, column))
      guard count > 0, let pointer = sqlite3_column_blob(statement, column) else {
        self = .blob(Data())
        return
      }
      self = .blob(Data(bytes: pointer, count: count))
    default:
      preconditionFailure("unknown SQLite storage class")
    }
  }

  init(_ value: DatabaseValue) {
    switch value.storage {
    case .null: self = .null
    case .int64(let v): self = .integer(v)
    case .double(let v): self = .real(v)
    case .string(let v): self = .text(v)
    case .blob(let v): self = .blob(v)
    }
  }
}
