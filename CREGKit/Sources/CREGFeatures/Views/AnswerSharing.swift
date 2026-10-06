import Observation
import SwiftUI

struct AnswerShare: Identifiable, Equatable {
  let id: UUID
  let markdown: String
}

/// Lives with ChatView, outside its lazy transcript. A request captures the
/// export at the tap and belongs to one completed More dismissal.
@MainActor @Observable
final class AnswerShareCoordinator {
  struct Request {
    var conversationID: UUID
    var moreID: UUID
    var share: AnswerShare
  }
  private(set) var pending: Request?
  var presented: AnswerShare?

  func request(conversationID: UUID, moreID: UUID, markdown: String) {
    guard presented == nil else { return }
    pending = Request(
      conversationID: conversationID, moreID: moreID,
      share: AnswerShare(id: moreID, markdown: markdown))
  }
  func moreDidDismiss(_ moreID: UUID) {
    guard let pending, pending.moreID == moreID else { return }
    self.pending = nil
    presented = pending.share
  }
  func reset() {
    pending = nil
    presented = nil
  }
}

#if canImport(UIKit)
  import UIKit

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
