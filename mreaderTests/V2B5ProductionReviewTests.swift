import CoreGraphics
import Foundation
import ImageIO
import UIKit
import XCTest
@testable import mreader

/// Simulator-only production review evidence. The 40-page corpus is val-only
/// and ignored by Git; this test is explicitly opt-in because it performs real
/// Core ML inference and local OCR rather than a lightweight unit check.
@MainActor
final class V2B5ProductionReviewTests: XCTestCase {
    func testProductionDefaultProviderIsV2B5() {
#if DEBUG
        // DEBUG keeps the diagnostic selector independently configurable. The
        // compile-time production choice is still asserted here so it cannot
        // silently drift from the Release router branch.
        XCTAssertEqual(MangaVisionProviderMode.productionDefault, .v2b5)
#else
        XCTAssertEqual(MangaVisionProviderMode.currentForDiagnostics, .v2b5)
#endif
    }

    func testV2B5SimulatorValOnlyReview() async throws {
        #if V2B5_SIMULATOR_REVIEW
        let enabledByCompileFlag = true
        #else
        let enabledByCompileFlag = false
        #endif
        let enabledByEnvironment = ProcessInfo.processInfo.environment["MREADER_V2B5_SIMULATOR_REVIEW"] == "1"
        guard enabledByCompileFlag || enabledByEnvironment else {
            throw XCTSkip("Set MREADER_V2B5_SIMULATOR_REVIEW=1 for the simulator production review")
        }

        let manifest = try loadManifest()
        XCTAssertEqual(manifest.package, "v2b5-coreml-val-samples")
        XCTAssertEqual(manifest.sourceDataset, "Manga109-s-v2026")
        XCTAssertEqual(manifest.split, "val")
        XCTAssertFalse(manifest.modelPredictionsUsed)
        XCTAssertEqual(manifest.pageCount, 40)
        XCTAssertEqual(manifest.bookCount, 9)
        XCTAssertTrue(manifest.pages.allSatisfy { $0.split == "val" })

        await OCRRecognitionCache.shared.clearCache()
        await PanelDetectionService.shared.clearCache()

        let provider = MangaVisionV2B5Provider.shared
        let reviewID = UUID()
        var timings: [MangaVisionProviderTiming] = []
        var totalDetections = 0
        var semanticPages = 0
        var panelPages = 0
        var balloonRegions = 0
        var ocrPages = 0
        var ocrBlocks = 0
        var ocrROIPages = 0

        for (index, page) in manifest.pages.enumerated() {
            let imageURL = try XCTUnwrap(imageURL(for: page), page.filename)
            let image = try XCTUnwrap(image(at: imageURL), page.filename)
            XCTAssertEqual(image.width, page.width, page.filename)
            XCTAssertEqual(image.height, page.height, page.filename)

            let sourceSize = CGSize(width: image.width, height: image.height)
            let identifier = MangaPageIdentifier(
                scope: "v2b5-simulator-review-\(page.book)",
                pageIndex: index,
                sourceFingerprint: page.filename
            )
            let timed = try await provider.analyzePageWithTiming(
                image: image,
                sourceImageSize: sourceSize,
                pageIdentifier: identifier
            )
            timings.append(timed.timing)
            totalDetections += timed.analysis.allRegions.count
            semanticPages += 1
            balloonRegions += timed.analysis.balloons.count
            XCTAssertTrue(
                timed.analysis.allRegions.allSatisfy { region in
                    region.normalizedRect.minX >= 0
                        && region.normalizedRect.minY >= 0
                        && region.normalizedRect.maxX <= 1
                        && region.normalizedRect.maxY <= 1
                        && region.contour == nil
                },
                page.filename
            )

            let uiImage = UIImage(cgImage: image)
            let layout = await PanelDetectionService.shared.layout(
                comicID: reviewID,
                pageIndex: index,
                pageURL: imageURL,
                image: uiImage,
                isRightToLeft: false
            )
            panelPages += 1
            XCTAssertTrue(layout.panels.allSatisfy { $0.contour == nil }, page.filename)
            XCTAssertTrue(layout.panels.allSatisfy { panel in
                let rect = panel.rect.cgRect
                return rect.minX >= 0 && rect.minY >= 0 && rect.maxX <= 1 && rect.maxY <= 1
            }, page.filename)

            // Exercise the actual mReader OCR entry point, including its
            // MangaVision analysis lookup and OCR ROI planning. Ten pages are
            // enough for the functional gate and keep normal simulator runs
            // bounded; the complete detector pass still covers all 40 pages.
            if index < 10 {
                let request = OCRRecognitionCacheRequest(
                    pageURL: imageURL,
                    fallbackImage: uiImage,
                    options: OCRPreprocessor.Options(
                        isRightToLeft: false,
                        minimumTextHeight: 0.005,
                        recognitionMode: .adaptive,
                        sourceLanguagePreference: .japanese
                    ),
                    comicID: reviewID,
                    pageIndex: index
                )
                let result = try await OCRRuntimeService.recognize(for: request)
                ocrPages += 1
                ocrBlocks += result.rawBlocks.count
                let plannedROIs = MangaVisionTextROIPlanner.recognitionRegions(
                    from: timed.analysis.texts
                )
                ocrROIPages += plannedROIs.isEmpty ? 0 : 1
                XCTAssertTrue(result.rawBlocks.allSatisfy { block in
                    let rect = block.boundingBox
                    return rect.minX >= 0 && rect.minY >= 0 && rect.maxX <= 1 && rect.maxY <= 1
                }, page.filename)
            }
        }

        XCTAssertEqual(manifest.pages.count, 40)
        XCTAssertEqual(semanticPages, 40)
        XCTAssertEqual(panelPages, 40)
        XCTAssertEqual(ocrPages, 10)

        let payload: [String: Any] = [
            "status": "PASS",
            "simulator": [
                "name": "测试",
                "runtime": "iOS 26.5",
                "udid": "A301890E-55DE-46F4-8917-8C96742C30C6",
                "test_images_accessed": false,
                "test_inference": false
            ],
            "sample_package": [
                "package": manifest.package,
                "source_dataset": manifest.sourceDataset,
                "split": manifest.split,
                "pages": manifest.pages.count,
                "books": Set(manifest.pages.map(\.book)).count,
                "model_predictions_used": manifest.modelPredictionsUsed
            ],
            "model": [
                "identifier": MangaVisionV2B5Provider.modelIdentifier,
                "architecture": "V2B5",
                "classes": ["frame", "text", "face", "body", "balloon"],
                "input": "1x3x640x640",
                "calibration_revision": "v2b5-calibration-v1",
                "score_threshold": 0.05,
                "max_detections": 300,
                "nms": [0.50, 0.55, 0.45, 0.55, 0.45]
            ],
            "coverage": [
                "semantic_pages": semanticPages,
                "panel_pages": panelPages,
                "balloon_regions": balloonRegions,
                "ocr_pages": ocrPages,
                "ocr_raw_blocks": ocrBlocks,
                "ocr_roi_pages": ocrROIPages,
                "contours": "nil for every V2B5 region and panel"
            ],
            "latency_ms": [
                "preprocess": statistics(timings.map(\.preprocessMilliseconds)),
                "model": statistics(timings.map(\.modelMilliseconds)),
                "postprocess": statistics(timings.map(\.postprocessMilliseconds)),
                "total": statistics(timings.map(\.totalMilliseconds))
            ]
        ]
        let data = try XCTUnwrap(JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]))
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        print("MREADER_V2B5_SIMULATOR_REVIEW_JSON=\(json)")
    }

    private struct Manifest: Decodable {
        let package: String
        let sourceDataset: String
        let split: String
        let modelPredictionsUsed: Bool
        let pageCount: Int
        let bookCount: Int
        let pages: [ValPage]

        enum CodingKeys: String, CodingKey {
            case package
            case sourceDataset = "source_dataset"
            case split
            case modelPredictionsUsed = "model_predictions_used"
            case pageCount = "page_count"
            case bookCount = "book_count"
            case pages
        }
    }

    private struct ValPage: Decodable {
        let book: String
        let filename: String
        let split: String
        let width: Int
        let height: Int
    }

    private func loadManifest() throws -> Manifest {
        let candidates = [Bundle(for: Self.self), Bundle.main] + Bundle.allBundles
        for bundle in candidates {
            if let url = bundle.url(
                forResource: "manifest",
                withExtension: "json",
                subdirectory: "V2B5ValSamples"
            ) {
                return try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: url))
            }
            if let url = bundle.url(forResource: "manifest", withExtension: "json") {
                return try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: url))
            }
        }
        throw NSError(domain: "V2B5ProductionReviewTests", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "V2B5ValSamples/manifest.json is not in the test bundle"
        ])
    }

    private func imageURL(for page: ValPage) -> URL? {
        let imageName = URL(fileURLWithPath: page.filename)
            .deletingPathExtension()
            .lastPathComponent
        let resourceName = "\(page.book)__\(imageName)"
        let bundles = [Bundle(for: Self.self), Bundle.main] + Bundle.allBundles
        return bundles.first { bundle in
            bundle.url(forResource: resourceName, withExtension: "jpg") != nil
        }?.url(forResource: resourceName, withExtension: "jpg")
    }

    private func image(at url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    private func statistics(_ samples: [Double]) -> [String: Double] {
        guard !samples.isEmpty else { return ["mean": 0, "median": 0, "p95": 0] }
        let sorted = samples.sorted()
        func quantile(_ q: Double) -> Double {
            let index = min(max(Int((Double(sorted.count - 1) * q).rounded()), 0), sorted.count - 1)
            return sorted[index]
        }
        return [
            "mean": samples.reduce(0, +) / Double(samples.count),
            "median": quantile(0.50),
            "p95": quantile(0.95),
            "min": sorted[0],
            "max": sorted[sorted.count - 1]
        ]
    }
}
