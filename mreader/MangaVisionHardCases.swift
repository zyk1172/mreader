import CryptoKit
import Foundation
import ImageIO
import UIKit
import ZIPFoundation

nonisolated enum MangaVisionHardCaseReviewState: String, Codable, CaseIterable, Sendable {
    case unreviewed
    case reviewed
    case annotated
    case rejected
    case exported
}

nonisolated enum MangaVisionHardCaseAnalysisState: String, Codable, Sendable {
    case available
    case unavailable
    case pending
}

nonisolated enum MangaVisionHardCaseInferenceMode: String, Codable, CaseIterable, Sendable {
    case full
    case halfLeft
    case halfRight
    case unknown
}

nonisolated enum MangaVisionHardCaseImageRetentionPolicy: String, Codable, CaseIterable, Sendable {
    case referenceOnly
    case copyOnCapture
    case copyOnExport

    static let defaultsKey = "mangavision_hard_case_retention_policy"
    static let developmentDefault = MangaVisionHardCaseImageRetentionPolicy.copyOnCapture
}

nonisolated enum MangaVisionHardCaseAffectedArea: String, Codable, CaseIterable, Sendable, Hashable {
    case frame
    case text
    case face
    case body
    case balloon
    case readingOrder = "reading_order"
    case ocrTranslation = "ocr_translation"
    case other

    var displayName: String {
        switch self {
        case .frame: "Frame"
        case .text: "Text"
        case .face: "Face"
        case .body: "Body"
        case .balloon: "Balloon"
        case .readingOrder: "阅读顺序"
        case .ocrTranslation: "OCR / 翻译"
        case .other: "其他"
        }
    }
}

nonisolated enum MangaVisionHardCaseIssueType: String, Codable, CaseIterable, Sendable, Hashable {
    case unspecifiedVisualError = "unspecified_visual_error"
    case missedDetection = "missed_detection"
    case falsePositive = "false_positive"
    case duplicate
    case boxTooLarge = "box_too_large"
    case boxTooSmall = "box_too_small"
    case boundaryError = "boundary_error"
    case frameMerge = "frame_merge"
    case frameSplit = "frame_split"
    case readingOrderError = "reading_order_error"
    case wrongPerson = "wrong_person"
    case multipleFacesConfused = "multiple_faces_confused"
    case overlappingPersonDuplicate = "overlapping_person_duplicate"
    case balloonTextAssociationError = "balloon_text_association_error"
    case roiError = "roi_error"
    case ocrAffected = "ocr_affected"
    case translationContextAffected = "translation_context_affected"
    case potentialSpeakerAssociationError = "potential_speaker_association_error"

    var displayName: String {
        switch self {
        case .unspecifiedVisualError: "未分类视觉错误"
        case .missedDetection: "漏检"
        case .falsePositive: "误检"
        case .duplicate: "重复"
        case .boxTooLarge: "框太大"
        case .boxTooSmall: "框太小"
        case .boundaryError: "边界错误"
        case .frameMerge: "分镜合并"
        case .frameSplit: "分镜拆分"
        case .readingOrderError: "阅读顺序错误"
        case .wrongPerson: "错人物"
        case .multipleFacesConfused: "多人脸混淆"
        case .overlappingPersonDuplicate: "人物重叠重复"
        case .balloonTextAssociationError: "气泡与文字对应错误"
        case .roiError: "ROI 错误"
        case .ocrAffected: "OCR 受影响"
        case .translationContextAffected: "翻译上下文受影响"
        case .potentialSpeakerAssociationError: "潜在说话人关联错误"
        }
    }
}

nonisolated enum MangaVisionHardCaseProductImpact: String, Codable, CaseIterable, Sendable, Hashable {
    case normalReading = "normal_reading"
    case guidedPanel = "guided_panel"
    case ocr
    case translation
    case personAssociation = "person_association"
    case none

    var displayName: String {
        switch self {
        case .normalReading: "普通阅读"
        case .guidedPanel: "Guided Panel"
        case .ocr: "OCR"
        case .translation: "翻译"
        case .personAssociation: "人物关联"
        case .none: "没明显影响"
        }
    }
}

