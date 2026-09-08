import SwiftUI
import UIKit

/// Keeps the real shelf alive behind an opaque launch cover so startup work can
/// progress without exposing intermediate NavigationStack/TabView layout states.
struct StartupRootView: View {
    static let minimumCoverDurationNanoseconds: UInt64 = 1_500_000_000

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isCoverVisible = true

    var body: some View {
        ZStack {
            ContentView()
                .allowsHitTesting(!isCoverVisible)
                .accessibilityHidden(isCoverVisible)

            if isCoverVisible {
                StartupCoverView()
                    .zIndex(1)
            }
        }
        .task {
            try? await Task.sleep(nanoseconds: Self.minimumCoverDurationNanoseconds)
            guard !Task.isCancelled else { return }

            if reduceMotion {
                isCoverVisible = false
            } else {
                withAnimation(.easeOut(duration: 0.18)) {
                    isCoverVisible = false
                }
            }
        }
    }
}

private struct StartupCoverView: View {
    var body: some View {
        ZStack {
            Color(uiColor: .systemBackground)
                .ignoresSafeArea()

            VStack(spacing: 16) {
                Image(systemName: "books.vertical.fill")
                    .font(.system(size: 46, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.primary)

                Text("MReader")
                    .font(.title2.weight(.semibold))

                ProgressView()
                    .controlSize(.small)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("MReader")
        .accessibilityIdentifier("mreader.startup.cover")
    }
}
