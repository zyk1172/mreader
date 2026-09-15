from pathlib import Path


def replace_once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        raise RuntimeError(f"{label}: expected exactly one match, found {count}")
    return text.replace(old, new, 1)


path = Path("mreader/ComicManager.swift")
text = path.read_text()

text = replace_once(
    text,
    '''    static func requiresSecurityScope(for url: URL) -> Bool {
        location(for: url) == .external
    }

    @discardableResult
    static func startAccessingIfNeeded(_ url: URL) -> Bool {
        let location = location(for: url)
        let shouldStart = location == .external
        #if DEBUG
        logLock.lock()
        let logKey = "\\(location.rawValue)|\\(url.standardizedFileURL.path)"
        let shouldLog = loggedDecisions.insert(logKey).inserted
        logLock.unlock()
        if shouldLog {
            MReaderLog.reader.debug(
                "resource access location=\\(location.rawValue, privacy: .public) securityScope=\\(shouldStart, privacy: .public) path=\\(url.standardizedFileURL.path, privacy: .public)"
            )
        }
        #endif
        return shouldStart && url.startAccessingSecurityScopedResource()
    }
''',
    '''    static func requiresSecurityScope(for url: URL) -> Bool {
        location(for: url) == .external
    }

    static func bookmarkCreationOptions(for url: URL) -> URL.BookmarkCreationOptions {
        requiresSecurityScope(for: url) ? .minimalBookmark : []
    }

    @discardableResult
    static func startAccessingIfNeeded(_ url: URL) -> Bool {
        let location = location(for: url)
        let shouldStart = location == .external
        let didStart = shouldStart && url.startAccessingSecurityScopedResource()
        #if DEBUG
        logLock.lock()
        let logKey = "\\(location.rawValue)|\\(shouldStart)|\\(didStart)|\\(url.standardizedFileURL.path)"
        let shouldLog = loggedDecisions.insert(logKey).inserted
        logLock.unlock()
        if shouldLog {
            MReaderLog.reader.debug(
                "resource access location=\\(location.rawValue, privacy: .public) securityScopeRequested=\\(shouldStart, privacy: .public) didStart=\\(didStart, privacy: .public) path=\\(url.standardizedFileURL.path, privacy: .public)"
            )
        }
        #endif
        return didStart
    }
''',
    "security scope policy",
)

text = replace_once(
    text,
    '''nonisolated final class SecurityScopedResource: @unchecked Sendable {
    let url: URL
    private let didStart: Bool
    private let lock = NSLock()
    private var isStopped = false

    init(url: URL) {
        self.url = url
        didStart = LocalResourceAccessPolicy.startAccessingIfNeeded(url)
    }
''',
    '''nonisolated final class SecurityScopedResource: @unchecked Sendable {
    let url: URL
    private let didStart: Bool
    private let lock = NSLock()
    private var isStopped = false

    var hasAccess: Bool {
        !LocalResourceAccessPolicy.requiresSecurityScope(for: url) || didStart
    }

    init(url: URL) {
        self.url = url
        didStart = LocalResourceAccessPolicy.startAccessingIfNeeded(url)
    }
''',
    "security scoped token state",
)

text = replace_once(
    text,
    '''    nonisolated static func loadPages(bookmarkData: Data) -> LoadResult? {
        do {
            let url = try resolveBookmark(bookmarkData)
            let accessToken = SecurityScopedResource(url: url)
            logMemory("load-pages-start \\(url.lastPathComponent)")
''',
    '''    nonisolated static func loadPages(bookmarkData: Data) -> LoadResult? {
        do {
            let url = try resolveBookmark(bookmarkData)
            let accessToken = SecurityScopedResource(url: url)
            guard accessToken.hasAccess else {
                logger.error("load-pages-security-scope-denied path=\\(url.path, privacy: .public)")
                return nil
            }
            logMemory("load-pages-start \\(url.lastPathComponent)")
''',
    "load pages access guard",
)

text = replace_once(
    text,
    '''    nonisolated static func resolveBookmark(_ bookmarkData: Data) throws -> URL {
        var isStale = false
        let url = try URL(resolvingBookmarkData: bookmarkData, options: .withoutUI, relativeTo: nil, bookmarkDataIsStale: &isStale)
        if isStale {
            logger.warning("bookmark-stale resolved-path=\\(url.path, privacy: .public)")
        }
        return url
    }
''',
    '''    nonisolated static func resolveBookmark(_ bookmarkData: Data) throws -> URL {
        var isStale = false
        let url = try URL(resolvingBookmarkData: bookmarkData, options: .withoutUI, relativeTo: nil, bookmarkDataIsStale: &isStale)
        guard !isStale else {
            logger.warning("bookmark-stale rejected-path=\\(url.path, privacy: .public)")
            throw CocoaError(.fileReadNoPermission)
        }
        return url
    }
''',
    "stale bookmark rejection",
)

text = replace_once(
    text,
    '''    nonisolated private static func createBookmark(for url: URL) -> Data? {
        do {
            return try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        } catch { return nil }
    }
''',
    '''    nonisolated private static func createBookmark(for url: URL) -> Data? {
        do {
            return try url.bookmarkData(
                options: LocalResourceAccessPolicy.bookmarkCreationOptions(for: url),
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        } catch {
            logger.error("bookmark-create-failed path=\\(url.path, privacy: .public) error=\\(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
''',
    "bookmark creation",
)

