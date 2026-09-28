import CoreGraphics
import Foundation
import Testing
@testable import mreader

@Suite(.serialized)
@MainActor
struct GuidedPanelFoundationTests {
    @Test func readingOrderUsesRightToLeftWithinRows() {
        let panels = twoByTwoPanels()
        let ordered = PanelReadingOrder.ordered(panels, isRightToLeft: true)
        #expect(ordered.map(\.rect.midX) == [0.75, 0.25, 0.75, 0.25])
        expectRowCenters(ordered)
    }

    @Test func readingOrderUsesLeftToRightWithinRows() {
        let panels = twoByTwoPanels()
        let ordered = PanelReadingOrder.ordered(panels, isRightToLeft: false)
        #expect(ordered.map(\.rect.midX) == [0.25, 0.75, 0.25, 0.75])
        expectRowCenters(ordered)
    }

    @Test func recursiveOrderKeepsFullWidthMiddlePanelBetweenRows() {
        let panels = [
            panel(x: 0.53, y: 0.04, width: 0.41, height: 0.20),
            panel(x: 0.06, y: 0.04, width: 0.41, height: 0.20),
            panel(x: 0.06, y: 0.32, width: 0.88, height: 0.24),
            panel(x: 0.53, y: 0.64, width: 0.41, height: 0.25),
            panel(x: 0.06, y: 0.64, width: 0.41, height: 0.25)
        ]
        let ordered = PanelReadingOrder.ordered(panels, isRightToLeft: true)
        #expect(ordered[0].rect.minX > ordered[1].rect.minX)
        #expect(ordered[2].rect.width > 0.8)
        #expect(ordered[3].rect.minX > ordered[4].rect.minX)
    }

    @Test func overlappingPageLayoutKeepsBottomPanelsInRightToLeftOrder() {
        let panels = [
            panel(x: 0.42, y: 0.08, width: 0.55, height: 0.39),
            panel(x: 0.12, y: 0.11, width: 0.27, height: 0.20),
            panel(x: 0.12, y: 0.33, width: 0.27, height: 0.20),
            panel(x: 0.50, y: 0.48, width: 0.47, height: 0.12),
            panel(x: 0.68, y: 0.63, width: 0.29, height: 0.32),
            panel(x: 0.35, y: 0.63, width: 0.32, height: 0.32),
            panel(x: 0.12, y: 0.63, width: 0.21, height: 0.32)
        ]

        let processed = PanelPostProcessor.process(
            panels,
            semanticRegions: [
                MangaVisionRegion(
                    type: .balloon,
                    normalizedRect: CGRect(x: 0.75, y: 0.70, width: 0.14, height: 0.10),
                    confidence: 0.82
                ),
                MangaVisionRegion(
                    type: .balloon,
                    normalizedRect: CGRect(x: 0.40, y: 0.70, width: 0.14, height: 0.10),
                    confidence: 0.82
                )
            ]
        )
        let ordered = PanelReadingOrder.ordered(processed, isRightToLeft: true)

        #expect(processed.count == 7)
        #expect(ordered.count == 7)
        let bottomCenters = ordered.suffix(3).map(\.rect.midX)
        #expect(zip(bottomCenters, [0.825, 0.51, 0.225]).allSatisfy { abs($0 - $1) < 0.000_001 })
    }

    @Test func postProcessorRemovesNearDuplicateBoxes() {
        let candidates = [
            panel(x: 0.08, y: 0.08, width: 0.40, height: 0.30, confidence: 0.91),
            panel(x: 0.09, y: 0.09, width: 0.39, height: 0.29, confidence: 0.62),
            panel(x: 0.54, y: 0.08, width: 0.38, height: 0.30, confidence: 0.88)
        ]
        let processed = PanelPostProcessor.process(candidates)
        #expect(processed.count == 2)
        #expect(processed.contains { abs($0.confidence - 0.91) < 0.001 })
    }

