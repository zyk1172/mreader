import CoreGraphics
import CryptoKit
import Foundation

/// 整本离线翻译的页级状态。它与 Reader 的实时缓存状态完全分离。
nonisolated enum OfflineTranslationPageState: String, Codable, CaseIterable, Sendable {
    case pending
    case processing
    case completed
    case noText
    case partial
    case failed
    case stale

    var countsAsCoverage: Bool {
        switch self {
        case .completed, .noText, .partial:
            return true
        case .pending, .processing, .failed, .stale:
            return false
        }
    }

    var needsTranslationWork: Bool {
        switch self {
        case .completed, .noText:
            return false
        case .pending, .processing, .partial, .failed, .stale:
            return true
        }
    }

    var isUsableOverlay: Bool {
        switch self {
        case .completed, .noText, .partial:
            return true
        case .pending, .processing, .failed, .stale:
            return false
        }
    }
}

/// 用页文件状态计算断点续传集合；任务记录中的 offset/数组只是兼容展示字段。
nonisolated enum OfflineTranslationPageFacts {
    static func remainingPageIndexes(
        plannedPageIndexes: [Int],
        states: [Int: OfflineTranslationPageState],
        excluding: Set<Int> = []
    ) -> [Int] {
        plannedPageIndexes.filter { pageIndex in
            !excluding.contains(pageIndex)
                && (states[pageIndex]?.needsTranslationWork ?? true)
        }
    }

    static func processedPageCount(
        plannedPageIndexes: [Int],
        states: [Int: OfflineTranslationPageState]
    ) -> Int {
        plannedPageIndexes.reduce(into: 0) { count, pageIndex in
            guard let state = states[pageIndex] else { return }
            if state == .completed || state == .noText || state == .partial || state == .failed {
                count += 1
            }
        }
    }
}

nonisolated enum OfflineTranslationJobState: String, Codable, CaseIterable, Sendable {
    case queued
    case running
    case paused
    case interrupted
    case needsConfiguration
    case completed
    case completedWithFailures
    case cancelled

    var isTerminal: Bool {
        switch self {
        case .completed, .completedWithFailures, .cancelled:
            return true
        case .queued, .running, .paused, .interrupted, .needsConfiguration:
            return false
        }
    }

    /// 系统后台任务只能接管已经排队、被系统中断或仍在运行中的任务；用户主动暂停、配置
    /// 错误和已结束任务都必须等待明确的用户操作，不能由旧 BG request 擅自重启。
    var isBackgroundResumable: Bool {
        switch self {
        case .queued, .interrupted, .running:
            return true
        case .paused, .needsConfiguration, .completed, .completedWithFailures, .cancelled:
            return false
        }
    }

    static func completionState(failedPageCount: Int, partialPageCount: Int) -> Self {
        failedPageCount > 0 || partialPageCount > 0
            ? .completedWithFailures
            : .completed
    }
}

/// 自动原文语言的整本共识。单页判断仍使用 TranslationSourceResolver；只有多个有效页面
/// 对同一语言形成稳定多数后，Coordinator 才把 sourceLanguage 从 automatic 锁定。
nonisolated struct OfflineTranslationSourceLanguageConsensus: Sendable, Equatable {
    private(set) var votes: [String: Double]
    private(set) var sampleCount: Int

    init(votes: [String: Double] = [:], sampleCount: Int = 0) {
        self.votes = votes
        self.sampleCount = sampleCount
    }

    mutating func register(languageCode: String, confidence: Double) {
        guard !languageCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              confidence.isFinite,
              confidence >= 0.60 else { return }
        votes[languageCode, default: 0] += confidence
        sampleCount += 1
    }

    var resolvedLanguageCode: String? {
        guard sampleCount >= 3,
              let winner = votes.max(by: { $0.value < $1.value }) else {
            return nil
        }
        let total = votes.values.reduce(0, +)
        guard total > 0,
              winner.value / total >= 0.65,
              winner.value >= 1.8 else {
            return nil
        }
        return winner.key
    }
}

nonisolated enum OfflineTranslationPauseReason: String, Codable, Sendable {
    case providerPolicyBlocked
    case lowDiskSpace
    case userRequested
    case interrupted
}

