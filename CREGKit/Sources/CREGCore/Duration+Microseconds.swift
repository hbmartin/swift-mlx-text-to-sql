import Foundation

public extension Duration {
  var microseconds: Int64 {
    let components = self.components
    return components.seconds * 1_000_000
      + components.attoseconds / 1_000_000_000_000
  }
}