    @Test func koharuNavigationDoesNotReclassifyFrameCandidatesByShape() {
        let large = panel(
            x: 0.08,
            y: 0.08,
            width: 0.44,
            height: 0.36,
            confidence: 0.75
        )
        let smallInset = panel(
            x: 0.19,
            y: 0.16,
            width: 0.17,
            height: 0.11,
            confidence: 0.99
        )
        let neighbor = panel(
            x: 0.56,
            y: 0.08,
            width: 0.36,
            height: 0.36,
            confidence: 0.80
        )

        let processed = PanelPostProcessor.process([smallInset, large, neighbor])

        #expect(processed.count == 3)
        func containsGeometry(_ expected: CGRect) -> Bool {
            processed.contains { panel in
                abs(panel.rect.minX - expected.minX) < 0.000_001
                    && abs(panel.rect.minY - expected.minY) < 0.000_001
                    && abs(panel.rect.width - expected.width) < 0.000_001
                    && abs(panel.rect.height - expected.height) < 0.000_001
            }
        }
        #expect(containsGeometry(smallInset.rect))
        #expect(containsGeometry(large.rect))
        #expect(containsGeometry(neighbor.rect))
    }

    @Test func koharuSelectedFramesAreUsableWithoutLegacyVisionShapeHeuristics() {
        let frames = [
            panel(x: 0.13, y: 0.12, width: 0.24, height: 0.23),
            panel(x: 0.55, y: 0.27, width: 0.25, height: 0.22),
            panel(x: 0.22, y: 0.53, width: 0.23, height: 0.24),
            panel(x: 0.61, y: 0.69, width: 0.24, height: 0.23)
        ]
        let processed = PanelPostProcessor.process(frames)

        #expect(PanelLayoutQuality.isUsable(processed))
    }

    @Test func visionLayoutKeepsStructurallyAlignedSmallPanels() {
        let smallPanels = [
            panel(x: 0.06, y: 0.06, width: 0.26, height: 0.22),
            panel(x: 0.36, y: 0.06, width: 0.26, height: 0.22),
            panel(x: 0.66, y: 0.06, width: 0.26, height: 0.22),
            panel(x: 0.06, y: 0.34, width: 0.26, height: 0.22)
        ]
        let processed = PanelPostProcessor.process(smallPanels)

        #expect(processed.count == 4)
        #expect(PanelLayoutQuality.isUsable(processed))
    }

    @Test func layoutQualityUsesAlreadySelectedKoharuNavigationFrames() {
        #expect(!PanelLayoutQuality.isUsable([]))
        #expect(PanelLayoutQuality.isUsable([panel(x: 0.05, y: 0.05, width: 0.9, height: 0.9)]))
        #expect(PanelLayoutQuality.isUsable(twoByTwoPanels()))
    }

    @Test func navigationSelectionCapsPathologicalFrameCounts() {
        let many = (0..<30).map { index in
            panel(
                x: 0.01 + CGFloat(index % 6) * 0.16,
                y: 0.01 + CGFloat(index / 6) * 0.19,
                width: 0.13,
                height: 0.15,
                confidence: 0.70
            )
        }
        let processed = PanelPostProcessor.process(many)
        #expect(processed.count == 20)
        #expect(PanelLayoutQuality.isUsable(processed))
    }

    @Test func calibratedLowScoreFrameSurvivesBesideHighScoreFrame() {
        let lowButValid = panel(
            x: 0.08,
            y: 0.08,
            width: 0.38,
            height: 0.34,
            confidence: 0.11
        )
        let high = panel(
            x: 0.54,
            y: 0.08,
            width: 0.38,
            height: 0.34,
            confidence: 0.92
        )

        let processed = PanelPostProcessor.process([lowButValid, high])

        #expect(processed.contains { $0.rect == lowButValid.rect })
        #expect(processed.contains { $0.rect == high.rect })
    }

