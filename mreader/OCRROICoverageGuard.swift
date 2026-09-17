import CoreGraphics
import Foundation
import UIKit
@preconcurrency import Vision
import os

nonisolated enum OCRROIRecoveryLevel: String, Sendable, Equatable {
    case roiOnly
    case partialRescan
    case fullPage
}

nonisolated enum OCRROICoverageReason: String, Sendable, Equatable {
    case complete
    case noTextEvidence
    case missingDetectorCoverage
    case smallGeometricGap
    case largeGeometricGap
    case characterDeficit
}

nonisolated struct OCRROICoverageDecision: Sendable, Equatable {
    let level: OCRROIRecoveryLevel
    let reason: OCRROICoverageReason
    let recoveryRegions: [CGRect]
    let locatorBlockCount: Int
    let uncoveredBlockCount: Int
    let preliminaryCharacterCount: Int
    let referenceCharacterCount: Int
}

/// Protects OCR recall from becoming identical to Manga Vision detector recall.
/// The detector remains the fast-path geometry hint, but a cheap full-page locator
/// can prove that text exists outside those ROIs and selectively reopen coverage.
nonisolated enum OCRROICoverageGuard {
    private static let minimumLocatorConfidence = 0.15
    private static let fullPageUncoveredAreaThreshold: CGFloat = 0.10
    private static let maximumPartialRegions = 4

    static func evaluate(
        detectorRegions: [CGRect],
        preliminaryBlocks: [TextBlock],
        locatorBlocks: [TextBlock],
        reference: AppleOCRReference?
    ) -> OCRROICoverageDecision {
        let normalizedDetector = detectorRegions
            .map { MangaPageCoordinateSpace.clampedNormalizedRect($0.standardized) }
            .filter { $0.width > 0.001 && $0.height > 0.001 }
        let usefulLocator = locatorBlocks.filter(isUsefulLocatorBlock)
        let preliminaryCharacters = usefulCharacterCount(in: preliminaryBlocks)
        let locatorCharacters = usefulCharacterCount(in: usefulLocator)
        let referenceCharacters = reference?.characterCount ?? 0
        let strongestReferenceCharacters = max(locatorCharacters, referenceCharacters)

        if normalizedDetector.isEmpty {
            let hasTextEvidence = !usefulLocator.isEmpty || strongestReferenceCharacters >= 4
            return OCRROICoverageDecision(
                level: hasTextEvidence ? .fullPage : .roiOnly,
                reason: hasTextEvidence ? .missingDetectorCoverage : .noTextEvidence,
                recoveryRegions: [],
                locatorBlockCount: usefulLocator.count,
                uncoveredBlockCount: usefulLocator.count,
                preliminaryCharacterCount: preliminaryCharacters,
                referenceCharacterCount: strongestReferenceCharacters
            )
        }

        let uncovered = usefulLocator.filter { block in
            !isCovered(block.boundingBox, by: normalizedDetector)
        }
        let uncoveredArea = min(
            uncovered.reduce(CGFloat.zero) {
                $0 + MangaPageCoordinateSpace.area(
                    MangaPageCoordinateSpace.clampedNormalizedRect($1.boundingBox.standardized)
                )
            },
            1
        )
        let uncoveredRatio = usefulLocator.isEmpty
            ? 0
            : Double(uncovered.count) / Double(usefulLocator.count)

        // A healthy detector cannot compensate for a local OCR result that is
        // effectively empty while a page-level source sees substantial text.
        if preliminaryCharacters == 0, strongestReferenceCharacters >= 4 {
            return fullPageDecision(
                reason: .characterDeficit,
                usefulLocator: usefulLocator,
                uncovered: uncovered,
                preliminaryCharacters: preliminaryCharacters,
                referenceCharacters: strongestReferenceCharacters
            )
        }

        if uncovered.count >= 3
            || (uncovered.count >= 2 && uncoveredRatio >= 0.45)
            || uncoveredArea >= fullPageUncoveredAreaThreshold {
            return fullPageDecision(
                reason: .largeGeometricGap,
                usefulLocator: usefulLocator,
                uncovered: uncovered,
                preliminaryCharacters: preliminaryCharacters,
                referenceCharacters: strongestReferenceCharacters
            )
        }

        if referenceCharacters >= 12 {
            let characterCoverage = Double(preliminaryCharacters) / Double(max(referenceCharacters, 1))
            let severeDeficit = preliminaryCharacters + 8 < referenceCharacters
                && characterCoverage < 0.55
            let unexplainedDeficit = uncovered.isEmpty
                && preliminaryCharacters + 10 < referenceCharacters
                && characterCoverage < 0.72
            if severeDeficit || unexplainedDeficit {
                return fullPageDecision(
                    reason: .characterDeficit,
                    usefulLocator: usefulLocator,
                    uncovered: uncovered,
                    preliminaryCharacters: preliminaryCharacters,
                    referenceCharacters: referenceCharacters
                )
            }
        }

        if !uncovered.isEmpty {
            let regions = mergedRecoveryRegions(for: uncovered)
            if regions.contains(where: { MangaPageCoordinateSpace.area($0) >= 0.35 }) {
                return fullPageDecision(
                    reason: .largeGeometricGap,
                    usefulLocator: usefulLocator,
                    uncovered: uncovered,
                    preliminaryCharacters: preliminaryCharacters,
                    referenceCharacters: strongestReferenceCharacters
                )
            }
            return OCRROICoverageDecision(
                level: .partialRescan,
                reason: .smallGeometricGap,
                recoveryRegions: Array(regions.prefix(maximumPartialRegions)),
                locatorBlockCount: usefulLocator.count,
                uncoveredBlockCount: uncovered.count,
                preliminaryCharacterCount: preliminaryCharacters,
                referenceCharacterCount: strongestReferenceCharacters
            )
        }

        return OCRROICoverageDecision(
            level: .roiOnly,
            reason: usefulLocator.isEmpty && strongestReferenceCharacters == 0
                ? .noTextEvidence
                : .complete,
            recoveryRegions: [],
            locatorBlockCount: usefulLocator.count,
            uncoveredBlockCount: 0,
            preliminaryCharacterCount: preliminaryCharacters,
            referenceCharacterCount: strongestReferenceCharacters
        )
    }

    private static func fullPageDecision(
        reason: OCRROICoverageReason,
        usefulLocator: [TextBlock],
        uncovered: [TextBlock],
        preliminaryCharacters: Int,
        referenceCharacters: Int
    ) -> OCRROICoverageDecision {
        OCRROICoverageDecision(
            level: .fullPage,
            reason: reason,
            recoveryRegions: [],
            locatorBlockCount: usefulLocator.count,
            uncoveredBlockCount: uncovered.count,
            preliminaryCharacterCount: preliminaryCharacters,
            referenceCharacterCount: referenceCharacters
        )
    }

    private static func isCovered(_ rawRect: CGRect, by detectorRegions: [CGRect]) -> Bool {
        let rect = MangaPageCoordinateSpace.clampedNormalizedRect(rawRect.standardized)
        guard rect.width > 0, rect.height > 0 else { return true }
        let center = CGPoint(x: rect.midX, y: rect.midY)
        return detectorRegions.contains { detector in
            let containment = MangaPageCoordinateSpace.containment(of: rect, in: detector)
            return containment >= 0.55
                || (detector.insetBy(dx: -0.004, dy: -0.004).contains(center)
                    && containment >= 0.25)
        }
    }

    private static func isUsefulLocatorBlock(_ block: TextBlock) -> Bool {
        guard block.confidence >= minimumLocatorConfidence,
              usefulCharacterCount(in: [block]) > 0 else { return false }
        let rect = MangaPageCoordinateSpace.clampedNormalizedRect(block.boundingBox.standardized)
        let area = MangaPageCoordinateSpace.area(rect)
        return rect.width >= 0.0015
            && rect.height >= 0.0015
            && area >= 0.000_01
            && area <= 0.35
    }

    private static func usefulCharacterCount(in blocks: [TextBlock]) -> Int {
        blocks.reduce(into: 0) { total, block in
            total += block.text.unicodeScalars.filter {
                CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0)
            }.count
        }
    }

    private static func mergedRecoveryRegions(for blocks: [TextBlock]) -> [CGRect] {
        var regions: [CGRect] = blocks.map { block in
            let rect = MangaPageCoordinateSpace.clampedNormalizedRect(block.boundingBox.standardized)
            let dx = max(rect.width * 0.30, 0.012)
            let dy = max(rect.height * 0.30, 0.012)
            return MangaPageCoordinateSpace.clampedNormalizedRect(
                rect.insetBy(dx: -dx, dy: -dy)
            )
        }.sorted {
            if abs($0.minY - $1.minY) > 0.005 { return $0.minY < $1.minY }
            return $0.minX < $1.minX
        }

        var merged: [CGRect] = []
        for region in regions {
            if let index = merged.firstIndex(where: { existing in
                existing.intersects(region)
                    || MangaPageCoordinateSpace.intersectionOverUnion(existing, region) >= 0.03
            }) {
                merged[index] = MangaPageCoordinateSpace.clampedNormalizedRect(
                    merged[index].union(region)
                )
            } else {
                merged.append(region)
            }
        }
        return merged.sorted {
            if abs($0.minY - $1.minY) > 0.005 { return $0.minY < $1.minY }
            return $0.minX < $1.minX
        }
    }
}

