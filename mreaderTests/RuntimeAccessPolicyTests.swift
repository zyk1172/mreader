import Foundation
import Testing
@testable import mreader

@Suite("Runtime access policy")
struct RuntimeAccessPolicyTests {
    @Test("App-owned paths do not request security scope")
    func appOwnedPathDoesNotRequestSecurityScope() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mreader-test")
        #expect(LocalResourceAccessPolicy.requiresSecurityScope(for: url) == false)
        #expect(LocalResourceAccessPolicy.bookmarkCreationOptions(for: url).isEmpty)
    }

    @Test("External paths use minimal bookmarks")
    func externalPathUsesMinimalBookmark() {
        let url = URL(fileURLWithPath: "/external-provider/MReader")
        #expect(LocalResourceAccessPolicy.requiresSecurityScope(for: url))
        #expect(LocalResourceAccessPolicy.bookmarkCreationOptions(for: url).contains(.minimalBookmark))
    }
}
