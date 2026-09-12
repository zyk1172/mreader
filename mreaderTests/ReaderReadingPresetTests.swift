import Testing
@testable import mreader

struct ReaderReadingPresetTests {
    @Test
    func samplePageIndicesHandleShortBooksWithoutCreatingAnInvalidRange() {
        #expect(ReadingPresetSamplePagePolicy.pageIndices(totalPages: 0) == [])
        #expect(ReadingPresetSamplePagePolicy.pageIndices(totalPages: 1) == [0])
        #expect(ReadingPresetSamplePagePolicy.pageIndices(totalPages: 2) == [0, 1])
        #expect(ReadingPresetSamplePagePolicy.pageIndices(totalPages: 3) == [2])
        #expect(ReadingPresetSamplePagePolicy.pageIndices(totalPages: 5) == [2, 3, 4])
        #expect(ReadingPresetSamplePagePolicy.pageIndices(totalPages: 8) == [2, 3, 4])
    }
}
