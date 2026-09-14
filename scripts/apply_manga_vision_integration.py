from pathlib import Path
import re


def read(path):
    return Path(path).read_text()


def write(path, value):
    Path(path).write_text(value)


def replace_once(text, old, new, label):
    count = text.count(old)
    if count != 1:
        raise RuntimeError(f"{label}: expected one match, found {count}")
    return text.replace(old, new, 1)

# MangaVisionService: expose provider descriptor and make source identity independent
# of whatever decode resolution happened to reach a consumer first.
p = "mreader/MangaVisionService.swift"
s = read(p)
s = replace_once(
    s,
    "    func performanceSnapshot() async -> MangaVisionPerformanceSnapshot {\n",
    "    func providerDescriptor() async -> MangaVisionProviderDescriptor {\n"
    "        await provider.descriptor\n"
    "    }\n\n"
    "    func performanceSnapshot() async -> MangaVisionPerformanceSnapshot {\n",
    "vision descriptor bridge",
)
old = '''    nonisolated private static func sourceFingerprint(pageURL: URL, image: UIImage) -> String {
        let size = image.cgImage.map { "\\($0.width)x\\($0.height)" }
            ?? "\\(Int(image.size.width * image.scale))x\\(Int(image.size.height * image.scale))"
        let source: String
        if pageURL.isFileURL {
            let values = try? pageURL.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            source = "\\(pageURL.path)#\\(values?.fileSize ?? 0)#\\(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)#\\(size)"
        } else {
            source = "\\(pageURL.absoluteString)#\\(size)"
        }
        return sha256(source)
    }
'''
new = '''    nonisolated private static func sourceFingerprint(pageURL: URL, image: UIImage) -> String {
        // Cache identity belongs to the source page, not to a particular 640/4096/6144
        // decode. This is what lets Guided Panel and OCR join the same inference.
        _ = image
        let source: String
        if pageURL.isFileURL {
            let values = try? pageURL.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            source = "\\(pageURL.path)#\\(values?.fileSize ?? 0)#\\(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)"
        } else {
            source = pageURL.absoluteString
        }
        return sha256(source)
    }
'''
s = replace_once(s, old, new, "vision source fingerprint")
write(p, s)

# PanelDetectionService: remove YOLO decoder/model loading from the Guided Panel layer.
p = "mreader/PanelDetectionService.swift"
s = read(p)
s = s.replace("import CoreML\n", "")
pattern = re.compile(r"\nnonisolated struct CoreMLPanelDetector: PanelDetecting, @unchecked Sendable \{.*?\n\}\n\n\nnonisolated enum PanelPostProcessor", re.S)
s, count = pattern.subn("\nnonisolated enum PanelPostProcessor", s, count=1)
if count != 1:
    raise RuntimeError(f"remove CoreMLPanelDetector: {count}")
