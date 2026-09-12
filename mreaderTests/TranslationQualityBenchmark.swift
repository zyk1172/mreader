import CoreGraphics
import Foundation

struct TranslationBenchmarkRect: Codable, Equatable, Sendable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    var cgRect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }
}

struct TranslationBenchmarkRegion: Codable, Equatable, Sendable {
    let id: String
    let text: String
    let rect: TranslationBenchmarkRect
    let readingOrder: Int
    let bubbleID: String?
}

struct TranslationBenchmarkPrediction: Equatable, Sendable {
    let id: String
    let text: String
    let rect: CGRect
}

struct TranslationBenchmarkReadingOrderScore: Equatable, Sendable {
    let pairwiseAccuracy: Double
    let coverage: Double

    var combinedScore: Double { pairwiseAccuracy * coverage }
}

struct TranslationBenchmarkRecoveryScore: Equatable, Sendable {
    let retryPrecision: Double
    let recoveryRecall: Double
    let finalCompleteness: Double
}

struct TranslationBenchmarkLayoutObservation: Equatable, Sendable {
    let fontSize: CGFloat
    let minimumReadableFontSize: CGFloat
    let isFullyVisible: Bool
    let escapedAllowedBounds: Bool
}

struct TranslationBenchmarkLayoutScore: Equatable, Sendable {
    let unreadableRate: Double
    let overflowRate: Double
    let escapedBoundsRate: Double
}

struct TranslationBenchmarkPerformanceScore: Equatable, Sendable {
    let p50Milliseconds: Double
    let p95Milliseconds: Double
    let requestCount: Int
    let estimatedCost: Double
}

struct TranslationBenchmarkTermOccurrence: Equatable, Sendable {
    let key: String
    let translatedValue: String
}

struct TranslationQualityBenchmarkManifest: Codable, Equatable, Sendable {
    struct Sample: Codable, Equatable, Sendable {
        enum AnnotationStatus: String, Codable, Sendable {
            case ready
            case pending
        }

        let id: String
        let image: String
        let license: String
        let sourceLanguage: String
        let annotationStatus: AnnotationStatus
        let goldText: String?
        /// Optional page-level gold file for regions, structure and expected page state.
        let goldAnnotation: String?
        let notes: String?

        var hasGoldReference: Bool {
            let hasText = !(goldText ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty
            let hasPageGold = !(goldAnnotation ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty
            return hasText || hasPageGold
        }
    }

    let schemaVersion: Int
    let samples: [Sample]
}

enum TranslationQualityBenchmark {
    static func detectionRecall(
        truth: [TranslationBenchmarkRegion],
        predictions: [TranslationBenchmarkPrediction],
        iouThreshold: Double = 0.50
    ) -> Double {
        guard !truth.isEmpty else { return predictions.isEmpty ? 1 : 0 }
        var unusedPredictionIndexes = Set(predictions.indices)
        var matchedTruthCount = 0

        for expected in truth {
            let best = unusedPredictionIndexes
                .map { index in
                    (index: index, iou: intersectionOverUnion(expected.rect.cgRect, predictions[index].rect))
                }
                .filter { $0.iou >= iouThreshold }
                .max { lhs, rhs in lhs.iou < rhs.iou }
            guard let best else { continue }
            unusedPredictionIndexes.remove(best.index)
            matchedTruthCount += 1
        }

        return Double(matchedTruthCount) / Double(truth.count)
    }

    static func characterErrorRate(
        reference: String,
        hypothesis: String,
        ignoresWhitespace: Bool = true
    ) -> Double {
        let referenceCharacters = Array(normalizedForCER(reference, ignoresWhitespace: ignoresWhitespace))
        let hypothesisCharacters = Array(normalizedForCER(hypothesis, ignoresWhitespace: ignoresWhitespace))
        guard !referenceCharacters.isEmpty else {
            return hypothesisCharacters.isEmpty ? 0 : 1
        }
        let distance = levenshteinDistance(referenceCharacters, hypothesisCharacters)
        return Double(distance) / Double(referenceCharacters.count)
    }