text = replace_once(
    text,
    '''    nonisolated static func setLibraryRoot(_ url: URL) -> Bool {
        let didStartAccessing = LocalResourceAccessPolicy.startAccessingIfNeeded(url)
        defer {
            if didStartAccessing {
                url.stopAccessingSecurityScopedResource()
            }
        }
        do {
            let bookmark = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
            UserDefaults.standard.set(bookmark, forKey: libraryRootBookmarkKey)
            return true
        } catch {
            return false
        }
    }
''',
    '''    nonisolated static func setLibraryRoot(_ url: URL) -> Bool {
        let requiresAccess = LocalResourceAccessPolicy.requiresSecurityScope(for: url)
        let didStartAccessing = LocalResourceAccessPolicy.startAccessingIfNeeded(url)
        guard !requiresAccess || didStartAccessing else {
            logger.error("library-root-security-scope-denied path=\\(url.path, privacy: .public)")
            return false
        }
        defer {
            if didStartAccessing {
                url.stopAccessingSecurityScopedResource()
            }
        }
        do {
            let bookmark = try url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
            UserDefaults.standard.set(bookmark, forKey: libraryRootBookmarkKey)
            return true
        } catch {
            logger.error("library-root-bookmark-create-failed path=\\(url.path, privacy: .public) error=\\(error.localizedDescription, privacy: .public)")
            return false
        }
    }
''',
    "library root bookmark",
)

text = replace_once(
    text,
    '''    nonisolated static func withSelectedLibraryRoot<T>(_ body: (URL) throws -> T) rethrows -> T? {
        guard let url = selectedLibraryRootURL() else { return nil }
        let didStart = LocalResourceAccessPolicy.startAccessingIfNeeded(url)
        defer {
            if didStart {
                url.stopAccessingSecurityScopedResource()
            }
        }
        return try body(url)
    }
''',
    '''    nonisolated static func withSelectedLibraryRoot<T>(_ body: (URL) throws -> T) rethrows -> T? {
        guard let url = selectedLibraryRootURL() else { return nil }
        let requiresAccess = LocalResourceAccessPolicy.requiresSecurityScope(for: url)
        let didStart = LocalResourceAccessPolicy.startAccessingIfNeeded(url)
        guard !requiresAccess || didStart else {
            logger.error("library-root-security-scope-denied path=\\(url.path, privacy: .public)")
            return nil
        }
        defer {
            if didStart {
                url.stopAccessingSecurityScopedResource()
            }
        }
        return try body(url)
    }
''',
    "selected library guard",
)

text = replace_once(
    text,
    '''        let didStart = LocalResourceAccessPolicy.startAccessingIfNeeded(selectedRoot)
        defer {
            if didStart {
                selectedRoot.stopAccessingSecurityScopedResource()
            }
        }
        return try body(targetRoot)
''',
    '''        let requiresAccess = LocalResourceAccessPolicy.requiresSecurityScope(for: selectedRoot)
        let didStart = LocalResourceAccessPolicy.startAccessingIfNeeded(selectedRoot)
        guard !requiresAccess || didStart else {
            logger.error("library-write-security-scope-denied path=\\(selectedRoot.path, privacy: .public)")
            return nil
        }
        defer {
            if didStart {
                selectedRoot.stopAccessingSecurityScopedResource()
            }
        }
        return try body(targetRoot)
''',
    "library write guard",
)

text = replace_once(
    text,
    '''    nonisolated static func importFileOrFolder(url: URL, destinationRoot: URL? = nil) async -> ImportResult? {
        let isSecurityScoped = LocalResourceAccessPolicy.startAccessingIfNeeded(url)
        defer { if isSecurityScoped { url.stopAccessingSecurityScopedResource() } }

        let ext = url.pathExtension.lowercased()
''',
    '''    nonisolated static func importFileOrFolder(url: URL, destinationRoot: URL? = nil) async -> ImportResult? {
        let requiresAccess = LocalResourceAccessPolicy.requiresSecurityScope(for: url)
        let isSecurityScoped = LocalResourceAccessPolicy.startAccessingIfNeeded(url)
        guard !requiresAccess || isSecurityScoped else {
            logger.error("import-security-scope-denied path=\\(url.path, privacy: .public)")
            return nil
        }
        defer { if isSecurityScoped { url.stopAccessingSecurityScopedResource() } }

        let ext = url.pathExtension.lowercased()
''',
    "import access guard",
)

text = replace_once(
    text,
    '''    nonisolated static func inspectImportFolder(_ url: URL) -> ImportFolderInspection {
        let didStart = LocalResourceAccessPolicy.startAccessingIfNeeded(url)
        defer {
            if didStart {
                url.stopAccessingSecurityScopedResource()
            }
        }
        guard let contents = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else {
''',
    '''    nonisolated static func inspectImportFolder(_ url: URL) -> ImportFolderInspection {
        let requiresAccess = LocalResourceAccessPolicy.requiresSecurityScope(for: url)
        let didStart = LocalResourceAccessPolicy.startAccessingIfNeeded(url)
        guard !requiresAccess || didStart else {
            logger.error("inspect-import-security-scope-denied path=\\(url.path, privacy: .public)")
            return ImportFolderInspection(hasDirectImages: false, importableChildren: [])
        }
        defer {
            if didStart {
                url.stopAccessingSecurityScopedResource()
            }
        }
        guard let contents = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else {
''',
    "inspect import guard",
)

path.write_text(text)

Path("mreaderTests/RuntimeAccessPolicyTests.swift").write_text('''import Foundation
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
''')