s = replace_once(s, "    static let modelVersion = 2\n", "    static let modelVersion = 3\n", "panel layout model version")
s = replace_once(
    s,
    "    private let primaryDetector: any PanelDetecting\n    private let fallbackDetector: any PanelDetecting\n",
    "    private let visionService: MangaVisionService\n    private let fallbackDetector: any PanelDetecting\n",
    "panel detector fields",
)
old_init = '''    init(detector: (any PanelDetecting)? = nil) {
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        cacheDirectory = root.appendingPathComponent("PanelLayouts", isDirectory: true)
        fallbackDetector = VisionRectanglePanelDetector()
        if let detector {
            primaryDetector = detector
        } else if let coreMLDetector = CoreMLPanelDetector.bundled() {
            primaryDetector = coreMLDetector
        } else {
            primaryDetector = VisionRectanglePanelDetector()
        }
        try? fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }
'''
new_init = '''    init(
        visionService: MangaVisionService = .shared,
        fallbackDetector: any PanelDetecting = VisionRectanglePanelDetector()
    ) {
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        cacheDirectory = root.appendingPathComponent("PanelLayouts", isDirectory: true)
        self.visionService = visionService
        self.fallbackDetector = fallbackDetector
        try? fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }
'''
s = replace_once(s, old_init, new_init, "panel service init")
s = replace_once(
    s,
    '''        return layout(
            cacheIdentity: identity,
            pageURL: pageURL,
            image: image,
            isRightToLeft: isRightToLeft
        )
''',
    '''        return await layout(
            cacheIdentity: identity,
            comicID: nil,
            pageIndex: nil,
            pageURL: pageURL,
            image: image,
            isRightToLeft: isRightToLeft
        )
''',
    "legacy panel layout call",
)
s = replace_once(
    s,
    '''        return layout(
            cacheIdentity: identity,
            pageURL: pageURL,
            image: image,
            isRightToLeft: isRightToLeft
        )
''',
    '''        return await layout(
            cacheIdentity: identity,
            comicID: comicID,
            pageIndex: pageIndex,
            pageURL: pageURL,
            image: image,
            isRightToLeft: isRightToLeft
        )
''',
    "preferred panel layout call",
)
s = replace_once(
    s,
    '''    private func layout(
        cacheIdentity: CacheIdentity,
        pageURL: URL,
        image: UIImage,
        isRightToLeft: Bool
    ) -> PanelPageLayout {
        let direction = isRightToLeft ? "rightToLeft" : "leftToRight"
''',
    '''    private func layout(
        cacheIdentity: CacheIdentity,
        comicID: UUID?,
        pageIndex: Int?,
        pageURL: URL,
        image: UIImage,
        isRightToLeft: Bool
    ) async -> PanelPageLayout {
        let descriptor = await visionService.providerDescriptor()
        let primaryIdentifier = "manga-vision:\\(descriptor.modelIdentifier):\\(descriptor.modelVersion)"
        let direction = isRightToLeft ? "rightToLeft" : "leftToRight"
''',
    "private panel layout signature",
)
s = s.replace("|\\(primaryDetector.identifier)|", "|\\(primaryIdentifier)|")
s = replace_once(
    s,
    "        let validDetectorIdentifiers = Set([primaryDetector.identifier, fallbackDetector.identifier])\n",
    "        let validDetectorIdentifiers = Set([primaryIdentifier, fallbackDetector.identifier])\n",
    "panel cache detector ids",
)
s = s.replace("detectorIdentifier: primaryDetector.identifier", "detectorIdentifier: primaryIdentifier")
old_primary = '''        let contentBounds = Self.detectedContentBounds(analysisImage)
        let primaryPanels = (try? primaryDetector.detectPanels(in: analysisImage)) ?? []
        var processed = PanelPostProcessor.process(primaryPanels)
        var detectorIdentifier = primaryDetector.identifier

        if !PanelLayoutQuality.isUsable(processed),
           primaryDetector.identifier != fallbackDetector.identifier {
            let fallbackPanels = (try? fallbackDetector.detectPanels(in: analysisImage)) ?? []
            let fallbackProcessed = PanelPostProcessor.process(fallbackPanels)
            if PanelLayoutQuality.isUsable(fallbackProcessed) {
                processed = fallbackProcessed
                detectorIdentifier = fallbackDetector.identifier
            }
        }
'''
new_primary = '''        let contentBounds = Self.detectedContentBounds(analysisImage)
        let mangaAnalysis = try? await visionService.analysis(
            comicID: comicID,
            pageIndex: pageIndex,
            pageURL: pageURL,
            image: image
        )
        let primaryPanels = (mangaAnalysis?.panels ?? []).map {
            DetectedPanel(
                rect: $0.normalizedRect,
                confidence: $0.confidence,
                source: .coreML
            )
        }
        var processed = PanelPostProcessor.process(primaryPanels)
        var detectorIdentifier = primaryIdentifier

        if !PanelLayoutQuality.isUsable(processed) {
            let fallbackPanels = (try? fallbackDetector.detectPanels(in: analysisImage)) ?? []
            let fallbackProcessed = PanelPostProcessor.process(fallbackPanels)
            if PanelLayoutQuality.isUsable(fallbackProcessed) {
                processed = fallbackProcessed
                detectorIdentifier = fallbackDetector.identifier
            }
        }
'''
s = replace_once(s, old_primary, new_primary, "panel primary analysis")
write(p, s)

# OCR coordinates delegate the crop/page conversion to the canonical page space.
p = "mreader/OCRCoordinateMapper.swift"
s = read(p)
old = '''    nonisolated static func normalizedPageRect(
        forSliceRect rect: CGRect,
        sourceRect: CGRect
    ) -> CGRect {
        CGRect(
            x: sourceRect.minX + rect.minX * sourceRect.width,
            y: sourceRect.minY + rect.minY * sourceRect.height,
            width: rect.width * sourceRect.width,
            height: rect.height * sourceRect.height
        )
    }
'''
new = '''    nonisolated static func normalizedPageRect(
        forSliceRect rect: CGRect,
        sourceRect: CGRect
    ) -> CGRect {
        MangaPageCoordinateSpace.normalizedPageRect(
            forCropLocalRect: rect,
            cropRect: sourceRect
        )
    }
'''
s = replace_once(s, old, new, "OCR coordinate mapper")
write(p, s)

