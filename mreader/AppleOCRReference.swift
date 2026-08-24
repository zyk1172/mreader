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
    static func isSupportedForDiagnostics() -> Bool {
        guard #available(iOS 16.0, *) else { return false }
        return ImageAnalyzer.isSupported
    }

    static func shouldAnalyze(
        options: OCRPreprocessor.Options,
        preliminaryBlocks: [TextBlock]
    ) -> Bool {
        if options.sourceLanguagePreference == .japanese {
            return true
        }
        if options.recognitionMode == .maximumAccuracy {
            return true
        }
        guard options.sourceLanguagePreference == nil
                || options.sourceLanguagePreference == .automatic else {
            return false
        }

        // Auto mode needs a second page-level signal when the locator/formal
        // pass has no Japanese script or has returned a suspiciously small or
        // Latin-dominant result. This is local Apple analysis, not network IO.
        let text = preliminaryBlocks.map(\.text).joined()
        let counts = scriptCounts(in: text)
        return preliminaryBlocks.isEmpty
            || counts.kana == 0
            || counts.latin > counts.kana + counts.han
            || preliminaryBlocks.count <= 12
    }

    static func analyzeIfNeeded(
        image: UIImage,
        options: OCRPreprocessor.Options,
        preliminaryBlocks: [TextBlock]
    ) async -> AppleOCRReference? {
        guard shouldAnalyze(options: options, preliminaryBlocks: preliminaryBlocks) else {
            return nil
        }
        guard #available(iOS 16.0, *), ImageAnalyzer.isSupported else {
            print("MReader OCR ImageAnalyzer unavailable")
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
            let reference = makeReference(from: analysis.transcript)
            print("MReader OCR ImageAnalyzer chars=\(reference.characterCount) language=\(reference.detectedLanguage ?? "unknown") kana=\(reference.kanaCount) han=\(reference.hanCount)")
            return reference
        } catch is CancellationError {
            return nil
        } catch {
            print("MReader OCR ImageAnalyzer failed: \(error.localizedDescription)")
            return nil
        }
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
        options: OCRPreprocessor.Options
    ) -> Bool {
        if reference.kanaCount > 0 { return true }
        guard reference.hanCount >= 4,
              options.sourceLanguagePreference == nil
                || options.sourceLanguagePreference == .automatic
                || options.sourceLanguagePreference == .japanese else {
            return false
        }
        // ImageAnalyzer transcript has no geometry. Existing vertical blocks
        // or the reader direction are only weak automatic-mode hints for a
        // Kanji-only page; explicit Japanese remains unconditional elsewhere.
        return options.sourceLanguagePreference == .japanese
            || JapaneseVerticalOCRService.verticalColumnCount(in: blocks) >= 1
            || options.isRightToLeft
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
