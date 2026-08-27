import AutoTableCharts
import CREGEngine
import ComposableArchitecture
import Foundation
import SwiftUI

#if DEBUG
#Preview("Settings — App Icon Picker") {
  SettingsView(store: PreviewFixtures.appStore(PreviewFixtures.settingsState()))
}

#Preview("Settings — App Icon Picker — Dark") {
  SettingsView(store: PreviewFixtures.appStore(PreviewFixtures.settingsState()))
    .preferredColorScheme(.dark)
}
#endif
