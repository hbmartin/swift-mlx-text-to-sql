import SwiftUI

#if canImport(UIKit)
  import UIKit

  struct AnswerShare: Identifiable {
    let id = UUID()
    let markdown: String
  }

  struct AnswerActivitySheet: UIViewControllerRepresentable {
    let markdown: String
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIActivityViewController {
      let controller = UIActivityViewController(
        activityItems: [markdown], applicationActivities: nil)
      controller.completionWithItemsHandler = { _, _, _, _ in dismiss() }
      return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
  }

  /// SwiftUI's content disappearance can precede the popover transition.
  /// UIKit's completed disappearance lets the row present sharing afterward.
  struct AnswerMoreDismissalObserver: UIViewControllerRepresentable {
    let didDismiss: () -> Void

    func makeUIViewController(context: Context) -> ObserverController {
      let controller = ObserverController()
      controller.didDismiss = didDismiss
      return controller
    }

    func updateUIViewController(_ controller: ObserverController, context: Context) {
      controller.didDismiss = didDismiss
    }

    final class ObserverController: UIViewController {
      var didDismiss: (() -> Void)?

      override func loadView() {
        view = UIView()
      }

      override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        didDismiss?()
      }
    }
  }
#endif