nonisolated struct MangaVisionHardCaseBox: Codable, Sendable, Hashable {
    let xMin: Double
    let yMin: Double
    let xMax: Double
    let yMax: Double

    init(xMin: Double, yMin: Double, xMax: Double, yMax: Double) {
        self.xMin = xMin
        self.yMin = yMin
        self.xMax = xMax
        self.yMax = yMax
    }

    init(normalizedRect rect: CGRect) {
        self.init(
            xMin: Double(rect.minX),
            yMin: Double(rect.minY),
            xMax: Double(rect.maxX),
            yMax: Double(rect.maxY)
        )
    }

    init(sourceRect rect: CGRect) {
        self.init(
            xMin: Double(rect.minX),
            yMin: Double(rect.minY),
            xMax: Double(rect.maxX),
            yMax: Double(rect.maxY)
        )
    }
}

nonisolated struct MangaVisionHardCaseDetection: Codable, Sendable, Hashable, Identifiable {
    let id: UUID
    let detectionClass: String
    let score: Float
    let normalizedBBox: MangaVisionHardCaseBox
    let sourceBBox: MangaVisionHardCaseBox

    init(region: MangaVisionRegion, sourceSize: CGSize) {
        id = region.id
        detectionClass = Self.className(for: region.type)
        score = region.confidence
        normalizedBBox = MangaVisionHardCaseBox(normalizedRect: region.normalizedRect)
        let sourceRect = CGRect(
            x: region.normalizedRect.minX * sourceSize.width,
            y: region.normalizedRect.minY * sourceSize.height,
            width: region.normalizedRect.width * sourceSize.width,
            height: region.normalizedRect.height * sourceSize.height
        )
        sourceBBox = MangaVisionHardCaseBox(sourceRect: sourceRect)
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case detectionClass = "class"
        case score
        case normalizedBBox
        case sourceBBox
    }

    static func className(for type: MangaRegionType) -> String {
        switch type {
        case .panel: "frame"
        case .text: "text"
        case .face: "face"
        case .body: "body"
        case .balloon: "balloon"
        }
    }
}

nonisolated struct MangaVisionHardCasePreprocessSnapshot: Codable, Sendable, Hashable {
    let sourceWidth: Int
    let sourceHeight: Int
    let cropRect: MangaVisionHardCaseBox?
    let scale: Double?
    let letterbox: MangaVisionHardCaseBox?
    let padding: MangaVisionHardCaseBox?

    static func unavailable(sourceSize: CGSize) -> Self {
        Self(
            sourceWidth: max(Int(sourceSize.width.rounded()), 0),
            sourceHeight: max(Int(sourceSize.height.rounded()), 0),
            cropRect: nil,
            scale: nil,
            letterbox: nil,
            padding: nil
        )
    }
}

nonisolated struct MangaVisionHardCaseFeedback: Codable, Sendable, Hashable {
    var affectedAreas: Set<MangaVisionHardCaseAffectedArea>
    var issueTypes: Set<MangaVisionHardCaseIssueType>
    var productImpacts: Set<MangaVisionHardCaseProductImpact>
    var note: String

    static let quickMark = Self(
        affectedAreas: [],
        issueTypes: [.unspecifiedVisualError],
        productImpacts: [],
        note: ""
    )

    func merging(_ other: Self) -> Self {
        Self(
            affectedAreas: affectedAreas.union(other.affectedAreas),
            issueTypes: issueTypes.union(other.issueTypes),
            productImpacts: productImpacts.union(other.productImpacts),
            note: [note, other.note]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .uniqued()
                .joined(separator: "\n")
        )
    }
}

