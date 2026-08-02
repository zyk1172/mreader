import UIKit

nonisolated struct OCRPipelineResult: Sendable {
    let rawBlocks: [TextBlock]
    let resolvedBlocks: [TextBlock]
    let lineBlocks: [TextBlock]
    let bubbleBlocks: [TextBlock]
    let rejectedBlocks: [TextBlock]
}

nonisolated enum MangaOCRPipeline {
    static func recognize(
        in image: UIImage,
        options: OCRPreprocessor.Options
    ) async throws -> OCRPipelineResult {
        let rawBlocks = try await OCRPreprocessor.recognizeCandidates(in: image, options: options)
        return resolveForDiagnostics(rawBlocks, isRightToLeft: options.isRightToLeft)
    }

    static func resolveForDiagnostics(
        _ rawBlocks: [TextBlock],
        isRightToLeft: Bool
    ) -> OCRPipelineResult {
        let resolution = OCRCandidateResolver.resolve(rawBlocks, isRightToLeft: isRightToLeft)
        let segmentation = MangaTextSegmenter.segment(
            resolution.resolvedBlocks,
            isRightToLeft: isRightToLeft
        )
        return OCRPipelineResult(
            rawBlocks: rawBlocks,
            resolvedBlocks: resolution.resolvedBlocks,
            lineBlocks: segmentation.lines,
            bubbleBlocks: segmentation.bubbles,
            rejectedBlocks: resolution.rejectedBlocks
        )
    }
}
