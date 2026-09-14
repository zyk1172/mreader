import CoreGraphics
import CoreML
import Foundation
import Testing
import UIKit
@testable import mreader

@Suite(.serialized)
@MainActor
struct MangaVisionLayerTests {
    @Test func adapterMapsFourSemanticClassesWithoutExposingIDsUpstream() throws {
        let output = try detectionTensor(rows: [
            [64, 64, 256, 256, 0.91, 0],
            [300, 80, 420, 180, 0.82, 1],
            [100, 300, 180, 380, 0.77, 2],
            [80, 280, 230, 560, 0.74, 3]
        ])
        let regions = YOLOMangaVisionProvider.decodeForDiagnostics(
            output,
            analysisImageSize: CGSize(width: 640, height: 640),
            labelsByClassID: [0: "frame", 1: "text", 2: "face", 3: "body"]
        )
        #expect(Set(regions.map(\.type)) == Set(MangaRegionType.allCases))
    }

    @Test func adapterReadsUltralyticsMetadataLabelSyntax() {
        let labels = YOLOMangaVisionProvider.parseClassLabelsForDiagnostics(
            "{0: 'frame', 1: 'text', 2: 'balloon', 3: \"face\", 4: 'body'}"
        )
        #expect(labels[0] == "frame")
        #expect(labels[1] == "text")
        #expect(labels[2] == "balloon")
        #expect(labels[3] == "face")
        #expect(labels[4] == "body")
    }

    @Test func adapterUsesPerSemanticConfidenceThresholds() throws {
        let output = try detectionTensor(rows: [
            [40, 40, 180, 180, 0.23, 0],
            [200, 40, 300, 140, 0.17, 1],
            [40, 220, 120, 300, 0.20, 2],
            [200, 220, 340, 500, 0.19, 3]
        ])
        let regions = YOLOMangaVisionProvider.decodeForDiagnostics(
            output,
            analysisImageSize: CGSize(width: 640, height: 640),
            labelsByClassID: [0: "frame", 1: "text", 2: "face", 3: "body"]
        )
        #expect(regions.map(\.type) == [.face])
    }

    @Test func scaleFitCoordinatesMapBackToOriginalPage() {
        let rect = MangaPageCoordinateSpace.sourceNormalizedRectFromScaleFitXYXY(
            x1: 160,
            y1: 0,
            x2: 480,
            y2: 640,
            inputSize: CGSize(width: 640, height: 640),
            sourceSize: CGSize(width: 320, height: 640)
        )
        #expect(abs(rect.minX) < 0.0001)
        #expect(abs(rect.minY) < 0.0001)
        #expect(abs(rect.width - 1) < 0.0001)
        #expect(abs(rect.height - 1) < 0.0001)
    }

    @Test func visionBottomLeftCoordinatesFlipIntoPageSpace() {
        let result = MangaPageCoordinateSpace.topLeftNormalizedRect(
            fromVisionRect: CGRect(x: 0.2, y: 0.1, width: 0.3, height: 0.25)
        )
        #expect(abs(result.minX - 0.2) < 0.0001)
        #expect(abs(result.minY - 0.65) < 0.0001)
        #expect(abs(result.width - 0.3) < 0.0001)
        #expect(abs(result.height - 0.25) < 0.0001)
    }

    @Test func normalizedRectClampNeverLeavesPage() {
        let result = MangaPageCoordinateSpace.clampedNormalizedRect(
            CGRect(x: -0.2, y: 0.8, width: 0.5, height: 0.5)
        )
        #expect(result.minX == 0)
        #expect(result.maxX <= 1)
        #expect(result.minY >= 0)
        #expect(result.maxY == 1)
    }

    @Test func sameTypeNMSKeepsHigherConfidenceButDoesNotMergeDifferentTypes() {
        let high = region(.text, x: 0.1, y: 0.1, width: 0.3, height: 0.2, confidence: 0.9)
        let low = region(.text, x: 0.11, y: 0.11, width: 0.29, height: 0.19, confidence: 0.5)
        let face = region(.face, x: 0.11, y: 0.11, width: 0.29, height: 0.19, confidence: 0.8)
        let result = MangaVisionRegionPostProcessor.deduplicated([low, face, high])
        #expect(result.count == 2)
        #expect(result.contains { $0.id == high.id })
        #expect(result.contains { $0.id == face.id })
    }