nonisolated struct MangaVisionHardCaseRecord: Codable, Sendable, Identifiable, Hashable {
    var id: UUID
    var createdAt: Date
    var updatedAt: Date
    var firstSeenAt: Date
    var lastSeenAt: Date
    var feedbackCount: Int

    let comicID: UUID
    let comicTitle: String
    let pageIndex: Int
    let pageIdentifier: String
    var pageSHA256: String

    var sourceReference: String
    var storedCopyReference: String?
    let pixelWidth: Int
    let pixelHeight: Int
    let orientation: Int

    let provider: String
    let modelName: String
    let modelSHA256: String
    let calibrationRevision: String
    let appVersion: String
    let appBuild: String

    let inferenceMode: MangaVisionHardCaseInferenceMode
    let preprocess: MangaVisionHardCasePreprocessSnapshot
    let detections: [MangaVisionHardCaseDetection]
    let analysisState: MangaVisionHardCaseAnalysisState

    var feedback: MangaVisionHardCaseFeedback
    var reviewState: MangaVisionHardCaseReviewState
    var imageRetentionPolicy: MangaVisionHardCaseImageRetentionPolicy
    var imageRetentionFailure: String?

    var deduplicationKey: String {
        "\(pageSHA256)|\(modelSHA256)|\(inferenceMode.rawValue)"
    }
}

nonisolated struct MangaVisionHardCaseStatistics: Sendable, Equatable {
    let total: Int
    let unreviewed: Int
    let reviewed: Int
    let annotated: Int
    let exported: Int
    let storageBytes: Int64
}

nonisolated enum MangaVisionHardCaseFeature {
    static let shortcutDefaultsKey = "mangavision_hard_case_feedback_shortcut"

    static func shortcutVisible(debugBuild: Bool, settingEnabled: Bool) -> Bool {
        debugBuild && settingEnabled
    }
}

nonisolated enum MangaVisionHardCaseSnapshotBuilder {
    static func detections(from analysis: MangaPageAnalysis?) -> [MangaVisionHardCaseDetection] {
        guard let analysis else { return [] }
        return analysis.allRegions.map {
            MangaVisionHardCaseDetection(region: $0, sourceSize: analysis.imageSize)
        }
    }

    static func pageIdentifier(from analysis: MangaPageAnalysis?, pageIndex: Int, pageURL: URL) -> String {
        if let identifier = analysis?.pageIdentifier {
            return "\(identifier.scope)|\(identifier.pageIndex)|\(identifier.sourceFingerprint)"
        }
        return "unavailable|\(pageIndex)|\(pageURL.lastPathComponent)"
    }
}

