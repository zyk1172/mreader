import Foundation

struct TranslationBenchmarkGroupingScore: Equatable, Sendable {
    let sameBubbleRecall: Double
    let crossBubbleFalseMergeRate: Double

    var combinedScore: Double {
        (sameBubbleRecall + (1 - crossBubbleFalseMergeRate)) / 2
    }
}

struct TranslationBenchmarkHumanReviewObservation: Equatable, Sendable {
    let fidelityPassed: Bool
    let consistencyPassed: Bool
    /// Bilingual blind-review rating. Values outside 1...5 are ignored rather
    /// than silently clamped into a valid score.
    let naturalnessRating: Int?
}

struct TranslationBenchmarkHumanReviewScore: Equatable, Sendable {
    let fidelityPassRate: Double
    let consistencyPassRate: Double
    let meanNaturalnessRating: Double?
    let reviewCount: Int
    let ratedNaturalnessCount: Int
}

enum TranslationBenchmarkPageState: String, Codable, Equatable, Sendable {
    case completed
    case partial
    case noText
    case failed
}

struct TranslationBenchmarkCompletenessObservation: Equatable, Sendable {
    let expected: TranslationBenchmarkPageState
    let actual: TranslationBenchmarkPageState
}

struct TranslationBenchmarkCompletenessScore: Equatable, Sendable {
    let exactStateAccuracy: Double
    let noTextFalsePositiveRate: Double
}

extension TranslationQualityBenchmark {
    static func groupingScore(
        truth: [TranslationBenchmarkRegion],
        predictedGroups: [[String]]
    ) -> TranslationBenchmarkGroupingScore {
        let uniqueTruth = Dictionary(
            truth.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let orderedTruth = uniqueTruth.values.sorted { lhs, rhs in
            if lhs.readingOrder == rhs.readingOrder { return lhs.id < rhs.id }
            return lhs.readingOrder < rhs.readingOrder
        }
        guard orderedTruth.count >= 2 else {
            return TranslationBenchmarkGroupingScore(
                sameBubbleRecall: 1,
                crossBubbleFalseMergeRate: 0
            )
        }

        var predictedMembership: [String: Set<Int>] = [:]
        for (groupIndex, group) in predictedGroups.enumerated() {
            for id in Set(group) where uniqueTruth[id] != nil {
                predictedMembership[id, default: []].insert(groupIndex)
            }
        }

        var sameBubblePairCount = 0
        var correctlyMergedSameBubblePairs = 0
        var crossBubblePairCount = 0
        var incorrectlyMergedCrossBubblePairs = 0

        for leftIndex in orderedTruth.indices {
            for rightIndex in orderedTruth.indices where rightIndex > leftIndex {
                let left = orderedTruth[leftIndex]
                let right = orderedTruth[rightIndex]
                let truthSameGroup = benchmarkGroupKey(for: left) == benchmarkGroupKey(for: right)
                let predictedSameGroup = !(predictedMembership[left.id] ?? [])
                    .intersection(predictedMembership[right.id] ?? [])
                    .isEmpty

                if truthSameGroup {
                    sameBubblePairCount += 1
                    if predictedSameGroup { correctlyMergedSameBubblePairs += 1 }
                } else {
                    crossBubblePairCount += 1
                    if predictedSameGroup { incorrectlyMergedCrossBubblePairs += 1 }
                }
            }
        }

        let sameBubbleRecall = sameBubblePairCount == 0
            ? 1
            : Double(correctlyMergedSameBubblePairs) / Double(sameBubblePairCount)
        let crossBubbleFalseMergeRate = crossBubblePairCount == 0
            ? 0
            : Double(incorrectlyMergedCrossBubblePairs) / Double(crossBubblePairCount)
        return TranslationBenchmarkGroupingScore(
            sameBubbleRecall: sameBubbleRecall,
            crossBubbleFalseMergeRate: crossBubbleFalseMergeRate
        )
    }

    static func humanReviewScore(
        observations: [TranslationBenchmarkHumanReviewObservation]
    ) -> TranslationBenchmarkHumanReviewScore {
        guard !observations.isEmpty else {
            return TranslationBenchmarkHumanReviewScore(
                fidelityPassRate: 0,
                consistencyPassRate: 0,
                meanNaturalnessRating: nil,
                reviewCount: 0,
                ratedNaturalnessCount: 0
            )
        }
        let reviewCount = observations.count
        let fidelityPasses = observations.filter(\.fidelityPassed).count
        let consistencyPasses = observations.filter(\.consistencyPassed).count
        let ratings = observations.compactMap { observation -> Int? in
            guard let rating = observation.naturalnessRating,
                  (1...5).contains(rating) else { return nil }
            return rating
        }
        let meanNaturalness = ratings.isEmpty
            ? nil
            : Double(ratings.reduce(0, +)) / Double(ratings.count)
        return TranslationBenchmarkHumanReviewScore(
            fidelityPassRate: Double(fidelityPasses) / Double(reviewCount),
            consistencyPassRate: Double(consistencyPasses) / Double(reviewCount),
            meanNaturalnessRating: meanNaturalness,
            reviewCount: reviewCount,
            ratedNaturalnessCount: ratings.count
        )
    }

    static func completenessScore(
        observations: [TranslationBenchmarkCompletenessObservation]
    ) -> TranslationBenchmarkCompletenessScore {
        guard !observations.isEmpty else {
            return TranslationBenchmarkCompletenessScore(
                exactStateAccuracy: 1,
                noTextFalsePositiveRate: 0
            )
        }
        let exact = observations.filter { $0.expected == $0.actual }.count
        let pagesThatContainOrFailedToResolveText = observations.filter { $0.expected != .noText }
        let falseNoText = pagesThatContainOrFailedToResolveText.filter { $0.actual == .noText }.count
        let falsePositiveRate = pagesThatContainOrFailedToResolveText.isEmpty
            ? 0
            : Double(falseNoText) / Double(pagesThatContainOrFailedToResolveText.count)
        return TranslationBenchmarkCompletenessScore(
            exactStateAccuracy: Double(exact) / Double(observations.count),
            noTextFalsePositiveRate: falsePositiveRate
        )
    }

    private static func benchmarkGroupKey(for region: TranslationBenchmarkRegion) -> String {
        if let bubbleID = region.bubbleID,
           !bubbleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "bubble:\(bubbleID)"
        }
        // Unframed narration/SFX must not become one synthetic bubble merely
        // because both have nil bubble IDs.
        return "standalone:\(region.id)"
    }
}
