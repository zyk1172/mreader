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
                group.contains(where: { representsSameObservation($0, candidate) })
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
            resolved.append(TextBlock(
                id: representative.id,
                text: representative.text,
                boundingBox: representative.boundingBox,
                translation: representative.translation,
                confidence: representative.confidence,
                ocrSource: Array(Set(winningGroup.map(\.ocrSource))).sorted().joined(separator: "+"),
                isFiltered: representative.isFiltered,
                filterReason: representative.filterReason,
                estimatedFontScale: representative.estimatedFontScale,
                textColorHex: inheritedColor,
                polygon: representative.polygon,
                translationLines: representative.translationLines,
                textOrientation: representative.textOrientation,
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

    private static func representsSameObservation(_ lhs: TextBlock, _ rhs: TextBlock) -> Bool {
        let intersection = lhs.boundingBox.intersection(rhs.boundingBox)
        let intersectionArea = intersection.isNull ? 0 : area(intersection)
        let smallerArea = min(area(lhs.boundingBox), area(rhs.boundingBox))
        if intersectionArea / max(smallerArea, 0.000_001) >= 0.45 {
            return true
        }

        let edgeTolerance = max(
            min(lhs.boundingBox.height, rhs.boundingBox.height) * 0.22,
            0.003
        )
        return abs(lhs.boundingBox.minX - rhs.boundingBox.minX) <= edgeTolerance
            && abs(lhs.boundingBox.minY - rhs.boundingBox.minY) <= edgeTolerance
            && abs(lhs.boundingBox.width - rhs.boundingBox.width) <= edgeTolerance * 1.5
            && abs(lhs.boundingBox.height - rhs.boundingBox.height) <= edgeTolerance
    }

    private static func consensusScore(_ group: [TextBlock]) -> Double {
        let agreementBonus = Double(group.count) * 1.6
        let confidence = group.reduce(0) { $0 + $1.confidence } / Double(group.count)
        let sources = Set(group.map(\.ocrSource)).count
        return agreementBonus + confidence + Double(sources) * 0.25
    }

    private static func candidateScore(_ block: TextBlock) -> Double {
        var score = block.confidence
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
