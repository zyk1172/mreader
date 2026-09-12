from __future__ import annotations

import hashlib
import json
from pathlib import Path
from urllib.request import Request, urlopen

ROOT = Path(__file__).resolve().parents[1]
FIXTURES = ROOT / "mreaderTests" / "Fixtures"
BRANCH_SCRIPT = ROOT / "scripts" / "apply_translation_gold_fixture.py"
WORKFLOW = ROOT / ".github" / "workflows" / "apply-translation-gold-fixture.yml"

SHIROHAGE_URL = "https://upload.wikimedia.org/wikipedia/commons/4/40/Sample_of_SHIROHAGE_MANGA.jpg"
SHIROHAGE_SHA1 = "8c828fc750e946ce94038a00782cbe115537c15e"
SHIROHAGE_IMAGE = "sample_shirohage_manga.jpg"


def download_shirohage() -> None:
    target = FIXTURES / SHIROHAGE_IMAGE
    request = Request(SHIROHAGE_URL, headers={"User-Agent": "mReader-fixture-fetch/1.0"})
    with urlopen(request, timeout=60) as response:
        data = response.read()
    digest = hashlib.sha1(data).hexdigest()
    if digest != SHIROHAGE_SHA1:
        raise RuntimeError(f"SHIROHAGE fixture SHA-1 mismatch: {digest}")
    target.write_bytes(data)


def patch_manifest() -> None:
    path = FIXTURES / "translation_quality_manifest.json"
    manifest = json.loads(path.read_text(encoding="utf-8"))
    manifest["schemaVersion"] = 2

    samples = manifest["samples"]
    negative = next(item for item in samples if item["id"] == "manga-page-publicdomainq")
    negative.update(
        {
            "license": "CC0",
            "sourceLanguage": "und",
            "annotationStatus": "ready",
            "goldText": None,
            "goldAnnotation": "manga_page_publicdomainq.gold.json",
            "notes": (
                "Licensed full-page negative fixture. It contains manga-drawing artwork but no "
                "human-verified translatable manga dialogue; use it to detect false text/noText "
                "state regressions, not as Japanese OCR ground truth."
            ),
        }
    )

    positive = {
        "id": "manga-page-shirohage-ja",
        "image": SHIROHAGE_IMAGE,
        "license": "CC BY-SA 4.0",
        "sourceLanguage": "ja",
        "annotationStatus": "pending",
        "goldText": None,
        "goldAnnotation": None,
        "notes": (
            "Licensed Japanese speech-balloon manga fixture from Wikimedia Commons. Keep pending "
            "until regions, reading order, bubble grouping and reference translations are human-verified."
        ),
    }
    existing = next((item for item in samples if item["id"] == positive["id"]), None)
    if existing is None:
        samples.append(positive)
    else:
        existing.update(positive)

    # Schema v2 permits page-level gold annotations in addition to single-string OCR gold.
    for sample in samples:
        sample.setdefault("goldAnnotation", None)

    path.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def write_negative_gold() -> None:
    path = FIXTURES / "manga_page_publicdomainq.gold.json"
    payload = {
        "schemaVersion": 1,
        "sampleID": "manga-page-publicdomainq",
        "expectedPageState": "noText",
        "regions": [],
        "referenceTranslations": {},
        "notes": (
            "Human-inspected negative page fixture: no manga dialogue/translation unit is annotated. "
            "Decorative drawing marks and the English INK bottle label are intentionally not treated "
            "as manga dialogue for translation completeness scoring."
        ),
    }
    path.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def patch_manifest_model() -> None:
    path = ROOT / "mreaderTests" / "TranslationQualityBenchmark.swift"
    text = path.read_text(encoding="utf-8")
    old = """        let annotationStatus: AnnotationStatus\n        let goldText: String?\n        let notes: String?\n"""
    new = """        let annotationStatus: AnnotationStatus\n        let goldText: String?\n        /// Optional page-level gold file for regions, structure and expected page state.\n        let goldAnnotation: String?\n        let notes: String?\n\n        var hasGoldReference: Bool {\n            let hasText = !(goldText ?? \"\")\n                .trimmingCharacters(in: .whitespacesAndNewlines)\n                .isEmpty\n            let hasPageGold = !(goldAnnotation ?? \"\")\n                .trimmingCharacters(in: .whitespacesAndNewlines)\n                .isEmpty\n            return hasText || hasPageGold\n        }\n"""
    if old not in text:
        raise RuntimeError("manifest model anchor not found")
    path.write_text(text.replace(old, new, 1), encoding="utf-8")