    @Test func largeBalloonOverlapDoesNotDeleteRealPanelUnlessNearlyIdentical() {
        let frame = panel(
            x: 0.48,
            y: 0.22,
            width: 0.44,
            height: 0.52,
            confidence: 0.42
        )
        let balloon = MangaVisionRegion(
            type: .balloon,
            normalizedRect: CGRect(x: 0.53, y: 0.18, width: 0.34, height: 0.28),
            confidence: 0.88
        )

        let processed = PanelPostProcessor.process(
            [frame],
            semanticRegions: [balloon]
        )

        #expect(processed.count == 1)
        #expect(processed[0].rect == frame.rect)
    }

    @Test func peripheralMarginStripWithoutSemanticsIsRejected() {
        let margin = panel(x: 0.0, y: 0.02, width: 0.07, height: 0.92, confidence: 0.82)
        let real = panel(x: 0.12, y: 0.08, width: 0.78, height: 0.36, confidence: 0.76)
        let processed = PanelPostProcessor.process(
            [margin, real],
            contentBounds: CGRect(x: 0, y: 0, width: 0.96, height: 0.98)
        )
        #expect(processed.count == 1)
        #expect(processed[0].rect == real.rect)
    }

    @Test func balloonLikeFrameAliasIsRejectedButContainingPanelSurvives() {
        let balloonRect = CGRect(x: 0.60, y: 0.12, width: 0.21, height: 0.17)
        let alias = panel(x: 0.595, y: 0.115, width: 0.22, height: 0.18, confidence: 0.66)
        let real = panel(x: 0.50, y: 0.06, width: 0.42, height: 0.34, confidence: 0.61)
        let balloon = MangaVisionRegion(
            type: .balloon,
            normalizedRect: balloonRect,
            confidence: 0.72
        )

        let processed = PanelPostProcessor.process(
            [alias, real],
            semanticRegions: [balloon]
        )

        #expect(processed.count == 1)
        let survivor = try? #require(processed.first)
        #expect(survivor?.rect != alias.rect)
        #expect((survivor?.rect.width ?? 0) >= 0.35)
        #expect((survivor?.rect.height ?? 0) >= 0.25)
        #expect(
            survivor?.rect.contains(
                CGPoint(x: balloonRect.midX, y: balloonRect.midY)
            ) == true
        )
    }

    @Test func semanticRecoveryRejectsTextContainedOnlyByOneBalloon() {
        let existing = panel(x: 0.05, y: 0.08, width: 0.38, height: 0.34, confidence: 0.90)
        let text = MangaVisionRegion(
            type: .text,
            normalizedRect: CGRect(x: 0.66, y: 0.16, width: 0.10, height: 0.06),
            confidence: 0.82
        )
        let balloon = MangaVisionRegion(
            type: .balloon,
            normalizedRect: CGRect(x: 0.62, y: 0.12, width: 0.20, height: 0.16),
            confidence: 0.78
        )

        let processed = PanelPostProcessor.process(
            [existing],
            semanticRegions: [text, balloon]
        )

        #expect(processed.count == 1)
        #expect(processed[0].rect == existing.rect)
    }

    @Test func semanticEvidenceNeverSynthesizesMissingFrame() {
        let existing = panel(x: 0.05, y: 0.08, width: 0.38, height: 0.34, confidence: 0.90)
        let textInsideBalloon = MangaVisionRegion(
            type: .text,
            normalizedRect: CGRect(x: 0.66, y: 0.16, width: 0.10, height: 0.06),
            confidence: 0.82
        )
        let textOutsideBalloon = MangaVisionRegion(
            type: .text,
            normalizedRect: CGRect(x: 0.84, y: 0.16, width: 0.08, height: 0.06),
            confidence: 0.82
        )
        let balloon = MangaVisionRegion(
            type: .balloon,
            normalizedRect: CGRect(x: 0.62, y: 0.12, width: 0.20, height: 0.16),
            confidence: 0.78
        )

        let processed = PanelPostProcessor.process(
            [existing],
            semanticRegions: [textInsideBalloon, textOutsideBalloon, balloon]
        )

        #expect(processed.count == 1)
        #expect(processed[0].rect == existing.rect)
    }

    @Test func semanticRecoveryNeverPromotesBalloonAloneToPanel() {
        let existing = panel(x: 0.05, y: 0.08, width: 0.38, height: 0.34, confidence: 0.90)
        let balloon = MangaVisionRegion(
            type: .balloon,
            normalizedRect: CGRect(x: 0.62, y: 0.12, width: 0.20, height: 0.16),
            confidence: 0.92
        )

        let processed = PanelPostProcessor.process(
            [existing],
            semanticRegions: [balloon]
        )

        #expect(processed.count == 1)
        #expect(processed[0].rect == existing.rect)
    }

    @Test func semanticRecoveryNeverPromotesSFXToPanel() {
        let existing = panel(x: 0.05, y: 0.08, width: 0.38, height: 0.34, confidence: 0.90)
        let effects = [
            MangaVisionRegion(
                type: .onomatopoeia,
                normalizedRect: CGRect(x: 0.62, y: 0.12, width: 0.12, height: 0.16),
                confidence: 0.96
            ),
            MangaVisionRegion(
                type: .onomatopoeia,
                normalizedRect: CGRect(x: 0.75, y: 0.20, width: 0.12, height: 0.18),
                confidence: 0.94
            )
        ]

        let processed = PanelPostProcessor.process(
            [existing],
            semanticRegions: effects
        )

        #expect(processed.count == 1)
        #expect(processed[0].rect == existing.rect)
    }

    @Test func viewportNeverExpandsSmallPanels() {
        let source = CGRect(x: 0.40, y: 0.40, width: 0.04, height: 0.04)
        let focused = GuidedPanelViewport.expandedAndClamped(
            source,
            contextPadding: 0.25
        )
        #expect(focused == source)
    }

    @Test func cachePathIsStableAndPageBased() {
        let id = UUID(uuidString: "12345678-1234-1234-1234-1234567890AB")!
        #expect(
            PanelDetectionService.cacheRelativePathForDiagnostics(comicID: id, pageIndex: 0)
                == "12345678-1234-1234-1234-1234567890ab/0001.json"
        )
        #expect(
            PanelDetectionService.cacheRelativePathForDiagnostics(comicID: id, pageIndex: 11)
                == "12345678-1234-1234-1234-1234567890ab/0012.json"
        )
    }

    @Test func panelNavigationCentersDetectedFrameInsteadOfLegacySemanticCrop() throws {
        let frame = CGRect(x: 0.08, y: 0.10, width: 0.84, height: 0.70)
        let focus = CGRect(x: 0.34, y: 0.16, width: 0.50, height: 0.44)
        let layout = PanelPageLayout(
            schemaVersion: PanelPageLayout.schemaVersion,
            modelVersion: PanelPageLayout.modelVersion,
            detectorIdentifier: "fixture",
            direction: "rightToLeft",
            sourceFingerprint: "fixture",
            panels: [
                PanelLayoutPanel(
                    rect: NormalizedRect(frame),
                    confidence: 0.9,
                    source: .coreML,
                    semanticFocusRect: NormalizedRect(focus)
                ),
                PanelLayoutPanel(
                    rect: NormalizedRect(CGRect(x: 0.08, y: 0.82, width: 0.40, height: 0.14)),
                    confidence: 0.9,
                    source: .coreML
                )
            ],
            contentBounds: NormalizedRect(CGRect(x: 0, y: 0, width: 1, height: 1)),
            usedFallback: false
        )

        let data = try JSONEncoder().encode(layout)
        let decoded = try JSONDecoder().decode(PanelPageLayout.self, from: data)

        #expect(decoded.schemaVersion == PanelPageLayout.schemaVersion)
        #expect(decoded.panels[0].semanticFocusRect?.cgRect == focus)
        #expect(decoded.focusRect(at: 0) == frame)
        #expect(decoded.focusRect(at: 1) == decoded.panelRects[1])

        let viewport = CGSize(width: 390, height: 844)
        let camera = GuidedPanelViewport.transform(
            normalizedPanel: decoded.focusRect(at: 0),
            imageAspectRatio: 0.70,
            viewportSize: viewport
        )
        let viewportCenter = CGPoint(x: viewport.width / 2, y: viewport.height / 2)
        let displayedFrameCenter = CGPoint(
            x: viewportCenter.x + (camera.focusedRect.midX - viewportCenter.x) * camera.scale + camera.offset.width,
            y: viewportCenter.y + (camera.focusedRect.midY - viewportCenter.y) * camera.scale + camera.offset.height
        )
        #expect(abs(displayedFrameCenter.x - viewportCenter.x) < 0.0001)
        #expect(abs(displayedFrameCenter.y - viewportCenter.y) < 0.0001)
    }

    @Test func guidedPanelDirectionDefaultsToNormalDirectionButCanBeIndependent() {
        let inherited = ComicBook(
            title: "Direction Test",
            bookmarkData: Data(),
            totalPages: 1,
            readingDirectionRaw: ReadingDirection.rightToLeft.rawValue
        )
        #expect(inherited.guidedPanelReadingDirectionRaw == ReadingDirection.rightToLeft.rawValue)

        let independent = ComicBook(
            title: "Direction Test",
            bookmarkData: Data(),
            totalPages: 1,
            readingDirectionRaw: ReadingDirection.leftToRight.rawValue,
            guidedPanelReadingDirectionRaw: ReadingDirection.rightToLeft.rawValue
        )
        #expect(independent.readingDirectionRaw == ReadingDirection.leftToRight.rawValue)
        #expect(independent.guidedPanelReadingDirectionRaw == ReadingDirection.rightToLeft.rawValue)
    }

    @Test func viewportUsesExactPanelBoundsWithoutPercentageExpansion() {
        let panel = CGRect(x: 0.08, y: 0.10, width: 0.30, height: 0.25)
        let exact = GuidedPanelViewport.expandedAndClamped(
            panel,
            contextPadding: 0.20
        )
        #expect(exact == panel)

        let transform = GuidedPanelViewport.transform(
            normalizedPanel: panel,
            imageAspectRatio: 0.70,
            viewportSize: CGSize(width: 390, height: 844),
            contextPadding: 0.20
        )
        let imageRect = GuidedPanelViewport.aspectFitRect(
            aspectRatio: 0.70,
            in: CGRect(x: 0, y: 0, width: 390, height: 844)
        )
        #expect(abs(transform.focusedRect.minX - (imageRect.minX + panel.minX * imageRect.width)) < 0.0001)
        #expect(abs(transform.focusedRect.minY - (imageRect.minY + panel.minY * imageRect.height)) < 0.0001)
        #expect(abs(transform.focusedRect.width - panel.width * imageRect.width) < 0.0001)
        #expect(abs(transform.focusedRect.height - panel.height * imageRect.height) < 0.0001)
    }

    private func expectRowCenters(_ ordered: [DetectedPanel]) {
        let expected: [CGFloat] = [0.20, 0.20, 0.70, 0.70]
        #expect(ordered.count == expected.count)
        for (panel, expectedY) in zip(ordered, expected) {
            #expect(abs(panel.rect.midY - expectedY) < 0.0001)
        }
    }

    private func twoByTwoPanels() -> [DetectedPanel] {
        [
            panel(x: 0.06, y: 0.05, width: 0.38, height: 0.30),
            panel(x: 0.56, y: 0.05, width: 0.38, height: 0.30),
            panel(x: 0.06, y: 0.55, width: 0.38, height: 0.30),
            panel(x: 0.56, y: 0.55, width: 0.38, height: 0.30)
        ]
    }

    private func panel(
        x: CGFloat,
        y: CGFloat,
        width: CGFloat,
        height: CGFloat,
        confidence: Float = 0.90
    ) -> DetectedPanel {
        DetectedPanel(
            rect: CGRect(x: x, y: y, width: width, height: height),
            confidence: confidence,
            source: .coreML
        )
    }
}