    @Test func textROIPaddingDeduplicatesAndClampsAtPageEdges() {
        let first = region(.text, x: 0.0, y: 0.0, width: 0.20, height: 0.10, confidence: 0.9)
        let duplicate = region(.text, x: 0.01, y: 0.005, width: 0.19, height: 0.095, confidence: 0.7)
        let rois = MangaVisionTextROIPlanner.recognitionRegions(from: [duplicate, first])
        #expect(rois.count == 1)
        #expect(rois[0].minX == 0)
        #expect(rois[0].minY == 0)
        #expect(rois[0].maxX <= 1)
        #expect(rois[0].maxY <= 1)
        #expect(rois[0].width > first.normalizedRect.width)
    }

    @Test func noDetectedTextLeavesROIsEmptyForFullPageOCRFallback() {
        #expect(MangaVisionTextROIPlanner.recognitionRegions(from: []).isEmpty)
    }

    @Test func textOwnershipUsesContainingPanelAndAvoidsCrossPanelGuessing() {
        let left = region(.panel, x: 0.05, y: 0.05, width: 0.40, height: 0.80)
        let right = region(.panel, x: 0.55, y: 0.05, width: 0.40, height: 0.80)
        let inside = MangaSemanticAnalyzer.owningPanel(
            for: CGRect(x: 0.62, y: 0.20, width: 0.15, height: 0.08),
            panels: [left, right]
        )
        let gutter = MangaSemanticAnalyzer.owningPanel(
            for: CGRect(x: 0.47, y: 0.30, width: 0.06, height: 0.06),
            panels: [left, right]
        )
        #expect(inside?.id == right.id)
        #expect(gutter == nil)
    }

    @Test func textReadingOrderRespectsRTLAndLTR() {
        let left = region(.text, x: 0.10, y: 0.10, width: 0.20, height: 0.08)
        let right = region(.text, x: 0.65, y: 0.10, width: 0.20, height: 0.08)
        let lower = region(.text, x: 0.60, y: 0.45, width: 0.20, height: 0.08)
        let rtl = MangaSemanticAnalyzer.orderedTextRegions([left, lower, right], isRightToLeft: true)
        let ltr = MangaSemanticAnalyzer.orderedTextRegions([left, lower, right], isRightToLeft: false)
        #expect(rtl.map(\.id) == [right.id, left.id, lower.id])
        #expect(ltr.map(\.id) == [left.id, right.id, lower.id])
    }

    @Test func faceAndBodyPairWithinPanel() {
        let panel = region(.panel, x: 0.05, y: 0.05, width: 0.9, height: 0.9)
        let body = region(.body, x: 0.20, y: 0.22, width: 0.34, height: 0.65, confidence: 0.85)
        let face = region(.face, x: 0.30, y: 0.20, width: 0.13, height: 0.14, confidence: 0.9)
        let people = MangaSemanticAnalyzer.personCandidates(
            faces: [face], bodies: [body], panels: [panel]
        )
        #expect(people.count == 1)
        #expect(people[0].face?.id == face.id)
        #expect(people[0].body?.id == body.id)
        #expect(people[0].panelID == panel.id)
    }

    @Test func faceOnlyAndBodyOnlyRemainValidPersonCandidates() {
        let panel = region(.panel, x: 0.0, y: 0.0, width: 1.0, height: 1.0)
        let face = region(.face, x: 0.1, y: 0.1, width: 0.12, height: 0.12)
        let body = region(.body, x: 0.7, y: 0.5, width: 0.2, height: 0.4)
        let people = MangaSemanticAnalyzer.personCandidates(
            faces: [face], bodies: [body], panels: [panel]
        )
        #expect(people.count == 2)
        #expect(people.contains { $0.face?.id == face.id && $0.body == nil })
        #expect(people.contains { $0.body?.id == body.id && $0.face == nil })
    }

    @Test func multiplePeopleDoNotCollapseIntoOneCandidate() {
        let panel = region(.panel, x: 0, y: 0, width: 1, height: 1)
        let bodies = [
            region(.body, x: 0.10, y: 0.25, width: 0.30, height: 0.65),
            region(.body, x: 0.60, y: 0.25, width: 0.30, height: 0.65)
        ]
        let faces = [
            region(.face, x: 0.18, y: 0.20, width: 0.13, height: 0.14),
            region(.face, x: 0.68, y: 0.20, width: 0.13, height: 0.14)
        ]
        let people = MangaSemanticAnalyzer.personCandidates(
            faces: faces, bodies: bodies, panels: [panel]
        )
        #expect(people.count == 2)
        #expect(people.allSatisfy { $0.face != nil && $0.body != nil })
    }

