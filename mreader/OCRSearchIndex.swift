import Combine
import Foundation
import SwiftUI
import UIKit

nonisolated struct OCRSearchRecord: Codable, Hashable, Sendable {
    let comicID: UUID
    let pageIndex: Int
    let text: String
    let updatedAt: Date
}

nonisolated struct OCRSearchResult: Identifiable, Sendable {
    let comicID: UUID
    let pageIndex: Int
    let comicTitle: String
    let snippet: String

    var id: String { "\(comicID.uuidString):\(pageIndex)" }
}

actor OCRSearchIndex {
    static let shared = OCRSearchIndex()
    static let checkpointRecordLimit = 50
    static let checkpointIntervalNanoseconds: UInt64 = 2_000_000_000

    private let fileURL: URL
    private var records: [String: OCRSearchRecord] = [:]
    private var didLoad = false
    private var pendingChanges = 0
    private var checkpointTask: Task<Void, Never>?

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            self.fileURL = support.appendingPathComponent("ocr_search_index.json")
        }
    }

    func index(comicID: UUID, pageIndex: Int, blocks: [TextBlock]) {
        loadIfNeeded()
        let text = blocks
            .filter { !$0.isFiltered }
            .map(\.text)
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let recordKey = key(comicID: comicID, pageIndex: pageIndex)
        if text.isEmpty {
            guard records.removeValue(forKey: recordKey) != nil else { return }
        } else {
            records[recordKey] = OCRSearchRecord(
                comicID: comicID,
                pageIndex: pageIndex,
                text: text,
                updatedAt: Date()
            )
        }
        markDirty()
    }

    func search(_ query: String, comics: [ComicBook]) -> [OCRSearchResult] {
        loadIfNeeded()
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return [] }
        let titles = Dictionary(uniqueKeysWithValues: comics.map { ($0.id, $0.title) })
        return records.values.compactMap { record in
            guard let title = titles[record.comicID],
                  let range = record.text.range(of: term, options: [.caseInsensitive, .diacriticInsensitive]) else { return nil }
            let lower = record.text.index(range.lowerBound, offsetBy: -36, limitedBy: record.text.startIndex) ?? record.text.startIndex
            let upper = record.text.index(range.upperBound, offsetBy: 72, limitedBy: record.text.endIndex) ?? record.text.endIndex
            let prefix = lower == record.text.startIndex ? "" : "..."
            let suffix = upper == record.text.endIndex ? "" : "..."
            return OCRSearchResult(
                comicID: record.comicID,
                pageIndex: record.pageIndex,
                comicTitle: title,
                snippet: prefix + String(record.text[lower..<upper]).replacingOccurrences(of: "\n", with: " ") + suffix
            )
        }
        .sorted {
            if $0.comicTitle != $1.comicTitle {
                return $0.comicTitle.localizedStandardCompare($1.comicTitle) == .orderedAscending
            }
            return $0.pageIndex < $1.pageIndex
        }
    }

    func indexedPageCount(for comicID: UUID) -> Int {
        loadIfNeeded()
        return records.values.lazy.filter { $0.comicID == comicID }.count
    }

    func remove(comicID: UUID) {
        loadIfNeeded()
        let originalCount = records.count
        records = records.filter { $0.value.comicID != comicID }
        guard records.count != originalCount else { return }
        markDirty()
    }

    /// 将内存中的增量立即写入现有 JSON 文件；用于进入后台、索引任务结束或测试清理。
    func flush() {
        checkpointTask?.cancel()
        checkpointTask = nil
        guard pendingChanges > 0 else { return }
        do {
            try persist()
            pendingChanges = 0
        } catch {
            // Keep the dirty count so a later foreground/background transition
            // can retry after a transient disk or filesystem failure.
            print("MReader OCR search index flush failed: \(error.localizedDescription)")
        }
    }

    private func key(comicID: UUID, pageIndex: Int) -> String {
        "\(comicID.uuidString):\(pageIndex)"
    }

    private func loadIfNeeded() {
        guard !didLoad else { return }
        didLoad = true
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([OCRSearchRecord].self, from: data) else { return }
        records = Dictionary(uniqueKeysWithValues: decoded.map { (key(comicID: $0.comicID, pageIndex: $0.pageIndex), $0) })
    }

    private func markDirty() {
        pendingChanges += 1
        if pendingChanges >= Self.checkpointRecordLimit {
            flush()
            return
        }
        guard checkpointTask == nil else { return }
        checkpointTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.checkpointIntervalNanoseconds)
            guard !Task.isCancelled, let self else { return }
            await self.flush()
        }
    }

    private func persist() throws {
        let values = records.values.sorted {
            $0.comicID == $1.comicID ? $0.pageIndex < $1.pageIndex : $0.comicID.uuidString < $1.comicID.uuidString
        }
        let data = try JSONEncoder().encode(values)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
    }
}

