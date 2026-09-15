import SwiftUI

/// Keeps the real shelf alive behind the branded launch overlay so startup work can
/// progress without exposing intermediate NavigationStack/TabView layout states.
struct StartupRootView: View {
    static let minimumCoverDurationNanoseconds = LaunchExperienceMetrics.minimumDisplayDurationNanoseconds

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var launchState = AppLaunchState()

    var body: some View {
        ZStack {
            LaunchGradientBackground()

            ContentView()
                // Short shelf/statistics pages use pull-to-refresh ScrollViews. Let
                // SwiftUI bounce only when content actually exceeds the viewport so
                // dragging a short page cannot reveal a screenful of empty space.
                .scrollBounceBehavior(.basedOnSize)
                .transaction { transaction in
                    if launchState.isVisible {
                        transaction.animation = nil
                        transaction.disablesAnimations = true
                    }
                }
                .allowsHitTesting(!launchState.isVisible)
                .accessibilityHidden(launchState.isVisible)

            if launchState.isVisible {
                LaunchOverlayView()
                    .transition(.opacity)
                    .zIndex(1)
            }
        }
        .animation(
            reduceMotion ? nil : .easeOut(duration: LaunchExperienceMetrics.fadeDuration),
            value: launchState.isVisible
        )
        .task {
            await launchState.start {}
        }
    }
}