    @Test func speakerAssociationProducesRankedHintsNotAnAuthoritativeAssignment() {
        let nearPerson = MangaPersonCandidate(
            panelID: nil,
            face: region(.face, x: 0.60, y: 0.20, width: 0.12, height: 0.12),
            body: nil,
            confidence: 0.9
        )
        let farPerson = MangaPersonCandidate(
            panelID: nil,
            face: region(.face, x: 0.05, y: 0.75, width: 0.12, height: 0.12),
            body: nil,
            confidence: 0.9
        )
        let text = region(.text, x: 0.62, y: 0.08, width: 0.18, height: 0.08)
        let hints = MangaSemanticAnalyzer.speakerCandidates(
            for: text,
            persons: [farPerson, nearPerson]
        )
        #expect(hints.count == 2)
        #expect(hints.first?.person.id == nearPerson.id)
        #expect(hints[0].score > hints[1].score)
    }

    @Test func samePageAnalysisUsesProviderOnlyOnce() async throws {
        let provider = FakeMangaVisionProvider(modelVersion: 1)
        let directory = temporaryCacheDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = MangaVisionService(provider: provider, cacheDirectory: directory)
        let image = makeImage()
        let url = URL(fileURLWithPath: "/tmp/mreader-manga-vision-cache-page.png")
        let comicID = UUID()

        _ = try await service.analysis(
            comicID: comicID, pageIndex: 0, pageURL: url, image: image
        )
        _ = try await service.analysis(
            comicID: comicID, pageIndex: 0, pageURL: url, image: image
        )
        #expect(await provider.calls() == 1)
    }

    @Test func modelVersionChangeInvalidatesDiskAnalysisCache() async throws {
        let directory = temporaryCacheDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let image = makeImage()
        let url = URL(fileURLWithPath: "/tmp/mreader-manga-vision-version-page.png")
        let comicID = UUID()

        let v1 = FakeMangaVisionProvider(modelVersion: 1)
        let first = MangaVisionService(provider: v1, cacheDirectory: directory)
        _ = try await first.analysis(
            comicID: comicID, pageIndex: 2, pageURL: url, image: image
        )
        #expect(await v1.calls() == 1)

        let v2 = FakeMangaVisionProvider(modelVersion: 2)
        let second = MangaVisionService(provider: v2, cacheDirectory: directory)
        _ = try await second.analysis(
            comicID: comicID, pageIndex: 2, pageURL: url, image: image
        )
        #expect(await v2.calls() == 1)
    }

    private func detectionTensor(rows: [[Double]]) throws -> MLMultiArray {
        let output = try MLMultiArray(
            shape: [1, NSNumber(value: rows.count), 6],
            dataType: .float32
        )
        for (row, values) in rows.enumerated() {
            for (feature, value) in values.enumerated() {
                output[row * 6 + feature] = NSNumber(value: value)
            }
        }
        return output
    }

    private func region(
        _ type: MangaRegionType,
        x: CGFloat,
        y: CGFloat,
        width: CGFloat,
        height: CGFloat,
        confidence: Float = 0.9
    ) -> MangaVisionRegion {
        MangaVisionRegion(
            type: type,
            normalizedRect: CGRect(x: x, y: y, width: width, height: height),
            confidence: confidence
        )
    }

    private func makeImage() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 64, height: 96)).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 64, height: 96))
        }
    }

    private func temporaryCacheDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MangaVisionTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private actor FakeMangaVisionProvider: MangaVisionProvider {
    private let version: Int
    private var callCount = 0

    init(modelVersion: Int) {
        version = modelVersion
    }

    var descriptor: MangaVisionProviderDescriptor {
        get async {
            MangaVisionProviderDescriptor(
                modelIdentifier: "fake-manga-vision",
                modelVersion: version,
                inputSize: CGSize(width: 64, height: 64),
                supportedRegionTypes: Set(MangaRegionType.allCases)
            )
        }
    }

    func analyzePage(
        image: CGImage,
        sourceImageSize: CGSize,
        pageIdentifier: MangaPageIdentifier
    ) async throws -> MangaPageAnalysis {
        _ = image
        callCount += 1
        return MangaPageAnalysis(
            pageIdentifier: pageIdentifier,
            imageSize: sourceImageSize,
            panels: [
                MangaVisionRegion(
                    type: .panel,
                    normalizedRect: CGRect(x: 0.05, y: 0.05, width: 0.9, height: 0.9),
                    confidence: 0.9
                )
            ],
            texts: [],
            faces: [],
            bodies: [],
            modelIdentifier: "fake-manga-vision",
            modelVersion: version
        )
    }

    func calls() -> Int { callCount }
}
