import Foundation
import Testing

@testable import CREGCore

@Suite struct FMStatusClientTests {
  /// Consumers arm the availability watch from a state snapshot that can be
  /// stale by the time the stream task runs. The initial yield is what lets a
  /// recovery inside that arm gap still drain a stranded queue.
  @Test func pollingUpdatesYieldTheCurrentValueOnSubscription() async {
    let stream = FMStatusClient.pollingUpdates(
      availability: { .available },
      interval: .seconds(60))
    var iterator = stream.makeAsyncIterator()
    let first = await iterator.next()
    #expect(first == .available)
  }

  /// A client built from just the synchronous read still supports the watch:
  /// the default `availabilityUpdates` derives from `availability` instead of
  /// silently finishing empty.
  @Test func defaultUpdatesStreamDerivesFromTheAvailabilityRead() async {
    let client = FMStatusClient(
      availability: { .unavailable(reason: .modelNotReady) })
    var iterator = client.availabilityUpdates().makeAsyncIterator()
    let first = await iterator.next()
    #expect(first == .unavailable(reason: .modelNotReady))
  }
}