@MainActor
final class OCRLibraryIndexer: ObservableObject {
    static let shared = OCRLibraryIndexer()

    @Published private(set) var activeComicID: UUID?
    @Published private(set) var progress: Double = 0
    @Published private(set) var lastError: String?
    private var task: Task<Void, Never>?

    private init() {}

    func start(_ comic: ComicBook) {
        task?.cancel()
        activeComicID = comic.id
        progress = 0
        lastError = nil
        task = Task {
            do {
                guard let result = await Self.loadPages(for: comic), !result.pages.isEmpty else {
                    throw MediaSourceError.notFound
                }
                let pageCount = max(result.pages.count, 1)
                for page in result.pages {
                    try Task.checkCancellation()
                    guard let image = await OCRPreprocessor.highResolutionImage(from: page.url, fallback: nil) else { continue }
                    let request = OCRRecognitionCacheRequest(
                        pageURL: page.url,
                        fallbackImage: image,
                        options: OCRPreprocessor.Options(
                            isRightToLeft: comic.readingDirectionRaw == ReadingDirection.rightToLeft.rawValue,
                            minimumTextHeight: comic.ocrMinimumTextHeight,
                            recognitionMode: .adaptive
                        )
                    )
                    let ocrResult = try await OCRRecognitionCache.shared.result(for: request)
                    await OCRSearchIndex.shared.index(comicID: comic.id, pageIndex: page.index, blocks: ocrResult.bubbleBlocks)
                    progress = Double(page.index + 1) / Double(pageCount)
                }
                await OCRSearchIndex.shared.flush()
                HapticManager.shared.play(.success)
            } catch is CancellationError {
                await OCRSearchIndex.shared.flush()
            } catch {
                await OCRSearchIndex.shared.flush()
                lastError = error.localizedDescription
                HapticManager.shared.play(.error)
            }
            activeComicID = nil
            task = nil
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        activeComicID = nil
    }

    private static func loadPages(for comic: ComicBook) async -> ComicManager.LoadResult? {
        switch comic.sourceType {
        case .local:
            return ComicManager.loadPages(bookmarkData: comic.bookmarkData)
        case .komga:
            return await RemotePageLoader.loadPages(for: comic)
        case .opds:
            return await OPDSProvider.loadPages(for: comic)
        }
    }
}

struct OCRSearchView: View {
    let comics: [ComicBook]
    let onOpen: (OCRSearchResult) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [OCRSearchResult] = []

    var body: some View {
        NavigationStack {
            Group {
                if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    ContentUnavailableView("ocr.search.prompt".localized, systemImage: "text.magnifyingglass")
                } else if results.isEmpty {
                    ContentUnavailableView.search(text: query)
                } else {
                    List(results) { result in
                        Button {
                            onOpen(result)
                            dismiss()
                        } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(result.comicTitle).font(.headline).foregroundStyle(.primary)
                                Text("ocr.search.page".localizedFormat(result.pageIndex + 1))
                                    .font(.caption).foregroundStyle(.secondary)
                                Text(result.snippet).font(.subheadline).foregroundStyle(.secondary).lineLimit(3)
                            }
                        }
                    }
                }
            }
            .navigationTitle("ocr.search.title".localized)
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: "ocr.search.placeholder".localized)
            .onChange(of: query) { _, value in
                Task { results = await OCRSearchIndex.shared.search(value, comics: comics) }
            }
            .toolbar { Button("nav.done".localized) { dismiss() } }
        }
    }
}
