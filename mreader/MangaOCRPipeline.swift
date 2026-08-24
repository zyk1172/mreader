import UIKit

nonisolated enum OCRDebugStage: String, CaseIterable, Codable, Sendable {
    case raw
    case candidate
    case filtered
    case filteredOut
    case rejected
    case bubble
    case translation

    var localizationKey: String {
        "ocr.debugStage.\(rawValue)"
    }

    var token: String {
        switch self {
        case .raw: return "RAW"
        case .candidate: return "CANDIDATE"
        case .filtered: return "FILTERED"
        case .filteredOut: return "FILTERED_OUT"
        case .rejected: return "REJECTED"
        case .bubble: return "BUBBLE"
        case .translation: return "TRANSLATION"
        }
    }
}

nonisolated struct OCRPageQuality: Sendable, Equatable {
    let averageConfidence: Double
    let usefulCharacterRatio: Double
    let expectedScriptRatio: Double
    let languagePlausibility: Double
    let verticalColumnCount: Int
    let blockCount: Int
    let characterCount: Int
    let charactersPerBlock: Double
    let japaneseScriptRatio: Double
    let kanaCount: Int
    let hanCount: Int
    let latinCount: Int
    let visionKitCharacterCount: Int
    let visionKitDetectedLanguage: String?
    let visionKitCoverage: Double

    var score: Double {
        min(
            1,
            max(
                0,
                averageConfidence * 0.25
                    + usefulCharacterRatio * 0.15
                    + expectedScriptRatio * 0.20
                    + languagePlausibility * 0.18
                    + min(Double(verticalColumnCount) / 4, 1) * 0.05
                    + visionKitCoverage * 0.14
                    + min(charactersPerBlock / 1.5, 1) * 0.08
            )
        )
    }

    var isSuspicious: Bool {
        score < 0.55 || expectedScriptRatio < 0.35 || languagePlausibility < 0.45
    }

    static func make(
        blocks: [TextBlock],
        isRightToLeft: Bool = false,
        sourceLanguagePreference: TranslationSourceLanguage? = nil,
        visionKitReference: AppleOCRReference? = nil
    ) -> Self {
        // Retain the diagnostic API's historical argument for callers and
        // cached test fixtures, but never use paging direction as a language
        // or completeness signal.
        _ = isRightToLeft
        let text = blocks.map(\.text).joined()
        var kana = 0
        var han = 0
        var latin = 0
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x3040...0x30FF, 0x31F0...0x31FF: kana += 1
            case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF: han += 1
            case 0x0041...0x005A, 0x0061...0x007A: latin += 1
            default: break
            }
        }
        let count = max(text.unicodeScalars.count, 1)
        let japaneseScriptRatio = Double(kana + han) / Double(count)
        let verticalColumnCount = JapaneseVerticalOCRService.verticalColumnCount(in: blocks)
        let expectedJapanese = sourceLanguagePreference == .japanese
            || visionKitReference?.detectedLanguage == "ja"
            || ((visionKitReference?.hanCount ?? 0) >= 4 && verticalColumnCount >= 1)
            || (verticalColumnCount >= 1 && han >= 4)
        let expectedScript = expectedJapanese
            ? Double(kana + han) / Double(count)
            : 1 - Double(kana) / Double(count)
        let languagePlausibility: Double
        if sourceLanguagePreference == .japanese || visionKitReference?.detectedLanguage == "ja" {
            languagePlausibility = expectedScript
        } else if sourceLanguagePreference == .english {
            languagePlausibility = Double(latin) / Double(count)
        } else {
            languagePlausibility = max(expectedScript, 0.5)
        }
        let averageConfidence = blocks.isEmpty
            ? 0
            : blocks.reduce(0) { $0 + $1.confidence } / Double(blocks.count)
        let useful = text.unicodeScalars.filter {
            CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0)
        }.count
        let visionKitCoverage: Double
        if let visionKitReference, visionKitReference.characterCount > 0 {
            visionKitCoverage = min(
                Double(text.unicodeScalars.count) / Double(visionKitReference.characterCount),
                1
            )
        } else {
            visionKitCoverage = 1
        }
        return Self(
            averageConfidence: averageConfidence,
            usefulCharacterRatio: Double(useful) / Double(count),
            expectedScriptRatio: expectedScript,
            languagePlausibility: languagePlausibility,
            verticalColumnCount: verticalColumnCount,
            blockCount: blocks.count,
            characterCount: text.unicodeScalars.count,
            charactersPerBlock: blocks.isEmpty
                ? 0
                : Double(text.unicodeScalars.count) / Double(blocks.count),
            japaneseScriptRatio: japaneseScriptRatio,
            kanaCount: kana,
            hanCount: han,
            latinCount: latin,
            visionKitCharacterCount: visionKitReference?.characterCount ?? 0,
            visionKitDetectedLanguage: visionKitReference?.detectedLanguage,
            visionKitCoverage: visionKitCoverage
        )
    }
}

