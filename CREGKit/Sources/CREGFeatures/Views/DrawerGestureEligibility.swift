import Foundation

/// Eligibility belongs to the entire drag, including direction changes and
/// navigation that arrives before the release.
struct DrawerGestureEligibility: Equatable {
  private(set) var startedRevealed: Bool?
  private(set) var eligible = false
  private(set) var cancelled = false
  mutating func change(startX: CGFloat, dx: CGFloat, dy: CGFloat, revealed: Bool) -> Bool {
    if startedRevealed == nil {
      startedRevealed = revealed
      eligible = revealed || startX < 44
    }
    guard eligible, !cancelled else { return false }
    if abs(dx) <= abs(dy) {
      cancelled = true
      return false
    }
    return true
  }
  func canRelease(startX: CGFloat, dx: CGFloat, dy: CGFloat, revealed: Bool) -> Bool {
    eligible && !cancelled && startedRevealed == revealed
      && (revealed || startX < 44) && abs(dx) > abs(dy)
  }
}