actor MangaVisionHardCaseStore {
    static let shared = MangaVisionHardCaseStore()

    private struct StoreEnvelope: Codable {
        let schemaVersion: Int
        var records: [MangaVisionHardCaseRecord]
    }

    private struct ExportManifest: Codable {
        let schemaVersion: Int
        let generatedAt: Date
        let recordCount: Int
        let modelNames: [String]
        let privacy: String
        let groundTruthStatus: String
        let records: [String]
    }

    private let fileManager: FileManager
    private let rootDirectory: URL
    private let recordsURL: URL
    private let imagesDirectory: URL
    private var records: [MangaVisionHardCaseRecord]

    init(rootDirectory: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        let base = rootDirectory
            ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("MangaVisionHardCases", isDirectory: true)
        self.rootDirectory = base
        self.recordsURL = base.appendingPathComponent("records.json")
        self.imagesDirectory = base.appendingPathComponent("images", isDirectory: true)
        try? fileManager.createDirectory(at: base, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: imagesDirectory, withIntermediateDirectories: true)

        if let data = try? Data(contentsOf: recordsURL),
           let envelope = try? JSONDecoder.hardCase.decode(StoreEnvelope.self, from: data),
           envelope.schemaVersion == 1 {
            self.records = envelope.records
        } else {
            self.records = []
        }
    }

    func allRecords() -> [MangaVisionHardCaseRecord] {
        records.sorted { $0.lastSeenAt > $1.lastSeenAt }
    }

    func record(id: UUID) -> MangaVisionHardCaseRecord? {
        records.first { $0.id == id }
    }

    func statistics() -> MangaVisionHardCaseStatistics {
        MangaVisionHardCaseStatistics(
            total: records.count,
            unreviewed: records.filter { $0.reviewState == .unreviewed }.count,
            reviewed: records.filter { $0.reviewState == .reviewed }.count,
            annotated: records.filter { $0.reviewState == .annotated }.count,
            exported: records.filter { $0.reviewState == .exported }.count,
            storageBytes: Self.directorySize(rootDirectory, fileManager: fileManager)
        )
    }

    @discardableResult
    func upsert(
        _ incoming: MangaVisionHardCaseRecord,
        imageData: Data? = nil,
        preferredExtension: String? = nil
    ) throws -> MangaVisionHardCaseRecord {
        let now = incoming.updatedAt
        if let index = records.firstIndex(where: { $0.deduplicationKey == incoming.deduplicationKey }) {
            var existing = records[index]
            existing.updatedAt = now
            existing.lastSeenAt = now
            existing.feedbackCount += max(incoming.feedbackCount, 1)
            existing.feedback = existing.feedback.merging(incoming.feedback)
            existing.imageRetentionFailure = incoming.imageRetentionFailure ?? existing.imageRetentionFailure

            if existing.storedCopyReference == nil,
               existing.imageRetentionPolicy == .copyOnCapture,
               let imageData {
                do {
                    existing.storedCopyReference = try retainImage(
                        data: imageData,
                        pageSHA256: existing.pageSHA256,
                        preferredExtension: preferredExtension
                    )
                    existing.imageRetentionFailure = nil
                } catch {
                    existing.imageRetentionFailure = error.localizedDescription
                }
            }
            records[index] = existing
            try persist()
            return existing
        }

        var stored = incoming
        if stored.imageRetentionPolicy == .copyOnCapture {
            if let imageData {
                do {
                    stored.storedCopyReference = try retainImage(
                        data: imageData,
                        pageSHA256: stored.pageSHA256,
                        preferredExtension: preferredExtension
                    )
                    stored.imageRetentionFailure = nil
                } catch {
                    stored.imageRetentionFailure = error.localizedDescription
                }
            } else if stored.imageRetentionFailure == nil {
                stored.imageRetentionFailure = "image-data-unavailable"
            }
        }

        records.append(stored)
        try persist()
        return stored
    }

    @discardableResult
    func update(
        id: UUID,
        feedback: MangaVisionHardCaseFeedback? = nil,
        reviewState: MangaVisionHardCaseReviewState? = nil
    ) throws -> MangaVisionHardCaseRecord? {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return nil }
        if let feedback { records[index].feedback = feedback }
        if let reviewState { records[index].reviewState = reviewState }
        records[index].updatedAt = Date()
        try persist()
        return records[index]
    }

    func delete(id: UUID) throws {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        let record = records.remove(at: index)
        if let reference = record.storedCopyReference {
            try? fileManager.removeItem(at: rootDirectory.appendingPathComponent(reference))
        }
        try persist()
    }

    func deleteAll() throws {
        records.removeAll()
        if fileManager.fileExists(atPath: imagesDirectory.path) {
            try? fileManager.removeItem(at: imagesDirectory)
        }
        try fileManager.createDirectory(at: imagesDirectory, withIntermediateDirectories: true)
        try persist()
    }

    func deleteExportedImages() throws {
        for index in records.indices where records[index].reviewState == .exported {
            if let reference = records[index].storedCopyReference {
                try? fileManager.removeItem(at: rootDirectory.appendingPathComponent(reference))
                records[index].storedCopyReference = nil
            }
        }
        try persist()
    }

    func imageURL(for record: MangaVisionHardCaseRecord) -> URL? {
        if let reference = record.storedCopyReference {
            let url = rootDirectory.appendingPathComponent(reference)
            if fileManager.fileExists(atPath: url.path) { return url }
        }
        guard let sourceURL = URL(string: record.sourceReference) else { return nil }
        return sourceURL.isFileURL && fileManager.fileExists(atPath: sourceURL.path) ? sourceURL : nil
    }

    func export(recordIDs: Set<UUID>? = nil) async throws -> URL {
        let selected = records.filter { recordIDs == nil || recordIDs?.contains($0.id) == true }
        let exportName = "mangavision-hardcases-\(Self.exportDateFormatter.string(from: Date()))"
        let stagingRoot = fileManager.temporaryDirectory
            .appendingPathComponent("\(exportName)-\(UUID().uuidString)", isDirectory: true)
        let packageRoot = stagingRoot.appendingPathComponent(exportName, isDirectory: true)
        let recordsDirectory = packageRoot.appendingPathComponent("records", isDirectory: true)
        let exportImagesDirectory = packageRoot.appendingPathComponent("images", isDirectory: true)
        let predictionsDirectory = packageRoot.appendingPathComponent("predictions", isDirectory: true)

        try fileManager.createDirectory(at: recordsDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: exportImagesDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: predictionsDirectory, withIntermediateDirectories: true)

        var exportedRecordNames: [String] = []
        for record in selected {
            var exportRecord = record
            let baseName = record.id.uuidString.lowercased()
            var relativeImageReference: String?

            if let storedCopyReference = record.storedCopyReference {
                let source = rootDirectory.appendingPathComponent(storedCopyReference)
                if fileManager.fileExists(atPath: source.path) {
                    let ext = source.pathExtension.isEmpty ? "img" : source.pathExtension
                    let destinationName = "\(baseName).\(ext)"
                    let destination = exportImagesDirectory.appendingPathComponent(destinationName)
                    try? fileManager.copyItem(at: source, to: destination)
                    if fileManager.fileExists(atPath: destination.path) {
                        relativeImageReference = "images/\(destinationName)"
                    }
                }
            } else if record.imageRetentionPolicy == .copyOnExport,
                      let sourceURL = URL(string: record.sourceReference),
                      let sourceData = await MangaVisionHardCasePageDataLoader.data(for: sourceURL) {
                let ext = Self.safeImageExtension(sourceURL.pathExtension)
                let destinationName = "\(baseName).\(ext)"
                let destination = exportImagesDirectory.appendingPathComponent(destinationName)
                try? sourceData.write(to: destination, options: .atomic)
                if fileManager.fileExists(atPath: destination.path) {
                    relativeImageReference = "images/\(destinationName)"
                }
            }

            exportRecord.sourceReference = Self.portableSourceReference(
                record.sourceReference,
                pageIndex: record.pageIndex
            )
            exportRecord.storedCopyReference = relativeImageReference
            exportRecord.imageRetentionFailure = nil

            let recordData = try JSONEncoder.hardCase.encode(exportRecord)
            try recordData.write(
                to: recordsDirectory.appendingPathComponent("\(baseName).json"),
                options: .atomic
            )

            let prediction = MangaVisionHardCasePredictionExport(
                recordID: record.id,
                pageSHA256: record.pageSHA256,
                modelName: record.modelName,
                modelSHA256: record.modelSHA256,
                inferenceMode: record.inferenceMode,
                imageWidth: record.pixelWidth,
                imageHeight: record.pixelHeight,
                detections: record.detections
            )
            let predictionData = try JSONEncoder.hardCase.encode(prediction)
            try predictionData.write(
                to: predictionsDirectory.appendingPathComponent("\(baseName).json"),
                options: .atomic
            )
            exportedRecordNames.append("records/\(baseName).json")
        }

        let manifest = ExportManifest(
            schemaVersion: 1,
            generatedAt: Date(),
            recordCount: selected.count,
            modelNames: Array(Set(selected.map(\.modelName))).sorted(),
            privacy: "LOCAL_ONLY_USER_EXPLICIT_EXPORT",
            groundTruthStatus: "Hard Cases are not ground truth until reviewed and annotated.",
            records: exportedRecordNames.sorted()
        )
        try JSONEncoder.hardCase.encode(manifest)
            .write(to: packageRoot.appendingPathComponent("manifest.json"), options: .atomic)

        let zipURL = fileManager.temporaryDirectory.appendingPathComponent("\(exportName).zip")
        try? fileManager.removeItem(at: zipURL)
        try fileManager.zipItem(
            at: packageRoot,
            to: zipURL,
            shouldKeepParent: true,
            compressionMethod: .deflate
        )

        let selectedIDs = Set(selected.map(\.id))
        for index in records.indices where selectedIDs.contains(records[index].id) {
            records[index].reviewState = .exported
            records[index].updatedAt = Date()
        }
        try persist()
        try? fileManager.removeItem(at: stagingRoot)
        return zipURL
    }

    private func retainImage(data: Data, pageSHA256: String, preferredExtension: String?) throws -> String {
        let ext = Self.safeImageExtension(preferredExtension)
        let relative = "images/\(pageSHA256).\(ext)"
        let destination = rootDirectory.appendingPathComponent(relative)
        if !fileManager.fileExists(atPath: destination.path) {
            try data.write(to: destination, options: .atomic)
        }
        return relative
    }

    private func persist() throws {
        let envelope = StoreEnvelope(schemaVersion: 1, records: records)
        let data = try JSONEncoder.hardCase.encode(envelope)
        try data.write(to: recordsURL, options: .atomic)
    }

    nonisolated static func portableSourceReference(
        _ sourceReference: String,
        pageIndex: Int
    ) -> String {
        guard let url = URL(string: sourceReference) else {
            return "page-\(pageIndex)"
        }
        let scheme = url.scheme?.lowercased()
        if scheme == "http" || scheme == "https" {
            return url.absoluteString
        }
        let filename = url.lastPathComponent
        return filename.isEmpty ? "page-\(pageIndex)" : filename
    }

    private static func safeImageExtension(_ candidate: String?) -> String {
        let value = (candidate ?? "").lowercased()
        let allowed = Set(["jpg", "jpeg", "png", "webp", "heic", "heif", "gif"])
        return allowed.contains(value) ? value : "img"
    }

    private static func directorySize(_ url: URL, fileManager: FileManager) -> Int64 {
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true else { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }

    private static let exportDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyyMMdd"
        return formatter
    }()
}