/// 整本翻译的处理管线。旧 Job 没有该字段时由恢复逻辑兼容为 Vision。
nonisolated enum OfflineTranslationProcessingMode: String, Codable, CaseIterable, Sendable {
    case ocrText
    case vision
}

enum OfflineTranslationNotificationKey {
    static let comicID = "comicID"
    static let setID = "setID"
    static let pageIndex = "pageIndex"
}

extension Notification.Name {
    static let offlineTranslationPageDidUpdate = Notification.Name("MReader.offlineTranslationPageDidUpdate")
}

nonisolated enum OfflineTranslationStartIntent: Sendable, Equatable {
    case entire
    case fromCurrent
    case retryFailed(setID: UUID)
    case missing(setID: UUID)

    var sourceSetID: UUID? {
        switch self {
        case .entire, .fromCurrent: return nil
        case .retryFailed(let setID), .missing(let setID): return setID
        }
    }
}

nonisolated enum OfflineTranslationSelection: Codable, Equatable, Sendable {
    case entireComic
    case fromPage(Int)
    case range(start: Int, end: Int)
    case missingPages
    case failedPages
    case explicitPages([Int])

    private enum CodingKeys: String, CodingKey {
        case kind
        case page
        case start
        case end
        case pageIndexes
    }

    private enum Kind: String, Codable {
        case entireComic
        case fromPage
        case range
        case missingPages
        case failedPages
        case explicitPages
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        switch kind {
        case .entireComic:
            self = .entireComic
        case .fromPage:
            self = .fromPage(try container.decode(Int.self, forKey: .page))
        case .range:
            self = .range(
                start: try container.decode(Int.self, forKey: .start),
                end: try container.decode(Int.self, forKey: .end)
            )
        case .missingPages:
            self = .missingPages
        case .failedPages:
            self = .failedPages
        case .explicitPages:
            self = .explicitPages(try container.decode([Int].self, forKey: .pageIndexes))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .entireComic:
            try container.encode(Kind.entireComic, forKey: .kind)
        case .fromPage(let page):
            try container.encode(Kind.fromPage, forKey: .kind)
            try container.encode(page, forKey: .page)
        case .range(let start, let end):
            try container.encode(Kind.range, forKey: .kind)
            try container.encode(start, forKey: .start)
            try container.encode(end, forKey: .end)
        case .missingPages:
            try container.encode(Kind.missingPages, forKey: .kind)
        case .failedPages:
            try container.encode(Kind.failedPages, forKey: .kind)
        case .explicitPages(let pageIndexes):
            try container.encode(Kind.explicitPages, forKey: .kind)
            try container.encode(pageIndexes, forKey: .pageIndexes)
        }
    }

    /// UI 使用 1-based 页码；持久化和任务执行统一使用 0-based 页索引。
    func pageIndexes(
        totalPages: Int,
        currentPageIndex: Int = 0,
        existingStates: [Int: OfflineTranslationPageState] = [:]
    ) throws -> [Int] {
        guard totalPages > 0 else {
            throw OfflineTranslationSelectionError.emptyComic
        }
        let pageIndexes: [Int]
        switch self {
        case .entireComic:
            pageIndexes = Array(0..<totalPages)
        case .fromPage(let page):
            guard (0..<totalPages).contains(page) else {
                throw OfflineTranslationSelectionError.pageOutOfBounds(page)
            }
            pageIndexes = Array(page..<totalPages)
        case .range(let start, let end):
            guard start <= end else {
                throw OfflineTranslationSelectionError.invalidRange(start: start, end: end)
            }
            guard (0..<totalPages).contains(start), (0..<totalPages).contains(end) else {
                throw OfflineTranslationSelectionError.rangeOutOfBounds(start: start, end: end)
            }
            pageIndexes = Array(start...end)
        case .missingPages:
            pageIndexes = (0..<totalPages).filter { index in
                guard let state = existingStates[index] else { return true }
                return state.needsTranslationWork
            }
        case .failedPages:
            pageIndexes = (0..<totalPages).filter { existingStates[$0] == .failed }
        case .explicitPages(let indexes):
            guard indexes.allSatisfy({ (0..<totalPages).contains($0) }) else {
                throw OfflineTranslationSelectionError.rangeOutOfBounds(start: indexes.min() ?? 0, end: indexes.max() ?? 0)
            }
            pageIndexes = indexes
        }
        guard !pageIndexes.isEmpty else {
            throw OfflineTranslationSelectionError.noMatchingPages
        }
        _ = currentPageIndex // Kept in the signature to make the UI/DTO boundary explicit.
        return pageIndexes
    }
}

