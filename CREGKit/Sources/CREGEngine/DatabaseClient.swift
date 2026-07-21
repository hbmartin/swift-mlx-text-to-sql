import Foundation
import GRDB
import SQLite3

/// Read-only access to the bundled portfolio database.
public struct DatabaseClient: Sendable {
  /// Executes a SELECT and returns the (possibly row-capped) result table.
  public var execute: @Sendable (_ sql: String) async throws -> QueryResult

  public init(execute: @escaping @Sendable (_ sql: String) async throws -> QueryResult) {
    self.execute = execute
  }
}

extension DatabaseClient {
  /// Maximum rows returned to the UI before truncation.
  public static let defaultRowCap = 500

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
    return DatabaseClient { sql in
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
          rows.append((0..<row.count).map { SQLValue(row[$0] as DatabaseValue) })
        }
        let elapsed = start.duration(to: .now)
        return QueryResult(
          columns: columns,
          rows: rows,
          isTruncated: isTruncated,
          elapsedMicroseconds: elapsed.microseconds
        )
      }
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
