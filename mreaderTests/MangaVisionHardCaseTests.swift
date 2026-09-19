import CoreGraphics
import Foundation
import XCTest
@testable import mreader

@MainActor
final class HardCaseRecordTests: XCTestCase {
    func testRecordUsesStableSampleIdentity() {
        let record = HardCaseFixture.record(
            pageSHA256: "page-sha",
            modelSHA256: "model-sha",
            inferenceMode: .halfLeft
        )

        XCTAssertEqual(record.deduplicationKey, "page-sha|model-sha|halfLeft")
        XCTAssertEqual(MangaVisionHardCaseIssueType.unspecifiedVisualError.rawValue, "unspecified_visual_error")
        XCTAssertEqual(MangaVisionHardCaseAffectedArea.readingOrder.rawValue, "reading_order")
        XCTAssertEqual(MangaVisionHardCaseProductImpact.guidedPanel.rawValue, "guided_panel")
        XCTAssertEqual(MangaVisionV2B5ProductionIdentity.modelName, "MangaVisionDetectorV2B5")
        XCTAssertEqual(
            MangaVisionV2B5ProductionIdentity.coreMLTreeSHA256,
            "ebde3f514e2fb84e48f73bd194041da671337f7b770e3baeae637ed8c5dba4c5"
        )
        XCTAssertEqual(MangaVisionV2B5ProductionIdentity.calibrationRevision, "v2b5-calibration-v1")
    }
}

@MainActor
final class HardCaseDeduplicationTests: XCTestCase {
    func testSamePageModelAndInferenceModeMergesFeedback() async throws {
        let root = HardCaseFixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MangaVisionHardCaseStore(rootDirectory: root)

        var first = HardCaseFixture.record()
        first.feedback = MangaVisionHardCaseFeedback(
            affectedAreas: [.body],
            issueTypes: [.duplicate],
            productImpacts: [.translation],
            note: "first"
        )
        var second = HardCaseFixture.record()
        second.feedback = MangaVisionHardCaseFeedback(
            affectedAreas: [.face],
            issueTypes: [.wrongPerson],
            productImpacts: [.personAssociation],
            note: "second"
        )

        _ = try await store.upsert(first)
        let merged = try await store.upsert(second)
        let records = await store.allRecords()

        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(merged.feedbackCount, 2)
        XCTAssertTrue(merged.feedback.affectedAreas.isSuperset(of: [.body, .face]))
        XCTAssertTrue(merged.feedback.issueTypes.isSuperset(of: [.duplicate, .wrongPerson]))
        XCTAssertTrue(merged.feedback.productImpacts.isSuperset(of: [.translation, .personAssociation]))
        XCTAssertTrue(merged.feedback.note.contains("first"))
        XCTAssertTrue(merged.feedback.note.contains("second"))
        XCTAssertEqual(merged.firstSeenAt, first.firstSeenAt)
        XCTAssertEqual(merged.lastSeenAt, second.lastSeenAt)
    }

    func testDifferentInferenceModesRemainDistinctSamples() async throws {
        let root = HardCaseFixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MangaVisionHardCaseStore(rootDirectory: root)

        _ = try await store.upsert(HardCaseFixture.record(inferenceMode: .full))
        _ = try await store.upsert(HardCaseFixture.record(inferenceMode: .halfRight))

        let records = await store.allRecords()
        XCTAssertEqual(records.count, 2)
    }
}

@MainActor
final class HardCasePersistenceTests: XCTestCase {
    func testRecordsSurviveStoreRecreation() async throws {
        let root = HardCaseFixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let firstStore = MangaVisionHardCaseStore(rootDirectory: root)
        let original = HardCaseFixture.record()
        _ = try await firstStore.upsert(original)

        let reopened = MangaVisionHardCaseStore(rootDirectory: root)
        let records = await reopened.allRecords()

        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.id, original.id)
        XCTAssertEqual(records.first?.pageSHA256, original.pageSHA256)
    }
}

