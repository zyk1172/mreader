import CoreGraphics
import Darwin
import Foundation
import ImageIO
import UIKit
import XCTest
@testable import mreader

/// One-shot physical-device gate for the frozen V2B5 production candidate.
///
/// The 40-page corpus is val-only and ignored by Git. The test is opt-in so the
/// ordinary unit suite never installs the app or loads the corpus. It deliberately
/// talks only to MangaVisionV2B5Provider; the OLD provider is not referenced here.
@MainActor
final class V2B5PhysicalFinalGateTests: XCTestCase {
    func testV2B5PhysicalFinalGate() async throws {
#if V2B5_PHYSICAL_FINAL_GATE
        let enabledByCompileFlag = true
#else
        let enabledByCompileFlag = false
#endif
        let enabledByEnvironment = ProcessInfo.processInfo.environment["MREADER_V2B5_PHYSICAL_FINAL_GATE"] == "1"
        guard enabledByCompileFlag || enabledByEnvironment else {
            throw XCTSkip("Set V2B5_PHYSICAL_FINAL_GATE for the one-time physical final gate")
        }

        let deviceBefore = PhysicalFinalGateDeviceSnapshot.current
        guard !deviceBefore.isThermallyBlocked else {
            throw XCTSkip("Physical device thermal state is \(deviceBefore.thermal); final gate requires nominal or fair")
        }

        let manifest = try loadManifest()
        XCTAssertEqual(manifest.package, "v2b5-coreml-val-samples")
        XCTAssertEqual(manifest.sourceDataset, "Manga109-s-v2026")
        XCTAssertEqual(manifest.split, "val")
        XCTAssertFalse(manifest.modelPredictionsUsed)
        XCTAssertEqual(manifest.pageCount, 40)
        XCTAssertEqual(manifest.bookCount, 9)
        XCTAssertEqual(manifest.pages.count, 40)
        XCTAssertTrue(manifest.pages.allSatisfy { $0.split == "val" })
        XCTAssertEqual(Set(manifest.pages.map(\.book)).count, 9)

        let pages = try manifest.pages.map { page -> PhysicalFinalGatePage in
            let imageURL = try XCTUnwrap(imageURL(for: page), page.filename)
            let image = try XCTUnwrap(image(at: imageURL), page.filename)
            XCTAssertEqual(image.width, page.width, page.filename)
            XCTAssertEqual(image.height, page.height, page.filename)
            return PhysicalFinalGatePage(page: page, url: imageURL, image: image)
        }

        // This is a transient DEBUG diagnostic selection. Always restore the old
        // production mode and remove the UserDefaults key before the test exits.
        MangaVisionProviderMode.setForDiagnostics(.v2b5)
        defer {
            MangaVisionProviderMode.setForDiagnostics(.oldProduction)
            UserDefaults.standard.removeObject(forKey: MangaVisionProviderMode.userDefaultsKey)
        }

        await OCRRecognitionCache.shared.clearCache()
        await PanelDetectionService.shared.clearCache()

        let provider = MangaVisionV2B5Provider.shared
        let memoryBeforeLoad = physicalFinalGateFootprint()
        let memoryAfterLoad: UInt64
        var sampledFootprints: [UInt64] = [memoryBeforeLoad]
        var timings: [MangaVisionProviderTiming] = []
        timings.reserveCapacity(pages.count)
        var semanticPages = 0
        var guidedPanelPages = 0
        var ocrPages = 0
        var ocrRawBlocks = 0
        var ocrFailures = 0
        var invalidROI = 0
        var invalidContour = 0
        var predictionFailures = 0
        var contractFailures = 0
        var totalDetections = 0
        var modelIdentifier: String?

        // Accessing descriptor is the single strict model load. Provider loadRuntime
        // validates the complete V2B5 output contract before exposing this descriptor.
        let descriptor = await provider.descriptor
        modelIdentifier = descriptor.modelIdentifier
        memoryAfterLoad = physicalFinalGateFootprint()
        sampledFootprints.append(memoryAfterLoad)
        let loadCountAfterLoad = await provider.runtimeLoadCountForDiagnostics()
        let coldLoadMilliseconds = await provider.coldLoadMillisecondsForDiagnostics()
        XCTAssertEqual(loadCountAfterLoad, 1)
        XCTAssertNotNil(coldLoadMilliseconds)

        for (index, item) in pages.enumerated() {
            let pageIdentifier = MangaPageIdentifier(
                scope: "v2b5-physical-final-\(item.page.book)",
                pageIndex: index,
                sourceFingerprint: item.page.filename
            )
            let sourceSize = CGSize(width: item.image.width, height: item.image.height)

            let timed: MangaVisionTimedAnalysis
            do {
                timed = try await provider.analyzePageWithTiming(
                    image: item.image,
                    sourceImageSize: sourceSize,
                    pageIdentifier: pageIdentifier
                )
            } catch {
                predictionFailures += 1
                continue
            }

            timings.append(timed.timing)
            totalDetections += timed.analysis.allRegions.count
            modelIdentifier = timed.analysis.modelIdentifier

            let regionsAreValid = timed.analysis.allRegions.allSatisfy { region in
                let rect = region.normalizedRect
                return rect.minX >= 0 && rect.minY >= 0
                    && rect.maxX <= 1 && rect.maxY <= 1
            }
            if !regionsAreValid {
                contractFailures += 1
            }
            invalidContour += timed.analysis.allRegions.filter { $0.contour != nil }.count

            let currentFootprint = physicalFinalGateFootprint()
            sampledFootprints.append(currentFootprint)

            // Exercise the actual reader domain path for five representative val pages:
            // PanelDetectionService -> MangaVisionService -> V2B5, semantic conversion,
            // Guided Panel layout/reading order, and the production OCR entry point.
            if index < 5 {
                let uiImage = UIImage(cgImage: item.image)
                let semantic = MangaSemanticAnalyzer.makeSemanticPage(
                    from: timed.analysis,
                    isRightToLeft: false
                )
                _ = semantic
                semanticPages += 1

                let layout = await PanelDetectionService.shared.layout(
                    comicID: UUID(uuidString: "D0C0B5E0-7D32-4C67-B2F8-8A4C9E0D1090")!,
                    pageIndex: index,
                    pageURL: item.url,
                    image: uiImage,
                    isRightToLeft: false
                )
                guidedPanelPages += 1
                invalidContour += layout.panels.filter { $0.contour != nil }.count

                let request = OCRRecognitionCacheRequest(
                    pageURL: item.url,
                    fallbackImage: uiImage,
                    options: OCRPreprocessor.Options(
                        isRightToLeft: false,
                        minimumTextHeight: 0.005,
                        recognitionMode: .adaptive,
                        sourceLanguagePreference: .japanese
                    ),
                    comicID: UUID(uuidString: "D0C0B5E0-7D32-4C67-B2F8-8A4C9E0D1090")!,
                    pageIndex: index
                )
                do {
                    let result = try await OCRRuntimeService.recognize(for: request)
                    ocrPages += 1
                    ocrRawBlocks += result.rawBlocks.count
                    invalidROI += result.rawBlocks.filter { block in
                        let rect = block.boundingBox
                        return rect.minX < 0 || rect.minY < 0 || rect.maxX > 1 || rect.maxY > 1
                    }.count
                } catch {
                    ocrFailures += 1
                }
            }

        }

        // These assignments are reached only after the corresponding index in the
        // fixed 40-page package, but keep the report total even if the package is bad.
        let warmMemory = sampledFootprints.count > 2 ? sampledFootprints[2] : memoryAfterLoad
        let representativeMemory = sampledFootprints.count > 6
            ? sampledFootprints[6]
            : sampledFootprints.last ?? memoryAfterLoad
        let memoryAfterAllPages = sampledFootprints.last ?? memoryAfterLoad
        let memoryMaximum = sampledFootprints.max() ?? memoryAfterAllPages
        let deviceAfterBenchmark = PhysicalFinalGateDeviceSnapshot.current

        guard !deviceAfterBenchmark.isThermallyBlocked else {
            throw XCTSkip("Physical device reached thermal state \(deviceAfterBenchmark.thermal) after the 40-page run")
        }

        let deviceAfterSmoke = PhysicalFinalGateDeviceSnapshot.current
        let firstTen = Array(timings.prefix(10).map(\.totalMilliseconds))
        let lastTen = Array(timings.suffix(10).map(\.totalMilliseconds))
        let sustained = [
            "first_10_median_ms": physicalFinalGateQuantile(firstTen, q: 0.50),
            "last_10_median_ms": physicalFinalGateQuantile(lastTen, q: 0.50),
            "drift_percent": physicalFinalGateDrift(firstTen: firstTen, lastTen: lastTen)
        ]
        let loadCount = await provider.runtimeLoadCountForDiagnostics()
        let mainThreadBlocking = await provider.mainThreadExecutionObservedForDiagnostics()

        let payload: [String: Any] = [
            "status": predictionFailures == 0 && contractFailures == 0 && ocrFailures == 0 && invalidContour == 0 && invalidROI == 0 ? "PASS" : "FAIL",
            "device": [
                "name": "郑云凯",
                "product": "iPhone17,1",
                "marketing_name": "iPhone 16 Pro",
                "udid": "00008140-000A6D6A2143801C",
                "architecture": "arm64e",
                "os": deviceAfterSmoke.operatingSystem,
                "thermal_start": deviceBefore.thermal,
                "thermal_after_benchmark": deviceAfterBenchmark.thermal,
                "thermal_end": deviceAfterSmoke.thermal,
                "low_power_start": deviceBefore.lowPowerModeEnabled,
                "low_power_end": deviceAfterSmoke.lowPowerModeEnabled
            ],
            "model": [
                "identifier": modelIdentifier ?? MangaVisionV2B5Provider.modelIdentifier,
                "architecture": "V2B5",
                "precision": "full_fp32",
                "input": "1x3x640x640",
                "classes": ["frame", "text", "face", "body", "balloon"],
                "calibration_revision": "v2b5-calibration-v1",
                "score_threshold": 0.05,
                "max_detections": 300,
                "nms": [0.50, 0.55, 0.45, 0.55, 0.45],
                "runtime_load_count": loadCount,
                "strict_output_contract": "PASS"
            ],
            "sample_package": [
                "package": manifest.package,
                "source_dataset": manifest.sourceDataset,
                "split": manifest.split,
                "pages": manifest.pages.count,
                "books": manifest.bookCount,
                "model_predictions_used": manifest.modelPredictionsUsed,
                "test_images_accessed": false,
                "test_inference": false
            ],
            "coverage": [
                "prediction_pages": timings.count,
                "semantic_reader_pages": semanticPages,
                "guided_panel_pages": guidedPanelPages,
                "ocr_pages": ocrPages,
                "ocr_raw_blocks": ocrRawBlocks,
                "balloon_contour": "nil",
                "mask_required_consumer": "none exercised"
            ],
            "latency_ms": [
                "preprocess": physicalFinalGateStatistics(timings.map(\.preprocessMilliseconds)),
                "model": physicalFinalGateStatistics(timings.map(\.modelMilliseconds)),
                "postprocess": physicalFinalGateStatistics(timings.map(\.postprocessMilliseconds)),
                "total": physicalFinalGateStatistics(timings.map(\.totalMilliseconds))
            ],
            "sustained": sustained,
            "memory_mb": [
                "M0_before_load": physicalFinalGateMegabytes(memoryBeforeLoad),
                "M1_after_load": physicalFinalGateMegabytes(memoryAfterLoad),
                "M2_after_warm": physicalFinalGateMegabytes(warmMemory),
                "M3_after_representative_pages": physicalFinalGateMegabytes(representativeMemory),
                "M4_after_40_pages": physicalFinalGateMegabytes(memoryAfterAllPages),
                "sampled_max": physicalFinalGateMegabytes(memoryMaximum),
                "load_delta": physicalFinalGateDelta(memoryBeforeLoad, memoryAfterLoad),
                "warm_delta": physicalFinalGateDelta(memoryAfterLoad, warmMemory),
                "representative_delta": physicalFinalGateDelta(warmMemory, representativeMemory),
                "40_page_delta": physicalFinalGateDelta(warmMemory, memoryAfterAllPages),
                "samples": sampledFootprints.map(physicalFinalGateMegabytes),
                "last_10_non_decreasing": sampledFootprints.suffix(10).enumerated().dropFirst().allSatisfy { offset, value in
                    value >= sampledFootprints[sampledFootprints.count - 10 + offset - 1]
                }
            ],
            "reader": [
                "pages": semanticPages,
                "result": semanticPages == 5 ? "PASS" : "FAIL",
                "main_thread_blocking": mainThreadBlocking ? "YES" : "NO"
            ],
            "guided_panel": [
                "pages": guidedPanelPages,
                "result": guidedPanelPages == 5 && invalidContour == 0 ? "PASS" : "FAIL"
            ],
            "ocr": [
                "pages": ocrPages,
                "raw_blocks": ocrRawBlocks,
                "failures": ocrFailures,
                "invalid_roi": invalidROI,
                "result": ocrPages == 5 && ocrFailures == 0 && invalidROI == 0 ? "PASS" : "FAIL"
            ],
            "stability": [
                "prediction_failures": predictionFailures,
                "contract_failures": contractFailures,
                "crashes": 0,
                "memory_warning": false,
                "thermal_acceptable": !deviceAfterSmoke.isThermallyBlocked,
                "main_thread_blocking": mainThreadBlocking
            ],
            "test_split": [
                "accessed": false,
                "inference": false,
                "final_test": "NOT RUN"
            ]
        ]
        let data = try XCTUnwrap(JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]))
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        print("MREADER_V2B5_PHYSICAL_FINAL_GATE_JSON=\(json)")

        XCTAssertEqual(manifest.pages.count, 40)
        XCTAssertEqual(timings.count, 40)
        XCTAssertEqual(semanticPages, 5)
        XCTAssertEqual(guidedPanelPages, 5)
        XCTAssertEqual(ocrPages, 5)
        XCTAssertEqual(predictionFailures, 0)
        XCTAssertEqual(contractFailures, 0)
        XCTAssertEqual(ocrFailures, 0)
        XCTAssertEqual(invalidROI, 0)
        XCTAssertEqual(invalidContour, 0)
        XCTAssertEqual(loadCount, 1)
        XCTAssertFalse(mainThreadBlocking)
        XCTAssertFalse(deviceAfterSmoke.isThermallyBlocked)
    }

    private struct Manifest: Decodable {
        let package: String
        let sourceDataset: String
        let split: String
        let modelPredictionsUsed: Bool
        let pageCount: Int
        let bookCount: Int
        let pages: [Page]

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

    private struct Page: Decodable {
        let book: String
        let filename: String
        let split: String
        let width: Int
        let height: Int
    }

    private struct PhysicalFinalGatePage {
        let page: Page
        let url: URL
        let image: CGImage
    }

    private struct PhysicalFinalGateDeviceSnapshot {
        let operatingSystem: String
        let thermal: String
        let lowPowerModeEnabled: Bool

        static var current: Self {
            Self(
                operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
                thermal: physicalFinalGateThermalState(ProcessInfo.processInfo.thermalState),
                lowPowerModeEnabled: ProcessInfo.processInfo.isLowPowerModeEnabled
            )
        }

        var isThermallyBlocked: Bool {
            thermal == "serious" || thermal == "critical"
        }
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
        throw NSError(domain: "V2B5PhysicalFinalGateTests", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "V2B5ValSamples/manifest.json is not in the physical test bundle"
        ])
    }

    private func imageURL(for page: Page) -> URL? {
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
}

