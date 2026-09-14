import CoreGraphics
import Foundation

nonisolated enum MangaVisionOCROrdering {
    static func orderedBlocks(
        _ blocks: [TextBlock],
        analysis: MangaPageAnalysis,
        isRightToLeft: Bool
    ) -> [TextBlock] {
        guard blocks.count > 1, !analysis.panels.isEmpty else {
            return AITranslator.sortedTextBlocks(blocks, isRightToLeft: isRightToLeft)
        }
        let semantic = MangaSemanticAnalyzer.makeSemanticPage(
            from: analysis,
            isRightToLeft: isRightToLeft
        )
        let panelRank = Dictionary(uniqueKeysWithValues: semantic.panels.enumerated().map {
            ($0.element.panel.id, $0.offset)
        })

        struct RankedBlock {
            let block: TextBlock
            let panelIndex: Int
        }
        let ranked = blocks.map { block -> RankedBlock in
            let panel = MangaSemanticAnalyzer.owningPanel(
                for: block.boundingBox,
                panels: semantic.panels.map(\.panel)
            )
            return RankedBlock(
                block: block,
                panelIndex: panel.flatMap { panelRank[$0.id] } ?? Int.max
            )
        }
        return ranked.sorted { lhs, rhs in
            if lhs.panelIndex != rhs.panelIndex {
                return lhs.panelIndex < rhs.panelIndex
            }
            let a = lhs.block.boundingBox
            let b = rhs.block.boundingBox
            let rowTolerance = max(min(a.height, b.height) * 0.45, 0.012)
            if abs(a.midY - b.midY) > rowTolerance {
                return a.midY < b.midY
            }
            if abs(a.midX - b.midX) > 0.004 {
                return isRightToLeft ? a.midX > b.midX : a.midX < b.midX
            }
            return a.minY < b.minY
        }.map(\.block)
    }

    static func applyingReadingOrder(
        to result: OCRPipelineResult,
        analysis: MangaPageAnalysis,
        isRightToLeft: Bool
    ) -> OCRPipelineResult {
        OCRPipelineResult(
            rawBlocks: result.rawBlocks,
            resolvedBlocks: orderedBlocks(
                result.resolvedBlocks,
                analysis: analysis,
                isRightToLeft: isRightToLeft
            ),
            lineBlocks: orderedBlocks(
                result.lineBlocks,
                analysis: analysis,
                isRightToLeft: isRightToLeft
            ),
            bubbleBlocks: orderedBlocks(
                result.bubbleBlocks,
                analysis: analysis,
                isRightToLeft: isRightToLeft
            ),
            rejectedBlocks: result.rejectedBlocks,
            detectedLanguage: result.detectedLanguage,
            quality: result.quality
        )
    }
}
