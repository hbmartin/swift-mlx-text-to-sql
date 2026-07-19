import ComposableArchitecture
import SwiftUI

struct SettingsView: View {
  @Bindable var store: StoreOf<ChatFeature>

  var body: some View {
    NavigationStack {
      Form {
        Section {
          Toggle("Developer mode", isOn: $store.developerMode)
        } footer: {
          Text("Shows the generated SQL and per-stage internals under each answer.")
        }

        Section {
          Button {
            store.send(.exportTapped)
          } label: {
            Label("Export session logs", systemImage: "square.and.arrow.up")
          }
          if let url = store.exportURL {
            ShareLink(item: url) {
              Label("Share exported logs", systemImage: "doc.text")
            }
          }
        } footer: {
          Text("Structured JSONL event logs for offline accuracy analysis.")
        }
      }
      .navigationTitle("Settings")
      .inlineNavigationTitle()
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { store.isSettingsPresented = false }
        }
      }
    }
  }
}
