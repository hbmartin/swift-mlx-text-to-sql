import CREGEngine
import Foundation
import GRDB

/// GRDB-backed implementation. All schema changes flow through the versioned
/// migrator; the pre-browser installed base (unversioned `conversation`/
/// `message`/`event` tables) is adopted by the baseline migration and rebuilt
/// with typed columns without losing a message.
final class HistoryStore: Sendable {
  let queue: DatabaseQueue
  static let encoder = JSONEncoder()
  static let decoder = JSONDecoder()
  /// Auto-titles cap at this many characters (first user question).
  static let titleLimit = 80

  static func encodedPayload(for message: ChatMessage) throws -> String {
    String(decoding: try encoder.encode(message), as: UTF8.self)
  }

  init(databaseURL: URL) throws {
    queue = try DatabaseQueue(path: databaseURL.path)
    try Self.migrator.migrate(queue)
  }

}