@MainActor
final class HardCasePredictionSnapshotTests: XCTestCase {
    func testSnapshotCopiesExistingFiveClassAnalysis() throws {
        let types: [MangaRegionType] = [.panel, .text, .face, .body, .balloon]
        let regions = types.enumerated().map { index, type in
            MangaVisionRegion(
                type: type,
                normalizedRect: CGRect(
                    x: CGFloat(index) * 0.1,
                    y: 0.2,
                    width: 0.08,
                    height: 0.1
                ),
                confidence: Float(0.8 + Double(index) * 0.02)
            )
        }
        let analysis = MangaPageAnalysis(
            pageIdentifier: MangaPageIdentifier(
                scope: "snapshot",
                pageIndex: 3,
                sourceFingerprint: "source"
            ),
            imageSize: CGSize(width: 1000, height: 2000),
            panels: regions.filter { $0.type == .panel },
            texts: regions.filter { $0.type == .text },
            balloons: regions.filter { $0.type == .balloon },
            faces: regions.filter { $0.type == .face },
            bodies: regions.filter { $0.type == .body },
            modelIdentifier: MangaVisionV2B5Provider.modelIdentifier,
            modelVersion: 5
        )

        let snapshot = MangaVisionHardCaseSnapshotBuilder.detections(from: analysis)

        XCTAssertEqual(snapshot.map(\.detectionClass), ["frame", "text", "balloon", "face", "body"])
        XCTAssertEqual(Set(snapshot.map(\.id)), Set(regions.map(\.id)))
        let frame = try XCTUnwrap(snapshot.first { $0.detectionClass == "frame" })
        XCTAssertEqual(frame.sourceBBox.yMin, 400, accuracy: 0.001)
        XCTAssertEqual(frame.sourceBBox.yMax, 600, accuracy: 0.001)
    }

    func testUnavailableAnalysisProducesEmptySnapshotWithoutInference() {
        XCTAssertTrue(MangaVisionHardCaseSnapshotBuilder.detections(from: nil).isEmpty)
    }
}

@MainActor
final class HardCaseExportTests: XCTestCase {
    func testExportCreatesZipAndPortableLocalSourceReference() async throws {
        let root = HardCaseFixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MangaVisionHardCaseStore(rootDirectory: root)
        let record = HardCaseFixture.record(
            sourceReference: "file:///private/var/mobile/Containers/Data/Application/ABC/Documents/page-001.jpg"
        )
        _ = try await store.upsert(record)

        let zipURL = try await store.export()
        defer { try? FileManager.default.removeItem(at: zipURL) }

        XCTAssertEqual(zipURL.pathExtension.lowercased(), "zip")
        XCTAssertTrue(FileManager.default.fileExists(atPath: zipURL.path))
        XCTAssertGreaterThan((try Data(contentsOf: zipURL)).count, 0)
        XCTAssertEqual(
            MangaVisionHardCaseStore.portableSourceReference(record.sourceReference, pageIndex: 0),
            "page-001.jpg"
        )
        XCTAssertEqual(
            MangaVisionHardCaseStore.portableSourceReference(
                "https://example.com/books/1/pages/2?token=public",
                pageIndex: 1
            ),
            "https://example.com/books/1/pages/2?token=public"
        )
    }
}

@MainActor
final class HardCaseImageRetentionTests: XCTestCase {
    func testCopyOnCaptureRetainsOnePageCopy() async throws {
        let root = HardCaseFixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MangaVisionHardCaseStore(rootDirectory: root)
        var record = HardCaseFixture.record()
        record.imageRetentionPolicy = .copyOnCapture

        let stored = try await store.upsert(
            record,
            imageData: Data("fixture-image".utf8),
            preferredExtension: "jpg"
        )

        let relative = try XCTUnwrap(stored.storedCopyReference)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(relative).path))
    }

    func testReferenceOnlyDoesNotCopyImage() async throws {
        let root = HardCaseFixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MangaVisionHardCaseStore(rootDirectory: root)
        var record = HardCaseFixture.record()
        record.imageRetentionPolicy = .referenceOnly

        let stored = try await store.upsert(
            record,
            imageData: Data("fixture-image".utf8),
            preferredExtension: "jpg"
        )

        XCTAssertNil(stored.storedCopyReference)
    }
}