nonisolated struct MangaVisionHardCasePredictionExport: Codable, Sendable {
    let recordID: UUID
    let pageSHA256: String
    let modelName: String
    let modelSHA256: String
    let inferenceMode: MangaVisionHardCaseInferenceMode
    let imageWidth: Int
    let imageHeight: Int
    let detections: [MangaVisionHardCaseDetection]
}

nonisolated enum MangaVisionHardCaseCaptureService {
    static func capture(
        comic: ComicBook,
        pageIndex: Int,
        pageURL: URL,
        feedback: MangaVisionHardCaseFeedback,
        inferenceMode: MangaVisionHardCaseInferenceMode = .unknown,
        retentionPolicy: MangaVisionHardCaseImageRetentionPolicy,
        store: MangaVisionHardCaseStore = .shared
    ) async throws -> MangaVisionHardCaseRecord {
        async let manifestTask = MangaVisionService.shared.modelManifestForDiagnostics()
        async let analysisTask = MangaVisionService.shared.cachedAnalysis(
            comicID: comic.id,
            pageIndex: pageIndex,
            pageURL: pageURL,
            image: UIImage()
        )
        async let imageDataTask = MangaVisionHardCasePageDataLoader.data(for: pageURL)

        let manifest = await manifestTask
        let analysis = await analysisTask
        let imageData = await imageDataTask
        let pageSHA256 = imageData.map(Self.sha256)
            ?? Self.sha256(Data(pageURL.absoluteString.utf8)).prefixedUnavailableHash
        let sourceSize = analysis?.imageSize
            ?? imageData.flatMap(MangaVisionHardCasePageDataLoader.pixelSize)
            ?? .zero
        let now = Date()
        let snapshotModelIdentifier = analysis?.modelIdentifier ?? manifest.modelID
        let isV2B5 = snapshotModelIdentifier == MangaVisionV2B5Provider.modelIdentifier
        let capturedModelName = isV2B5
            ? MangaVisionV2B5ProductionIdentity.modelName
            : snapshotModelIdentifier
        let capturedModelSHA256 = isV2B5
            ? MangaVisionV2B5ProductionIdentity.coreMLTreeSHA256
            : manifest.modelFileHash

        let record = MangaVisionHardCaseRecord(
            id: UUID(),
            createdAt: now,
            updatedAt: now,
            firstSeenAt: now,
            lastSeenAt: now,
            feedbackCount: 1,
            comicID: comic.id,
            comicTitle: comic.title,
            pageIndex: pageIndex,
            pageIdentifier: MangaVisionHardCaseSnapshotBuilder.pageIdentifier(
                from: analysis,
                pageIndex: pageIndex,
                pageURL: pageURL
            ),
            pageSHA256: pageSHA256,
            sourceReference: pageURL.absoluteString,
            storedCopyReference: nil,
            pixelWidth: max(Int(sourceSize.width.rounded()), 0),
            pixelHeight: max(Int(sourceSize.height.rounded()), 0),
            orientation: imageData.map(MangaVisionHardCasePageDataLoader.orientation) ?? 1,
            provider: snapshotModelIdentifier,
            modelName: capturedModelName,
            modelSHA256: capturedModelSHA256,
            calibrationRevision: manifest.calibrationRevision,
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            appBuild: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
            inferenceMode: inferenceMode,
            preprocess: .unavailable(sourceSize: sourceSize),
            detections: MangaVisionHardCaseSnapshotBuilder.detections(from: analysis),
            analysisState: analysis == nil ? .unavailable : .available,
            feedback: feedback,
            reviewState: .unreviewed,
            imageRetentionPolicy: retentionPolicy,
            imageRetentionFailure: imageData == nil ? "image-data-unavailable" : nil
        )

        return try await store.upsert(
            record,
            imageData: imageData,
            preferredExtension: pageURL.pathExtension
        )
    }

    static func quickMark(
        comic: ComicBook,
        pageIndex: Int,
        pageURL: URL,
        retentionPolicy: MangaVisionHardCaseImageRetentionPolicy,
        store: MangaVisionHardCaseStore = .shared
    ) async throws -> MangaVisionHardCaseRecord {
        try await capture(
            comic: comic,
            pageIndex: pageIndex,
            pageURL: pageURL,
            feedback: .quickMark,
            retentionPolicy: retentionPolicy,
            store: store
        )
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

nonisolated enum MangaVisionHardCasePageDataLoader {
    static func data(for url: URL) async -> Data? {
        if RemotePageLoader.isRemotePageURL(url) {
            return await RemotePageLoader.imageData(forRemotePageURL: url)
        }
        if ComicManager.isArchivePageURL(url) {
            return await Task.detached(priority: .utility) {
                ComicManager.imageData(forArchivePageURL: url)
            }.value
        }
        guard url.isFileURL else { return nil }
        return await Task.detached(priority: .utility) {
            let didStart = LocalResourceAccessPolicy.startAccessingIfNeeded(url)
            defer {
                if didStart { url.stopAccessingSecurityScopedResource() }
            }
            return try? Data(contentsOf: url, options: [.mappedIfSafe])
        }.value
    }

    static func pixelSize(_ data: Data) -> CGSize? {
        guard let source = CGImageSourceCreateWithData(
            data as CFData,
            [kCGImageSourceShouldCache: false] as CFDictionary
        ),
        let properties = CGImageSourceCopyPropertiesAtIndex(
            source,
            0,
            [kCGImageSourceShouldCache: false] as CFDictionary
        ) as? [CFString: Any],
        let width = properties[kCGImagePropertyPixelWidth] as? CGFloat,
        let height = properties[kCGImagePropertyPixelHeight] as? CGFloat,
        width > 0,
        height > 0 else {
            return nil
        }
        return CGSize(width: width, height: height)
    }

    static func orientation(_ data: Data) -> Int {
        guard let source = CGImageSourceCreateWithData(
            data as CFData,
            [kCGImageSourceShouldCache: false] as CFDictionary
        ),
        let properties = CGImageSourceCopyPropertiesAtIndex(
            source,
            0,
            [kCGImageSourceShouldCache: false] as CFDictionary
        ) as? [CFString: Any] else {
            return 1
        }
        if let value = properties[kCGImagePropertyOrientation] as? NSNumber {
            return value.intValue
        }
        return 1
    }
}

private extension String {
    nonisolated var prefixedUnavailableHash: String {
        "unavailable:\(self)"
    }
}

private extension JSONEncoder {
    nonisolated static var hardCase: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}

private extension JSONDecoder {
    nonisolated static var hardCase: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

private extension Array where Element == String {
    nonisolated func uniqued() -> [String] {
        var seen = Set<String>()
        return filter { seen.insert($0).inserted }
    }
}
