import CREGEngine
import ComposableArchitecture
import SwiftUI

#if canImport(MessageUI)
  import MessageUI
#endif

/// Settings: Developer Mode, model/build information, privacy/about content,
/// and the complete Support Bundle email export.
struct SettingsView: View {
  @Bindable var store: StoreOf<AppFeature>
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

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

        if case .failed(let failure) = store.modelReadiness {
          Section("SQL model preparation") {
            ModelPreparationFailureBanner(
              failure: failure,
              developerMode: store.developerMode,
              retry: { store.send(.retryPreparation) },
              retryCompatibility:
                store.developerMode && failure.allowsCompatibilityRetry
                ? { store.send(.retryCompatibilityPreparation) } : nil)
          }
        }

        Section {
          Toggle("Developer mode", isOn: $store.developerMode)
        } footer: {
          Text(
            "Shows generated SQL, per-stage internals, and expandable technical error details. Normal mode keeps those details private."
          )
        }

        appearanceSection

        if store.supportsAlternateIcons {
          AppIconSection(store: store)
        }

        Section("Model & build") {
          LabeledContent("App version", value: Self.appVersion)
          LabeledContent("Build", value: Self.buildNumber)
          LabeledContent("SQL model", value: Self.modelIdentity.key)
          LabeledContent(
            "Model revision",
            value: String(Self.modelIdentity.revision.prefix(12)))
          LabeledContent("Build channel", value: Self.buildChannel)
          LabeledContent(
            "Runtime mode",
            value: store.modelPreparationReport?.mode.rawValue ?? "not ready")
          if let identity = store.debugModelIdentity {
            LabeledContent("Debug candidate", value: identity.baseModelKey)
            LabeledContent(
              "Training run",
              value: String(identity.trainingRunID.suffix(8)))
          }
        }

        Section("Privacy & about") {
          Text(
            "CREG answers portfolio questions fully on device. Conversations, drafts, and diagnostics never leave this iPhone unless you explicitly share or email an export."
          )
          .font(.footnote)
          Text(
            "The bundled portfolio snapshot is fixed as of \(PortfolioAsOfDateDisplay.text). Answers about “now” reflect that snapshot, not today’s date."
          )
          .font(.footnote)
          .foregroundStyle(.secondary)
        }

        Section {
          Button {
            store.send(.supportBundleExportTapped)
          } label: {
            if store.isBuildingSupportBundle {
              HStack(spacing: 8) {
                ProgressView()
                Text("Assembling support bundle…")
              }
            } else {
              Label(
                "Email complete support bundle",
                systemImage: "envelope.badge")
            }
          }
          .disabled(store.isBuildingSupportBundle)
        } footer: {
          Text(
            "Creates a ZIP with your conversation history, drafts, feedback, sanitized diagnostics, and model/build manifests — not the model weights or the portfolio database. It contains your questions and result data; review before sending."
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
      .sheet(
        item: Binding(
          get: { store.supportBundleExport },
          set: { if $0 == nil { store.send(.supportBundleDismissed) } })
      ) { export in
        SupportBundleSendView(export: export)
      }
    }
  }

  /// The theme override. `.system` is the default and the app ships no
  /// `UIUserInterfaceStyle`, so leaving this alone means CREG follows iOS.
  private var appearanceSection: some View {
    Section {
      if dynamicTypeSize.isAccessibilitySize {
        Picker(
          "Theme",
          selection: appearanceBinding
        ) {
          appearanceChoices
        }
        .pickerStyle(.inline)
      } else {
        Picker(
          "Theme",
          selection: appearanceBinding
        ) {
          appearanceChoices
        }
        .pickerStyle(.segmented)
        .labelsHidden()
      }
    } header: {
      Text("Appearance")
    } footer: {
      Text(
        "System follows your iPhone’s Light/Dark setting, including its automatic schedule. Light and Dark pin CREG to that theme instead."
      )
    }
  }

  private var appearanceBinding: Binding<AppearancePreference> {
    Binding(
      get: { store.appearance },
      set: { store.send(.appearanceSelected($0)) })
  }

  @ViewBuilder
  private var appearanceChoices: some View {
    ForEach(AppearancePreference.allCases, id: \.self) { preference in
      Text(preference.title).tag(preference)
    }
  }

