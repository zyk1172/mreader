import Foundation

struct TranslationGoldReviewReceipt: Codable, Equatable, Sendable {
    enum Method: String, Codable, Sendable {
        case visualHumanReview
    }

    let reviewer: String
    let reviewedAt: String
    let method: Method
    let sourceImageSHA1: String

    var isValid: Bool {
        let trimmedReviewer = reviewer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedReviewer.isEmpty,
              ISO8601DateFormatter().date(from: reviewedAt) != nil else {
            return false
        }
        let normalizedSHA1 = sourceImageSHA1.lowercased()
        guard normalizedSHA1.count == 40 else { return false }
        return normalizedSHA1.unicodeScalars.allSatisfy { scalar in
            (48...57).contains(Int(scalar.value)) || (97...102).contains(Int(scalar.value))
        }
    }
}

enum TranslationGoldReviewIssue: String, Equatable, Sendable {
    case duplicateRegionID
    case emptyRegionID
    case emptyRegionText
    case invalidRegionRect
    case invalidReadingOrder
    case emptyBubbleID
    case unknownReferenceTranslationRegion
    case emptyReferenceTranslation
    case invalidNoTextPayload
    case missingTextRegions
    case unresolvedPageState
    case candidateHasReviewReceipt
    case missingReviewReceipt
    case invalidReviewReceipt
    case sourceImageMismatch
}