def write_page_gold_model() -> None:
    path = ROOT / "mreaderTests" / "TranslationBenchmarkPageGold.swift"
    path.write_text(
        """import Foundation\n\n/// Human-authored page-level ground truth. It deliberately lives outside the\n/// runtime translation pipeline so model output can never become its own gold.\nstruct TranslationBenchmarkPageGold: Codable, Equatable, Sendable {\n    let schemaVersion: Int\n    let sampleID: String\n    let expectedPageState: TranslationBenchmarkPageState\n    let regions: [TranslationBenchmarkRegion]\n    let referenceTranslations: [String: String]\n    let notes: String?\n\n    var isInternallyConsistent: Bool {\n        if expectedPageState == .noText {\n            return regions.isEmpty && referenceTranslations.isEmpty\n        }\n        let regionIDs = Set(regions.map(\\.id))\n        return !regions.isEmpty && Set(referenceTranslations.keys).isSubset(of: regionIDs)\n    }\n}\n""",
        encoding="utf-8",
    )


def patch_existing_manifest_test() -> None:
    path = ROOT / "mreaderTests" / "TranslationQualityBenchmarkTests.swift"
    text = path.read_text(encoding="utf-8")
    text = text.replace("XCTAssertEqual(manifest.schemaVersion, 1)", "XCTAssertEqual(manifest.schemaVersion, 2)", 1)
    old = """        XCTAssertTrue(ready.allSatisfy { sample in\n            guard let goldText = sample.goldText else { return false }\n            return !goldText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty\n        })\n\n        let pending = try XCTUnwrap(manifest.samples.first { $0.id == \"manga-page-publicdomainq\" })\n        XCTAssertEqual(pending.annotationStatus, .pending)\n        XCTAssertNil(pending.goldText)\n"""
    new = """        XCTAssertTrue(ready.allSatisfy(\\.hasGoldReference))\n\n        let negative = try XCTUnwrap(manifest.samples.first { $0.id == \"manga-page-publicdomainq\" })\n        XCTAssertEqual(negative.annotationStatus, .ready)\n        XCTAssertNil(negative.goldText)\n        XCTAssertEqual(negative.goldAnnotation, \"manga_page_publicdomainq.gold.json\")\n\n        let pending = try XCTUnwrap(manifest.samples.first { $0.id == \"manga-page-shirohage-ja\" })\n        XCTAssertEqual(pending.annotationStatus, .pending)\n        XCTAssertNil(pending.goldText)\n        XCTAssertNil(pending.goldAnnotation)\n"""
    if old not in text:
        raise RuntimeError("manifest test anchor not found")
    path.write_text(text.replace(old, new, 1), encoding="utf-8")


