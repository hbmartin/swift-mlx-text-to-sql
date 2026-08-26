import CryptoKit
import Foundation

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

struct ContextDelimitedIdentity {
  let contextKey: String

  init(parts: [String]) {
    // ruleid: creg-identity-requires-structured-components
    self.contextKey = parts.joined(separator: "|")
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

struct HashedDelimitedIdentity {
  let parts: [String]

  var snapshotKey: String {
    let encoded = parts.joined(separator: "|")
    // ruleid: creg-identity-requires-structured-components
    return SHA256.hash(data: Data(encoded.utf8)).description
  }
}

struct SwitchDelimitedIdentity {
  enum Mode {
    case enabled
    case disabled
  }

  let parts: [String]
  let mode: Mode

  var resultIdentity: String {
    switch mode {
    case .enabled:
      // ruleid: creg-identity-requires-structured-components
      parts.joined(separator: "|")
    case .disabled:
      "disabled"
    }
  }
}

struct SwitchIdentityWithDisplayWork {
  enum Mode {
    case enabled
    case disabled
  }

  let parts: [String]
  let mode: Mode
  let structuredIdentity: String

  var resultIdentity: String {
    switch mode {
    case .enabled:
      // ok: creg-identity-requires-structured-components
      let displayValue = parts.joined(separator: " | ")
      _ = displayValue
      structuredIdentity
    case .disabled:
      structuredIdentity
    }
  }
}

struct SwitchLocallyStagedDelimitedIdentity {
  enum Mode {
    case disabled
    case enabled
  }

  let parts: [String]
  let mode: Mode

  var snapshotKey: String {
    switch mode {
    case .disabled:
      "disabled"
    case .enabled:
      let encoded = parts.joined(separator: "|")
      // ruleid: creg-identity-requires-structured-components
      encoded
    }
  }
}

struct IfDelimitedIdentity {
  let parts: [String]
  let enabled: Bool

  var cacheIdentity: String {
    // ruleid: creg-identity-requires-structured-components
    if enabled {
      parts.joined(separator: "|")
    } else {
      "disabled"
    }
  }
}

struct DisplayOrUnrelatedSuffixNames {
  let parts: [String]

  var displayCacheKey: String {
    // ok: creg-identity-requires-structured-components
    parts.joined(separator: " | ")
  }

  var monkey: String {
    // ok: creg-identity-requires-structured-components
    parts.joined(separator: " | ")
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
