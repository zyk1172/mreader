import Foundation
import Testing
@testable import mreader

@Suite(.serialized)
@MainActor
struct LaunchExperienceTests {
    @Test func firstFrameStartsWithVisibleOverlay() {
        let state = AppLaunchState(minimumDisplayDurationNanoseconds: 1)

        #expect(state.phase == .launching)
        #expect(state.isVisible)
    }

    @Test func immediateStartupStillHonorsMinimumDisplayDuration() async {
        let minimumDuration: UInt64 = 80_000_000
        let state = AppLaunchState(
            minimumDisplayDurationNanoseconds: minimumDuration
        )
        let start = DispatchTime.now().uptimeNanoseconds

        await state.start {}

        let elapsed = DispatchTime.now().uptimeNanoseconds - start
        #expect(elapsed >= minimumDuration - 10_000_000)
        #expect(state.phase == .ready)
        #expect(!state.isVisible)
    }

    @Test func slowStartupKeepsOverlayVisiblePastMinimumDuration() async {
        let state = AppLaunchState(minimumDisplayDurationNanoseconds: 20_000_000)
        let startTask = Task { @MainActor in
            await state.start {
                try? await Task.sleep(nanoseconds: 120_000_000)
            }
        }

        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(state.isVisible)

        await startTask.value
        #expect(state.phase == .ready)
        #expect(!state.isVisible)
    }

    @Test func startupCompletionRemovesOverlayFromState() async {
        let state = AppLaunchState(minimumDisplayDurationNanoseconds: 1)

        await state.start {}

        #expect(state.phase == .ready)
        #expect(!state.isVisible)
    }

    @Test func staticAndSwiftUILaunchStagesShareVisualContract() {
        #expect(LaunchExperienceMetrics.backgroundColorName == "LaunchBackground")
        #expect(LaunchExperienceMetrics.glyphImageName == "LaunchGlyph")
        #expect(LaunchExperienceMetrics.artworkVerticalRatio == 0.40)
        #expect(LaunchExperienceMetrics.artworkPointSize == 108)
        #expect(LaunchExperienceMetrics.brandBottomPadding == 28)
        #expect(LaunchExperienceMetrics.labelSpacing == 5)
        #expect(LaunchExperienceMetrics.fadeDuration == 0.20)
    }
}