def write_gold_fixture_tests() -> None:
    path = ROOT / "mreaderTests" / "TranslationGoldFixtureTests.swift"
    path.write_text(
        """import Foundation\nimport XCTest\n\nfinal class TranslationGoldFixtureTests: XCTestCase {\n    func testReadyPageGoldFilesDecodeAndMatchManifest() throws {\n        let manifest: TranslationQualityBenchmarkManifest = try decodeFixture(\n            \"translation_quality_manifest\",\n            extension: \"json\"\n        )\n        let pageGoldSamples = manifest.samples.filter {\n            $0.annotationStatus == .ready && $0.goldAnnotation != nil\n        }\n        XCTAssertFalse(pageGoldSamples.isEmpty)\n\n        for sample in pageGoldSamples {\n            let annotation = try XCTUnwrap(sample.goldAnnotation)\n            let file = URL(fileURLWithPath: annotation)\n            let gold: TranslationBenchmarkPageGold = try decodeFixture(\n                file.deletingPathExtension().lastPathComponent,\n                extension: file.pathExtension\n            )\n            XCTAssertEqual(gold.schemaVersion, 1)\n            XCTAssertEqual(gold.sampleID, sample.id)\n            XCTAssertTrue(gold.isInternallyConsistent)\n        }\n    }\n\n    func testPublicDomainQPageIsExplicitNoTextNegativeGold() throws {\n        let gold: TranslationBenchmarkPageGold = try decodeFixture(\n            \"manga_page_publicdomainq.gold\",\n            extension: \"json\"\n        )\n        XCTAssertEqual(gold.expectedPageState, .noText)\n        XCTAssertTrue(gold.regions.isEmpty)\n        XCTAssertTrue(gold.referenceTranslations.isEmpty)\n        XCTAssertTrue(gold.isInternallyConsistent)\n\n        let score = TranslationQualityBenchmark.completenessScore(\n            observations: [.init(expected: .noText, actual: .noText)]\n        )\n        XCTAssertEqual(score.exactStateAccuracy, 1, accuracy: 0.0001)\n        XCTAssertEqual(score.noTextFalsePositiveRate, 0, accuracy: 0.0001)\n    }\n\n    func testPendingJapaneseMangaFixtureIsBundledButCannotReportQualityYet() throws {\n        let manifest: TranslationQualityBenchmarkManifest = try decodeFixture(\n            \"translation_quality_manifest\",\n            extension: \"json\"\n        )\n        let sample = try XCTUnwrap(manifest.samples.first { $0.id == \"manga-page-shirohage-ja\" })\n        XCTAssertEqual(sample.annotationStatus, .pending)\n        XCTAssertFalse(sample.hasGoldReference)\n\n        let bundle = Bundle(for: TranslationGoldFixtureTests.self)\n        let imageURL = bundle.url(\n            forResource: \"sample_shirohage_manga\",\n            withExtension: \"jpg\",\n            subdirectory: \"Fixtures\"\n        ) ?? bundle.url(forResource: \"sample_shirohage_manga\", withExtension: \"jpg\")\n        XCTAssertNotNil(imageURL)\n    }\n\n    private func decodeFixture<T: Decodable>(\n        _ name: String,\n        extension fileExtension: String\n    ) throws -> T {\n        let bundle = Bundle(for: TranslationGoldFixtureTests.self)\n        let url = try XCTUnwrap(\n            bundle.url(forResource: name, withExtension: fileExtension, subdirectory: \"Fixtures\")\n                ?? bundle.url(forResource: name, withExtension: fileExtension)\n        )\n        return try JSONDecoder().decode(T.self, from: Data(contentsOf: url))\n    }\n}\n""",
        encoding="utf-8",
    )


def patch_readme() -> None:
    path = FIXTURES / "README.md"
    text = path.read_text(encoding="utf-8")
    old = """The larger `manga_page_publicdomainq.png` fixture is a CC0 example manga page\nfrom Wikimedia Commons and is retained for future page-level recovery tests.\n"""
    new = """The larger `manga_page_publicdomainq.png` fixture is a CC0 manga-drawing page\nfrom Wikimedia Commons. Visual review found no human-verified translatable manga\ndialogue on the page, so it is intentionally a **negative `noText` gold fixture**.\nIt must not be used as Japanese OCR/translation ground truth. Its page-level gold\nannotation is `manga_page_publicdomainq.gold.json`.\n\n`sample_shirohage_manga.jpg` is Wikimedia Commons' `Sample of SHIROHAGE MANGA.jpg`,\na Japanese speech-balloon manga example by しんぎんぐきゃっと, licensed under\nCC BY-SA 4.0. The repository stores the original file unchanged (SHA-1\n`8c828fc750e946ce94038a00782cbe115537c15e`).\n\n- Source: https://commons.wikimedia.org/wiki/File:Sample_of_SHIROHAGE_MANGA.jpg\n- License: https://creativecommons.org/licenses/by-sa/4.0/\n- Author: しんぎんぐきゃっと\n- Fixture status: `pending` until human gold regions, reading order, grouping and\n  reference translations are completed.\n"""
    if old not in text:
        raise RuntimeError("fixture README anchor not found")
    path.write_text(text.replace(old, new, 1), encoding="utf-8")


def remove_temporary_files() -> None:
    BRANCH_SCRIPT.unlink(missing_ok=True)
    WORKFLOW.unlink(missing_ok=True)


def main() -> None:
    FIXTURES.mkdir(parents=True, exist_ok=True)
    download_shirohage()
    patch_manifest()
    write_negative_gold()
    patch_manifest_model()
    write_page_gold_model()
    patch_existing_manifest_test()
    write_gold_fixture_tests()
    patch_readme()
    remove_temporary_files()


if __name__ == "__main__":
    main()
