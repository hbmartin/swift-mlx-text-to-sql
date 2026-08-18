import CREGCore
import CREGTestSupport
import Foundation

extension UUID {
  init(_ intValue: Int) {
    let isNegative = intValue < 0
    let intValue = isNegative ? -intValue : intValue
    var hexString = String(format: "%016llx", intValue)
    hexString.insert("-", at: hexString.index(hexString.startIndex, offsetBy: 4))
    self.init(
      uuidString: "00000000-0000-000\(isNegative ? "1" : "0")-\(hexString)"
    )!
  }
}

extension RangeReplaceableCollection {
  init<Source: AsyncSequence>(_ source: Source) async rethrows
  where Source.Element == Element {
    self.init()
    for try await item in source {
      append(item)
    }
  }
}