nonisolated enum OfflineTranslationSelectionError: LocalizedError, Equatable, Sendable {
    case emptyComic
    case pageOutOfBounds(Int)
    case invalidRange(start: Int, end: Int)
    case rangeOutOfBounds(start: Int, end: Int)
    case noMatchingPages

    var errorDescription: String? {
        switch self {
        case .emptyComic:
            return "漫画没有可翻译的页面"
        case .pageOutOfBounds(let page):
            return "页面索引越界：\(page)"
        case .invalidRange(let start, let end):
            return "页面范围无效：\(start)-\(end)"
        case .rangeOutOfBounds(let start, let end):
            return "页面范围越界：\(start)-\(end)"
        case .noMatchingPages:
            return "没有符合条件的页面"
        }
    }
}

nonisolated struct OfflineTranslationRect: Codable, Equatable, Sendable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    init(_ rect: CGRect) {
        self.init(
            x: Double(rect.minX),
            y: Double(rect.minY),
            width: Double(rect.width),
            height: Double(rect.height)
        )
    }

    var cgRect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }
}

nonisolated struct OfflineTranslationPoint: Codable, Equatable, Sendable {
    let x: Double
    let y: Double

    init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    init(_ point: CGPoint) {
        self.init(x: Double(point.x), y: Double(point.y))
    }

    var cgPoint: CGPoint { CGPoint(x: x, y: y) }
}