@MainActor
final class ReaderFeedbackEntryTests: XCTestCase {
    func testShortcutIsDebugAndSettingGated() {
        XCTAssertFalse(MangaVisionHardCaseFeature.shortcutVisible(debugBuild: false, settingEnabled: true))
        XCTAssertFalse(MangaVisionHardCaseFeature.shortcutVisible(debugBuild: true, settingEnabled: false))
        XCTAssertTrue(MangaVisionHardCaseFeature.shortcutVisible(debugBuild: true, settingEnabled: true))
    }

    func testQuickMarkIsUnreviewedUnspecifiedVisualError() {
        let feedback = MangaVisionHardCaseFeedback.quickMark
        XCTAssertEqual(feedback.issueTypes, [.unspecifiedVisualError])
        XCTAssertTrue(feedback.affectedAreas.isEmpty)
        XCTAssertTrue(feedback.productImpacts.isEmpty)
        XCTAssertEqual(HardCaseFixture.record(feedback: feedback).reviewState, .unreviewed)
    }
}

@MainActor
final class FiveClassIssueTypeTests: XCTestCase {
    func testFiveModelClassesMapToStableExportNames() {
        XCTAssertEqual(MangaVisionHardCaseDetection.className(for: .panel), "frame")
        XCTAssertEqual(MangaVisionHardCaseDetection.className(for: .text), "text")
        XCTAssertEqual(MangaVisionHardCaseDetection.className(for: .face), "face")
        XCTAssertEqual(MangaVisionHardCaseDetection.className(for: .body), "body")
        XCTAssertEqual(MangaVisionHardCaseDetection.className(for: .balloon), "balloon")
    }

    func testDetectionJSONUsesPortableClassKey() throws {
        let region = MangaVisionRegion(
            type: .body,
            normalizedRect: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4),
            confidence: 0.88
        )
        let detection = MangaVisionHardCaseDetection(
            region: region,
            sourceSize: CGSize(width: 1000, height: 2000)
        )
        let data = try JSONEncoder().encode(detection)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        XCTAssertEqual(object["class"] as? String, "body")
        XCTAssertNil(object["detectionClass"])
    }

    func testClassSpecificIssueTypesAreRepresentable() {
        let required: Set<MangaVisionHardCaseIssueType> = [
            .frameMerge,
            .frameSplit,
            .readingOrderError,
            .wrongPerson,
            .multipleFacesConfused,
            .overlappingPersonDuplicate,
            .balloonTextAssociationError,
            .roiError,
            .ocrAffected,
            .translationContextAffected,
            .potentialSpeakerAssociationError
        ]
        XCTAssertTrue(Set(MangaVisionHardCaseIssueType.allCases).isSuperset(of: required))
    }
}

private enum HardCaseFixture {
    static func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("mreader-hard-case-tests-\(UUID().uuidString)", isDirectory: true)
    }

    static func record(
        pageSHA256: String = "page-sha",
        modelSHA256: String = "model-sha",
        inferenceMode: MangaVisionHardCaseInferenceMode = .full,
        sourceReference: String = "file:///tmp/page.jpg",
        feedback: MangaVisionHardCaseFeedback = .quickMark
    ) -> MangaVisionHardCaseRecord {
        let created = Date(timeIntervalSince1970: 1_700_000_000)
        return MangaVisionHardCaseRecord(
            id: UUID(),
            createdAt: created,
            updatedAt: created,
            firstSeenAt: created,
            lastSeenAt: created,
            feedbackCount: 1,
            comicID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            comicTitle: "Fixture",
            pageIndex: 0,
            pageIdentifier: "fixture|0|source",
            pageSHA256: pageSHA256,
            sourceReference: sourceReference,
            storedCopyReference: nil,
            pixelWidth: 1000,
            pixelHeight: 2000,
            orientation: 1,
            provider: "MangaVisionService",
            modelName: MangaVisionV2B5ProductionIdentity.modelName,
            modelSHA256: modelSHA256,
            calibrationRevision: "v2b5-calibration-v1",
            appVersion: "1.1",
            appBuild: "2",
            inferenceMode: inferenceMode,
            preprocess: .unavailable(sourceSize: CGSize(width: 1000, height: 2000)),
            detections: [],
            analysisState: .available,
            feedback: feedback,
            reviewState: .unreviewed,
            imageRetentionPolicy: .referenceOnly,
            imageRetentionFailure: nil
        )
    }
}
