import SwiftUI
import UIKit
import os

/// 把外层 `UIScrollView` 的滚动偏移夹回合法范围。
///
/// 两个真实会留下「一大块空白」的场景：
/// 1. 内容变短（同步/刷新后条目减少、筛选后结果变少、删除漫画）。`UIScrollView`
///    不会自己收回报废的 `contentOffset`，内容会整块滑到屏幕上方。
/// 2. 快速连续滑动把偏移甩到内容之外，回弹结束后偏移仍停在非法值上，此时
///    `LazyVGrid` 一个 cell 都不再实例化，整页只剩空白，要再滑一下才恢复。
///    （在模拟器上 34 次快速上滑可以稳定复现。）
///
/// 用法：挂到 `ScrollView` 的**内容**上（不是 ScrollView 自己），这样向上一定能走到外层
/// 的 `UIScrollView`。只在滚动已经静止、且偏移确实超出合法范围时才动手，因此不会和
/// 正常的下拉回弹或惯性滚动打架。
struct ScrollOffsetClampingView: UIViewRepresentable {
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        DispatchQueue.main.async { context.coordinator.attach(from: view) }
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        DispatchQueue.main.async { context.coordinator.attach(from: uiView) }
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.detach()
    }

    final class Coordinator {
        private weak var scrollView: UIScrollView?
        private var contentSizeObservation: NSKeyValueObservation?
        private var contentOffsetObservation: NSKeyValueObservation?
        private var pendingWork: DispatchWorkItem?
        private var isClamping = false

        func attach(from view: UIView) {
            guard let enclosing = view.enclosingScrollView else { return }
            guard scrollView !== enclosing else { return }
            detach()
            scrollView = enclosing
            contentSizeObservation = enclosing.observe(\.contentSize, options: [.new]) { [weak self] scrollView, _ in
                guard Thread.isMainThread else { return }
                MainActor.assumeIsolated {
                    self?.schedule(after: 0, for: scrollView)
                }
            }
            contentOffsetObservation = enclosing.observe(\.contentOffset, options: [.new]) { [weak self] scrollView, _ in
                guard Thread.isMainThread else { return }
                MainActor.assumeIsolated {
                    self?.schedule(after: 0.2, for: scrollView)
                }
            }
        }

        func detach() {
            pendingWork?.cancel()
            pendingWork = nil
            contentSizeObservation = nil
            contentOffsetObservation = nil
            scrollView = nil
        }

        private func schedule(after delay: TimeInterval, for scrollView: UIScrollView) {
            guard !isClamping else { return }
            pendingWork?.cancel()
            let work = DispatchWorkItem { [weak self, weak scrollView] in
                guard let scrollView, let self, self.scrollView === scrollView else { return }
                self.clampIfNeeded(scrollView)
            }
            pendingWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }

        private func clampIfNeeded(_ scrollView: UIScrollView) {
            // 手势或惯性还在进行时不插手，等它停下来再判断；这里重新排队，
            // 避免「因为还在滚动所以跳过」把非法偏移留在原地。
            guard !scrollView.isDragging, !scrollView.isDecelerating else {
                schedule(after: 0.2, for: scrollView)
                return
            }
            let minOffsetY = -scrollView.adjustedContentInset.top
            let maxOffsetY = max(
                minOffsetY,
                scrollView.contentSize.height
                    - scrollView.bounds.height
                    + scrollView.adjustedContentInset.bottom
            )
            guard scrollView.contentOffset.y > maxOffsetY + 1 else { return }

            isClamping = true
            MReaderLog.reader.debug(
                "scroll offset clamped old=\(Int(scrollView.contentOffset.y), privacy: .public) new=\(Int(maxOffsetY), privacy: .public) contentHeight=\(Int(scrollView.contentSize.height), privacy: .public)"
            )
            scrollView.setContentOffset(
                CGPoint(x: scrollView.contentOffset.x, y: maxOffsetY),
                animated: false
            )
            isClamping = false
        }
    }
}
