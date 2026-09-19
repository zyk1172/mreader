import CoreGraphics
import Foundation
import XCTest
@testable import mreader

@MainActor
final class V2B5FiveClassContractTests: XCTestCase {
    func testFiveClassContractIsStable() {
        XCTAssertEqual(
            MangaVisionV2B5ClassOrder.labels,
            ["frame", "text", "face", "body", "balloon"]
        )
        XCTAssertEqual(
            MangaVisionV2B5ClassOrder.regionTypes,
            [.panel, .text, .face, .body, .balloon]
        )
        XCTAssertEqual(
            Set(MangaVisionV2B5ClassOrder.regionTypes),
            Set(MangaRegionType.allCases)
        )
        XCTAssertEqual(MangaVisionV2B5OutputContract.inputShape, [1, 3, 640, 640])
        XCTAssertEqual(
            MangaVisionV2B5OutputContract.specs.filter { $0.role == "classification" }.map(\.channels),
            [5, 5, 5, 5]
        )
    }

    func testProductionProviderIsV2B5() {
        XCTAssertEqual(MangaVisionProviderMode.productionDefault, .v2b5)
        XCTAssertEqual(MangaVisionProviderMode.currentForDiagnostics, .v2b5)
        XCTAssertEqual(MangaVisionV2B5Provider.modelResourceName, "MangaVisionV2B5")
    }

    func testFiveClassesAreExposedToMangaPageAnalysis() {
        let regions = MangaVisionV2B5ClassOrder.regionTypes.enumerated().map { index, type in
            MangaVisionRegion(
                type: type,
                normalizedRect: CGRect(
                    x: CGFloat(index) * 0.1,
                    y: 0.1,
                    width: 0.08,
                    height: 0.08
                ),
                confidence: 0.9
            )
        }
        let analysis = makeAnalysis(regions: regions)

        XCTAssertEqual(analysis.allRegions.count, 5)
        for type in MangaVisionV2B5ClassOrder.regionTypes {
            XCTAssertEqual(analysis.regions(of: type).count, 1, type.rawValue)
        }
        XCTAssertEqual(analysis.panels.first?.type, .panel)
        XCTAssertEqual(analysis.texts.first?.type, .text)
        XCTAssertEqual(analysis.faces.first?.type, .face)
        XCTAssertEqual(analysis.bodies.first?.type, .body)
        XCTAssertEqual(analysis.balloons.first?.type, .balloon)
    }

    func testFaceAndBodySurviveDomainConversion() {
        let face = MangaVisionRegion(
            type: .face,
            normalizedRect: CGRect(x: 0.22, y: 0.18, width: 0.12, height: 0.12),
            confidence: 0.91
        )
        let body = MangaVisionRegion(
            type: .body,
            normalizedRect: CGRect(x: 0.16, y: 0.28, width: 0.28, height: 0.58),
            confidence: 0.87
        )
        let analysis = makeAnalysis(regions: [face, body])

        XCTAssertEqual(analysis.faces.map(\.id), [face.id])
        XCTAssertEqual(analysis.bodies.map(\.id), [body.id])
        XCTAssertEqual(analysis.regions(of: .face).first?.normalizedRect, face.normalizedRect)
        XCTAssertEqual(analysis.regions(of: .body).first?.normalizedRect, body.normalizedRect)
    }

    func testBalloonSurvivesDomainConversionWithNilContour() {
        let balloon = MangaVisionRegion(
            type: .balloon,
            normalizedRect: CGRect(x: 0.52, y: 0.20, width: 0.28, height: 0.24),
            confidence: 0.83
        )
        let analysis = makeAnalysis(regions: [balloon])

        XCTAssertEqual(analysis.balloons.map(\.id), [balloon.id])
        XCTAssertNil(analysis.balloons.first?.contour)
        XCTAssertNil(analysis.allRegions.first?.contour)
    }

    func testV2B5CapabilitiesDoNotDependOnDetectionArrayEmptiness() {
        let descriptor = MangaVisionProviderDescriptor(
            modelIdentifier: MangaVisionV2B5Provider.modelIdentifier,
            modelVersion: 5,
            inputSize: CGSize(width: 640, height: 640),
            supportedRegionTypes: Set(MangaVisionV2B5ClassOrder.regionTypes)
        )
        let capabilities = descriptor.capabilities

        XCTAssertTrue(capabilities.supportsFrame)
        XCTAssertTrue(capabilities.supportsText)
        XCTAssertTrue(capabilities.supportsFace)
        XCTAssertTrue(capabilities.supportsBody)
        XCTAssertTrue(capabilities.supportsBalloon)
        XCTAssertFalse(capabilities.supportsBalloonMask)
    }

    func testLegacyModelIsNotBundled() {
        let bundles = [Bundle.main, Bundle(for: Self.self)] + Bundle.allBundles + Bundle.allFrameworks
        let legacyResources = bundles.compactMap { bundle in
            bundle.url(forResource: "PanelDetector", withExtension: "mlmodelc")
        }
        XCTAssertTrue(legacyResources.isEmpty, "Legacy PanelDetector resources remain: \(legacyResources)")

        let v2b5Resources = bundles.compactMap { bundle in
            bundle.url(forResource: MangaVisionV2B5Provider.modelResourceName, withExtension: "mlmodelc")
        }
        XCTAssertFalse(v2b5Resources.isEmpty, "V2B5 compiled model is missing from the test host")
    }

    private func makeAnalysis(regions: [MangaVisionRegion]) -> MangaPageAnalysis {
        MangaPageAnalysis(
            pageIdentifier: MangaPageIdentifier(
                scope: "v2b5-five-class-contract",
                pageIndex: 0,
                sourceFingerprint: "fixture"
            ),
            imageSize: CGSize(width: 640, height: 640),
            panels: regions.filter { $0.type == .panel },
            texts: regions.filter { $0.type == .text },
            balloons: regions.filter { $0.type == .balloon },
            faces: regions.filter { $0.type == .face },
            bodies: regions.filter { $0.type == .body },
            modelIdentifier: MangaVisionV2B5Provider.modelIdentifier,
            modelVersion: 5
        )
    }
}
