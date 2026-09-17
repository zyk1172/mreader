import CoreGraphics
import Foundation

nonisolated struct MangaVisionRegressionObservation: Sendable, Equatable {
    let expectedRegions: [MangaVisionRegion]
    let predictedRegions: [MangaVisionRegion]
    let expectedOCRRects: [CGRect]
    let predictedOCRRects: [CGRect]
    let usedFallback: Bool
    let inferenceCount: Int

    init(
        expectedRegions: [MangaVisionRegion] = [],
        predictedRegions: [MangaVisionRegion] = [],
        expectedOCRRects: [CGRect] = [],
        predictedOCRRects: [CGRect] = [],
        usedFallback: Bool = false,
        inferenceCount: Int = 1
    ) {
        self.expectedRegions = expectedRegions
        self.predictedRegions = predictedRegions
        self.expectedOCRRects = expectedOCRRects
        self.predictedOCRRects = predictedOCRRects
        self.usedFallback = usedFallback
        self.inferenceCount = max(inferenceCount, 0)
    }
}

nonisolated struct MangaVisionRegressionMetrics: Sendable, Equatable {
    let panelRecall: Double?
    let textRecall: Double?
    let balloonRecall: Double?
    let ocrFinalRecall: Double?
    let fallbackRate: Double
    let inferenceCountPerPage: Double
    let pageCount: Int

    static func aggregate(
        _ observations: [MangaVisionRegressionObservation],
        matchThreshold: CGFloat = 0.50
    ) -> MangaVisionRegressionMetrics {
        let panel = recall(
            expected: observations.flatMap { $0.expectedRegions.filter { $0.type == .panel }.map(\.normalizedRect) },
            predicted: observations.flatMap { $0.predictedRegions.filter { $0.type == .panel }.map(\.normalizedRect) },
            threshold: matchThreshold
        )
        let text = recall(
            expected: observations.flatMap { $0.expectedRegions.filter { $0.type == .text }.map(\.normalizedRect) },
            predicted: observations.flatMap { $0.predictedRegions.filter { $0.type == .text }.map(\.normalizedRect) },
            threshold: matchThreshold
        )
        let balloon = recall(
            expected: observations.flatMap { $0.expectedRegions.filter { $0.type == .balloon }.map(\.normalizedRect) },
            predicted: observations.flatMap { $0.predictedRegions.filter { $0.type == .balloon }.map(\.normalizedRect) },
            threshold: matchThreshold
        )
        let ocr = recall(
            expected: observations.flatMap(\.expectedOCRRects),
            predicted: observations.flatMap(\.predictedOCRRects),
            threshold: matchThreshold
        )
        let pages = observations.count
        return MangaVisionRegressionMetrics(
            panelRecall: panel,
            textRecall: text,
            balloonRecall: balloon,
            ocrFinalRecall: ocr,
            fallbackRate: pages == 0
                ? 0
                : Double(observations.filter(\.usedFallback).count) / Double(pages),
            inferenceCountPerPage: pages == 0
                ? 0
                : Double(observations.reduce(0) { $0 + $1.inferenceCount }) / Double(pages),
            pageCount: pages
        )
    }

    private static func recall(
        expected: [CGRect],
        predicted: [CGRect],
        threshold: CGFloat
    ) -> Double? {
        guard !expected.isEmpty else { return nil }
        var available = Set(predicted.indices)
        var matched = 0
        for target in expected {
            let best = available
                .map { index in
                    (index, MangaPageCoordinateSpace.intersectionOverUnion(target, predicted[index]))
                }
                .max { lhs, rhs in lhs.1 < rhs.1 }
            guard let best, best.1 >= threshold else { continue }
            available.remove(best.0)
            matched += 1
        }
        return Double(matched) / Double(expected.count)
    }
}

nonisolated struct MangaVisionRegressionGate: Sendable, Equatable {
    let minimumPanelRecall: Double
    let minimumTextRecall: Double
    let minimumBalloonRecall: Double
    let minimumOCRFinalRecall: Double
    let maximumFallbackRate: Double
    let maximumInferenceCountPerPage: Double

    static let release = MangaVisionRegressionGate(
        minimumPanelRecall: 0.80,
        minimumTextRecall: 0.75,
        minimumBalloonRecall: 0.70,
        minimumOCRFinalRecall: 0.80,
        maximumFallbackRate: 0.20,
        maximumInferenceCountPerPage: 4.0
    )

    func failures(for metrics: MangaVisionRegressionMetrics) -> [String] {
        var failures: [String] = []
        appendRecallFailure(
            name: "panel-recall",
            actual: metrics.panelRecall,
            minimum: minimumPanelRecall,
            into: &failures
        )
        appendRecallFailure(
            name: "text-recall",
            actual: metrics.textRecall,
            minimum: minimumTextRecall,
            into: &failures
        )
        appendRecallFailure(
            name: "balloon-recall",
            actual: metrics.balloonRecall,
            minimum: minimumBalloonRecall,
            into: &failures
        )
        appendRecallFailure(
            name: "ocr-final-recall",
            actual: metrics.ocrFinalRecall,
            minimum: minimumOCRFinalRecall,
            into: &failures
        )
        if metrics.fallbackRate > maximumFallbackRate {
            failures.append("fallback-rate:\(formatted(metrics.fallbackRate))>\(formatted(maximumFallbackRate))")
        }
        if metrics.inferenceCountPerPage > maximumInferenceCountPerPage {
            failures.append(
                "inference-count-per-page:\(formatted(metrics.inferenceCountPerPage))>\(formatted(maximumInferenceCountPerPage))"
            )
        }
        return failures
    }

    private func appendRecallFailure(
        name: String,
        actual: Double?,
        minimum: Double,
        into failures: inout [String]
    ) {
        // A metric with no verified labels is not silently treated as 100% or 0%.
        // Corpus review status decides whether that metric is eligible for gating.
        guard let actual else { return }
        if actual < minimum {
            failures.append("\(name):\(formatted(actual))<\(formatted(minimum))")
        }
    }

    private func formatted(_ value: Double) -> String {
        String(format: "%.3f", value)
    }
}
