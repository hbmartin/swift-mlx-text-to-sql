import CREGEngine
import SwiftUI

/// Renders a query result inline in the transcript: horizontally scrollable
/// grid, paged vertically with a "Show more" affordance.
struct ResultTableView: View {
  let result: QueryResult

  @State private var visibleRows = ResultTableView.pageSize
  private static let pageSize = 20

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      if result.rows.isEmpty {
        Text("No matching rows.")
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .padding(10)
      } else {
        ScrollView(.horizontal, showsIndicators: true) {
          Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
            GridRow {
              ForEach(result.columns, id: \.self) { column in
                Text(column)
                  .font(.caption.weight(.semibold))
                  .foregroundStyle(.secondary)
              }
            }
            Divider()
            ForEach(Array(result.rows.prefix(visibleRows).enumerated()), id: \.offset) { _, row in
              GridRow {
                ForEach(Array(row.enumerated()), id: \.offset) { index, value in
                  Text(
                    PortfolioValueFormatting.displayString(
                      for: value,
                      column: index < result.columns.count
                        ? result.columns[index] : "")
                  )
                  .font(.caption.monospacedDigit())
                  .lineLimit(1)
                }
              }
            }
          }
          .padding(10)
        }
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))

        HStack(spacing: 12) {
          Text(footerText)
            .font(.caption2)
            .foregroundStyle(.tertiary)
          if visibleRows < result.rowCount {
            Button("Show more") {
              visibleRows += Self.pageSize
            }
            .font(.caption2)
          }
          Spacer(minLength: 0)
          Menu {
            Button("Copy as CSV") {
              Pasteboard.copy(result.csvString())
            }
            Button("Copy as Markdown") {
              Pasteboard.copy(result.markdownTableString())
            }
          } label: {
            Image(systemName: "doc.on.doc")
              .font(.caption)
          }
          .accessibilityLabel("Copy table")
          ShareLink(item: result.csvString()) {
            Image(systemName: "square.and.arrow.up")
              .font(.caption)
          }
          .accessibilityLabel("Share table as CSV")
        }
      }
    }
  }

  private var footerText: String {
    let total = "\(result.rowCount)\(result.isTruncated ? "+" : "")"
    if visibleRows < result.rowCount {
      return "Showing \(visibleRows) of \(total) rows"
    }
    return "\(total) row\(result.rowCount == 1 ? "" : "s")"
  }
}
