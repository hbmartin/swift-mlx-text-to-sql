import Foundation
import GRDB
import SQLite3

/// Read-only access to the bundled portfolio database.
public struct DatabaseClient: Sendable {
  /// Prepares SQL without stepping it. The supplied bytes are never rewritten.
  public var validate: @Sendable (_ sql: String) async throws -> SQLValidationReport
  /// Executes a SELECT and returns the (possibly row-capped) result table.
  public var execute: @Sendable (_ sql: String) async throws -> QueryResult

  public init(
    validate: @escaping @Sendable (_ sql: String) async throws
      -> SQLValidationReport = { _ in SQLValidationReport() },
    execute: @escaping @Sendable (_ sql: String) async throws -> QueryResult
  ) {
    self.validate = validate
    self.execute = execute
  }
}

extension DatabaseClient {
  /// Maximum rows returned to the UI before truncation. Python evaluation
  /// uses 10,000 (`eval.ex.ROW_CAP`); schema-v3 policy calibration excludes
  /// results above this 500-row production cap from voting and digest parity.
  public static let defaultRowCap = 500

  static func sqliteTextFixtureData() throws -> Data {
    guard let url = Bundle.module.url(
      forResource: "sqlite_text_fixtures", withExtension: "json")
    else { throw CocoaError(.fileNoSuchFile) }
    return try Data(contentsOf: url)
  }

  /// Opens `url` read-only and installs a deny-all-but-SELECT SQLite
  /// authorizer as the second line of defense behind the read-only
  /// connection (PRD §6). Grammar-constrained decoding is the first line.
  public static func live(url: URL, rowCap: Int = defaultRowCap) throws -> DatabaseClient {
    var configuration = Configuration()
    configuration.readonly = true
    configuration.prepareDatabase { db in
      let rc = sqlite3_set_authorizer(
        db.sqliteConnection,
        { _, action, _, _, _, _ in
          switch action {
          case SQLITE_SELECT, SQLITE_READ, SQLITE_FUNCTION, SQLITE_RECURSIVE,
            // transactions/savepoints are read-only-safe on a read-only
            // connection and GRDB wraps every read in one
            SQLITE_TRANSACTION, SQLITE_SAVEPOINT:
            return SQLITE_OK
          default:
            return SQLITE_DENY
          }
        },
        nil
      )
      guard rc == SQLITE_OK else {
        throw DatabaseError(resultCode: ResultCode(rawValue: rc), message: "could not install authorizer")
      }
    }
    let queue = try DatabaseQueue(path: url.path, configuration: configuration)
    return DatabaseClient(
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
          let statement = try db.makeStatement(sql: sql)
          let columns = statement.columnNames
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
            isTruncated: isTruncated,
            elapsedMicroseconds: elapsed.microseconds
          )
        }
      })
  }
}

extension SQLValidationIssue {
  static func classify(_ error: any Error) -> SQLValidationIssue {
    let message = String(describing: error)
    if error is CancellationError {
      return SQLValidationIssue(
        kind: .interrupted,
        disposition: .terminal,
        message: message)
    }
    if message.contains("[portfolio_database_unavailable]") {
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

public extension Duration {
  var microseconds: Int64 {
    let components = self.components
    return components.seconds * 1_000_000 + components.attoseconds / 1_000_000_000_000
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
