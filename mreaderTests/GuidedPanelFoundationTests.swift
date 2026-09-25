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

    @Test func postProcessorPrefersContainingPanelOverHighConfidenceDialogueBox() {
        let realPanel = panel(
            x: 0.08,
            y: 0.08,
            width: 0.44,
            height: 0.36,
            confidence: 0.55
        )
        let dialogueBox = panel(
            x: 0.19,
            y: 0.16,
            width: 0.17,
            height: 0.11,
            confidence: 0.99
        )
        let neighborPanel = panel(
            x: 0.56,
            y: 0.08,
            width: 0.36,
            height: 0.36,
            confidence: 0.80
        )

        let processed = PanelPostProcessor.process([dialogueBox, realPanel, neighborPanel])

        #expect(processed.contains { abs($0.rect.width - realPanel.rect.width) < 0.0001 })
        #expect(!processed.contains { abs($0.rect.width - dialogueBox.rect.width) < 0.0001 })
    }

    @Test func visionLayoutRejectsFloatingDialogueBoxPattern() {
        let dialogueBoxes = [
            panel(x: 0.13, y: 0.12, width: 0.24, height: 0.23),
            panel(x: 0.55, y: 0.27, width: 0.25, height: 0.22),
            panel(x: 0.22, y: 0.53, width: 0.23, height: 0.24),
            panel(x: 0.61, y: 0.69, width: 0.24, height: 0.23)
        ]
        let processed = PanelPostProcessor.process(dialogueBoxes)

        #expect(!PanelLayoutQuality.isUsable(processed))
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

    @Test func layoutQualityRejectsImplausibleResults() {
        #expect(!PanelLayoutQuality.isUsable([]))
        #expect(!PanelLayoutQuality.isUsable([panel(x: 0.05, y: 0.05, width: 0.9, height: 0.9)]))
        #expect(PanelLayoutQuality.isUsable(twoByTwoPanels()))

        let tooMany = (0..<13).map { index in
            panel(
                x: 0.02 + CGFloat(index % 4) * 0.24,
                y: 0.02 + CGFloat(index / 4) * 0.24,
                width: 0.20,
                height: 0.20
            )
        }
        #expect(!PanelLayoutQuality.isUsable(tooMany))
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

    @Test func panelLayoutSemanticFocusRoundTripsAndFallsBackToFrame() throws {
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
        #expect(decoded.focusRect(at: 0) == focus)
        #expect(decoded.focusRect(at: 1) == decoded.panelRects[1])
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

    @Test func viewportAddsContextWithoutLeavingPageBounds() {
        let expanded = GuidedPanelViewport.expandedAndClamped(
            CGRect(x: 0.0, y: 0.0, width: 0.30, height: 0.25)
        )
        #expect(expanded.minX == 0)
        #expect(expanded.minY == 0)
        #expect(expanded.maxX <= 1)
        #expect(expanded.maxY <= 1)

        let transform = GuidedPanelViewport.transform(
            normalizedPanel: CGRect(x: 0.55, y: 0.08, width: 0.36, height: 0.28),
            imageAspectRatio: 0.70,
            viewportSize: CGSize(width: 390, height: 844)
        )
        #expect(transform.scale >= 1)
        #expect(transform.scale <= GuidedPanelViewport.defaultMaximumScale)
        #expect(transform.focusedRect.width > 0)
        #expect(transform.focusedRect.height > 0)
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