# OCRPreprocessor: text detections become bounded ROI slices, while empty detections
# keep the exact full-page slicing path.
p = "mreader/OCRPreprocessor.swift"
s = read(p)
s = replace_once(
    s,
    '''    nonisolated static func recognizeCandidatesWithReference(
        in image: UIImage,
        options: Options
    ) async throws -> OCRCandidateRecognitionResult {
''',
    '''    nonisolated static func recognizeCandidatesWithReference(
        in image: UIImage,
        options: Options,
        visionTextRegions: [MangaVisionRegion] = []
    ) async throws -> OCRCandidateRecognitionResult {
''',
    "OCR ROI signature",
)
s = replace_once(
    s,
    '''        let slices = sliceImage(normalizedImage, fullPixelSize: fullSize)
        MReaderLog.aiVision.debug(
            "OCR preprocess slices=\\(slices.count, privacy: .public) strategy=\\(options.recognitionMode.rawValue, privacy: .public) image=\\(Int(fullSize.width), privacy: .public)x\\(Int(fullSize.height), privacy: .public)"
        )
''',
    '''        let plannedRegions = MangaVisionTextROIPlanner.recognitionRegions(from: visionTextRegions)
        let slices = plannedRegions.isEmpty
            ? sliceImage(normalizedImage, fullPixelSize: fullSize)
            : cropImage(
                normalizedImage,
                fullPixelSize: fullSize,
                normalizedRegions: plannedRegions
            )
        MReaderLog.aiVision.debug(
            "OCR preprocess slices=\\(slices.count, privacy: .public) mangaVisionROI=\\(plannedRegions.count, privacy: .public) fallbackFullPage=\\(plannedRegions.isEmpty, privacy: .public) strategy=\\(options.recognitionMode.rawValue, privacy: .public) image=\\(Int(fullSize.width), privacy: .public)x\\(Int(fullSize.height), privacy: .public)"
        )
''',
    "OCR ROI slices",
)
marker = "    nonisolated private static func sliceImage(_ image: UIImage, fullPixelSize: CGSize) -> [(image: UIImage, rect: CGRect)] {\n"
helper = '''    nonisolated private static func cropImage(
        _ image: UIImage,
        fullPixelSize: CGSize,
        normalizedRegions: [CGRect]
    ) -> [(image: UIImage, rect: CGRect)] {
        guard let cgImage = image.cgImage else { return [] }
        let bounds = CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height)
        return normalizedRegions.compactMap { normalized -> (UIImage, CGRect)? in
            var pixelRect = MangaPageCoordinateSpace.pixelRect(
                fromNormalized: normalized,
                imageSize: fullPixelSize
            ).integral.intersection(bounds)
            guard !pixelRect.isNull, pixelRect.width >= 4, pixelRect.height >= 4 else { return nil }
            // Integral rounding can leave maxX/maxY one pixel outside on fractional source sizes.
            pixelRect = pixelRect.intersection(bounds)
            guard let cropped = cgImage.cropping(to: pixelRect) else { return nil }
            return (
                UIImage(cgImage: cropped, scale: image.scale, orientation: image.imageOrientation),
                pixelRect
            )
        }
    }

'''
if marker not in s:
    raise RuntimeError("OCR crop helper marker missing")
s = s.replace(marker, helper + marker, 1)
old_map = '''    nonisolated private static func mapVisionRect(_ visionRect: CGRect, sliceRect: CGRect, fullPixelSize: CGSize) -> CGRect {
        let x = (sliceRect.minX + visionRect.minX * sliceRect.width) / fullPixelSize.width
        let yInSliceFromTop = (1 - visionRect.maxY) * sliceRect.height
        let y = (sliceRect.minY + yInSliceFromTop) / fullPixelSize.height
        let width = visionRect.width * sliceRect.width / fullPixelSize.width
        let height = visionRect.height * sliceRect.height / fullPixelSize.height
        return CGRect(x: x, y: y, width: width, height: height)
    }
'''
new_map = '''    nonisolated private static func mapVisionRect(_ visionRect: CGRect, sliceRect: CGRect, fullPixelSize: CGSize) -> CGRect {
        let localTopLeft = MangaPageCoordinateSpace.topLeftNormalizedRect(fromVisionRect: visionRect)
        let cropNormalized = MangaPageCoordinateSpace.normalizedRect(
            fromPixel: sliceRect,
            imageSize: fullPixelSize
        )
        return MangaPageCoordinateSpace.normalizedPageRect(
            forCropLocalRect: localTopLeft,
            cropRect: cropNormalized
        )
    }
'''
s = replace_once(s, old_map, new_map, "OCR Vision coordinate mapping")
write(p, s)