enum TranslationGoldReviewValidator {
    static func structuralIssues(
        for gold: TranslationBenchmarkPageGold
    ) -> Set<TranslationGoldReviewIssue> {
        var issues: Set<TranslationGoldReviewIssue> = []
        let regionIDs = gold.regions.map(\.id)
        let trimmedRegionIDs = regionIDs.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

        if trimmedRegionIDs.contains(where: \.isEmpty) {
            issues.insert(.emptyRegionID)
        }
        if Set(regionIDs).count != regionIDs.count {
            issues.insert(.duplicateRegionID)
        }
        if gold.regions.contains(where: { $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            issues.insert(.emptyRegionText)
        }
        if gold.regions.contains(where: { !isValidNormalizedRect($0.rect) }) {
            issues.insert(.invalidRegionRect)
        }

        let readingOrders = gold.regions.map(\.readingOrder).sorted()
        if readingOrders != Array(0..<gold.regions.count) {
            issues.insert(.invalidReadingOrder)
        }
        if gold.regions.contains(where: { region in
            guard let bubbleID = region.bubbleID else { return false }
            return bubbleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) {
            issues.insert(.emptyBubbleID)
        }

        let regionIDSet = Set(regionIDs)
        if !Set(gold.referenceTranslations.keys).isSubset(of: regionIDSet) {
            issues.insert(.unknownReferenceTranslationRegion)
        }
        if gold.referenceTranslations.values.contains(where: {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) {
            issues.insert(.emptyReferenceTranslation)
        }

        switch gold.expectedPageState {
        case .unknown:
            break
        case .noText:
            if !gold.regions.isEmpty || !gold.referenceTranslations.isEmpty {
                issues.insert(.invalidNoTextPayload)
            }
        case .completed, .partial, .failed:
            if gold.regions.isEmpty {
                issues.insert(.missingTextRegions)
            }
        }

        return issues
    }

    static func reportabilityIssues(
        for gold: TranslationBenchmarkPageGold,
        expectedSourceImageSHA1: String? = nil
    ) -> Set<TranslationGoldReviewIssue> {
        var issues = structuralIssues(for: gold)

        if gold.expectedPageState == .unknown {
            issues.insert(.unresolvedPageState)
        }

        switch gold.verificationStatus {
        case .candidate:
            if gold.review != nil {
                issues.insert(.candidateHasReviewReceipt)
            }
        case .humanVerified:
            guard let review = gold.review else {
                issues.insert(.missingReviewReceipt)
                return issues
            }
            if !review.isValid {
                issues.insert(.invalidReviewReceipt)
            }
            if let expectedSourceImageSHA1,
               review.sourceImageSHA1.lowercased() != expectedSourceImageSHA1.lowercased() {
                issues.insert(.sourceImageMismatch)
            }
        }

        return issues
    }

    private static func isValidNormalizedRect(_ rect: TranslationBenchmarkRect) -> Bool {
        let values = [rect.x, rect.y, rect.width, rect.height]
        guard values.allSatisfy(\.isFinite), rect.width > 0, rect.height > 0 else {
            return false
        }
        let epsilon = 0.000_001
        return rect.x >= -epsilon
            && rect.y >= -epsilon
            && rect.x + rect.width <= 1 + epsilon
            && rect.y + rect.height <= 1 + epsilon
    }
}

struct TranslationReportableBaselineScore: Equatable, Sendable {
    let detectionRecall: Double
    let meanRegionCER: Double
    let readingOrder: TranslationBenchmarkReadingOrderScore
    let grouping: TranslationBenchmarkGroupingScore
    let matchedRegionCount: Int
    let truthRegionCount: Int
}

enum TranslationGoldScoringError: Error, Equatable {
    case goldNotReportable
}

enum TranslationGoldBaselineScorer {
    static func score(
        gold: TranslationBenchmarkPageGold,
        baseline: TranslationFirstPageBaselineReport,
        expectedSourceImageSHA1: String,
        iouThreshold: Double = 0.50
    ) throws -> TranslationReportableBaselineScore {
        let reportabilityIssues = TranslationGoldReviewValidator.reportabilityIssues(
            for: gold,
            expectedSourceImageSHA1: expectedSourceImageSHA1
        )
        guard gold.verificationStatus == .humanVerified,
              reportabilityIssues.isEmpty else {
            throw TranslationGoldScoringError.goldNotReportable
        }

        let predictions = baseline.lineBlocks.enumerated().map { index, block in
            TranslationBenchmarkPrediction(
                id: "prediction-\(index)",
                text: block.text,
                rect: block.rect.cgRect
            )
        }
        let detectionRecall = TranslationQualityBenchmark.detectionRecall(
            truth: gold.regions,
            predictions: predictions,
            iouThreshold: iouThreshold
        )

        let matches = matchTruthToBaseline(
            truth: gold.regions,
            baselineBlocks: baseline.lineBlocks,
            iouThreshold: iouThreshold
        )
        let cerValues = gold.regions.map { region in
            let hypothesis = matches[region.id].map { baseline.lineBlocks[$0].text } ?? ""
            return TranslationQualityBenchmark.characterErrorRate(
                reference: region.text,
                hypothesis: hypothesis
            )
        }
        let meanCER = cerValues.isEmpty
            ? 0
            : cerValues.reduce(0, +) / Double(cerValues.count)

        let referenceOrder = gold.regions
            .sorted { lhs, rhs in
                if lhs.readingOrder == rhs.readingOrder { return lhs.id < rhs.id }
                return lhs.readingOrder < rhs.readingOrder
            }
            .map(\.id)
        let predictedOrder = matches
            .sorted { $0.value < $1.value }
            .map(\.key)
        let readingOrder = TranslationQualityBenchmark.readingOrderScore(
            referenceIDs: referenceOrder,
            predictedIDs: predictedOrder
        )

        var groups: [String: [String]] = [:]
        for (truthID, baselineIndex) in matches {
            let block = baseline.lineBlocks[baselineIndex]
            let key = block.bubbleRect.map(bubbleKey)
                ?? "standalone-\(baselineIndex)"
            groups[key, default: []].append(truthID)
        }
        let grouping = TranslationQualityBenchmark.groupingScore(
            truth: gold.regions,
            predictedGroups: Array(groups.values)
        )

        return TranslationReportableBaselineScore(
            detectionRecall: detectionRecall,
            meanRegionCER: meanCER,
            readingOrder: readingOrder,
            grouping: grouping,
            matchedRegionCount: matches.count,
            truthRegionCount: gold.regions.count
        )
    }

    private static func matchTruthToBaseline(
        truth: [TranslationBenchmarkRegion],
        baselineBlocks: [TranslationBaselineBlock],
        iouThreshold: Double
    ) -> [String: Int] {
        var unused = Set(baselineBlocks.indices)
        var matches: [String: Int] = [:]
        let orderedTruth = truth.sorted { lhs, rhs in
            if lhs.readingOrder == rhs.readingOrder { return lhs.id < rhs.id }
            return lhs.readingOrder < rhs.readingOrder
        }

        for expected in orderedTruth {
            let best = unused
                .map { index in
                    (
                        index: index,
                        iou: TranslationQualityBenchmark.intersectionOverUnion(
                            expected.rect.cgRect,
                            baselineBlocks[index].rect.cgRect
                        )
                    )
                }
                .filter { $0.iou >= iouThreshold }
                .max { lhs, rhs in lhs.iou < rhs.iou }
            guard let best else { continue }
            unused.remove(best.index)
            matches[expected.id] = best.index
        }
        return matches
    }

    private static func bubbleKey(_ rect: TranslationBenchmarkRect) -> String {
        [rect.x, rect.y, rect.width, rect.height]
            .map { Int(($0 * 10_000).rounded()) }
            .map(String.init)
            .joined(separator: ":")
    }
}