    static func readingOrderScore(
        referenceIDs: [String],
        predictedIDs: [String]
    ) -> TranslationBenchmarkReadingOrderScore {
        guard !referenceIDs.isEmpty else {
            return TranslationBenchmarkReadingOrderScore(
                pairwiseAccuracy: predictedIDs.isEmpty ? 1 : 0,
                coverage: predictedIDs.isEmpty ? 1 : 0
            )
        }
        let uniqueReference = unique(referenceIDs)
        let referenceSet = Set(uniqueReference)
        let uniquePrediction = unique(predictedIDs).filter { referenceSet.contains($0) }
        let coverage = Double(uniquePrediction.count) / Double(uniqueReference.count)
        guard uniquePrediction.count >= 2 else {
            return TranslationBenchmarkReadingOrderScore(
                pairwiseAccuracy: uniquePrediction.count == uniqueReference.count ? 1 : 0,
                coverage: coverage
            )
        }

        let predictedPosition = Dictionary(uniqueKeysWithValues: uniquePrediction.enumerated().map { ($0.element, $0.offset) })
        var comparablePairs = 0
        var correctPairs = 0
        for leftIndex in uniqueReference.indices {
            for rightIndex in uniqueReference.indices where rightIndex > leftIndex {
                let leftID = uniqueReference[leftIndex]
                let rightID = uniqueReference[rightIndex]
                guard let leftPosition = predictedPosition[leftID],
                      let rightPosition = predictedPosition[rightID] else { continue }
                comparablePairs += 1
                if leftPosition < rightPosition { correctPairs += 1 }
            }
        }
        let pairwiseAccuracy = comparablePairs == 0
            ? 0
            : Double(correctPairs) / Double(comparablePairs)
        return TranslationBenchmarkReadingOrderScore(
            pairwiseAccuracy: pairwiseAccuracy,
            coverage: coverage
        )
    }

    /// Drift is measured per semantic key without assuming a single reference
    /// translation. The dominant normalized variant is treated as the stable
    /// form; every other variant counts as drift.
    static func terminologyDriftRate(
        occurrences: [TranslationBenchmarkTermOccurrence]
    ) -> Double {
        guard !occurrences.isEmpty else { return 0 }
        let grouped = Dictionary(grouping: occurrences, by: \.key)
        var drifted = 0
        var total = 0
        for values in grouped.values {
            let normalized = values.map { normalizeTerm($0.translatedValue) }.filter { !$0.isEmpty }
            guard !normalized.isEmpty else { continue }
            let counts = Dictionary(grouping: normalized, by: { $0 }).mapValues(\.count)
            let dominantCount = counts.values.max() ?? 0
            drifted += normalized.count - dominantCount
            total += normalized.count
        }
        guard total > 0 else { return 0 }
        return Double(drifted) / Double(total)
    }

    static func partialRecoveryScore(
        totalItemCount: Int,
        expectedMissingIDs: Set<String>,
        retriedIDs: Set<String>,
        recoveredIDs: Set<String>
    ) -> TranslationBenchmarkRecoveryScore {
        let retriedExpected = retriedIDs.intersection(expectedMissingIDs).count
        let retryPrecision = retriedIDs.isEmpty
            ? (expectedMissingIDs.isEmpty ? 1 : 0)
            : Double(retriedExpected) / Double(retriedIDs.count)
        let recoveredExpected = recoveredIDs.intersection(expectedMissingIDs).count
        let recoveryRecall = expectedMissingIDs.isEmpty
            ? 1
            : Double(recoveredExpected) / Double(expectedMissingIDs.count)
        let initialCompleted = max(totalItemCount - expectedMissingIDs.count, 0)
        let finalCompleted = min(initialCompleted + recoveredExpected, max(totalItemCount, 0))
        let finalCompleteness = totalItemCount <= 0
            ? 1
            : Double(finalCompleted) / Double(totalItemCount)
        return TranslationBenchmarkRecoveryScore(
            retryPrecision: retryPrecision,
            recoveryRecall: recoveryRecall,
            finalCompleteness: finalCompleteness
        )
    }