/// 稳定的页级 DTO。不要把 TextBlock 直接编码进离线文件，避免实时模型字段变化破坏历史译文。
nonisolated struct OfflineTranslatedBlock: Codable, Equatable, Sendable, Identifiable {
    let id: String
    let sourceText: String
    let translation: String?
    let translationLines: [String]
    let textBox: OfflineTranslationRect
    let bubbleBox: OfflineTranslationRect?
    let textPolygon: [OfflineTranslationPoint]
    let bubblePolygon: [OfflineTranslationPoint]
    let confidence: Double
    let classification: String
    let estimatedFontScale: Double
    let textColorHex: String?
    let textOrientation: TextOrientation

    private enum CodingKeys: String, CodingKey {
        case id, sourceText, translation, translationLines, lines, textBox, bubbleBox
        case textPolygon, bubblePolygon, polygon, confidence, classification, estimatedFontScale, textColorHex, textOrientation
    }

    init(
        id: String,
        sourceText: String,
        translation: String?,
        translationLines: [String],
        textBox: OfflineTranslationRect,
        bubbleBox: OfflineTranslationRect? = nil,
        textPolygon: [OfflineTranslationPoint] = [],
        bubblePolygon: [OfflineTranslationPoint] = [],
        confidence: Double,
        classification: String,
        estimatedFontScale: Double,
        textColorHex: String? = nil,
        textOrientation: TextOrientation? = nil
    ) {
        self.id = id
        self.sourceText = sourceText
        self.translation = translation
        self.translationLines = translationLines
        self.textBox = textBox
        self.bubbleBox = bubbleBox
        self.textPolygon = textPolygon
        self.bubblePolygon = bubblePolygon
        self.confidence = confidence
        self.classification = classification
        self.estimatedFontScale = estimatedFontScale
        self.textColorHex = textColorHex
        self.textOrientation = textOrientation ?? .inferred(from: textBox.cgRect)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        sourceText = try container.decode(String.self, forKey: .sourceText)
        translation = try container.decodeIfPresent(String.self, forKey: .translation)
        translationLines = try container.decodeIfPresent([String].self, forKey: .translationLines)
            ?? (try container.decodeIfPresent([String].self, forKey: .lines))
            ?? []
        textBox = try container.decode(OfflineTranslationRect.self, forKey: .textBox)
        bubbleBox = try container.decodeIfPresent(OfflineTranslationRect.self, forKey: .bubbleBox)
        textPolygon = try container.decodeIfPresent([OfflineTranslationPoint].self, forKey: .textPolygon)
            ?? (try container.decodeIfPresent([OfflineTranslationPoint].self, forKey: .polygon))
            ?? []
        bubblePolygon = try container.decodeIfPresent([OfflineTranslationPoint].self, forKey: .bubblePolygon) ?? []
        confidence = try container.decode(Double.self, forKey: .confidence)
        classification = try container.decode(String.self, forKey: .classification)
        estimatedFontScale = try container.decode(Double.self, forKey: .estimatedFontScale)
        textColorHex = try container.decodeIfPresent(String.self, forKey: .textColorHex)
        textOrientation = try container.decodeIfPresent(TextOrientation.self, forKey: .textOrientation)
            ?? .inferred(from: textBox.cgRect)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(sourceText, forKey: .sourceText)
        try container.encodeIfPresent(translation, forKey: .translation)
        try container.encode(translationLines, forKey: .translationLines)
        try container.encode(textBox, forKey: .textBox)
        try container.encodeIfPresent(bubbleBox, forKey: .bubbleBox)
        try container.encode(textPolygon, forKey: .textPolygon)
        try container.encode(bubblePolygon, forKey: .bubblePolygon)
        try container.encode(confidence, forKey: .confidence)
        try container.encode(classification, forKey: .classification)
        try container.encode(estimatedFontScale, forKey: .estimatedFontScale)
        try container.encodeIfPresent(textColorHex, forKey: .textColorHex)
        try container.encode(textOrientation, forKey: .textOrientation)
    }

    init(block: TextBlock, id: String? = nil) {
        let allowedClassifications = Set([
            "dialogue", "narration", "soundEffect", "url",
            "advertisement", "watermark", "copyright", "pageNumber"
        ])
        let sourceClassification = block.ocrSource
            .split(separator: ":")
            .last?
            .split(separator: "+", maxSplits: 1)
            .first
            .map(String.init)
        let classification: String
        if allowedClassifications.contains(block.ocrSource) {
            classification = block.ocrSource
        } else if let sourceClassification,
                  allowedClassifications.contains(sourceClassification) {
            classification = sourceClassification
        } else {
            classification = "dialogue"
        }
        self.init(
            id: id ?? block.id.uuidString,
            sourceText: block.text,
            translation: block.translation,
            translationLines: block.translationLines,
            textBox: OfflineTranslationRect(block.boundingBox),
            bubbleBox: block.bubbleBox.map(OfflineTranslationRect.init),
            textPolygon: block.polygon.map(OfflineTranslationPoint.init),
            bubblePolygon: block.bubblePolygon.map(OfflineTranslationPoint.init),
            confidence: block.confidence,
            classification: classification,
            estimatedFontScale: block.estimatedFontScale,
            textColorHex: block.textColorHex,
            textOrientation: block.textOrientation
        )
    }

    func textBlock() -> TextBlock {
        TextBlock(
            id: stableUUID(for: id),
            text: sourceText,
            boundingBox: textBox.cgRect,
            translation: translation,
            confidence: confidence,
            ocrSource: "offline:\(classification)",
            estimatedFontScale: estimatedFontScale,
            textColorHex: textColorHex,
            bubbleBox: bubbleBox?.cgRect,
            polygon: textPolygon.map(\.cgPoint),
            bubblePolygon: bubblePolygon.map(\.cgPoint),
            translationLines: translationLines,
            textOrientation: textOrientation
        )
    }

    private func stableUUID(for value: String) -> UUID {
        var bytes = Array(SHA256.hash(data: Data(value.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}

nonisolated struct OfflineTranslatedPage: Codable, Equatable, Sendable {
    /// v2 起字号尺度与文字方向都基于物理显示轴。v1 已保存的 geometry 无法可靠修复，
    /// 必须重新翻译而不是继续显示旧的错误字号。
    static let currentSchemaVersion = 2

    let schemaVersion: Int
    let comicID: UUID
    let setID: UUID
    let pageIndex: Int
    let sourceFingerprint: String
    let pixelWidth: Int
    let pixelHeight: Int
    let blocks: [OfflineTranslatedBlock]
    var state: OfflineTranslationPageState
    let savedAt: Date
    let providerID: UUID
    let visionModel: String
    var resolvedSourceLanguage: String?
    var errorMessage: String?

    init(
        comicID: UUID,
        setID: UUID,
        pageIndex: Int,
        sourceFingerprint: String,
        pixelWidth: Int,
        pixelHeight: Int,
        blocks: [OfflineTranslatedBlock],
        state: OfflineTranslationPageState,
        savedAt: Date = Date(),
        providerID: UUID,
        visionModel: String,
        resolvedSourceLanguage: String? = nil,
        errorMessage: String? = nil
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.comicID = comicID
        self.setID = setID
        self.pageIndex = pageIndex
        self.sourceFingerprint = sourceFingerprint
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.blocks = blocks
        self.state = state
        self.savedAt = savedAt
        self.providerID = providerID
        self.visionModel = visionModel
        self.resolvedSourceLanguage = resolvedSourceLanguage
        self.errorMessage = errorMessage
    }
}

nonisolated struct OfflineTranslationSetManifest: Codable, Equatable, Sendable, Identifiable {
    static let currentSchemaVersion = 2

    let schemaVersion: Int
    let id: UUID
    let comicID: UUID
    let sourceLanguage: TranslationSourceLanguage
    var resolvedSourceLanguage: String?
    let targetLanguage: TranslationTargetLanguage
    let providerID: UUID
    let providerName: String
    let baseURL: String
    let visionModel: String
    let promptRevision: String
    let promptSnapshot: String
    let totalPages: Int
    var completedPageCount: Int
    var noTextPageCount: Int
    var partialPageCount: Int
    var failedPageCount: Int
    var stalePageCount: Int
    var coverage: Double
    var failureMessages: [String: String]
    let createdAt: Date
    var updatedAt: Date
    let derivedFromSetID: UUID?
    /// 用于派生集合的廉价源版本判断；页面指纹仍由 Reader 在最终使用前兜底校验。
    var sourceRevision: String?
    /// 新任务冻结的处理配置；旧 manifest 缺失时按旧行为回退到 Vision。
    let processingMode: OfflineTranslationProcessingMode?
    let textModel: String?
    let ocrRecognitionMode: OCRRecognitionMode?
    let usesVisualOCRVerification: Bool?

    init(
        id: UUID = UUID(),
        comicID: UUID,
        sourceLanguage: TranslationSourceLanguage,
        targetLanguage: TranslationTargetLanguage,
        providerID: UUID,
        providerName: String,
        baseURL: String,
        visionModel: String,
        promptRevision: String,
        promptSnapshot: String,
        totalPages: Int,
        createdAt: Date = Date(),
        derivedFromSetID: UUID? = nil,
        sourceRevision: String? = nil,
        processingMode: OfflineTranslationProcessingMode? = nil,
        textModel: String? = nil,
        ocrRecognitionMode: OCRRecognitionMode? = nil,
        usesVisualOCRVerification: Bool? = nil
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.id = id
        self.comicID = comicID
        self.sourceLanguage = sourceLanguage
        self.resolvedSourceLanguage = nil
        self.targetLanguage = targetLanguage
        self.providerID = providerID
        self.providerName = providerName
        self.baseURL = baseURL
        self.visionModel = visionModel
        self.promptRevision = promptRevision
        self.promptSnapshot = promptSnapshot
        self.totalPages = totalPages
        self.completedPageCount = 0
        self.noTextPageCount = 0
        self.partialPageCount = 0
        self.failedPageCount = 0
        self.stalePageCount = 0
        self.coverage = 0
        self.failureMessages = [:]
        self.createdAt = createdAt
        self.updatedAt = createdAt
        self.derivedFromSetID = derivedFromSetID
        self.sourceRevision = sourceRevision
        self.processingMode = processingMode
        self.textModel = textModel
        self.ocrRecognitionMode = ocrRecognitionMode
        self.usesVisualOCRVerification = usesVisualOCRVerification
    }

    var coveredPageCount: Int {
        completedPageCount + noTextPageCount + partialPageCount
    }

    /// 只有所有页面都已经以 completed/noText 覆盖，才可以替换当前完整译本。
    /// partial、failed、stale 或缺失页面都必须保留旧 Set 的回退机会。
    var isCompleteSet: Bool {
        coveredPageCount == totalPages
            && partialPageCount == 0
            && failedPageCount == 0
            && stalePageCount == 0
    }
}

nonisolated struct OfflineTranslationIndex: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let comicID: UUID
    var activeSetID: UUID?
    var activeSetIDsByTargetLanguage: [String: UUID]
    var setIDs: [UUID]

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, comicID, activeSetID, activeSetIDsByTargetLanguage, setIDs
    }

    init(comicID: UUID, activeSetID: UUID? = nil, activeSetIDsByTargetLanguage: [String: UUID] = [:], setIDs: [UUID] = []) {
        self.schemaVersion = Self.currentSchemaVersion
        self.comicID = comicID
        self.activeSetID = activeSetID
        self.activeSetIDsByTargetLanguage = activeSetIDsByTargetLanguage
        self.setIDs = setIDs
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? Self.currentSchemaVersion
        comicID = try container.decode(UUID.self, forKey: .comicID)
        activeSetID = try container.decodeIfPresent(UUID.self, forKey: .activeSetID)
        activeSetIDsByTargetLanguage = try container.decodeIfPresent([String: UUID].self, forKey: .activeSetIDsByTargetLanguage) ?? [:]
        setIDs = try container.decodeIfPresent([UUID].self, forKey: .setIDs) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(comicID, forKey: .comicID)
        try container.encodeIfPresent(activeSetID, forKey: .activeSetID)
        try container.encode(activeSetIDsByTargetLanguage, forKey: .activeSetIDsByTargetLanguage)
        try container.encode(setIDs, forKey: .setIDs)
    }
}

nonisolated struct OfflineTranslationJobRecord: Codable, Equatable, Sendable, Identifiable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let id: UUID
    let comicID: UUID
    let setID: UUID
    var state: OfflineTranslationJobState
    let selection: OfflineTranslationSelection
    let pageIndexes: [Int]
    var nextPageOffset: Int
    var currentPageIndex: Int?
    /// 当前批次正在执行的页面。它只用于恢复和进度展示，页面文件状态才是事实来源。
    var activePageIndexes: [Int]?
    let providerID: UUID
    let providerName: String
    let baseURL: String
    let visionModel: String
    let sourceLanguage: TranslationSourceLanguage
    var resolvedSourceLanguage: String?
    /// automatic 模式下的跨页投票；旧任务缺失字段时按空共识恢复。
    var sourceLanguageVotes: [String: Double]?
    var sourceLanguageSampleCount: Int?
    let targetLanguage: TranslationTargetLanguage
    let promptRevision: String
    let promptSnapshot: String
    /// 用户的风格指令单独保存；旧版本 job 没有该字段时由恢复逻辑使用默认值。
    let styleInstructions: String?
    /// 新 Set 完成后是否自动成为 active；旧版本任务按兼容策略默认 true。
    let activateWhenComplete: Bool?
    let readingDirectionRaw: String
    let totalPages: Int
    var completedPageIndexes: [Int]
    var noTextPageIndexes: [Int]
    /// 旧任务缺失该字段时按空数组兼容；partial 页面仍需后续重翻。
    var partialPageIndexes: [Int]?
    var failedPageIndexes: [Int]
    var retryCounts: [String: Int]
    /// 连续触发 Provider 内容策略拒绝的次数；旧 job 缺失时按 0 处理。
    var consecutiveProviderPolicyFailures: Int?
    /// 暂停原因的稳定 raw value，避免 UI 依赖易变的错误原文。
    var pauseReason: String?
    /// 新任务冻结的处理配置；旧 Job 缺失时恢复逻辑按旧 Vision 行为兼容。
    let processingMode: OfflineTranslationProcessingMode?
    let textModel: String?
    let ocrRecognitionMode: OCRRecognitionMode?
    let usesVisualOCRVerification: Bool?
    var lastError: String?
    let createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        comicID: UUID,
        setID: UUID,
        state: OfflineTranslationJobState = .queued,
        selection: OfflineTranslationSelection,
        pageIndexes: [Int],
        providerID: UUID,
        providerName: String,
        baseURL: String,
        visionModel: String,
        sourceLanguage: TranslationSourceLanguage,
        targetLanguage: TranslationTargetLanguage,
        promptRevision: String,
        promptSnapshot: String,
        styleInstructions: String? = nil,
        activateWhenComplete: Bool = true,
        readingDirectionRaw: String,
        totalPages: Int,
        processingMode: OfflineTranslationProcessingMode? = .ocrText,
        textModel: String? = nil,
        ocrRecognitionMode: OCRRecognitionMode? = .adaptive,
        usesVisualOCRVerification: Bool? = false,
        createdAt: Date = Date()
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.id = id
        self.comicID = comicID
        self.setID = setID
        self.state = state
        self.selection = selection
        self.pageIndexes = pageIndexes
        self.nextPageOffset = 0
        self.currentPageIndex = nil
        self.activePageIndexes = []
        self.providerID = providerID
        self.providerName = providerName
        self.baseURL = baseURL
        self.visionModel = visionModel
        self.sourceLanguage = sourceLanguage
        self.resolvedSourceLanguage = nil
        self.sourceLanguageVotes = [:]
        self.sourceLanguageSampleCount = 0
        self.targetLanguage = targetLanguage
        self.promptRevision = promptRevision
        self.promptSnapshot = promptSnapshot
        self.styleInstructions = styleInstructions
        self.activateWhenComplete = activateWhenComplete
        self.readingDirectionRaw = readingDirectionRaw
        self.totalPages = totalPages
        self.completedPageIndexes = []
        self.noTextPageIndexes = []
        self.partialPageIndexes = []
        self.failedPageIndexes = []
        self.retryCounts = [:]
        self.consecutiveProviderPolicyFailures = 0
        self.pauseReason = nil
        self.processingMode = processingMode
        self.textModel = textModel
        self.ocrRecognitionMode = ocrRecognitionMode
        self.usesVisualOCRVerification = usesVisualOCRVerification
        self.lastError = nil
        self.createdAt = createdAt
        self.updatedAt = createdAt
    }
}