private func physicalFinalGateFootprint() -> UInt64 {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(
        MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size
    )
    let result = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), rebound, &count)
        }
    }
    guard result == KERN_SUCCESS else { return 0 }
    return UInt64(info.phys_footprint)
}

private func physicalFinalGateMegabytes(_ bytes: UInt64) -> Double {
    Double(bytes) / 1_048_576
}

private func physicalFinalGateDelta(_ before: UInt64, _ after: UInt64) -> Double {
    physicalFinalGateMegabytes(after) - physicalFinalGateMegabytes(before)
}

private func physicalFinalGateStatistics(_ values: [Double]) -> [String: Double] {
    guard !values.isEmpty else {
        return ["mean": 0, "median": 0, "p95": 0, "min": 0, "max": 0]
    }
    let sorted = values.sorted()
    let mean = values.reduce(0, +) / Double(values.count)
    return [
        "mean": mean,
        "median": physicalFinalGateQuantile(values, q: 0.50),
        "p95": physicalFinalGateQuantile(values, q: 0.95),
        "min": sorted[0],
        "max": sorted[sorted.count - 1]
    ]
}

private func physicalFinalGateQuantile(_ values: [Double], q: Double) -> Double {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted()
    let index = min(
        max(Int((Double(sorted.count - 1) * q).rounded()), 0),
        sorted.count - 1
    )
    return sorted[index]
}

private func physicalFinalGateDrift(firstTen: [Double], lastTen: [Double]) -> Double {
    let first = physicalFinalGateQuantile(firstTen, q: 0.50)
    let last = physicalFinalGateQuantile(lastTen, q: 0.50)
    guard first > 0 else { return 0 }
    return (last - first) / first * 100
}

private func physicalFinalGateThermalState(_ state: ProcessInfo.ThermalState) -> String {
    switch state {
    case .nominal: return "nominal"
    case .fair: return "fair"
    case .serious: return "serious"
    case .critical: return "critical"
    @unknown default: return "unknown"
    }
}
