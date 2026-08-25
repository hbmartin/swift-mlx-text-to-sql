struct DelimitedIdentity {
  let requestKey: String
  let displayText: String

  init(parts: [String]) {
    // ruleid: creg-identity-requires-structured-components
    self.requestKey = parts.joined(separator: "|")
    // ok: creg-identity-requires-structured-components
    self.displayText = parts.joined(separator: " | ")
  }
}

struct ComputedDelimitedIdentity {
  let parts: [String]

  var requestIdentity: String {
    // ruleid: creg-identity-requires-structured-components
    parts.joined(separator: "|")
  }
}

func localDisplayValue(parts: [String]) -> String {
  // ok: creg-identity-requires-structured-components
  let requestKey = parts.joined(separator: " | ")
  return requestKey
}

struct StructuredIdentity {
  struct Key: Hashable {
    let resultFingerprint: String
    let sql: String
  }

  // ok: creg-identity-requires-structured-components
  let requestKey = Key(resultFingerprint: "result", sql: "SELECT 1")
}
