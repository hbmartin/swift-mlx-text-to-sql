extension RangeReplaceableCollection {
  init<Source: AsyncSequence>(_ source: Source) async rethrows
  where Source.Element == Element {
    self.init()
    for try await item in source {
      append(item)
    }
  }
}