nonisolated struct OfflineTranslationSetSummary: Identifiable, Sendable {
    let manifest: OfflineTranslationSetManifest
    let isActive: Bool
    let jobs: [OfflineTranslationJobRecord]

    var id: UUID { manifest.id }
}

nonisolated enum OfflineTranslationStorageError: LocalizedError, Sendable {
    case invalidPage
    case invalidSet
    case writeFailed(String)
    case lowDiskSpace

    var errorDescription: String? {
        switch self {
        case .invalidPage: return "离线译文页面数据无效"
        case .invalidSet: return "离线译文集合数据无效"
        case .writeFailed(let message): return "离线译文保存失败：\(message)"
        case .lowDiskSpace: return "设备可用空间不足，离线翻译已暂停"
        }
    }
}

nonisolated enum OfflineTranslationConfigurationError: LocalizedError, Sendable {
    case missingProvider
    case missingAPIKey
    case invalidBaseURL
    case missingVisionModel
    case missingTextModel

    var errorDescription: String? {
        switch self {
        case .missingProvider: return "没有可用的 AI Provider"
        case .missingAPIKey: return "当前 Provider 没有 API Key"
        case .invalidBaseURL: return "当前 Provider 的 Base URL 无效"
        case .missingVisionModel: return "当前 Provider 没有配置 Vision Model"
        case .missingTextModel: return "当前 Provider 没有配置 Text Model"
        }
    }
}

