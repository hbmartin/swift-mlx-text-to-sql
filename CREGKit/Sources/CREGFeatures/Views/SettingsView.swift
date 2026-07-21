import ComposableArchitecture
import SwiftUI

struct SettingsView: View {
  @Bindable var store: StoreOf<ChatFeature>

  var body: some View {
    NavigationStack {
      Form {
        if let failure = store.presentedFailure {
          Section {
            FailureBanner(
              failure: failure,
              developerMode: store.developerMode,
              dismiss: { store.send(.dismissFailure) })
          }
        }

        Section {
          Toggle("Developer mode", isOn: $store.developerMode)
        } footer: {
          Text(
            "Shows generated SQL, per-stage internals, and expandable technical error details. Normal mode keeps those details private."
          )
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
          Text(
            "Structured JSONL for offline accuracy analysis. Exports include questions, generated SQL, errors, and full result rows; treat them as portfolio data."
          )
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
