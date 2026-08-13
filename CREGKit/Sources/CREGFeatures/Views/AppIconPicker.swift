import ComposableArchitecture
import SwiftUI

/// Settings' app-icon chooser.
///
/// The swatches are drawn rather than shipped as images: a `.icon` document is
/// compiled into the asset catalog and cannot be read back at runtime, so any
/// bundled preview would be a second copy of the artwork to keep in sync. A
/// chip carrying the ground and the three chart segments is what actually
/// distinguishes the three icons.
struct AppIconSection: View {
  let store: StoreOf<AppFeature>
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  var body: some View {
    Section {
      let pickerLayout = dynamicTypeSize.isAccessibilitySize
        ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
        : AnyLayout(HStackLayout(spacing: 18))
      pickerLayout {
        ForEach(AppIconVariant.allCases, id: \.self) { variant in
          Button {
            store.send(.appIconSelected(variant))
          } label: {
            AppIconSwatch(
              variant: variant,
              isSelected: store.appIcon == variant)
          }
          .buttonStyle(.plain)
          .frame(maxWidth: dynamicTypeSize.isAccessibilitySize ? .infinity : nil, alignment: .leading)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.vertical, 4)
    } header: {
      Text("App icon")
    } footer: {
      Text(
        "iOS shows a confirmation alert whenever an app changes its icon. The choice applies to the Home Screen immediately."
      )
    }
  }
}

private struct AppIconSwatch: View {
  let variant: AppIconVariant
  let isSelected: Bool
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  private var shape: RoundedRectangle {
    RoundedRectangle(cornerRadius: 15, style: .continuous)
  }

  var body: some View {
    let swatchLayout = dynamicTypeSize.isAccessibilitySize
      ? AnyLayout(HStackLayout(spacing: 12))
      : AnyLayout(VStackLayout(spacing: 6))
    swatchLayout {
      shape
        .fill(
          LinearGradient(
            colors: variant.groundColors,
            startPoint: .top,
            endPoint: .bottom)
        )
        .frame(width: 64, height: 64)
        .overlay { AppIconSwatchMark(variant: variant) }
        .overlay {
          shape.strokeBorder(
            isSelected ? CREGBrand.blue : Color.primary.opacity(0.12),
            lineWidth: isSelected ? 3 : 1)
        }
        .overlay(alignment: .bottomTrailing) {
          if isSelected {
            Image(systemName: "checkmark.circle.fill")
              .font(.title3)
              .symbolRenderingMode(.palette)
              .foregroundStyle(.white, CREGBrand.blue)
              .offset(x: 6, y: 6)
          }
        }
      Text(variant.title)
        .font(.caption2)
        .foregroundStyle(isSelected ? .primary : .secondary)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(variant.title)
    .accessibilityValue(isSelected ? "Selected" : "Not selected")
    .accessibilityAddTraits(isSelected ? .isSelected : [])
  }
}

/// A miniature of the icon's Q: the three-segment donut that is the only thing
/// separating one palette from another.
private struct AppIconSwatchMark: View {
  let variant: AppIconVariant

  var body: some View {
    let colors = variant.segmentColors
    let span = 1.0 / Double(colors.count)
    ZStack {
      ForEach(colors.indices, id: \.self) { index in
        Circle()
          .trim(
            from: Double(index) * span + 0.018,
            to: Double(index + 1) * span - 0.018)
          .stroke(
            colors[index],
            style: StrokeStyle(lineWidth: 9, lineCap: .butt))
          .rotationEffect(.degrees(-90))
      }
    }
    .frame(width: 30, height: 30)
  }
}

extension AppIconVariant {
  /// Mirrors the palettes in `tools/make_app_icons.py`; change one and change
  /// the other, or the chooser starts lying about what it will apply.
  var groundColors: [Color] {
    switch self {
    case .midnight, .midnightGold:
      [
        Color(red: 0.086, green: 0.188, blue: 0.310),
        Color(red: 0.024, green: 0.051, blue: 0.110),
      ]
    case .indigo:
      [
        Color(red: 0.227, green: 0.227, blue: 0.502),
        Color(red: 0.102, green: 0.102, blue: 0.271),
      ]
    }
  }

  var segmentColors: [Color] {
    switch self {
    case .midnight:
      [
        CREGBrand.turquoise,
        CREGBrand.blue,
        Color(red: 0.557, green: 0.482, blue: 0.961),
      ]
    case .indigo:
      [
        CREGBrand.blue,
        Color(red: 0.184, green: 0.851, blue: 0.753),
        Color(red: 0.910, green: 0.725, blue: 0.231),
      ]
    case .midnightGold:
      [
        CREGBrand.turquoise,
        CREGBrand.blue,
        Color(red: 0.910, green: 0.725, blue: 0.231),
      ]
    }
  }
}
