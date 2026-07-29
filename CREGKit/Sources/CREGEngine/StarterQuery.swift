import Foundation

/// The fixed date represented by the bundled portfolio snapshot. Relative
/// product queries use this value rather than the device clock.
public enum PortfolioSnapshot {
  public static let asOfDate = "2026-07-01"
  public static let nextTwelveMonthsEndExclusive = "2027-07-01"
}

/// A reviewed, versioned product query shown on the empty chat surface.
///
/// Raw values are persisted in telemetry. Add a new case when query semantics
/// change instead of reusing an existing identifier with different meaning.
public enum StarterQueryID: String, CaseIterable, Sendable, Equatable, Hashable,
  Codable, Identifiable
{
  case highestVacancyV1 = "highest-vacancy-v1"
  case rentRollByPropertyTypeV1 = "rent-roll-by-property-type-v1"
  case leaseExpirationsNextTwelveMonthsV1 =
    "lease-expirations-next-twelve-months-v1"

  public var id: String { rawValue }

  public var question: String {
    switch self {
    case .highestVacancyV1:
      "Which properties have the highest vacancy?"
    case .rentRollByPropertyTypeV1:
      "What's my rent roll by property type?"
    case .leaseExpirationsNextTwelveMonthsV1:
      "Which leases expire in the next 12 months?"
    }
  }

  /// Human-reviewable meaning, deliberately separate from display copy.
  public var semantics: String {
    switch self {
    case .highestVacancyV1:
      "Five held properties with the highest vacancy at each property's latest financial snapshot."
    case .rentRollByPropertyTypeV1:
      "Annual base rent from Active or Holdover leases at held properties, grouped by property type."
    case .leaseExpirationsNextTwelveMonthsV1:
      "Active leases at held properties expiring on or after \(PortfolioSnapshot.asOfDate) and before \(PortfolioSnapshot.nextTwelveMonthsEndExclusive), listed with tenant and property identity."
    }
  }

  public var sql: String {
    switch self {
    case .highestVacancyV1:
      """
      SELECT p.name AS property, 1 - f.occupancy_rate AS vacancy_rate
      FROM properties p
      JOIN property_financials f ON f.property_id = p.property_id
      WHERE p.status != 'Sold'
        AND f.period_end = (
          SELECT MAX(pf.period_end)
          FROM property_financials pf
          WHERE pf.property_id = p.property_id
        )
      ORDER BY vacancy_rate DESC, p.name
      LIMIT 5
      """
    case .rentRollByPropertyTypeV1:
      """
      SELECT p.property_type, SUM(l.annual_base_rent) AS annual_rent_roll
      FROM leases l
      JOIN properties p ON p.property_id = l.property_id
      WHERE p.status != 'Sold'
        AND l.status IN ('Active', 'Holdover')
      GROUP BY p.property_type
      ORDER BY annual_rent_roll DESC, p.property_type
      """
    case .leaseExpirationsNextTwelveMonthsV1:
      """
      SELECT l.lease_id, t.name AS tenant, p.name AS property, l.suite,
             l.expiration_date, l.status
      FROM leases l
      JOIN tenants t ON t.tenant_id = l.tenant_id
      JOIN properties p ON p.property_id = l.property_id
      WHERE p.status != 'Sold'
        AND l.status = 'Active'
        AND l.expiration_date >= '\(PortfolioSnapshot.asOfDate)'
        AND l.expiration_date < '\(PortfolioSnapshot.nextTwelveMonthsEndExclusive)'
      ORDER BY l.expiration_date, t.name, p.name, l.lease_id
      """
    }
  }
}