/// Cheap full-page coverage probe. Its text is never promoted directly to the
/// translation pipeline; only its geometry and coarse character evidence select
/// the recovery level.
nonisolated enum OCRROICoverageLocator {
    private static let maximumDimension: CGFloat = 1_400

    static func locate(
        in image: UIImage,
        options: OCRPreprocessor.Options
    ) async -> [TextBlock] {
        let normalized = normalizedOrientationImage(image)
        guard let cgImage = downsampledCGImage(normalized, maximumDimension: maximumDimension) else {
            return []
        }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .fast
        request.usesLanguageCorrection = false
        request.minimumTextHeight = Float(max(options.minimumTextHeight * 0.72, 0.002))
        if let preference = options.sourceLanguagePreference, preference != .automatic {
            request.recognitionLanguages = preference.recognitionLanguageIdentifiers
        } else {
            request.recognitionLanguages = options.languages
        }

        do {
            let handler = VNImageRequestHandler(cgImage: cgImage, orientation: .up, options: [:])
            try handler.perform([request])
        } catch is CancellationError {
            return []
        } catch {
            MReaderLog.aiVision.error(
                "OCR coverage locator failed reason=\(MReaderLog.describe(error), privacy: .public)"
            )
            return []
        }

        return (request.results ?? []).compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            let rect = MangaPageCoordinateSpace.topLeftNormalizedRect(
                fromVisionRect: observation.boundingBox
            )
            guard rect.width > 0.001, rect.height > 0.001 else { return nil }
            return TextBlock(
                text: text,
                boundingBox: rect,
                confidence: Double(candidate.confidence),
                ocrSource: "coverage-locator",
                estimatedFontScale: Double(min(rect.width, rect.height)),
                textOrientation: .inferred(from: rect)
            )
        }
    }

    private static func normalizedOrientationImage(_ image: UIImage) -> UIImage {
        guard image.imageOrientation != .up else { return image }
        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        format.opaque = false
        return UIGraphicsImageRenderer(size: image.size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
    }

    private static func downsampledCGImage(
        _ image: UIImage,
        maximumDimension: CGFloat
    ) -> CGImage? {
        guard let source = image.cgImage else { return nil }
        let width = CGFloat(source.width)
        let height = CGFloat(source.height)
        let maximum = max(width, height)
        guard maximum > maximumDimension else { return source }
        let scale = maximumDimension / maximum
        let targetWidth = max(Int((width * scale).rounded()), 1)
        let targetHeight = max(Int((height * scale).rounded()), 1)
        guard let context = CGContext(
            data: nil,
            width: targetWidth,
            height: targetHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return source }
        context.interpolationQuality = .medium
        context.draw(source, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
        return context.makeImage() ?? source
    }
}

/// Executes the detector-ROI fast path first and only expands OCR coverage when
/// independent page evidence proves that the ROI set is incomplete.
nonisolated enum OCRROICoverageRecognizer {
    static func recognizeCandidatesWithReference(
        in image: UIImage,
        options: OCRPreprocessor.Options,
        visionTextRegions: [MangaVisionRegion]
    ) async throws -> OCRCandidateRecognitionResult {
        let plannedRegions = MangaVisionTextROIPlanner.recognitionRegions(from: visionTextRegions)
        guard !plannedRegions.isEmpty else {
            return try await OCRPreprocessor.recognizeCandidatesWithReference(
                in: image,
                options: options,
                visionTextRegions: []
            )
        }

        let normalizedImage = normalizedOrientationImage(image)
        let initial = try await OCRPreprocessor.recognizeCandidatesWithReference(
            in: normalizedImage,
            options: options,
            visionTextRegions: visionTextRegions
        )
        try Task.checkCancellation()
        let locator = await OCRROICoverageLocator.locate(in: normalizedImage, options: options)
        try Task.checkCancellation()
        let decision = OCRROICoverageGuard.evaluate(
            detectorRegions: plannedRegions,
            preliminaryBlocks: initial.blocks,
            locatorBlocks: locator,
            reference: initial.visionKitReference
        )
        MReaderLog.aiVision.debug(
            "OCR ROI coverage level=\(decision.level.rawValue, privacy: .public) reason=\(decision.reason.rawValue, privacy: .public) locator=\(decision.locatorBlockCount, privacy: .public) uncovered=\(decision.uncoveredBlockCount, privacy: .public) preliminaryChars=\(decision.preliminaryCharacterCount, privacy: .public) referenceChars=\(decision.referenceCharacterCount, privacy: .public) recoveryRegions=\(decision.recoveryRegions.count, privacy: .public)"
        )

        switch decision.level {
        case .roiOnly:
            return initial
        case .fullPage:
            let fallback = try await OCRPreprocessor.recognizeCandidatesWithReference(
                in: normalizedImage,
                options: options,
                visionTextRegions: []
            )
            return OCRCandidateRecognitionResult(
                blocks: fallback.blocks,
                visionKitReference: fallback.visionKitReference ?? initial.visionKitReference
            )
        case .partialRescan:
            var recovered = initial.blocks
            for region in decision.recoveryRegions {
                try Task.checkCancellation()
                guard let crop = crop(normalizedImage, normalizedRect: region) else { continue }
                let result = try await OCRPreprocessor.recognizeCandidatesWithReference(
                    in: crop,
                    options: options,
                    visionTextRegions: []
                )
                recovered.append(contentsOf: result.blocks.map {
                    remapped($0, from: region)
                })
            }
            return OCRCandidateRecognitionResult(
                blocks: recovered,
                visionKitReference: initial.visionKitReference
            )
        }
    }

    static func remappedForDiagnostics(
        _ block: TextBlock,
        from normalizedCrop: CGRect
    ) -> TextBlock {
        remapped(block, from: normalizedCrop)
    }

    private static func crop(_ image: UIImage, normalizedRect: CGRect) -> UIImage? {
        guard let cgImage = image.cgImage else { return nil }
        let normalized = MangaPageCoordinateSpace.clampedNormalizedRect(normalizedRect.standardized)
        let bounds = CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height)
        var pixelRect = CGRect(
            x: normalized.minX * CGFloat(cgImage.width),
            y: normalized.minY * CGFloat(cgImage.height),
            width: normalized.width * CGFloat(cgImage.width),
            height: normalized.height * CGFloat(cgImage.height)
        ).integral.intersection(bounds)
        guard !pixelRect.isNull, pixelRect.width >= 4, pixelRect.height >= 4 else { return nil }
        pixelRect = pixelRect.intersection(bounds)
        guard let cropped = cgImage.cropping(to: pixelRect) else { return nil }
        return UIImage(cgImage: cropped, scale: image.scale, orientation: .up)
    }

    private static func remapped(_ block: TextBlock, from rawCrop: CGRect) -> TextBlock {
        let crop = MangaPageCoordinateSpace.clampedNormalizedRect(rawCrop.standardized)
        func mapRect(_ rect: CGRect) -> CGRect {
            MangaPageCoordinateSpace.clampedNormalizedRect(CGRect(
                x: crop.minX + rect.minX * crop.width,
                y: crop.minY + rect.minY * crop.height,
                width: rect.width * crop.width,
                height: rect.height * crop.height
            ))
        }
        func mapPoint(_ point: CGPoint) -> CGPoint {
            CGPoint(
                x: min(max(crop.minX + point.x * crop.width, 0), 1),
                y: min(max(crop.minY + point.y * crop.height, 0), 1)
            )
        }
        let fontScale = block.estimatedFontScale * Double(
            block.textOrientation == .horizontal ? crop.height : crop.width
        )
        return TextBlock(
            id: block.id,
            text: block.text,
            boundingBox: mapRect(block.boundingBox),
            translation: block.translation,
            confidence: block.confidence,
            ocrSource: "roi-recovery:\(block.ocrSource)",
            isFiltered: block.isFiltered,
            filterReason: block.filterReason,
            estimatedFontScale: fontScale,
            textColorHex: block.textColorHex,
            bubbleBox: block.bubbleBox.map(mapRect),
            layoutSafeRegion: block.layoutSafeRegion.map(mapRect),
            polygon: block.polygon.map(mapPoint),
            bubblePolygon: block.bubblePolygon.map(mapPoint),
            translationLines: block.translationLines,
            textOrientation: block.textOrientation,
            layoutRole: block.layoutRole,
            sourceLineCount: block.sourceLineCount
        )
    }

    private static func normalizedOrientationImage(_ image: UIImage) -> UIImage {
        guard image.imageOrientation != .up else { return image }
        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        format.opaque = false
        return UIGraphicsImageRenderer(size: image.size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
    }
}
