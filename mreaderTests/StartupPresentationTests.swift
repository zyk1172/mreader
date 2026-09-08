import Testing
@testable import mreader

struct StartupPresentationTests {
    @Test func launchCoverKeepsTheRequestedMinimumDuration() {
        #expect(StartupRootView.minimumCoverDurationNanoseconds == 1_500_000_000)
    }
}