nonisolated enum OfflineTranslationRetryDecision: Equatable, Sendable {
    case needsConfiguration
    case retry(afterSeconds: UInt64)
    case fail
}

/// 纯策略层，便于在不发起网络请求的情况下回归 401/429/格式错误行为。
nonisolated enum OfflineTranslationRetryPolicy {
    static let backoffSeconds: [UInt64] = [2, 5, 15]

    private static func isRetryableMessage(_ message: String) -> Bool {
        let lowercased = message.lowercased()
        return lowercased.contains("timeout")
            || lowercased.contains("timed out")
            || lowercased.contains("json")
            || lowercased.contains("坐标")
            || lowercased.contains("格式")
            || lowercased.contains("network")
    }

    private static func isPolicyMessage(_ message: String) -> Bool {
        let lowercased = message.lowercased()
        return lowercased.contains("1301")
            || lowercased.contains("policy")
            || lowercased.contains("unsafe")
            || lowercased.contains("safety")
            || lowercased.contains("moderation")
            || lowercased.contains("内容策略")
            || lowercased.contains("敏感")
    }

    private static func requiresConfiguration(statusCode: Int?, message: String) -> Bool {
        guard let statusCode else { return false }
        if statusCode == 401 { return true }
        // 403 既可能是鉴权失败，也可能是 Provider 的内容审查；先看消息再决定。
        return statusCode == 403 && !isPolicyMessage(message)
    }

    static func decision(for error: Error, attempt: Int) -> OfflineTranslationRetryDecision {
        var retryAfterSeconds: UInt64?
        if let requestError = error as? AITranslationRequestError,
           case .server(_, let statusCode, let message) = requestError {
            if requiresConfiguration(statusCode: statusCode, message: message) {
                return .needsConfiguration
            }
            let retryableStatus = statusCode == 408
                || statusCode == 409
                || statusCode == 429
                || (statusCode ?? 0) >= 500
            guard retryableStatus else { return .fail }
        } else if let requestError = error as? AITranslationRequestError,
                  case .serverWithRetryAfter(_, let statusCode, let message, let retryAfter) = requestError {
            if requiresConfiguration(statusCode: statusCode, message: message) {
                return .needsConfiguration
            }
            let retryableStatus = statusCode == 408
                || statusCode == 409
                || statusCode == 429
                || (statusCode ?? 0) >= 500
            guard retryableStatus else { return .fail }
            retryAfterSeconds = retryAfter
        } else {
            guard isRetryableMessage(error.localizedDescription) else { return .fail }
        }

        guard backoffSeconds.indices.contains(max(attempt, 0)) else { return .fail }
        return .retry(afterSeconds: retryAfterSeconds ?? backoffSeconds[max(attempt, 0)])
    }
}

