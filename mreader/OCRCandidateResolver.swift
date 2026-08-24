import CoreGraphics
import Foundation

nonisolated struct OCRCandidateResolution: Sendable {
    let resolvedBlocks: [TextBlock]
    let rejectedBlocks: [TextBlock]
}

nonisolated enum OCRCandidateResolver {
    static func resolve(
        _ candidates: [TextBlock],
        isRightToLeft: Bool
    ) -> OCRCandidateResolution {
        let usable = candidates.filter {
            !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard usable.count > 1 else {
            return OCRCandidateResolution(resolvedBlocks: usable, rejectedBlocks: [])
        }

        var geometryGroups: [[TextBlock]] = []
        for candidate in usable {
            if let index = geometryGroups.firstIndex(where: { group in
                // Complete-link geometry is deliberate here. A candidate must
                // agree with every member already in the group; matching any
                // member would let A~B~C transitively swallow two adjacent
                // dialogue regions.
                group.allSatisfy { representsSameObservation($0, candidate) }
            }) {
                geometryGroups[index].append(candidate)
            } else {
                geometryGroups.append([candidate])
            }
        }

        var resolved: [TextBlock] = []
        var rejected: [TextBlock] = []
        for group in geometryGroups {
            guard group.count > 1 else {
                resolved.append(contentsOf: group)
                continue
            }

            var textGroups: [[TextBlock]] = []
            for candidate in group {
                if let index = textGroups.firstIndex(where: { textGroup in
                    textGroup.contains(where: {
                        normalizedText($0.text) == normalizedText(candidate.text)
                    })
                }) {
                    textGroups[index].append(candidate)
                } else {
                    textGroups.append([candidate])
                }
            }

            let winningGroup = textGroups.max { lhs, rhs in
                consensusScore(lhs) < consensusScore(rhs)
            } ?? group
            let representative = winningGroup.max { lhs, rhs in
                candidateScore(lhs) < candidateScore(rhs)
            } ?? winningGroup[0]
            let inheritedLayoutRole: TranslationLayoutRole = winningGroup.contains {
                $0.layoutRole == .standalone
            } ? .standalone : representative.layoutRole
            let inheritedColor = winningGroup.compactMap(\.textColorHex).first
                ?? group.compactMap(\.textColorHex).first
            let winningScales = winningGroup.map(\.estimatedFontScale).sorted()
            let inheritedScale = winningScales[winningScales.count / 2]
            let inheritedOrientation = winningGroup.filter { $0.textOrientation == .vertical }.count
                > winningGroup.count / 2
                ? TextOrientation.vertical
                : TextOrientation.horizontal
            let inheritedBubbleGeometry = validatedBubbleGeometry(
                for: representative.boundingBox,
                in: winningGroup
            )
            resolved.append(TextBlock(
                id: representative.id,
                text: representative.text,
                boundingBox: representative.boundingBox,
                translation: representative.translation,
                confidence: representative.confidence,
                ocrSource: Array(Set(winningGroup.map(\.ocrSource))).sorted().joined(separator: "+"),
                isFiltered: representative.isFiltered,
                filterReason: representative.filterReason,
                estimatedFontScale: inheritedScale,
                textColorHex: inheritedColor,
                bubbleBox: inheritedBubbleGeometry?.box,
                polygon: representative.polygon,
                bubblePolygon: inheritedBubbleGeometry?.polygon ?? [],
                translationLines: representative.translationLines,
                textOrientation: inheritedOrientation,
                layoutRole: inheritedLayoutRole
            ))
            rejected.append(contentsOf: group.filter { $0.id != representative.id })
        }

        return OCRCandidateResolution(
            resolvedBlocks: AITranslator.sortedTextBlocks(resolved, isRightToLeft: isRightToLeft),
            rejectedBlocks: rejected
        )
    }

    static func colorsAreCompatible(
        _ lhs: String?,
        _ rhs: String?,
        maximumDistance: Double = 42
    ) -> Bool {
        guard let lhs = rgbComponents(lhs), let rhs = rgbComponents(rhs) else {
            return true
        }
        let red = lhs.red - rhs.red
        let green = lhs.green - rhs.green
        let blue = lhs.blue - rhs.blue
        return sqrt(red * red + green * green + blue * blue) <= maximumDistance
    }

    nonisolated static func representsSameObservationForDiagnostics(
        _ lhs: TextBlock,
        _ rhs: TextBlock
    ) -> Bool {
        representsSameObservation(lhs, rhs)
    }

    nonisolated static func validatedBubbleGeometry(
        for textRect: CGRect,
        candidates: [TextBlock]
    ) -> (box: CGRect, polygon: [CGPoint])? {
        validatedBubbleGeometry(for: textRect, in: candidates)
    }

    private static func validatedBubbleGeometry(
        for textRect: CGRect,
        in candidates: [TextBlock]
    ) -> (box: CGRect, polygon: [CGPoint])? {
        let textArea = area(textRect)
        guard textArea > 0 else { return nil }
        let toleranceX = max(0.004, textRect.width * 0.10)
        let toleranceY = max(0.004, textRect.height * 0.10)
        return candidates.compactMap { candidate -> (box: CGRect, polygon: [CGPoint])? in
            guard let bubble = candidate.bubbleBox,
                  bubble.width > 0,
                  bubble.height > 0,
                  bubble.minX >= 0,
                  bubble.minY >= 0,
                  bubble.maxX <= 1.02,
                  bubble.maxY <= 1.02,
                  bubble.insetBy(dx: -toleranceX, dy: -toleranceY).contains(textRect),
                  area(bubble) <= 0.55,
                  area(bubble) / textArea <= 600 else {
                return nil
            }
            return (bubble, candidate.bubblePolygon)
        }
        .min { lhs, rhs in area(lhs.box) < area(rhs.box) }
    }

    private static func representsSameObservation(_ lhs: TextBlock, _ rhs: TextBlock) -> Bool {
        guard lhs.textOrientation == rhs.textOrientation else { return false }

        let lhsArea = area(lhs.boundingBox)
        let rhsArea = area(rhs.boundingBox)
        guard lhsArea > 0, rhsArea > 0 else { return false }

        let iou = intersectionOverUnion(lhs.boundingBox, rhs.boundingBox)
        let sizeRatio = max(lhsArea, rhsArea) / max(min(lhsArea, rhsArea), 0.000_001)
        guard iou >= 0.55, sizeRatio <= 2.0 else { return false }

        let centerDistance = hypot(
            lhs.boundingBox.midX - rhs.boundingBox.midX,
            lhs.boundingBox.midY - rhs.boundingBox.midY
        )
        let largestDimension = max(
            max(lhs.boundingBox.width, lhs.boundingBox.height),
            max(rhs.boundingBox.width, rhs.boundingBox.height)
        )
        let centerTolerance = max(largestDimension * 0.60, 0.012)
        guard centerDistance <= centerTolerance else { return false }

        let lhsAspect = max(lhs.boundingBox.width, lhs.boundingBox.height)
            / max(min(lhs.boundingBox.width, lhs.boundingBox.height), 0.000_001)
        let rhsAspect = max(rhs.boundingBox.width, rhs.boundingBox.height)
            / max(min(rhs.boundingBox.width, rhs.boundingBox.height), 0.000_001)
        let aspectRatio = max(lhsAspect, rhsAspect) / max(min(lhsAspect, rhsAspect), 0.000_001)
        return aspectRatio <= 1.75
    }

    private static func consensusScore(_ group: [TextBlock]) -> Double {
        // A preprocessing variant is not an independent OCR engine. Count at
        // most one vote per source family and weight recovery sources below
        // the original Vision pass so inverted hallucinations cannot win by
        // appearing in several derived images.
        let bestByFamily = group.reduce(into: [String: TextBlock]()) { result, block in
            let family = sourceFamily(block.ocrSource)
            if let existing = result[family], candidateScore(existing) >= candidateScore(block) {
                return
            }
            result[family] = block
        }
        let bestCandidate = bestByFamily.values.max {
            consensusCandidateScore($0) < consensusCandidateScore($1)
        } ?? group[0]
        let corroborationBonus = min(
            Double(max(bestByFamily.count - 1, 0)) * 0.08,
            0.16
        )
        return consensusCandidateScore(bestCandidate) + corroborationBonus
    }

    private static func consensusCandidateScore(_ block: TextBlock) -> Double {
        let recoveryPenalty: Double
        switch sourceFamily(block.ocrSource) {
        case "enhanced":
            // Enhanced Vision is useful recovery evidence, but a higher raw
            // confidence should still beat a weak original pass.
            recoveryPenalty = 0.05
        case "inverted":
            recoveryPenalty = 0.55
        case "tesseract":
            recoveryPenalty = 0.25
        case "ja-reference":
            recoveryPenalty = 0.15
        default:
            recoveryPenalty = 0
        }
        return block.confidence - recoveryPenalty
    }

    private static func candidateScore(_ block: TextBlock) -> Double {
        var score = block.confidence * sourceWeight(for: sourceFamily(block.ocrSource))
        let text = block.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.contains("�") { score -= 0.5 }
        let usefulCount = text.unicodeScalars.filter {
            CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0)
        }.count
        let symbolCount = max(text.unicodeScalars.count - usefulCount, 0)
        if !text.isEmpty {
            score -= Double(symbolCount) / Double(text.unicodeScalars.count) * 0.15
        }
        return score
    }

    private static func sourceFamily(_ source: String) -> String {
        let normalized = source.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.contains("+") { return "merged" }
        if normalized.hasPrefix("original:") || normalized == "original" { return "original" }
        if normalized.hasPrefix("enhanced:") || normalized == "enhanced" { return "enhanced" }
        if normalized.hasPrefix("inverted:") || normalized == "inverted" { return "inverted" }
        if normalized.hasPrefix("tesseract:") || normalized.contains("tesseract") { return "tesseract" }
        if normalized.hasPrefix("ja-reference:") || normalized == "ja-reference" {
            return "ja-reference"
        }
        if normalized.hasPrefix("vision") || normalized.hasPrefix("visual-") {
            return "vision"
        }
        return normalized.split(separator: ":", maxSplits: 1).first.map(String.init) ?? normalized
    }

    private static func sourceWeight(for family: String) -> Double {
        switch family {
        case "original", "vision", "merged": return 1.0
        case "enhanced": return 0.80
        case "tesseract": return 0.65
        case "ja-reference": return 0.75
        case "inverted": return 0.35
        default: return 0.70
        }
    }

    private static func intersectionOverUnion(_ lhs: CGRect, _ rhs: CGRect) -> Double {
        let intersection = lhs.intersection(rhs)
        let intersectionArea = intersection.isNull ? 0 : area(intersection)
        let unionArea = area(lhs) + area(rhs) - intersectionArea
        guard unionArea > 0 else { return 0 }
        return Double(intersectionArea / unionArea)
    }

    private static func normalizedText(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)
            .replacingOccurrences(of: "[\\p{P}\\p{S}]", with: "", options: .regularExpression)
    }

    private static func area(_ rect: CGRect) -> CGFloat {
        max(rect.width, 0) * max(rect.height, 0)
    }

    private static func rgbComponents(_ hex: String?) -> (red: Double, green: Double, blue: Double)? {
        guard var value = hex?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        if value.hasPrefix("#") { value.removeFirst() }
        guard value.count == 6, let number = Int(value, radix: 16) else { return nil }
        return (
            Double((number >> 16) & 0xFF),
            Double((number >> 8) & 0xFF),
            Double(number & 0xFF)
        )
    }
}