nonisolated struct OCRPipelineResult: Sendable {
    let rawBlocks: [TextBlock]
    let resolvedBlocks: [TextBlock]
    let lineBlocks: [TextBlock]
    let bubbleBlocks: [TextBlock]
    let rejectedBlocks: [TextBlock]
    /// 本地 OCR 层通过脚本分类得到的页面级语言线索（如 "en" / "ja" / "ko" / "zh"），
    /// 供翻译源语言解析器作为先验，避免把 English 短句误判成其它拉丁语言。
    let detectedLanguage: String?
    let quality: OCRPageQuality?

    init(
        rawBlocks: [TextBlock],
        resolvedBlocks: [TextBlock],
        lineBlocks: [TextBlock],
        bubbleBlocks: [TextBlock],
        rejectedBlocks: [TextBlock],
        detectedLanguage: String?,
        quality: OCRPageQuality? = nil
    ) {
        self.rawBlocks = rawBlocks
        self.resolvedBlocks = resolvedBlocks
        self.lineBlocks = lineBlocks
        self.bubbleBlocks = bubbleBlocks
        self.rejectedBlocks = rejectedBlocks
        self.detectedLanguage = detectedLanguage
        self.quality = quality
    }
}

nonisolated enum MangaOCRPipeline {
    static func recognize(
        in image: UIImage,
        options: OCRPreprocessor.Options
    ) async throws -> OCRPipelineResult {
        let candidateResult = try await OCRPreprocessor.recognizeCandidatesWithReference(in: image, options: options)
        let visionBlocks = candidateResult.blocks
        let verticalBlocks = await JapaneseVerticalOCRService.recognizeIfNeeded(
            in: image,
            existingBlocks: visionBlocks,
            options: options,
            visionKitReference: candidateResult.visionKitReference
        )
        let rawBlocks = visionBlocks + verticalBlocks
        return resolveForDiagnostics(
            rawBlocks,
            isRightToLeft: options.isRightToLeft,
            sourceLanguagePreference: options.sourceLanguagePreference,
            visionKitReference: candidateResult.visionKitReference
        )
    }

    static func resolveForDiagnostics(
        _ rawBlocks: [TextBlock],
        isRightToLeft: Bool,
        sourceLanguagePreference: TranslationSourceLanguage? = nil,
        visionKitReference: AppleOCRReference? = nil
    ) -> OCRPipelineResult {
        let resolution = OCRCandidateResolver.resolve(rawBlocks, isRightToLeft: isRightToLeft)
        let segmentation = MangaTextSegmenter.segment(
            resolution.resolvedBlocks,
            isRightToLeft: isRightToLeft
        )
        let result = OCRPipelineResult(
            rawBlocks: rawBlocks,
            resolvedBlocks: resolution.resolvedBlocks,
            lineBlocks: segmentation.lines,
            bubbleBlocks: segmentation.bubbles,
            rejectedBlocks: resolution.rejectedBlocks,
            detectedLanguage: detectedLanguage(
                in: rawBlocks,
                sourceLanguagePreference: sourceLanguagePreference,
                visionKitReference: visionKitReference
            ),
            quality: OCRPageQuality.make(
                blocks: resolution.resolvedBlocks,
                sourceLanguagePreference: sourceLanguagePreference,
                visionKitReference: visionKitReference
            )
        )
        let quality = result.quality
        print("MReader OCR summary raw=\(rawBlocks.count) resolved=\(resolution.resolvedBlocks.count) lines=\(segmentation.lines.count) bubbles=\(segmentation.bubbles.count) chars=\(quality?.characterCount ?? 0) language=\(result.detectedLanguage ?? "unknown") jpScript=\(String(format: "%.2f", quality?.japaneseScriptRatio ?? 0)) kana=\(quality?.kanaCount ?? 0) han=\(quality?.hanCount ?? 0) latin=\(quality?.latinCount ?? 0) visionKitChars=\(quality?.visionKitCharacterCount ?? 0) visionKitCoverage=\(String(format: "%.2f", quality?.visionKitCoverage ?? 1)) charsPerBlock=\(String(format: "%.2f", quality?.charactersPerBlock ?? 0)) coverage=\(String(format: "%.2f", quality?.score ?? 0))")
        return result
    }

    /// 与 OCRPreprocessor.recognitionPlan 一致的脚本启发：kana→ja、hangul→ko、
    /// 竖排 CJK→ja、无竖排 CJK→zh、latin→en。只作为语言线索，不作为最终结论。
    private static func detectedLanguage(
        in blocks: [TextBlock],
        sourceLanguagePreference: TranslationSourceLanguage?,
        visionKitReference: AppleOCRReference?
    ) -> String? {
        if sourceLanguagePreference == .japanese { return "ja" }
        if let referenceLanguage = visionKitReference?.detectedLanguage {
            return referenceLanguage
        }
        if let visionKitReference,
           visionKitReference.hanCount >= 4,
           JapaneseVerticalOCRService.verticalColumnCount(in: blocks) >= 1 {
            return "ja"
        }
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
        if cjk > 0 {
            if JapaneseVerticalOCRService.verticalColumnCount(in: blocks) >= 1 {
                return "ja"
            }
            return "zh"
        }
        if latin > 0 { return "en" }
        return nil
    }
}
