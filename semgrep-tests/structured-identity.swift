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

struct LocallyStagedDelimitedIdentity {
  let cacheKey: String

  init(parts: [String]) {
    let encoded = parts.joined(separator: "|")
    // ruleid: creg-identity-requires-structured-components
    self.cacheKey = encoded
  }
}

struct ComputedLocallyStagedIdentity {
  let parts: [String]

  var dataIdentity: String {
    let encoded = parts.joined(separator: "|")
    // ruleid: creg-identity-requires-structured-components
    return encoded
  }
}

struct DisplayIdentityLabel {
  let parts: [String]

  var displayIdentity: String {
    // ok: creg-identity-requires-structured-components
    parts.joined(separator: " | ")
  }
}

struct StructuredIdentityWithDisplayWork {
  let parts: [String]
  let structuredIdentity: String

  var requestIdentity: String {
    // ok: creg-identity-requires-structured-components
    let displayValue = parts.joined(separator: " | ")
    _ = displayValue
    return structuredIdentity
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
