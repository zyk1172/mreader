import UIKit

nonisolated struct OCRPipelineResult: Sendable {
    let rawBlocks: [TextBlock]
    let resolvedBlocks: [TextBlock]
    let lineBlocks: [TextBlock]
    let bubbleBlocks: [TextBlock]
    let rejectedBlocks: [TextBlock]
    /// 本地 OCR 层通过脚本分类得到的页面级语言线索（如 "en" / "ja" / "ko" / "zh"），
    /// 供翻译源语言解析器作为先验，避免把 English 短句误判成其它拉丁语言。
    let detectedLanguage: String?
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
            rejectedBlocks: resolution.rejectedBlocks,
            detectedLanguage: detectedLanguage(in: rawBlocks, isRightToLeft: isRightToLeft)
        )
    }

    /// 与 OCRPreprocessor.recognitionPlan 一致的脚本启发：kana→ja、hangul→ko、
    /// CJK→(RTL?ja:zh)、latin→en。只作为语言线索，不作为最终结论。
    private static func detectedLanguage(in blocks: [TextBlock], isRightToLeft: Bool) -> String? {
        let text = blocks.map(\.text).joined()
        var kana = 0, hangul = 0, cjk = 0, latin = 0
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x3040...0x30FF, 0x31F0...0x31FF: kana += 1
            case 0xAC00...0xD7AF, 0x1100...0x11FF: hangul += 1
            case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF: cjk += 1
            case 0x0041...0x005A, 0x0061...0x007A: latin += 1
            default: break
            }
        }
        if kana > 0 { return "ja" }
        if hangul > 0 { return "ko" }
        if cjk > 0 { return isRightToLeft ? "ja" : "zh" }
        if latin > 0 { return "en" }
        return nil
    }
}