    static func successfulTranslationsRemainStable(
        before: [String: String],
        after: [String: String],
        excludingRecoveredIDs: Set<String>
    ) -> Bool {
        before.allSatisfy { id, translation in
            excludingRecoveredIDs.contains(id) || after[id] == translation
        }
    }

    static func layoutScore(
        observations: [TranslationBenchmarkLayoutObservation]
    ) -> TranslationBenchmarkLayoutScore {
        guard !observations.isEmpty else {
            return TranslationBenchmarkLayoutScore(
                unreadableRate: 0,
                overflowRate: 0,
                escapedBoundsRate: 0
            )
        }
        let count = Double(observations.count)
        let unreadable = observations.filter { $0.fontSize + 0.001 < $0.minimumReadableFontSize }.count
        let overflow = observations.filter { !$0.isFullyVisible }.count
        let escaped = observations.filter(\.escapedAllowedBounds).count
        return TranslationBenchmarkLayoutScore(
            unreadableRate: Double(unreadable) / count,
            overflowRate: Double(overflow) / count,
            escapedBoundsRate: Double(escaped) / count
        )
    }

    static func performanceScore(
        latenciesMilliseconds: [Double],
        requestCount: Int,
        estimatedCost: Double
    ) -> TranslationBenchmarkPerformanceScore {
        TranslationBenchmarkPerformanceScore(
            p50Milliseconds: percentile(latenciesMilliseconds, percentile: 0.50),
            p95Milliseconds: percentile(latenciesMilliseconds, percentile: 0.95),
            requestCount: max(requestCount, 0),
            estimatedCost: max(estimatedCost, 0)
        )
    }

    static func intersectionOverUnion(_ lhs: CGRect, _ rhs: CGRect) -> Double {
        let left = lhs.standardized
        let right = rhs.standardized
        guard left.width > 0, left.height > 0, right.width > 0, right.height > 0 else { return 0 }
        let intersection = left.intersection(right)
        guard !intersection.isNull, intersection.width > 0, intersection.height > 0 else { return 0 }
        let intersectionArea = intersection.width * intersection.height
        let unionArea = left.width * left.height + right.width * right.height - intersectionArea
        guard unionArea > 0 else { return 0 }
        return Double(intersectionArea / unionArea)
    }

    static func percentile(_ values: [Double], percentile: Double) -> Double {
        let sorted = values.filter(\.isFinite).sorted()
        guard !sorted.isEmpty else { return 0 }
        let clamped = min(max(percentile, 0), 1)
        if clamped == 0 { return sorted[0] }
        let rank = Int(ceil(clamped * Double(sorted.count))) - 1
        return sorted[min(max(rank, 0), sorted.count - 1)]
    }

    private static func normalizedForCER(_ value: String, ignoresWhitespace: Bool) -> String {
        let normalized = value.precomposedStringWithCanonicalMapping
        guard ignoresWhitespace else { return normalized }
        return normalized.unicodeScalars
            .filter { !CharacterSet.whitespacesAndNewlines.contains($0) }
            .map(String.init)
            .joined()
    }

    private static func normalizeTerm(_ value: String) -> String {
        value
            .precomposedStringWithCanonicalMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.filter { seen.insert($0).inserted }
    }

    private static func levenshteinDistance<T: Equatable>(_ lhs: [T], _ rhs: [T]) -> Int {
        if lhs.isEmpty { return rhs.count }
        if rhs.isEmpty { return lhs.count }
        var previous = Array(0...rhs.count)
        for (leftIndex, leftValue) in lhs.enumerated() {
            var current = Array(repeating: 0, count: rhs.count + 1)
            current[0] = leftIndex + 1
            for (rightIndex, rightValue) in rhs.enumerated() {
                let insertion = current[rightIndex] + 1
                let deletion = previous[rightIndex + 1] + 1
                let substitution = previous[rightIndex] + (leftValue == rightValue ? 0 : 1)
                current[rightIndex + 1] = min(insertion, deletion, substitution)
            }
            previous = current
        }
        return previous[rhs.count]
    }
}