# MangaOCRPipeline forwards Manga Vision text regions and applies panel-first order.
p = "mreader/MangaOCRPipeline.swift"
s = read(p)
pattern = re.compile(r'''    static func recognize\(
        in image: UIImage,
        options: OCRPreprocessor\.Options
    \) async throws -> OCRPipelineResult \{.*?\n    \}\n\n    static func resolveForDiagnostics''', re.S)
new_func = '''    static func recognize(
        in image: UIImage,
        options: OCRPreprocessor.Options,
        mangaAnalysis: MangaPageAnalysis? = nil
    ) async throws -> OCRPipelineResult {
        let candidateResult = try await OCRPreprocessor.recognizeCandidatesWithReference(
            in: image,
            options: options,
            visionTextRegions: mangaAnalysis?.texts ?? []
        )
        let visionBlocks = candidateResult.blocks
        let verticalBlocks = await JapaneseVerticalOCRService.recognizeIfNeeded(
            in: image,
            existingBlocks: visionBlocks,
            options: options,
            visionKitReference: candidateResult.visionKitReference
        )
        let rawBlocks = visionBlocks + verticalBlocks
        let result = resolveForDiagnostics(
            rawBlocks,
            isRightToLeft: options.isRightToLeft,
            sourceLanguagePreference: options.sourceLanguagePreference,
            visionKitReference: candidateResult.visionKitReference
        )
        guard let mangaAnalysis else { return result }
        return MangaVisionOCROrdering.applyingReadingOrder(
            to: result,
            analysis: mangaAnalysis,
            isRightToLeft: options.isRightToLeft
        )
    }

    static func resolveForDiagnostics'''
s, count = pattern.subn(new_func, s, count=1)
if count != 1:
    raise RuntimeError(f"MangaOCRPipeline recognize patch: {count}")
write(p, s)

# OCR cache: share the page analysis and fall back naturally when the detector has
# no text output or the model is unavailable.
p = "mreader/OCRRecognitionCache.swift"
s = read(p)
s = replace_once(
    s,
    '''    let pageURL: URL
    let fallbackImage: UIImage
    let options: OCRPreprocessor.Options
''',
    '''    let pageURL: URL
    let fallbackImage: UIImage
    let options: OCRPreprocessor.Options
    var comicID: UUID? = nil
    var pageIndex: Int? = nil
''',
    "OCR cache request identity",
)
s = replace_once(
    s,
    '''            "local-ocr-v9-canonical-bubble-region-borderless",
            JapaneseVerticalOCRService.revision,
''',
    '''            "local-ocr-v10-manga-vision-roi-panel-order",
            MangaVisionService.analysisRevision,
            JapaneseVerticalOCRService.revision,
''',
    "OCR cache revision",
)
old_hit = '''        if let cached = cachedResult(forKey: key, isRightToLeft: request.options.isRightToLeft) {
            MReaderLog.aiVision.debug(
                "local OCR cache hit key=\\(key.prefix(10), privacy: .public) blocks=\\(cached.resolvedBlocks.count, privacy: .public)"
            )
            return cached
        }
'''
new_hit = '''        if let cached = cachedResult(forKey: key, isRightToLeft: request.options.isRightToLeft) {
            MReaderLog.aiVision.debug(
                "local OCR cache hit key=\\(key.prefix(10), privacy: .public) blocks=\\(cached.resolvedBlocks.count, privacy: .public)"
            )
            if let analysis = try? await MangaVisionService.shared.analysis(
                comicID: request.comicID,
                pageIndex: request.pageIndex,
                pageURL: request.pageURL,
                image: request.fallbackImage
            ) {
                return MangaVisionOCROrdering.applyingReadingOrder(
                    to: cached,
                    analysis: analysis,
                    isRightToLeft: request.options.isRightToLeft
                )
            }
            return cached
        }
'''
s = replace_once(s, old_hit, new_hit, "OCR cache hit analysis")
old_task = '''        let task = Task(priority: .userInitiated) {
            let image = await OCRPreprocessor.highResolutionImage(
                from: request.pageURL,
                fallback: request.fallbackImage
            ) ?? request.fallbackImage
            return try await MangaOCRPipeline.recognize(in: image, options: request.options)
        }
'''
new_task = '''        let task = Task(priority: .userInitiated) {
            let image = await OCRPreprocessor.highResolutionImage(
                from: request.pageURL,
                fallback: request.fallbackImage
            ) ?? request.fallbackImage
            let analysis = try? await MangaVisionService.shared.analysis(
                comicID: request.comicID,
                pageIndex: request.pageIndex,
                pageURL: request.pageURL,
                image: image
            )
            return try await MangaOCRPipeline.recognize(
                in: image,
                options: request.options,
                mangaAnalysis: analysis
            )
        }
'''
s = replace_once(s, old_task, new_task, "OCR cache task analysis")
write(p, s)

