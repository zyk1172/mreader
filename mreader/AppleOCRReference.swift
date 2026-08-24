import UIKit
import VisionKit

/// Apple Live Text is used as a page-level reference only. It supplies
/// language/completeness evidence, not geometry for translation overlays.
nonisolated struct AppleOCRReference: Equatable, Sendable {
    let transcript: String
    let characterCount: Int
    let kanaCount: Int
    let hanCount: Int
    let hangulCount: Int
    let latinCount: Int
    let detectedLanguage: String?

    var isJapaneseEvidence: Bool {
        kanaCount > 0 || (hanCount >= 4 && detectedLanguage == "ja")
    }
}

nonisolated enum AppleOCRReferenceService {
    private static let capabilityLock = NSLock()
    private static var processCapability: ProcessCapability = .unknown

    private enum ProcessCapability {
        case unknown
        case available
        case unavailable
    }

    static func isSupportedForDiagnostics() -> Bool {
        guard #available(iOS 16.0, *) else { return false }
        return ImageAnalyzer.isSupported
    }

    static func shouldAnalyze(
        options: OCRPreprocessor.Options,
        preliminaryBlocks: [TextBlock],
        image: UIImage? = nil
    ) -> Bool {
        let text = preliminaryBlocks.map(\.text).joined()
        let counts = scriptCounts(in: text)
        let total = max(text.unicodeScalars.count, 1)
        let japaneseCharacters = counts.kana + counts.han
        let japaneseRatio = Double(japaneseCharacters) / Double(total)
        let averageConfidence = preliminaryBlocks.isEmpty
            ? 0
            : preliminaryBlocks.reduce(0) { $0 + $1.confidence } / Double(preliminaryBlocks.count)
        let usefulCharacters = text.unicodeScalars.filter {
            CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0)
        }.count
        let usefulRatio = Double(usefulCharacters) / Double(total)
        let verticalColumns = JapaneseVerticalOCRService.verticalColumnCount(in: preliminaryBlocks)
        // Image-only dark columns are intentionally excluded here. They are
        // useful for diagnostics, but comic artwork is not language evidence.
        let hasVerticalEvidence = verticalColumns >= 2
        let hasJapaneseScript = counts.kana > 0 || counts.han >= 4
        let weakCoverage = preliminaryBlocks.isEmpty
            || averageConfidence < 0.58
            || usefulRatio < 0.42
            || text.unicodeScalars.count < 8
        let implausibleJapanese = japaneseRatio < 0.55
            || (counts.latin > max(japaneseCharacters, 2) && verticalColumns >= 1)
        let clearlyLatin = counts.latin >= 8
            && counts.latin >= max(japaneseCharacters * 2, counts.hangul * 2)
            && averageConfidence >= 0.78
            && usefulRatio >= 0.75
        let clearlyKorean = counts.hangul >= 6
            && counts.hangul > japaneseCharacters
            && averageConfidence >= 0.78
            && usefulRatio >= 0.75

        // Explicit Japanese and maximum accuracy are quality hints, not a
        // reason to pay for Live Text on every good page. Only suspicious
        // local results request the page-level reference.
        if options.sourceLanguagePreference == .japanese {
            return weakCoverage || implausibleJapanese
        }
        if options.recognitionMode == .maximumAccuracy {
            return weakCoverage
                || (hasVerticalEvidence && hasJapaneseScript)
                || (hasJapaneseScript && counts.latin > japaneseCharacters)
        }
        guard options.sourceLanguagePreference == nil
                || options.sourceLanguagePreference == .automatic else {
            return false
        }

        // Auto mode must not send every healthy English or Korean page through
        // Live Text. It is reserved for empty/weak results, ambiguous CJK, or
        // a page whose geometry strongly suggests Japanese vertical writing.
        // This is local Apple analysis, not network IO.
        if weakCoverage { return true }
        if clearlyLatin || clearlyKorean { return false }
        if hasVerticalEvidence && (hasJapaneseScript || counts.latin > 0) {
            return true
        }
        if counts.kana > 0 && counts.latin > japaneseCharacters {
            return true
        }
        if counts.han > 0 {
            // Han-only horizontal text is not enough to distinguish Chinese
            // from Japanese. Without vertical evidence, keep the fast local
            // result and avoid paying for a page reference on every Chinese
            // page.
            return false
        }
        return false
    }

    static func analyzeIfNeeded(
        image: UIImage,
        options: OCRPreprocessor.Options,
        preliminaryBlocks: [TextBlock]
    ) async -> AppleOCRReference? {
        guard shouldAnalyze(
            options: options,
            preliminaryBlocks: preliminaryBlocks,
            image: image
        ) else {
            return nil
        }
        guard #available(iOS 16.0, *), ImageAnalyzer.isSupported else {
            print("MReader OCR ImageAnalyzer unavailable")
            return nil
        }
        guard !isProcessUnavailable() else {
            print("MReader OCR ImageAnalyzer skipped after explicit unavailable error")
            return nil
        }

        do {
            var configuration = ImageAnalyzer.Configuration([.text])
            let requestedLanguages = options.sourceLanguagePreference?.recognitionLanguageIdentifiers ?? [
                "ja-JP", "zh-Hans", "zh-Hant", "ko-KR", "en-US"
            ]
            let supported = Set(ImageAnalyzer.supportedTextRecognitionLanguages)
            configuration.locales = requestedLanguages.filter(supported.contains)
            let analysis = try await ImageAnalyzer().analyze(image, configuration: configuration)
            markProcessAvailable()
            let reference = makeReference(from: analysis.transcript)
            print("MReader OCR ImageAnalyzer chars=\(reference.characterCount) language=\(reference.detectedLanguage ?? "unknown") kana=\(reference.kanaCount) han=\(reference.hanCount)")
            return reference
        } catch is CancellationError {
            return nil
        } catch {
            if isExplicitUnavailableError(error) {
                markProcessUnavailable()
            }
            print("MReader OCR ImageAnalyzer failed: \(error.localizedDescription)")
            return nil
        }
    }

    private static func isProcessUnavailable() -> Bool {
        capabilityLock.lock()
        defer { capabilityLock.unlock() }
        return processCapability == .unavailable
    }

    private static func markProcessAvailable() {
        capabilityLock.lock()
        processCapability = .available
        capabilityLock.unlock()
    }

    private static func markProcessUnavailable() {
        capabilityLock.lock()
        processCapability = .unavailable
        capabilityLock.unlock()
    }

    private static func isExplicitUnavailableError(_ error: Error) -> Bool {
        let description = error.localizedDescription.lowercased()
        return description.contains("not supported")
            || description.contains("unsupported")
            || description.contains("unavailable")
            || description.contains("sandbox")
            || description.contains("permission denied")
            || description.contains("access denied")
    }

    static func makeReference(from transcript: String) -> AppleOCRReference {
        let counts = scriptCounts(in: transcript)
        let language: String?
        if counts.kana > 0 {
            language = "ja"
        } else if counts.hangul > 0 {
            language = "ko"
        } else if counts.han > 0 {
            language = nil
        } else if counts.latin > 0 {
            language = "en"
        } else {
            language = nil
        }
        return AppleOCRReference(
            transcript: transcript,
            characterCount: transcript.unicodeScalars.count,
            kanaCount: counts.kana,
            hanCount: counts.han,
            hangulCount: counts.hangul,
            latinCount: counts.latin,
            detectedLanguage: language
        )
    }

    static func suggestsJapanese(
        _ reference: AppleOCRReference,
        blocks: [TextBlock],
        options: OCRPreprocessor.Options,
        image: UIImage? = nil
    ) -> Bool {
        if reference.kanaCount > 0 { return true }
        guard reference.hanCount >= 4,
              options.sourceLanguagePreference == nil
                || options.sourceLanguagePreference == .automatic
                || options.sourceLanguagePreference == .japanese else {
            return false
        }
        // ImageAnalyzer transcript has no geometry. Existing vertical blocks
        // are the only automatic-mode geometry hint for a Kanji-only page;
        // image-only dark columns are deliberately not language evidence.
        return options.sourceLanguagePreference == .japanese
            || JapaneseVerticalOCRService.verticalColumnCount(in: blocks) >= 1
    }

    private static func scriptCounts(in text: String) -> (kana: Int, han: Int, hangul: Int, latin: Int) {
        var kana = 0
        var han = 0
        var hangul = 0
        var latin = 0
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x3040...0x30FF, 0x31F0...0x31FF:
                kana += 1
            case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF:
                han += 1
            case 0xAC00...0xD7AF, 0x1100...0x11FF:
                hangul += 1
            case 0x0041...0x005A, 0x0061...0x007A:
                latin += 1
            default:
                break
            }
        }
        return (kana, han, hangul, latin)
    }
}
