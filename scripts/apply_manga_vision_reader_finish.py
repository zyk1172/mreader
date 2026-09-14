from pathlib import Path


def replace_once(path, old, new, label):
    p = Path(path)
    text = p.read_text()
    count = text.count(old)
    if count != 1:
        raise RuntimeError(f"{label}: expected one match, got {count}")
    p.write_text(text.replace(old, new, 1))

# Fix OCR-bubble recovery so all retries share the same structured Manga Vision context.
replace_once(
    "mreader/AITranslationPageCoordinator.swift",
    '''        try await applyBatchTranslationSafely(
            to: &translated,
            indexes: Array(translated.indices),
            request: request
        )
        let missing = translated.indices.filter {
''',
    '''        var contextualRequest = request
        contextualRequest.previousContext = await MangaVisionTranslationContext.context(
            for: request,
            blocks: translated
        )
        try await applyBatchTranslationSafely(
            to: &translated,
            indexes: Array(translated.indices),
            request: contextualRequest
        )
        let missing = translated.indices.filter {
''',
    "existing OCR bubble semantic context",
)

# Reader: direct OCR uses the same page identity as Guided Panel / translation.
replace_once(
    "mreader/ReaderView.swift",
    '''        let cacheRequest = OCRRecognitionCacheRequest(
            pageURL: url,
            fallbackImage: image,
            options: options
        )
''',
    '''        let cacheRequest = OCRRecognitionCacheRequest(
            pageURL: url,
            fallbackImage: image,
            options: options,
            comicID: comicID,
            pageIndex: pageIndex
        )
''',
    "Reader OCR page identity",
)

# Reuse Reader's existing prefetch lifecycle instead of adding a second policy/queue.
replace_once(
    "mreader/ReaderView.swift",
    '''    @State private var translationPrefetchTask: Task<Void, Never>?
''',
    '''    @State private var translationPrefetchTask: Task<Void, Never>?
    @State private var mangaVisionPreanalysisTask: Task<Void, Never>?
''',
    "Manga Vision preanalysis task state",
)
replace_once(
    "mreader/ReaderView.swift",
    '''            RemotePagePrefetcher.shared.cancelAll()
            translationPrefetchTask?.cancel()
            translationPrefetchTask = nil
            recordReadingActivity()
''',
    '''            RemotePagePrefetcher.shared.cancelAll()
            translationPrefetchTask?.cancel()
            translationPrefetchTask = nil
            mangaVisionPreanalysisTask?.cancel()
            mangaVisionPreanalysisTask = nil
            recordReadingActivity()
''',
    "cancel Manga Vision preanalysis",
)
replace_once(
    "mreader/ReaderView.swift",
    '''        ReaderImageCache.shared.preload(
            urls,
            maxPixelSize: isContinuous ? 8192 : 4096,
            maximumConcurrent: isContinuous ? 2 : 3,
            delay: isContinuous ? 0.05 : 0.1
        )
    }

    private func scheduleTranslationPrefetch(around index: Int) {
''',
    '''        ReaderImageCache.shared.preload(
            urls,
            maxPixelSize: isContinuous ? 8192 : 4096,
            maximumConcurrent: isContinuous ? 2 : 3,
            delay: isContinuous ? 0.05 : 0.1
        )

        mangaVisionPreanalysisTask?.cancel()
        mangaVisionPreanalysisTask = nil
        let shouldPreanalyze = readingMode == .guidedPanel
            || comic.isOCREnabled
            || comic.isAITranslationEnabled
        if shouldPreanalyze {
            let comicID = comic.id
            let pages = manager.pages
            // Feed the same already-computed Reader prefetch ordering into Manga Vision.
            // The service itself caps work at three pages, so this can never expand to a book scan.
            let visionIndices = [index] + preferredIndices
            mangaVisionPreanalysisTask = Task(priority: .utility) {
                await MangaVisionService.shared.preanalyze(
                    comicID: comicID,
                    pages: pages,
                    indices: visionIndices
                )
            }
        }
    }

    private func scheduleTranslationPrefetch(around index: Int) {
''',
    "reuse Reader prefetch for Manga Vision",
)

print("reader integration finish applied")
