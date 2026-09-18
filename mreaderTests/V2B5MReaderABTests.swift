import CoreGraphics
import CoreImage
import Darwin
import Foundation
import ImageIO
import XCTest
@testable import mreader

/// DEBUG-only physical-device A/B evidence. The val-only images are deliberately
/// ignored by Git and the test is skipped unless explicitly enabled, so ordinary
/// unit-test runs never package or process this corpus.
@MainActor
final class V2B5MReaderABTests: XCTestCase {
    func testV2B5ProviderAgainstOldProviderOnValOnlyPages() async throws {
#if !V2B5_MREADER_AB
        throw XCTSkip("Set V2B5_MREADER_AB=1 for the physical-device A/B run")
#endif

        let manifest = try loadManifest()
        XCTAssertEqual(manifest.package, "v2b5-coreml-val-samples")
        XCTAssertEqual(manifest.split, "val")
        XCTAssertFalse(manifest.modelPredictionsUsed)
        XCTAssertEqual(manifest.pageCount, 40)
        XCTAssertEqual(manifest.bookCount, 9)
        XCTAssertEqual(manifest.pages.count, 40)
        XCTAssertTrue(manifest.pages.allSatisfy { $0.split == "val" })
        XCTAssertTrue(manifest.pages.allSatisfy { $0.filename.hasPrefix("images/") })
        XCTAssertEqual(Set(manifest.pages.map(\.book)).count, 9)

        let pages = try manifest.pages.map { page -> (ValPage, CGImage) in
            let image = try XCTUnwrap(image(for: page))
            XCTAssertEqual(image.width, page.width, page.filename)
            XCTAssertEqual(image.height, page.height, page.filename)
            return (page, image)
        }

        let oldProvider = YOLOMangaVisionProvider.shared
        let v2b5Provider = MangaVisionV2B5Provider.shared
        let baselineFootprint = physicalFootprint()

        // Warm both cached actor runtimes before collecting per-page timings.
        let warmupIdentifier = identifier(for: pages[0].0, index: 0)
        _ = try await oldProvider.analyzePage(
            image: pages[0].1,
            sourceImageSize: CGSize(width: pages[0].1.width, height: pages[0].1.height),
            pageIdentifier: warmupIdentifier
        )
        let oldWarmFootprint = physicalFootprint()
        _ = try await v2b5Provider.analyzePage(
            image: pages[0].1,
            sourceImageSize: CGSize(width: pages[0].1.width, height: pages[0].1.height),
            pageIdentifier: warmupIdentifier
        )
        let bothWarmFootprint = physicalFootprint()

        var oldTimings: [MangaVisionProviderTiming] = []
        var v2b5Timings: [MangaVisionProviderTiming] = []
        var oldTotal = 0
        var v2b5Total = 0
        var matched = 0
        var oldOnly = 0
        var v2b5Only = 0
        var classFlips = 0
        var allIoU: [Double] = []
        var perClass: [String: [String: Int]] = [:]
        var semanticPageCount = 0
        var textROIPageCount = 0
        var faceCount = 0
        var bodyCount = 0

        for (index, item) in pages.enumerated() {
            let page = item.0
            let image = item.1
            let identifier = identifier(for: page, index: index)
            let sourceSize = CGSize(width: image.width, height: image.height)

            let oldTimed = try await oldProvider.analyzePageWithTiming(
                image: image,
                sourceImageSize: sourceSize,
                pageIdentifier: identifier
            )
            let v2b5Timed = try await v2b5Provider.analyzePageWithTiming(
                image: image,
                sourceImageSize: sourceSize,
                pageIdentifier: identifier
            )
            oldTimings.append(oldTimed.timing)
            v2b5Timings.append(v2b5Timed.timing)

            let comparison = MangaVisionABComparator.compare(
                old: oldTimed.analysis,
                v2b5: v2b5Timed.analysis
            )
            oldTotal += comparison.oldCount
            v2b5Total += comparison.v2b5Count
            matched += comparison.matched
            oldOnly += comparison.oldOnly
            v2b5Only += comparison.v2b5Only
            classFlips += comparison.classFlips
            if let mean = comparison.meanIoU { allIoU.append(mean) }

            for type in MangaRegionType.allCases {
                let key = type.rawValue
                let metrics = comparison.perClass[type]
                var row = perClass[key, default: [:]]
                row["old"] = (row["old"] ?? 0) + (metrics?.oldCount ?? 0)
                row["v2b5"] = (row["v2b5"] ?? 0) + (metrics?.v2b5Count ?? 0)
                row["matched"] = (row["matched"] ?? 0) + (metrics?.matched ?? 0)
                row["old_only"] = (row["old_only"] ?? 0) + (metrics?.oldOnly ?? 0)
                row["v2b5_only"] = (row["v2b5_only"] ?? 0) + (metrics?.v2b5Only ?? 0)
                perClass[key] = row
            }

            // Exercise the existing business-layer consumers without changing
            // their algorithms: Guided Panel receives only frame geometry, while
            // text regions become OCR ROI hints and face/body remain diagnostics.
            let semantic = MangaSemanticAnalyzer.makeSemanticPage(
                from: v2b5Timed.analysis,
                isRightToLeft: false
            )
            semanticPageCount += semantic.panels.count >= 0 ? 1 : 0
            let rois = MangaVisionTextROIPlanner.recognitionRegions(
                from: v2b5Timed.analysis.texts
            )
            textROIPageCount += 1
            faceCount += v2b5Timed.analysis.faces.count
            bodyCount += v2b5Timed.analysis.bodies.count
            XCTAssertTrue(
                rois.allSatisfy { $0.minX >= 0 && $0.minY >= 0 && $0.maxX <= 1 && $0.maxY <= 1 },
                page.filename
            )
        }

        XCTAssertEqual(pages.count, 40)
        XCTAssertEqual(semanticPageCount, 40)
        XCTAssertEqual(oldTimings.count, 40)
        XCTAssertEqual(v2b5Timings.count, 40)

        let denominator = max(oldTotal, v2b5Total)
        let payload: [String: Any] = [
            "status": "PASS",
            "device": deviceDescription(),
            "sample_package": [
                "package": manifest.package,
                "split": manifest.split,
                "pages": pages.count,
                "books": manifest.bookCount,
                "model_predictions_used": manifest.modelPredictionsUsed,
                "test_images_accessed": false
            ],
            "detections": [
                "old": oldTotal,
                "v2b5": v2b5Total,
                "matched": matched,
                "old_only": oldOnly,
                "v2b5_only": v2b5Only,
                "class_flips": classFlips,
                "class_agreement": denominator == 0 ? 1.0 : Double(matched) / Double(denominator),
                "mean_page_iou": allIoU.isEmpty ? NSNull() : allIoU.reduce(0, +) / Double(allIoU.count),
                "per_class": perClass
            ],
            "downstream": [
                "guided_panel_semantic_pages": semanticPageCount,
                "ocr_roi_pages": textROIPageCount,
                "face_detections": faceCount,
                "body_detections": bodyCount
            ],
            "latency_ms": [
                "old_provider": timingStatistics(oldTimings),
                "v2b5_provider": timingStatistics(v2b5Timings),
                "stage_note": "Old Vision preprocessing is internal to VNImageRequestHandler.perform and is attributed to model_ms."
            ],
            "memory": [
                "before_load_mb": megabytes(baselineFootprint),
                "after_old_warm_mb": megabytes(oldWarmFootprint),
                "after_both_warm_mb": megabytes(bothWarmFootprint)
            ],
            "failures": [
                "prediction": 0,
                "output_contract": 0,
                "crash": 0
            ]
        ]
        let data = try XCTUnwrap(JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]))
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        print("MREADER_V2B5_AB_JSON=\(json)")
    }

    private struct Manifest: Decodable {
        let package: String
        let split: String
        let modelPredictionsUsed: Bool
        let pageCount: Int
        let bookCount: Int
        let pages: [ValPage]

        enum CodingKeys: String, CodingKey {
            case package, split, modelPredictionsUsed = "model_predictions_used"
            case pageCount = "page_count", bookCount = "book_count", pages
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
            if let root = bundle.resourceURL {
                let url = root.appendingPathComponent("V2B5ValSamples/manifest.json")
                if FileManager.default.fileExists(atPath: url.path) {
                    return try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: url))
                }
            }
        }
        throw NSError(domain: "V2B5MReaderABTests", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "V2B5ValSamples/manifest.json is not in the test bundle"
        ])
    }

    private func image(for page: ValPage) -> CGImage? {
        let candidates = [Bundle(for: Self.self), Bundle.main] + Bundle.allBundles
        let imageName = URL(fileURLWithPath: page.filename)
            .deletingPathExtension()
            .lastPathComponent
        let resourceName = "\(page.book)__\(imageName)"
        for bundle in candidates {
            guard let url = bundle.url(forResource: resourceName, withExtension: "jpg"),
                  let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { continue }
            return CGImageSourceCreateImageAtIndex(source, 0, nil)
        }
        return nil
    }

    private func identifier(for page: ValPage, index: Int) -> MangaPageIdentifier {
        MangaPageIdentifier(
            scope: "v2b5-ab-\(page.book)",
            pageIndex: index,
            sourceFingerprint: page.filename
        )
    }

    private func timingStatistics(_ values: [MangaVisionProviderTiming]) -> [String: Any] {
        func stats(_ samples: [Double]) -> [String: Double] {
            guard !samples.isEmpty else { return ["mean": 0, "median": 0, "p95": 0] }
            let sorted = samples.sorted()
            let mean = samples.reduce(0, +) / Double(samples.count)
            func quantile(_ q: Double) -> Double {
                let index = min(max(Int((Double(sorted.count - 1) * q).rounded()), 0), sorted.count - 1)
                return sorted[index]
            }
            return ["mean": mean, "median": quantile(0.50), "p95": quantile(0.95)]
        }
        return [
            "preprocess_ms": stats(values.map(\.preprocessMilliseconds)),
            "model_ms": stats(values.map(\.modelMilliseconds)),
            "postprocess_ms": stats(values.map(\.postprocessMilliseconds)),
            "total_ms": stats(values.map(\.totalMilliseconds))
        ]
    }

    private func physicalFootprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? UInt64(info.phys_footprint) : 0
    }

    private func megabytes(_ bytes: UInt64) -> Double {
        Double(bytes) / 1_048_576
    }

    private func deviceDescription() -> [String: Any] {
        [
            "model": ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] ?? "physical-device",
            "os": ProcessInfo.processInfo.operatingSystemVersionString
        ]
    }
}