nonisolated enum OfflineTranslationPolicyCircuit {
    static let refusalThreshold = 3

    static func isProviderRefusal(_ error: Error) -> Bool {
        let message = error.localizedDescription.lowercased()
        let statusCode: Int?
        if let requestError = error as? AITranslationRequestError {
            switch requestError {
            case .server(_, let status, _), .serverWithRetryAfter(_, let status, _, _):
                statusCode = status
            default:
                statusCode = nil
            }
        } else {
            statusCode = nil
        }
        guard statusCode == 400 || statusCode == 403 else { return false }
        return message.contains("1301")
            || message.contains("policy")
            || message.contains("unsafe")
            || message.contains("safety")
            || message.contains("内容策略")
            || message.contains("敏感")
    }
}

nonisolated enum OfflineTranslationFingerprint {
    static func sha256(for data: Data) -> String {
        hex(SHA256.hash(data: data))
    }

    static func sha256(
        fileAt fileURL: URL,
        chunkSize: Int = 8 * 1024 * 1024
    ) throws -> String {
        precondition(chunkSize > 0)

        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }

        var hasher = SHA256()
        while true {
            guard let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty else {
                break
            }
            hasher.update(data: chunk)
        }

        return hex(hasher.finalize())
    }

    private static func hex<S: Sequence>(_ digest: S) -> String where S.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}

nonisolated extension TextBlock {
    func offlineTranslatedBlock(id: String? = nil) -> OfflineTranslatedBlock {
        OfflineTranslatedBlock(block: self, id: id)
    }
}
