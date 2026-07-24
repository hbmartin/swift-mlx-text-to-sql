import CREGEngine
import Foundation

/// Column-aware display formatting for the frozen CREG portfolio schema:
/// dollars, fraction rates as percents, square feet, DSCR ratios, ungrouped
/// years/identifiers, and ISO dates. Display-only — canonical result
/// identity, voting, and CSV export never see these strings. Output is
/// deterministic en-US so unit tests hold across device locales.
public enum PortfolioValueFormatting {
  enum Style {
    /// Years and identifiers: digits without grouping ("2019", not "2,019").
    case plainDigits
    /// Counts such as `term_months`: default numeric display.
    case count
    case currency
    /// `*_psf` columns: dollars per square foot.
    case currencyPerSquareFoot
    case squareFeet
    /// Rates stored as 0–1 fractions in the schema (ltv, occupancy_rate,
    /// interest_rate, *_pct, target_irr, cap_rate).
    case percent
    /// DSCR-style coverage multiples.
    case ratio
    case date
    case plain
  }

  public static func displayString(for value: SQLValue, column: String) -> String {
    switch value {
    case .null, .blob:
      return value.displayString
    case .text(let text):
      guard style(forColumn: column) == .date,
        let formatted = formattedISODate(text)
      else { return text }
      return formatted
    case .integer(let integer):
      guard abs(integer) < 1_000_000_000_000 else { return value.displayString }
      return formattedNumeric(Double(integer), isWhole: true, column: column)
        ?? value.displayString
    case .real(let real):
      guard abs(real) < 1e15 else { return value.displayString }
      return formattedNumeric(real, isWhole: real == real.rounded(), column: column)
        ?? value.displayString
    }
  }

  // MARK: - Column classification

  /// Matches the frozen schema's column names inside arbitrary result labels
  /// ("avg(occupancy_rate)", "total_noi"). Order resolves overlaps:
  /// months before rent (`free_rent_months`), psf before currency
  /// (`base_rent_psf`), currency before percent (`vacancy_loss`).
  static func style(forColumn label: String) -> Style {
    let normalized = label.lowercased()
    func has(_ hints: String...) -> Bool {
      hints.contains { containsWord(normalized, word: $0) }
    }

    if has("id") { return .plainDigits }
    if has("year") { return .plainDigits }
    if has("month", "months", "floor", "floors") { return .count }
    if has("psf") { return .currencyPerSquareFoot }
    if has("sqft", "sf", "square") { return .squareFeet }
    if has("dscr") { return .ratio }
    if has("date", "period_end", "maturity", "inception") { return .date }
    if has(
      "value", "price", "rent", "balance", "income", "expense", "expenses",
      "capital", "deposit", "noi", "capex", "loss", "allowance",
      "debt_service", "irr_dollars")
    {
      return .currency
    }
    if has(
      "rate", "pct", "irr", "ltv", "occupancy", "vacancy", "escalation")
    {
      return .percent
    }
    return .plain
  }

  /// True when `word` occurs in `label` bounded by non-alphanumerics, so
  /// "rate" matches "avg(cap_rate)" but not "credit_rating".
  static func containsWord(_ label: String, word: String) -> Bool {
    var search = label.startIndex
    while let range = label.range(of: word, range: search..<label.endIndex) {
      let beforeOK =
        range.lowerBound == label.startIndex
        || !label[label.index(before: range.lowerBound)].isWordCharacter
      let afterOK =
        range.upperBound == label.endIndex
        || !label[range.upperBound].isWordCharacter
      if beforeOK && afterOK { return true }
      search = label.index(after: range.lowerBound)
    }
    return false
  }

  // MARK: - Numeric styles

  static func formattedNumeric(
    _ value: Double, isWhole: Bool, column: String
  ) -> String? {
    switch style(forColumn: column) {
    case .plainDigits:
      guard isWhole else { return nil }
      return String(Int64(value))
    case .currency:
      return currencyString(value, fractionDigits: isWhole ? 0 : 2)
    case .currencyPerSquareFoot:
      return currencyString(value, fractionDigits: 2) + "/sf"
    case .squareFeet:
      return grouped(abs(value), fractionDigits: 0)
        .withSign(of: value) + " sf"
    case .percent:
      return percentString(value)
    case .ratio:
      return String(format: "%.2f", value) + "×"
    case .count, .date, .plain:
      return nil
    }
  }

  static func currencyString(_ value: Double, fractionDigits: Int) -> String {
    (value < 0 ? "-$" : "$") + grouped(abs(value), fractionDigits: fractionDigits)
  }

  /// Values at or below 1.5 are the schema's 0–1 fractions and scale by 100;
  /// larger values are treated as already being percent points, so a query's
  /// explicit `* 100` still renders correctly.
  static func percentString(_ value: Double) -> String {
    let points = abs(value) <= 1.5 ? value * 100 : value
    let rounded = (points * 100).rounded() / 100
    if rounded == rounded.rounded() && abs(rounded) < 1e15 {
      return String(Int64(rounded)) + "%"
    }
    return "\(rounded)%"
  }

  /// Deterministic en-US grouping ("12,400"); `value` must be non-negative.
  static func grouped(_ value: Double, fractionDigits: Int) -> String {
    let formatted = String(format: "%.\(fractionDigits)f", value)
    let parts = formatted.split(separator: ".", maxSplits: 1)
    var digits = Array(parts[0])
    var index = digits.count - 3
    while index > 0 {
      digits.insert(",", at: index)
      index -= 3
    }
    let wholePart = String(digits)
    return parts.count == 2 ? wholePart + "." + parts[1] : wholePart
  }

  // MARK: - Dates

  /// Renders schema ISO dates ("2015-03-01" → "Mar 1, 2015", "2015-03" →
  /// "Mar 2015"). Anything else passes through unchanged.
  static func formattedISODate(_ text: String) -> String? {
    let parts = text.split(separator: "-")
    guard
      (2...3).contains(parts.count),
      parts[0].count == 4,
      let year = Int(parts[0]),
      let month = Int(parts[1]),
      (1...12).contains(month)
    else { return nil }
    let monthName = Self.monthNames[month - 1]
    guard parts.count == 3 else { return "\(monthName) \(year)" }
    guard let day = Int(parts[2]), (1...31).contains(day) else { return nil }
    return "\(monthName) \(day), \(year)"
  }

  private static let monthNames = [
    "Jan", "Feb", "Mar", "Apr", "May", "Jun",
    "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
  ]
}

extension Character {
  fileprivate var isWordCharacter: Bool { isLetter || isNumber }
}

extension String {
  fileprivate func withSign(of value: Double) -> String {
    value < 0 ? "-" + self : self
  }
}
