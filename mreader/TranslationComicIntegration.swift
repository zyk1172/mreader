import CoreGraphics
import Foundation

/// Semantic role of translated manga text. This is intentionally richer than
/// `TranslationLayoutRole`: layout role only decides bubble-vs-standalone
/// geometry, while content role decides how translated text should coexist
/// with the original artwork.
nonisolated enum TranslationContentRole: String, Codable, Sendable, Equatable {
    case dialogue
    case narration
    case soundEffect
    case other

    static func fromClassification(_ value: String) -> Self {
        let normalized = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
        switch normalized {
        case "dialogue", "speech", "bubble": return .dialogue
        case "narration", "caption": return .narration
        case "soundeffect", "sfx", "onomatopoeia": return .soundEffect
        default: return .other
        }
    }

    static func from(block: TextBlock) -> Self {
        let sourceClassification = block.ocrSource
            .split(separator: ":")
            .last?
            .split(separator: "+", maxSplits: 1)
            .first
            .map(String.init) ?? block.ocrSource
        let role = fromClassification(sourceClassification)
        if role != .other { return role }
        return block.layoutRole == .dialogue ? .dialogue : .other
    }
}

/// Product-level display strategy. It is deliberately separate from geometry:
/// the same measured layout may be shown as an assist card or as a lightweight
/// sound-effect annotation.
nonisolated enum TranslationDisplayMode: String, Codable, Sendable, Equatable {
    case inPlace
    case assistOverlay
    case annotation
}

nonisolated enum TranslationDisplayPolicy {
    static func mode(
        contentRole: TranslationContentRole,
        hasReliableDetectedBubble: Bool,
        prefersInPlace: Bool
    ) -> TranslationDisplayMode {
        switch contentRole {
        case .dialogue where hasReliableDetectedBubble && prefersInPlace:
            return .inPlace
        case .soundEffect:
            return .annotation
        case .dialogue, .narration, .other:
            return .assistOverlay
        }
    }
}

nonisolated enum TranslationRegionPolicy {
    /// A model-provided safe region is placement evidence, never bubble evidence.
    /// It must stay on-page and overlap the source text; reliable bubble content
    /// is additionally intersected with the physical bubble so in-place text
    /// cannot escape the actual balloon.
    static func resolvedLayoutSafeRegion(
        sourceTextRegion: CGRect,
        proposedSafeRegion: CGRect?,
        detectedBubble: CGRect?,
        pageBounds: CGRect
    ) -> CGRect? {
        guard !pageBounds.isNull, pageBounds.width > 0, pageBounds.height > 0 else { return nil }
        guard let proposedSafeRegion else { return nil }
        let safe = proposedSafeRegion.standardized.intersection(pageBounds.standardized)
        guard !safe.isNull, safe.width > 0, safe.height > 0,
              safe.intersects(sourceTextRegion.standardized) else { return nil }
        guard let detectedBubble else { return safe }
        let bubble = detectedBubble.standardized.intersection(pageBounds.standardized)
        guard !bubble.isNull, bubble.width > 0, bubble.height > 0 else { return safe }
        let constrained = safe.intersection(bubble)
        guard !constrained.isNull, constrained.width > 0, constrained.height > 0,
              constrained.intersects(sourceTextRegion.standardized) else { return nil }
        return constrained
    }
}

extension TextBlock {
    /// F10 names the three region semantics explicitly while retaining the old
    /// stored fields for source compatibility with the OCR pipeline.
    nonisolated var textRegion: CGRect { boundingBox }
    nonisolated var detectedBubble: CGRect? { bubbleBox }

    /// `layoutSafeRegion` is allowed to be nil for legacy/local OCR. New offline
    /// results persist it independently from `bubbleBox`; callers fall back to a
    /// validated physical bubble or bounded local region only when it is absent.
    /// They must never reinterpret an arbitrary safe rectangle as a bubble.
    nonisolated var effectiveLayoutSafeRegion: CGRect? {
        layoutSafeRegion
    }

    nonisolated var translationContentRole: TranslationContentRole {
        TranslationContentRole.from(block: self)
    }
}