  static var appVersion: String {
    Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
      ?? "unknown"
  }

  static var buildNumber: String {
    Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"
  }

  static var modelIdentity: (key: String, revision: String) {
    SupportBundleBuilder.bundledModelIdentity()
  }

  static var buildChannel: String {
    (try? BuildChannel.load().rawValue) ?? "invalid"
  }
}

enum PortfolioAsOfDateDisplay {
  static var text: String { CREGEngine.PortfolioSnapshot.asOfDate }
}

extension AppFeature.SupportBundleExport: Identifiable {
  public var id: URL { url }
}

/// Pre-addressed Mail composition for the Support Bundle, with a share-sheet
/// fallback when Mail is unavailable.
struct SupportBundleSendView: View {
  let export: AppFeature.SupportBundleExport
  @Environment(\.dismiss) private var dismiss

  static let supportAddress = "harold.martin@gmail.com"
  static let sensitiveContentsWarning =
    "This bundle contains your portfolio questions, results, drafts, and diagnostics. Send it only if you are comfortable sharing that data with support."

  var body: some View {
    #if canImport(MessageUI)
      if MFMailComposeViewController.canSendMail() {
        MailComposerView(export: export, dismiss: { dismiss() })
          .ignoresSafeArea()
      } else {
        fallback
      }
    #else
      fallback
    #endif
  }

  private var fallback: some View {
    VStack(spacing: 16) {
      Image(systemName: "envelope.badge")
        .font(.largeTitle)
        .foregroundStyle(CREGBrand.blue)
      Text("Mail isn’t configured on this iPhone")
        .font(.headline)
      Text(
        "Share the bundle another way and send it to \(Self.supportAddress). \(Self.sensitiveContentsWarning)"
      )
      .font(.footnote)
      .foregroundStyle(.secondary)
      .multilineTextAlignment(.center)
      ShareLink(item: export.url) {
        Label("Share support bundle", systemImage: "square.and.arrow.up")
          .frame(maxWidth: .infinity)
      }
      .buttonStyle(.borderedProminent)
      Button("Done") { dismiss() }
    }
    .padding(24)
    .presentationDetents([.medium])
  }
}

#if canImport(MessageUI)
  struct MailComposerView: UIViewControllerRepresentable {
    let export: AppFeature.SupportBundleExport
    let dismiss: () -> Void

    func makeUIViewController(context: Context) -> MFMailComposeViewController {
      let controller = MFMailComposeViewController()
      controller.mailComposeDelegate = context.coordinator
      controller.setToRecipients([SupportBundleSendView.supportAddress])
      controller.setSubject(
        "CREG support bundle · \(export.manifest.appVersion) (\(export.manifest.buildNumber))")
      controller.setMessageBody(
        """
        A complete CREG support bundle is attached.

        ⚠️ \(SupportBundleSendView.sensitiveContentsWarning)

        Conversations: \(export.manifest.conversationCount)
        Messages: \(export.manifest.messageCount)
        Model: \(export.manifest.modelKey) @ \(export.manifest.modelRevision.prefix(12))
        Build channel: \(export.manifest.buildChannel)
        Runtime mode: \(export.manifest.runtimeMode.rawValue)
        Evaluated: \(export.manifest.isEvaluated)
        """,
        isHTML: false)
      if let data = try? Data(contentsOf: export.url) {
        controller.addAttachmentData(
          data,
          mimeType: "application/zip",
          fileName: "creg-support-bundle.zip")
      }
      return controller
    }

    func updateUIViewController(
      _ uiViewController: MFMailComposeViewController, context: Context
    ) {}

    func makeCoordinator() -> Coordinator {
      Coordinator(dismiss: dismiss)
    }

    final class Coordinator: NSObject, MFMailComposeViewControllerDelegate {
      let dismiss: () -> Void

      init(dismiss: @escaping () -> Void) {
        self.dismiss = dismiss
      }

      func mailComposeController(
        _ controller: MFMailComposeViewController,
        didFinishWith result: MFMailComposeResult,
        error: (any Error)?
      ) {
        dismiss()
      }
    }
  }
#endif
