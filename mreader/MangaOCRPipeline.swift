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
    let sourceReliability: Double
    let geometryPlausibility: Double
    let recoverySourceRatio: Double

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
                    + sourceReliability * 0.08
                    + geometryPlausibility * 0.07
            )
        )
    }

    var isSuspicious: Bool {
        score < 0.55
            || expectedScriptRatio < 0.35
            || languagePlausibility < 0.45
            || sourceReliability < 0.55
            || geometryPlausibility < 0.45
            || (recoverySourceRatio >= 0.50 && charactersPerBlock < 2.0)
    }

    static func translationSafeBlocks(
        _ blocks: [TextBlock],
        sourceLanguagePreference: TranslationSourceLanguage? = nil,
        visionKitReference: AppleOCRReference? = nil
    ) -> (accepted: [TextBlock], rejected: [TextBlock]) {
        guard !blocks.isEmpty else { return ([], []) }
        let quality = make(
            blocks: blocks,
            sourceLanguagePreference: sourceLanguagePreference,
            visionKitReference: visionKitReference
        )
        let hardAccepted = blocks.filter(isHardSafeBlock)
        let hardAcceptedIDs = Set(hardAccepted.map(\.id))
        let hardRejected = rejectedBlocks(
            blocks.filter { !hardAcceptedIDs.contains($0.id) },
            reason: "OCR几何/字符/恢复来源不安全"
        )

        // 页面质量只决定是否进入更严格的 block 级检查；几何、可用字符和
        // inverted/Tesseract 的来源置信度不能因为同页其它对白正确而被跳过。
        guard quality.isSuspicious else {
            return (hardAccepted, hardRejected)
        }

        let accepted = hardAccepted.filter { block in
            guard block.confidence >= 0.55,
                  isHardSafeBlock(block) else {
                return false
            }
            let counts = scriptCounts(in: block.text)
            switch sourceLanguagePreference {
            case .japanese:
                guard counts.kana + counts.han > 0 else { return false }
            case .english:
                guard counts.latin > 0 else { return false }
            case .simplifiedChinese, .traditionalChinese:
                guard counts.han > 0, counts.kana == 0, counts.hangul == 0 else { return false }
            case .korean:
                guard counts.hangul > 0 else { return false }
            default:
                break
            }
            return true
        }
        let acceptedIDs = Set(accepted.map(\.id))
        let strictRejected = rejectedBlocks(
            hardAccepted.filter { !acceptedIDs.contains($0.id) },
            reason: "OCR质量可疑"
        )
        return (accepted, hardRejected + strictRejected)
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
        let sourceWeights = blocks.map { sourceWeight(for: $0.ocrSource) }
        let sourceReliability = sourceWeights.isEmpty
            ? 0
            : sourceWeights.reduce(0, +) / Double(sourceWeights.count)
        let averageGeometryPlausibility = blocks.isEmpty
            ? 0
            : blocks
                .map { Self.geometryPlausibility(for: $0) }
                .reduce(0, +) / Double(blocks.count)
        let recoverySourceCount = blocks.filter { block in
            let source = block.ocrSource.lowercased()
            return source.contains("enhanced")
                || source.contains("inverted")
                || source.contains("tesseract")
        }.count
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
            visionKitCoverage: visionKitCoverage,
            sourceReliability: sourceReliability,
            geometryPlausibility: averageGeometryPlausibility,
            recoverySourceRatio: Double(recoverySourceCount) / Double(max(blocks.count, 1))
        )
    }

    private static func containsUsefulCharacter(_ text: String) -> Bool {
        text.unicodeScalars.contains {
            CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0)
        }
    }

    private static func isHardSafeBlock(_ block: TextBlock) -> Bool {
        isGeometryPlausible(block)
            && containsUsefulCharacter(block.text)
            && isSourceSpecificConfidenceSafe(block)
    }

    private static func isSourceSpecificConfidenceSafe(_ block: TextBlock) -> Bool {
        let source = block.ocrSource.lowercased()
        if source.contains("inverted") {
            return block.confidence >= 0.85
        }
        if source.contains("tesseract") {
            return block.confidence >= 0.70
        }
        return true
    }

    private static func rejectedBlocks(_ blocks: [TextBlock], reason: String) -> [TextBlock] {
        blocks.map { block in
            var rejectedBlock = block
            rejectedBlock.isFiltered = true
            rejectedBlock.filterReason = reason
            return rejectedBlock
        }
    }

    private static func isGeometryPlausible(_ block: TextBlock) -> Bool {
        let rect = block.boundingBox
        guard rect.width > 0,
              rect.height > 0,
              rect.minX >= -0.02,
              rect.minY >= -0.02,
              rect.maxX <= 1.02,
              rect.maxY <= 1.02,
              block.estimatedFontScale.isFinite,
              block.estimatedFontScale > 0 else {
            return false
        }
        let minimumAxis = max(min(rect.width, rect.height), 0.000_1)
        return block.estimatedFontScale / Double(minimumAxis) <= 3.0
    }

    private static func geometryPlausibility(for block: TextBlock) -> Double {
        guard isGeometryPlausible(block) else { return 0 }
        let minimumAxis = max(min(block.boundingBox.width, block.boundingBox.height), 0.000_1)
        let ratio = block.estimatedFontScale / Double(minimumAxis)
        return min(1, 1 / max(ratio, 1))
    }

    private static func sourceWeight(for source: String) -> Double {
        let normalized = source.lowercased()
        if normalized.contains("inverted") { return 0.35 }
        if normalized.contains("tesseract") { return 0.65 }
        if normalized.contains("enhanced") { return 0.80 }
        if normalized.contains("original") || normalized.contains("vision") {
            return 1.0
        }
        return 0.70
    }

    private static func scriptCounts(in text: String) -> (
        kana: Int, han: Int, hangul: Int, latin: Int
    ) {
        var counts = (kana: 0, han: 0, hangul: 0, latin: 0)
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x3040...0x30FF, 0x31F0...0x31FF: counts.kana += 1
            case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF: counts.han += 1
            case 0x1100...0x11FF, 0x3130...0x318F, 0xAC00...0xD7AF: counts.hangul += 1
            case 0x0041...0x024F: counts.latin += 1
            default: break
            }
        }
        return counts
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
        let quality = OCRPageQuality.make(
            blocks: resolution.resolvedBlocks,
            sourceLanguagePreference: sourceLanguagePreference,
            visionKitReference: visionKitReference
        )
        let qualityGate = OCRPageQuality.translationSafeBlocks(
            resolution.resolvedBlocks,
            sourceLanguagePreference: sourceLanguagePreference,
            visionKitReference: visionKitReference
        )
        let segmentation = MangaTextSegmenter.segment(
            qualityGate.accepted,
            isRightToLeft: isRightToLeft
        )
        let result = OCRPipelineResult(
            rawBlocks: rawBlocks,
            resolvedBlocks: qualityGate.accepted,
            lineBlocks: segmentation.lines,
            bubbleBlocks: segmentation.bubbles,
            rejectedBlocks: resolution.rejectedBlocks + qualityGate.rejected,
            detectedLanguage: detectedLanguage(
                in: rawBlocks,
                sourceLanguagePreference: sourceLanguagePreference,
                visionKitReference: visionKitReference
            ),
            quality: quality
        )
        print("MReader OCR summary raw=\(rawBlocks.count) resolved=\(qualityGate.accepted.count) lines=\(segmentation.lines.count) bubbles=\(segmentation.bubbles.count) chars=\(quality.characterCount) language=\(result.detectedLanguage ?? "unknown") jpScript=\(String(format: "%.2f", quality.japaneseScriptRatio)) kana=\(quality.kanaCount) han=\(quality.hanCount) latin=\(quality.latinCount) visionKitChars=\(quality.visionKitCharacterCount) visionKitCoverage=\(String(format: "%.2f", quality.visionKitCoverage)) charsPerBlock=\(String(format: "%.2f", quality.charactersPerBlock)) coverage=\(String(format: "%.2f", quality.score)) suspicious=\(quality.isSuspicious) rejectedByQuality=\(qualityGate.rejected.count)")
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