# Translation request identity and structured Manga Vision context.
p = "mreader/AITranslationPageCoordinator.swift"
s = read(p)
s = replace_once(
    s,
    '''    var previousContext: String
    /// Stable scope/page identity for chapter-local context. Existing callers
''',
    '''    var previousContext: String
    /// Optional business identity used to join Manga Vision inference with Guided Panel/OCR.
    var comicID: UUID? = nil
    /// Stable scope/page identity for chapter-local context. Existing callers
''',
    "translation comic identity",
)
s = replace_once(
    s,
    '''        let cacheRequest = OCRRecognitionCacheRequest(
            pageURL: request.pageURL,
            fallbackImage: request.image,
            options: options
        )
''',
    '''        let cacheRequest = OCRRecognitionCacheRequest(
            pageURL: request.pageURL,
            fallbackImage: request.image,
            options: options,
            comicID: request.comicID,
            pageIndex: request.pageIndex
        )
''',
    "translation OCR request identity",
)
s = replace_once(
    s,
    '''                previousContext: request.previousContext,
                visionModelDescriptor: request.configuration.visionModelDescriptor,
''',
    '''                previousContext: await MangaVisionTranslationContext.context(
                    for: request,
                    blocks: []
                ),
                visionModelDescriptor: request.configuration.visionModelDescriptor,
''',
    "vision translation semantic context",
)
old_translate_guard = '''        guard !translated.isEmpty else {
            return AITranslationOCRResult(blocks: [], missingBlockIDs: [])
        }

        try await applyBatchTranslationSafely(to: &translated, indexes: Array(translated.indices), request: request)
        let missing = translated.indices.filter {
'''
new_translate_guard = '''        guard !translated.isEmpty else {
            return AITranslationOCRResult(blocks: [], missingBlockIDs: [])
        }

        var contextualRequest = request
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
'''
s = replace_once(s, old_translate_guard, new_translate_guard, "OCR translation semantic context")
s = replace_once(
    s,
    '''            try await applyBatchTranslationSafely(
                to: &translated,
                indexes: missing,
                request: request
            )
''',
    '''            try await applyBatchTranslationSafely(
                to: &translated,
                indexes: missing,
                request: contextualRequest
            )
''',
    "OCR retry semantic context",
)
write(p, s)

# Reader: Guided Panel uses the preferred book/page identity, and translation
# requests carry the same identity so every consumer can join one analysis.
p = "mreader/ReaderView.swift"
s = read(p)
s = replace_once(
    s,
    '''        let detectedLayout = await PanelDetectionService.shared.layout(
            for: pageURL,
            image: image,
            isRightToLeft: readingDirection == .rightToLeft
        )
''',
    '''        let detectedLayout = await PanelDetectionService.shared.layout(
            comicID: comic.id,
            pageIndex: page.index,
            pageURL: pageURL,
            image: image,
            isRightToLeft: readingDirection == .rightToLeft
        )
''',
    "Guided Panel Manga Vision identity",
)
# There are two page-request constructors in ReaderView. Both have a local comicID.
needle = '''                        sourceLanguagePreference: comic.translationSourceLanguage,
                        previousContext: "",
                        contextScopeID: TranslationContextBuilder.scopeID(
'''
replacement = '''                        sourceLanguagePreference: comic.translationSourceLanguage,
                        previousContext: "",
                        comicID: comicID,
                        contextScopeID: TranslationContextBuilder.scopeID(
'''
s = replace_once(s, needle, replacement, "prefetch translation comic id")
needle = '''            sourceLanguagePreference: comicTranslationSourceLanguage,
            previousContext: "",
            contextScopeID: TranslationContextBuilder.scopeID(
'''
replacement = '''            sourceLanguagePreference: comicTranslationSourceLanguage,
            previousContext: "",
            comicID: comicID,
            contextScopeID: TranslationContextBuilder.scopeID(
'''
s = replace_once(s, needle, replacement, "page translation comic id")
write(p, s)

print("Manga Vision integration patches applied")
