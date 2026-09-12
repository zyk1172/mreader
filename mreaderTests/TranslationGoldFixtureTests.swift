import Foundation
import XCTest

final class TranslationGoldFixtureTests: XCTestCase {
    func testReadyPageGoldFilesDecodeAndMatchManifest() throws {
        let manifest: TranslationQualityBenchmarkManifest = try decodeFixture(
            "translation_quality_manifest",
            extension: "json"
        )
        let pageGoldSamples = manifest.samples.filter {
            $0.annotationStatus == .ready && $0.goldAnnotation != nil
        }
        XCTAssertFalse(pageGoldSamples.isEmpty)

        for sample in pageGoldSamples {
            let annotation = try XCTUnwrap(sample.goldAnnotation)
            let file = URL(fileURLWithPath: annotation)
            let gold: TranslationBenchmarkPageGold = try decodeFixture(
                file.deletingPathExtension().lastPathComponent,
                extension: file.pathExtension
            )
            XCTAssertEqual(gold.schemaVersion, 1)
            XCTAssertEqual(gold.sampleID, sample.id)
            XCTAssertTrue(gold.isInternallyConsistent)
        }
    }

    func testPublicDomainQPageIsExplicitNoTextNegativeGold() throws {
        let gold: TranslationBenchmarkPageGold = try decodeFixture(
            "manga_page_publicdomainq.gold",
            extension: "json"
        )
        XCTAssertEqual(gold.expectedPageState, .noText)
        XCTAssertTrue(gold.regions.isEmpty)
        XCTAssertTrue(gold.referenceTranslations.isEmpty)
        XCTAssertTrue(gold.isInternallyConsistent)

        let score = TranslationQualityBenchmark.completenessScore(
            observations: [.init(expected: .noText, actual: .noText)]
        )
        XCTAssertEqual(score.exactStateAccuracy, 1, accuracy: 0.0001)
        XCTAssertEqual(score.noTextFalsePositiveRate, 0, accuracy: 0.0001)
    }

    func testPendingJapaneseMangaFixtureIsBundledButCannotReportQualityYet() throws {
        let manifest: TranslationQualityBenchmarkManifest = try decodeFixture(
            "translation_quality_manifest",
            extension: "json"
        )
        let sample = try XCTUnwrap(manifest.samples.first { $0.id == "manga-page-shirohage-ja" })
        XCTAssertEqual(sample.annotationStatus, .pending)
        XCTAssertFalse(sample.hasGoldReference)

        let bundle = Bundle(for: TranslationGoldFixtureTests.self)
        let imageURL = bundle.url(
            forResource: "sample_shirohage_manga",
            withExtension: "jpg",
            subdirectory: "Fixtures"
        ) ?? bundle.url(forResource: "sample_shirohage_manga", withExtension: "jpg")
        XCTAssertNotNil(imageURL)
    }

    private func decodeFixture<T: Decodable>(
        _ name: String,
        extension fileExtension: String
    ) throws -> T {
        let bundle = Bundle(for: TranslationGoldFixtureTests.self)
        let url = try XCTUnwrap(
            bundle.url(forResource: name, withExtension: fileExtension, subdirectory: "Fixtures")
                ?? bundle.url(forResource: name, withExtension: fileExtension)
        )
        return try JSONDecoder().decode(T.self, from: Data(contentsOf: url))
    }
}
