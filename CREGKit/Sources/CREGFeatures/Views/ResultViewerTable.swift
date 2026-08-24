import AutoTableCharts
import CREGEngine
import ComposableArchitecture
import SwiftUI

extension ResultViewerView {
  @ViewBuilder
  func searchable<Content: View>(_ content: Content) -> some View {
    #if os(iOS)
      content.searchable(
        text: $searchText,
        placement: .navigationBarDrawer(displayMode: .always),
        prompt: "Search rows")
    #else
      content.searchable(text: $searchText, prompt: "Search rows")
    #endif
  }

  func table(
    displayRows: [[SQLValue]],
    widths: [CGFloat]
  ) -> some View {
    ZStack(alignment: .top) {
      ScrollView(.horizontal) {
        VStack(alignment: .leading, spacing: 0) {
          headerRow(widths: widths)
          Divider()
          ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 0) {
              ForEach(Array(displayRows.enumerated()), id: \.offset) { entry in
                rowView(
                  entry.element,
                  displayIndex: entry.offset,
                  widths: widths)
              }
            }
          }
          .scrollDismissesKeyboard(.interactively)
        }
      }
      .scrollIndicators(.visible)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

      if searchIsActive && displayRows.isEmpty {
        noMatchesState
      }
    }
    .overlay(alignment: .bottom) { copyFeedback }
    .sensoryFeedback(.success, trigger: copyFeedbackTrigger)
    .task(id: copyFeedbackTrigger) {
      guard copyFeedbackTrigger > 0 else { return }
      let trigger = copyFeedbackTrigger
      try? await Task.sleep(for: .seconds(1.4))
      guard !Task.isCancelled, trigger == copyFeedbackTrigger else { return }
      withAnimation(reduceMotion ? nil : .smooth(duration: 0.2)) {
        copyFeedbackMessage = nil
      }
    }
  }

  func headerRow(widths: [CGFloat]) -> some View {
    HStack(alignment: .top, spacing: 0) {
      ForEach(Array(result.columns.enumerated()), id: \.offset) { index, column in
        Button {
          sort = ResultViewerLogic.toggleSort(sort, column: index)
        } label: {
          HStack(alignment: .top, spacing: 4) {
            Text(column)
              .font(textSize.headerFont)
              .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
              .multilineTextAlignment(.leading)
            if sort?.column == index {
              Image(
                systemName: sort?.ascending == true
                  ? "chevron.up" : "chevron.down"
              )
              .font(.caption2.weight(.bold))
              .contentTransition(.symbolEffect(.replace))
            }
          }
          .foregroundStyle(
            sort?.column == index ? CREGBrand.blue : Color.secondary
          )
          .padding(.horizontal, cellHorizontalPadding)
          .padding(.vertical, 8)
          .frame(width: widths[index], alignment: .leading)
          .frame(minHeight: 44, alignment: .topLeading)
          .contentShape(Rectangle())
          .overlay(alignment: .trailing) { Divider() }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
          sort?.column == index
            ? "Sort by \(column), \(sort?.ascending == true ? "ascending" : "descending")"
            : "Sort by \(column)")
      }
    }
    .padding(.horizontal, 10)
    .background(.thinMaterial)
    .animation(reduceMotion ? nil : .snappy(duration: 0.2), value: sort)
  }

  func rowView(
    _ row: [SQLValue],
    displayIndex: Int,
    widths: [CGFloat]
  ) -> some View {
    let rowIsSelected = selectedCell?.row == displayIndex
    return HStack(alignment: .top, spacing: 0) {
      ForEach(result.columns.indices, id: \.self) { index in
        let value: SQLValue = index < row.count ? row[index] : .null
        let column = result.columns[index]
        let displayed = ResultViewerLogic.displayedCopyValue(
          value, column: column)
        let raw = ResultViewerLogic.rawCopyValue(value)
        let selection = ResultCellSelection(row: displayIndex, column: index)
        let isSelected = selectedCell == selection

        Button {
          selectedCell = isSelected ? nil : selection
        } label: {
          Text(displayed)
            .font(textSize.cellFont)
            .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
            .multilineTextAlignment(.leading)
            .padding(.horizontal, cellHorizontalPadding)
            .frame(
              width: index < widths.count ? widths[index] : 120,
              alignment: .topLeading
            )
            .padding(.vertical, rowVerticalPadding)
            .background(
              isSelected ? CREGBrand.blue.opacity(0.14) : Color.clear
            )
            .overlay(alignment: .trailing) { Divider() }
            .overlay {
              if isSelected {
                RoundedRectangle(cornerRadius: 6)
                  .stroke(CREGBrand.blue, lineWidth: 2)
                  .padding(2)
              }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
          cellCopyActions(displayed: displayed, raw: raw, row: row)
        }
        .accessibilityLabel(
          "Row \(displayIndex + 1), \(column), \(displayed)"
        )
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityAction(named: "Copy value") {
          copy(displayed, confirmation: "Value copied")
        }
        .accessibilityAction(named: "Copy row as CSV") {
          copy(
            ResultViewerLogic.csvRowString(row),
            confirmation: "Row copied")
        }
      }
    }
    .padding(.horizontal, 10)
    .background(
      rowIsSelected
        ? CREGBrand.blue.opacity(0.06)
        : displayIndex.isMultiple(of: 2)
          ? Color.clear
          : Color.primary.opacity(0.035))
  }

  @ViewBuilder
  func cellCopyActions(
    displayed: String,
    raw: String,
    row: [SQLValue]
  ) -> some View {
    Button {
      copy(displayed, confirmation: "Value copied")
    } label: {
      Label("Copy Value", systemImage: "doc.on.doc")
    }
    if raw != displayed {
      Button {
        copy(raw, confirmation: "Raw value copied")
      } label: {
        Label("Copy Raw Value", systemImage: "number")
      }
    }
    Button {
      copy(
        ResultViewerLogic.csvRowString(row),
        confirmation: "Row copied")
    } label: {
      Label("Copy Row as CSV", systemImage: "tablecells")
    }
  }

  func selectionAccessory(
    _ selected: SelectedResultCell
  ) -> some View {
    let layout =
      dynamicTypeSize.isAccessibilitySize
      ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
      : AnyLayout(HStackLayout(alignment: .center, spacing: 12))
    return layout {
      VStack(alignment: .leading, spacing: 2) {
        Text("Row \(selected.selection.row + 1) · \(selected.columnName)")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
        Text(selected.displayedValue)
          .font(textSize.cellFont)
          .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
          .textSelection(.enabled)
      }
      if !dynamicTypeSize.isAccessibilitySize {
        Spacer(minLength: 0)
      }
      selectionActions(selected)
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 8)
    .background(.thinMaterial)
    .transition(
      reduceMotion
        ? .opacity
        : .opacity.combined(with: .move(edge: .bottom))
    )
    .animation(
      reduceMotion ? nil : .smooth(duration: 0.22),
      value: selectedCell)
  }

  func selectionActions(_ selected: SelectedResultCell) -> some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: 6) {
        selectionCopyButton(selected)
        selectionMoreMenu(selected)
        clearSelectionButton
      }
      VStack(alignment: .leading, spacing: 4) {
        selectionCopyButton(selected)
        selectionMoreMenu(selected)
        clearSelectionButton
      }
    }
  }

  func selectionCopyButton(
    _ selected: SelectedResultCell
  ) -> some View {
    Button {
      copy(selected.displayedValue, confirmation: "Value copied")
    } label: {
      Label("Copy Value", systemImage: "doc.on.doc")
        .cregTextButtonLabelTarget()
    }
    .buttonStyle(.borderedProminent)
  }

  func selectionMoreMenu(_ selected: SelectedResultCell) -> some View {
    Menu {
      if selected.rawValue != selected.displayedValue {
        Button {
          copy(selected.rawValue, confirmation: "Raw value copied")
        } label: {
          Label("Copy Raw Value", systemImage: "number")
        }
      }
      Button {
        copy(
          ResultViewerLogic.csvRowString(selected.row),
          confirmation: "Row copied")
      } label: {
        Label("Copy Row as CSV", systemImage: "tablecells")
      }
    } label: {
      Label("More", systemImage: "ellipsis.circle")
        .cregTextButtonLabelTarget()
    }
    .buttonStyle(.bordered)
  }

  var clearSelectionButton: some View {
    Button {
      selectedCell = nil
    } label: {
      Image(systemName: "xmark")
        .cregIconButtonTarget()
    }
    .buttonStyle(.plain)
    .accessibilityLabel("Clear cell selection")
    .cregLargeContentViewer("Clear selection", systemImage: "xmark")
  }

}
