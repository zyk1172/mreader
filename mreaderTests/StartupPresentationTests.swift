import Testing
@testable import mreader

struct StartupPresentationTests {
    @Test func launchCoverKeepsTheRequestedMinimumDuration() {
        #expect(
            StartupRootView.minimumCoverDurationNanoseconds
                == LaunchExperienceMetrics.minimumDisplayDurationNanoseconds
        )
        #expect(StartupRootView.minimumCoverDurationNanoseconds == 2_000_000_000)
    }
}
