import Foundation
import CoreGraphics
import Testing
@testable import mreader

struct OCRSearchIndexTests {
    @Test
    func checkpointPolicyUsesBoundedBatchAndDelay() {
        #expect(OCRSearchIndex.checkpointRecordLimit == 50)
        #expect(OCRSearchIndex.checkpointIntervalNanoseconds == 2_000_000_000)
    }

    @Test
    func flushKeepsExistingJSONRecordFormat() async throws {
        let index = OCRSearchIndex()
        let comicID = UUID()
        let block = TextBlock(text: "checkpoint text", boundingBox: .zero)

        await index.index(comicID: comicID, pageIndex: 3, blocks: [block])
        await index.flush()

        let fileURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ocr_search_index.json")
        let data = try Data(contentsOf: fileURL)
        let records = try JSONDecoder().decode([OCRSearchRecord].self, from: data)
        #expect(records.contains { $0.comicID == comicID && $0.pageIndex == 3 && $0.text == "checkpoint text" })

        await index.remove(comicID: comicID)
        await index.flush()
    }

    @Test
    func failedFlushKeepsDirtyChangesForRetry() async throws {
        let blocker = FileManager.default.temporaryDirectory
            .appendingPathComponent("MReaderOCRIndexBlocker-\(UUID().uuidString)")
        try Data("not a directory".utf8).write(to: blocker)
        let fileURL = blocker.appendingPathComponent("ocr_search_index.json")
        let index = OCRSearchIndex(fileURL: fileURL)
        let comicID = UUID()
        let block = TextBlock(text: "retry after failure", boundingBox: .zero)
        defer { try? FileManager.default.removeItem(at: blocker) }

        await index.index(comicID: comicID, pageIndex: 1, blocks: [block])
        await index.flush()

        try FileManager.default.removeItem(at: blocker)
        try FileManager.default.createDirectory(at: blocker, withIntermediateDirectories: true)
        await index.flush()

        let data = try Data(contentsOf: fileURL)
        let records = try JSONDecoder().decode([OCRSearchRecord].self, from: data)
        #expect(records.contains { $0.comicID == comicID && $0.pageIndex == 1 && $0.text == "retry after failure" })
    }
}
