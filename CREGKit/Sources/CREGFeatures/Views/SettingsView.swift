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
  @State private var presentedSupportID: UUID?

  var body: some View {
    NavigationStack {
      Form {
        if !store.visibleFailures.isEmpty {
          Section {
            OwnedFailureBanners(failures: store.visibleFailures, developerMode: store.developerMode,
              dismiss: { store.send(.dismissOwnedFailure($0)) },
              retryableWriteOwners: store.retryableConversationWriteOwners,
              retrySaving: { store.send(.retryConversationWrites($0)) })
            if store.visibleFailures.contains(where: { $0.failure.recovery == .retryHistory }) {
              RetryHistoryButton(isLoading: store.historySummaryPhase.isLoading,
                retry: { store.send(.retryHistoryTapped) }, isRetry: store.historyLoadIsRetry, isSlow: store.slowHistoryRequestID != nil)
            }
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

        appearanceSection

        if store.supportsAlternateIcons {
          AppIconSection(store: store)
        }

        Section("Privacy & about") {
          Text("CREG answers portfolio questions on your iPhone.")
          Text("Conversations, drafts, and diagnostics stay on device unless you share an export.")
            .foregroundStyle(.secondary)
          PortfolioSnapshotContextView()
        }

        Section {
          Toggle("Developer mode", isOn: $store.developerMode)
        } header: {
          Text("Advanced")
        } footer: {
          Text("Shows generated SQL and detailed diagnostics in conversations.")
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
          .disabled(store.isBuildingSupportBundle || store.supportBundleExport != nil)
        } footer: {
          Text(
            "Includes all stored conversations: questions, results, generated SQL, drafts, answer feedback and corrections, event history, diagnostics, and a full history database snapshot. Review the ZIP before sending."
          )
        }

        #if DEBUG
          answerabilityDebugSection
        #endif
      }
      .accessibilityIdentifier("settings-scroll")
      .navigationTitle("Settings")
      .inlineNavigationTitle()
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { store.isSettingsPresented = false }
        }
      }
      .sheet(
        item: Binding(
          get: {
            store.supportBundleExport.flatMap {
              store.supportBundlePresentationID == $0.requestID ? $0 : nil
            }
          },
          set: { value in
            if value == nil, let id = presentedSupportID ?? store.supportBundlePresentationID {
              presentedSupportID = id
              store.send(.supportBundleDismissalRequested(id))
            }
          }),
        onDismiss: {
          if let id = presentedSupportID ?? store.supportBundleDismissalID {
            store.send(.supportBundleDismissed(id))
          }
          presentedSupportID = nil
        }
      ) { export in
        SupportBundleSendView(export: export)
          .cregPresentedSurfaceProbe()
          .environment(\.dynamicTypeSize, dynamicTypeSize)
          .onAppear { presentedSupportID = export.requestID }
      }
    }
  }

  #if DEBUG
    private var answerabilityDebugSection: some View {
      Section {
        Button {
          store.send(.answerabilityCaptureTapped)
        } label: {
          if store.isCapturingAnswerability {
            HStack(spacing: 8) {
              ProgressView()
              Text("Capturing scope verdicts…")
            }
          } else {
            Label("Capture answerability verdicts", systemImage: "checklist")
          }
        }
        .disabled(
          store.isCapturingAnswerability
            || store.fmAvailability != .available
            || !store.isInferenceIdle)
        if let export = store.answerabilityCaptureExport {
          ShareLink(item: export) {
            Label("Share capture", systemImage: "square.and.arrow.up")
          }
        }
      } header: {
        Text("Answerability (debug)")
      } footer: {
        if store.fmAvailability == .available {
          Text(
            "Runs the complete bundled answerability corpus through the on-device Foundation Model and exports the verdicts for the offline scorer (docs/eval.md)."
          )
        } else {
          Text(
            "Apple Intelligence must be available to capture the complete answerability corpus."
          )
        }
      }
    }
  #endif

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
      Text("System follows your iPhone’s appearance.")
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
  static let text = PortfolioValueFormatting.formattedISODate(CREGEngine.PortfolioSnapshot.asOfDate)
    ?? CREGEngine.PortfolioSnapshot.asOfDate
}

extension AppFeature.SupportBundleExport: Identifiable {
  public var id: UUID { requestID }
}

/// Pre-addressed Mail composition for the Support Bundle, with a share-sheet
/// fallback when Mail is unavailable.
struct SupportBundleSendView: View {
  let export: AppFeature.SupportBundleExport
  @Environment(\.dismiss) private var dismiss

  static let supportAddress = "harold.martin@gmail.com"
  static let sensitiveContentsWarning =
    "This bundle contains all stored conversations, including your portfolio questions, results, generated SQL, drafts, answer feedback and corrections, event history, diagnostics, and a full history database snapshot. Send it only if you are comfortable sharing that data with support."

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
    var view = SupportBundleFallbackView(url: export.url, done: { dismiss() })
    #if DEBUG && canImport(MessageUI)
      if case .scenario(let configuration) = AccessibilityUITestConfiguration.currentRequest,
        configuration.scenario == .supportBundleDismissal
      {
        view.simulatedMailCompletion = { sent in
          MailComposerView.Coordinator(dismiss: { dismiss() })
            .finish(result: sent ? .sent : .cancelled)
        }
      }
    #endif
    return view.accessibilityIdentifier("ui-test-support-bundle-fallback")
  }
}

struct SupportBundleFallbackView: View {
  let url: URL
  var done: () -> Void
  #if DEBUG
    var simulatedMailCompletion: ((Bool) -> Void)? = nil
  #endif

  var body: some View {
    ScrollView {
      VStack(spacing: 16) {
        Image(systemName: "envelope.badge")
          .font(.largeTitle)
          .foregroundStyle(CREGBrand.blue)
        Text("Mail isn’t configured on this iPhone")
          .font(.headline)
          .fixedSize(horizontal: false, vertical: true)
          .multilineTextAlignment(.center)
          .frame(maxWidth: .infinity)
        Text(
          "Share the bundle another way and send it to \(SupportBundleSendView.supportAddress). \(SupportBundleSendView.sensitiveContentsWarning)"
        )
        .font(.footnote)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity)
        .accessibilityIdentifier("support-bundle-warning")
        ShareLink(item: url) {
          Label {
            Text("Share support bundle")
              .fixedSize(horizontal: false, vertical: true)
              .multilineTextAlignment(.center)
          } icon: {
            Image(systemName: "square.and.arrow.up")
          }
          .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.borderedProminent)
        Button(action: done) {
          Text("Done").frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.bordered)
        #if DEBUG
          if let simulatedMailCompletion {
            Button("Mail Cancel") { simulatedMailCompletion(false) }
              .accessibilityIdentifier("support-mail-cancel").cregTextButtonLabelTarget()
            Button("Mail Send") { simulatedMailCompletion(true) }
              .accessibilityIdentifier("support-mail-send").cregTextButtonLabelTarget()
          }
        #endif
      }
      .padding(24)
      .frame(maxWidth: .infinity)
    }
    .presentationDetents([.large])
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
        finish(result: result)
      }

      func finish(result: MFMailComposeResult) {
        dismiss()
      }
    }
  }
#endif
