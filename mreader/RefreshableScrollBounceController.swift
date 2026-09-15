import SwiftUI
import UIKit

/// SwiftUI's `.refreshable` installs a `UIRefreshControl` and can force vertical
/// bouncing even when a parent uses `.scrollBounceBehavior(.basedOnSize)`.
/// The three root shelf pages all use `.refreshable`, which is why the previous
/// SwiftUI-only fix did not stop the large pull-down blank area.
///
/// Only `alwaysBounceVertical` is overridden. Normal `bounces` stays untouched,
/// so long shelf content retains standard iOS edge elasticity while short pages
/// can no longer be pulled through a screenful of empty space. Reader scrolling
/// and unrelated horizontal scroll views are not touched.
struct RefreshableScrollBounceController: UIViewRepresentable {
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.isUserInteractionEnabled = false
        view.coordinator = context.coordinator
        return view
    }

    func updateUIView(_ uiView: ProbeView, context: Context) {
        uiView.coordinator = context.coordinator
        context.coordinator.scheduleApply(from: uiView.window)
    }

    static func dismantleUIView(_ uiView: ProbeView, coordinator: Coordinator) {
        coordinator.restore()
    }

    final class ProbeView: UIView {
        weak var coordinator: Coordinator?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            coordinator?.scheduleApply(from: window)
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            coordinator?.scheduleApply(from: window)
        }
    }

    @MainActor
    final class Coordinator {
        private struct OriginalState {
            weak var scrollView: UIScrollView?
            let alwaysBounceVertical: Bool
        }

        private var originalStates: [ObjectIdentifier: OriginalState] = [:]
        private var pendingWorkItems: [DispatchWorkItem] = []

        func scheduleApply(from window: UIWindow?) {
            pendingWorkItems.forEach { $0.cancel() }
            pendingWorkItems.removeAll()

            // SwiftUI may attach/configure UIRefreshControl after the representable
            // enters the hierarchy. Recheck across the next few layout turns so our
            // final state wins that setup race deterministically.
            for delay in [0.0, 0.08, 0.30] {
                let workItem = DispatchWorkItem { [weak self, weak window] in
                    guard let self else { return }
                    self.apply(in: window)
                }
                pendingWorkItems.append(workItem)
                DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
            }
        }

        private func apply(in window: UIWindow?) {
            guard let window else { return }
            let refreshableScrollViews = window.allDescendantScrollViews.filter {
                $0.refreshControl != nil
            }
            let liveIDs = Set(refreshableScrollViews.map(ObjectIdentifier.init))

            originalStates = originalStates.filter { id, state in
                guard let scrollView = state.scrollView else { return false }
                return liveIDs.contains(id) && scrollView.window === window
            }

            for scrollView in refreshableScrollViews {
                let id = ObjectIdentifier(scrollView)
                if originalStates[id] == nil {
                    originalStates[id] = OriginalState(
                        scrollView: scrollView,
                        alwaysBounceVertical: scrollView.alwaysBounceVertical
                    )
                }

                scrollView.alwaysBounceVertical = false
            }
        }

        func restore() {
            pendingWorkItems.forEach { $0.cancel() }
            pendingWorkItems.removeAll()
            for state in originalStates.values {
                guard let scrollView = state.scrollView else { continue }
                scrollView.alwaysBounceVertical = state.alwaysBounceVertical
            }
            originalStates.removeAll()
        }
    }
}

private extension UIView {
    var allDescendantScrollViews: [UIScrollView] {
        var result: [UIScrollView] = []
        if let scrollView = self as? UIScrollView {
            result.append(scrollView)
        }
        for subview in subviews {
            result.append(contentsOf: subview.allDescendantScrollViews)
        }
        return result
    }
}
