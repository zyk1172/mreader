import CoreGraphics
import Testing
import UIKit
@testable import mreader

@Suite(.serialized)
@MainActor
struct GeometryPanelDetectorTests {
    @Test func xyCutFindsFourPanelsFromTwoPageSpanningGutters() throws {
        let image = makeGridPage()
        let cgImage = try #require(image.cgImage)
        let detector = GeometryPanelDetector(maximumDimension: 800)

        let panels = try detector.detectPanels(in: cgImage)
        let processed = PanelPostProcessor.process(panels)

        #expect(processed.count == 4)
        #expect(processed.allSatisfy { $0.source == .pageGeometry })
        #expect(processed.allSatisfy { $0.confidence >= 0.50 })

        let top = processed.filter { $0.rect.midY < 0.5 }
        let bottom = processed.filter { $0.rect.midY > 0.5 }
        #expect(top.count == 2)
        #expect(bottom.count == 2)
    }

    @Test func interiorSpeechBalloonCannotCreateAPanelSplit() throws {
        let image = makeSinglePanelWithSpeechBalloon()
        let cgImage = try #require(image.cgImage)
        let detector = GeometryPanelDetector(maximumDimension: 800)

        let panels = try detector.detectPanels(in: cgImage)

        #expect(panels.count == 1)
        #expect(panels[0].source == .pageGeometry)
        #expect(panels[0].rect.width > 0.85)
        #expect(panels[0].rect.height > 0.85)
        #expect(panels[0].confidence < 0.50)
    }

    @Test func broadBlankArtworkBandIsNotPromotedToAGutter() throws {
        let size = CGSize(width: 700, height: 1_000)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            UIColor(white: 0.45, alpha: 1).setFill()
            UIRectFill(CGRect(origin: .zero, size: size))

            // Simulates a large white sky/background area inside one full-bleed panel.
            // It spans the page, but has no dark frame boundary on either shoulder.
            UIColor.white.setFill()
            UIRectFill(CGRect(x: 0, y: 420, width: size.width, height: 140))
        }

        let cgImage = try #require(image.cgImage)
        let detector = GeometryPanelDetector(maximumDimension: 800)
        let panels = try detector.detectPanels(in: cgImage)

        #expect(panels.count == 1)
        #expect(panels[0].confidence < 0.50)
    }

    @Test func invalidOuterMarginSeparatorDoesNotHideRealInnerGutter() throws {
        let size = CGSize(width: 700, height: 1_000)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))

            UIColor(white: 0.38, alpha: 1).setFill()
            let topPanel = CGRect(x: 35, y: 120, width: 630, height: 350)
            let bottomPanel = CGRect(x: 35, y: 510, width: 630, height: 430)
            context.fill(topPanel)
            context.fill(bottomPanel)

            UIColor.black.setStroke()
            for rect in [topPanel, bottomPanel] {
                let outline = UIBezierPath(rect: rect)
                outline.lineWidth = 4
                outline.stroke()
            }
        }

        let cgImage = try #require(image.cgImage)
        let panels = try GeometryPanelDetector(maximumDimension: 1_000)
            .detectPanels(in: cgImage)

        #expect(panels.count == 2)
        #expect(panels[0].rect.maxY < panels[1].rect.minY
            || panels[1].rect.maxY < panels[0].rect.minY)
    }

    @Test func rasterCoordinatesRemainTopLeftOrigin() throws {
        let size = CGSize(width: 500, height: 800)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))

            UIColor(white: 0.32, alpha: 1).setFill()
            let shortTop = CGRect(x: 25, y: 30, width: 450, height: 180)
            let tallBottom = CGRect(x: 25, y: 255, width: 450, height: 510)
            context.fill(shortTop)
            context.fill(tallBottom)

            UIColor.black.setStroke()
            for rect in [shortTop, tallBottom] {
                let outline = UIBezierPath(rect: rect)
                outline.lineWidth = 4
                outline.stroke()
            }
        }

        let cgImage = try #require(image.cgImage)
        let panels = try GeometryPanelDetector(maximumDimension: 800)
            .detectPanels(in: cgImage)
        #expect(panels.count == 2)

        let shortPanel = try #require(panels.min(by: { $0.rect.height < $1.rect.height }))
        let tallPanel = try #require(panels.max(by: { $0.rect.height < $1.rect.height }))
        #expect(shortPanel.rect.midY < tallPanel.rect.midY)
    }

    @Test func narrowPageCanStillSplitAlongItsLongAxis() throws {
        let size = CGSize(width: 60, height: 400)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))

            UIColor(white: 0.35, alpha: 1).setFill()
            let first = CGRect(x: 2, y: 5, width: 56, height: 175)
            let second = CGRect(x: 2, y: 220, width: 56, height: 175)
            context.fill(first)
            context.fill(second)

            UIColor.black.setStroke()
            for rect in [first, second] {
                let outline = UIBezierPath(rect: rect)
                outline.lineWidth = 2
                outline.stroke()
            }
        }

        let cgImage = try #require(image.cgImage)
        let panels = try GeometryPanelDetector(maximumDimension: 800)
            .detectPanels(in: cgImage)

        #expect(panels.count == 2)
    }

    @Test func moderateResidualCoverageCannotEraseMostOfAGeometryLeaf() {
        let geometry = [
            DetectedPanel(
                rect: CGRect(x: 0.05, y: 0.05, width: 0.90, height: 0.40),
                confidence: 0.84,
                source: .pageGeometry
            ),
            DetectedPanel(
                rect: CGRect(x: 0.05, y: 0.52, width: 0.90, height: 0.42),
                confidence: 0.84,
                source: .pageGeometry
            )
        ]
        let partialModel = [
            DetectedPanel(
                rect: CGRect(x: 0.08, y: 0.55, width: 0.30, height: 0.22),
                confidence: 0.92,
                source: .coreML
            ),
            DetectedPanel(
                rect: CGRect(x: 0.62, y: 0.55, width: 0.30, height: 0.22),
                confidence: 0.91,
                source: .coreML
            )
        ]

        let result = PanelCandidateFusion.resolve(
            geometry: geometry,
            model: partialModel,
            contentBounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            imageAspectRatio: 0.70
        )

        // Failed split coverage must never delete the geometry leaf. The learned
        // boxes may survive as explicit insets, but both original geometry panels remain.
        #expect(result.panels.filter { $0.source == .pageGeometry }.count == 2)
        #expect(result.panels.contains {
            abs($0.rect.minY - 0.52) < 0.0001
                && abs($0.rect.width - 0.90) < 0.0001
        })
    }

    @Test func singleHighConfidenceInsetSurvivesInsideGeometryParent() {
        let geometry = [
            DetectedPanel(
                rect: CGRect(x: 0.05, y: 0.05, width: 0.90, height: 0.40),
                confidence: 0.82,
                source: .pageGeometry
            ),
            DetectedPanel(
                rect: CGRect(x: 0.05, y: 0.52, width: 0.90, height: 0.42),
                confidence: 0.80,
                source: .pageGeometry
            )
        ]
        let inset = DetectedPanel(
            rect: CGRect(x: 0.62, y: 0.62, width: 0.24, height: 0.20),
            confidence: 0.86,
            source: .coreML
        )

        let result = PanelCandidateFusion.resolve(
            geometry: geometry,
            model: [inset],
            contentBounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            imageAspectRatio: 0.70
        )

        #expect(result.panels.contains { $0.source == .coreML })
        #expect(result.panels.contains { $0.rect == inset.rect })
    }

    @Test func nestedGeometryAndModelBoxesAreNotGenericDuplicatesWhenSizesDiffer() {
        let parent = DetectedPanel(
            rect: CGRect(x: 0.05, y: 0.05, width: 0.80, height: 0.80),
            confidence: 0.80,
            source: .pageGeometry
        )
        let inset = DetectedPanel(
            rect: CGRect(x: 0.58, y: 0.58, width: 0.18, height: 0.18),
            confidence: 0.92,
            source: .coreML
        )

        let processed = PanelPostProcessor.process([parent, inset])

        #expect(processed.count == 2)
        #expect(processed.contains { $0.source == .pageGeometry })
        #expect(processed.contains { $0.source == .coreML })
    }

    @Test func multipleCredibleInsetsCanCoexistInsideOneGeometryPanel() {
        let geometry = [
            DetectedPanel(
                rect: CGRect(x: 0.05, y: 0.05, width: 0.90, height: 0.40),
                confidence: 0.84,
                source: .pageGeometry
            ),
            DetectedPanel(
                rect: CGRect(x: 0.05, y: 0.52, width: 0.90, height: 0.42),
                confidence: 0.84,
                source: .pageGeometry
            )
        ]
        let insets = [
            DetectedPanel(
                rect: CGRect(x: 0.10, y: 0.58, width: 0.24, height: 0.18),
                confidence: 0.88,
                source: .coreML
            ),
            DetectedPanel(
                rect: CGRect(x: 0.66, y: 0.70, width: 0.24, height: 0.18),
                confidence: 0.87,
                source: .coreML
            )
        ]

        let result = PanelCandidateFusion.resolve(
            geometry: geometry,
            model: insets,
            contentBounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            imageAspectRatio: 0.70
        )

        #expect(result.panels.filter { $0.source == .pageGeometry }.count == 2)
        #expect(result.panels.filter { $0.source == .coreML }.count == 2)
    }

    @Test func tinyNestedModelBoxesAreNotPromotedToInsets() {
        let geometry = [
            DetectedPanel(
                rect: CGRect(x: 0.05, y: 0.05, width: 0.90, height: 0.40),
                confidence: 0.84,
                source: .pageGeometry
            ),
            DetectedPanel(
                rect: CGRect(x: 0.05, y: 0.52, width: 0.90, height: 0.42),
                confidence: 0.84,
                source: .pageGeometry
            )
        ]
        let tiny = [
            DetectedPanel(
                rect: CGRect(x: 0.10, y: 0.58, width: 0.10, height: 0.10),
                confidence: 0.95,
                source: .coreML
            ),
            DetectedPanel(
                rect: CGRect(x: 0.78, y: 0.80, width: 0.10, height: 0.10),
                confidence: 0.95,
                source: .coreML
            )
        ]

        let result = PanelCandidateFusion.resolve(
            geometry: geometry,
            model: tiny,
            contentBounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            imageAspectRatio: 0.70
        )

        #expect(result.panels.count == 2)
        #expect(result.panels.allSatisfy { $0.source == .pageGeometry })
    }

    @Test func sparseModelCornersCannotSplitACoarseGeometryLeaf() {
        let geometry = [
            DetectedPanel(
                rect: CGRect(x: 0.05, y: 0.05, width: 0.90, height: 0.40),
                confidence: 0.84,
                source: .pageGeometry
            ),
            DetectedPanel(
                rect: CGRect(x: 0.05, y: 0.52, width: 0.90, height: 0.42),
                confidence: 0.84,
                source: .pageGeometry
            )
        ]
        let sparseModel = [
            DetectedPanel(
                rect: CGRect(x: 0.08, y: 0.55, width: 0.12, height: 0.12),
                confidence: 0.90,
                source: .coreML
            ),
            DetectedPanel(
                rect: CGRect(x: 0.80, y: 0.79, width: 0.12, height: 0.12),
                confidence: 0.90,
                source: .coreML
            )
        ]

        let result = PanelCandidateFusion.resolve(
            geometry: geometry,
            model: sparseModel,
            contentBounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            imageAspectRatio: 0.70
        )

        #expect(result.panels.count == 2)
        #expect(result.panels.allSatisfy { $0.source == .pageGeometry })
    }

    @Test func geometryLayoutBeatsOneBadFullPageModelFrame() {
        let geometry = fourGeometryPanels()
        let model = [
            DetectedPanel(
                rect: CGRect(x: 0.02, y: 0.02, width: 0.96, height: 0.96),
                confidence: 0.91,
                source: .coreML
            )
        ]

        let result = PanelCandidateFusion.resolve(
            geometry: geometry,
            model: model,
            contentBounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            imageAspectRatio: 0.70
        )

        #expect(result.reason.hasPrefix("geometry-primary"))
        #expect(result.panels.count == 4)
        #expect(!result.usedVirtualFallback)
        #expect(result.panels.allSatisfy { $0.source == .pageGeometry })
    }

    @Test func nearDuplicateModelBoxCannotReplaceGeometryBoundary() {
        let geometric = DetectedPanel(
            rect: CGRect(x: 0.08, y: 0.08, width: 0.40, height: 0.34),
            confidence: 0.72,
            source: .pageGeometry
        )
        let learned = DetectedPanel(
            rect: CGRect(x: 0.085, y: 0.085, width: 0.395, height: 0.335),
            confidence: 0.99,
            source: .coreML
        )

        let processed = PanelPostProcessor.process([learned, geometric])

        #expect(processed.count == 1)
        #expect(processed[0].source == .pageGeometry)
        #expect(processed[0].rect == geometric.rect)
    }

    @Test func modelMaySplitOnlyAnUndersegmentedGeometryLeaf() {
        let geometry = [
            DetectedPanel(
                rect: CGRect(x: 0.05, y: 0.05, width: 0.90, height: 0.40),
                confidence: 0.82,
                source: .pageGeometry
            ),
            DetectedPanel(
                rect: CGRect(x: 0.05, y: 0.52, width: 0.90, height: 0.42),
                confidence: 0.82,
                source: .pageGeometry
            )
        ]
        let model = [
            DetectedPanel(
                rect: CGRect(x: 0.07, y: 0.54, width: 0.40, height: 0.38),
                confidence: 0.78,
                source: .coreML
            ),
            DetectedPanel(
                rect: CGRect(x: 0.53, y: 0.54, width: 0.40, height: 0.38),
                confidence: 0.80,
                source: .coreML
            )
        ]

        let result = PanelCandidateFusion.resolve(
            geometry: geometry,
            model: model,
            contentBounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            imageAspectRatio: 0.70
        )

        #expect(result.reason == "geometry-primary")
        #expect(result.panels.count == 3)
        #expect(result.panels.filter { $0.source == .coreML }.count == 2)
        #expect(result.panels.filter { $0.source == .pageGeometry }.count == 1)
    }

    @Test func modelFrameThatMatchesSpeechBalloonIsRejected() {
        let fakeFrame = DetectedPanel(
            rect: CGRect(x: 0.34, y: 0.22, width: 0.22, height: 0.16),
            confidence: 0.94,
            source: .coreML
        )
        let balloon = CGRect(x: 0.335, y: 0.215, width: 0.23, height: 0.17)

        let result = PanelCandidateFusion.resolve(
            geometry: [],
            model: [fakeFrame],
            contentBounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            imageAspectRatio: 0.70,
            balloonRegions: [balloon],
            textRegions: []
        )

        #expect(result.usedVirtualFallback)
        #expect(result.panels.allSatisfy { $0.source == .virtualPanel })
    }

    @Test func fullBleedModelPanelWithOneInsetIsNotMistakenForPageContainer() {
        let model = [
            DetectedPanel(
                rect: CGRect(x: 0.05, y: 0.05, width: 0.90, height: 0.90),
                confidence: 0.92,
                source: .coreML
            ),
            DetectedPanel(
                rect: CGRect(x: 0.64, y: 0.62, width: 0.20, height: 0.18),
                confidence: 0.88,
                source: .coreML
            )
        ]

        let result = PanelCandidateFusion.resolve(
            geometry: [],
            model: model,
            contentBounds: CGRect(x: 0.04, y: 0.04, width: 0.92, height: 0.92),
            imageAspectRatio: 0.70
        )

        #expect(!result.usedVirtualFallback)
        #expect(result.panels.count == 2)
        #expect(result.panels.contains { $0.rect.width > 0.80 })
        #expect(result.panels.contains { $0.rect.width < 0.30 })
    }

    @Test func largeRealPanelThatDoesNotCoverPageContentIsNotSuppressedAsContainer() {
        let model = [
            DetectedPanel(
                rect: CGRect(x: 0.05, y: 0.05, width: 0.70, height: 0.80),
                confidence: 0.93,
                source: .coreML
            ),
            DetectedPanel(
                rect: CGRect(x: 0.10, y: 0.12, width: 0.20, height: 0.18),
                confidence: 0.86,
                source: .coreML
            ),
            DetectedPanel(
                rect: CGRect(x: 0.48, y: 0.56, width: 0.18, height: 0.16),
                confidence: 0.84,
                source: .coreML
            )
        ]

        let result = PanelCandidateFusion.resolve(
            geometry: [],
            model: model,
            contentBounds: CGRect(x: 0.02, y: 0.02, width: 0.96, height: 0.96),
            imageAspectRatio: 0.70
        )

        #expect(result.panels.contains { $0.rect.width > 0.65 })
    }

    @Test func learnedWholePageContainerIsSuppressedWhenSpecificFramesExist() {
        let model = [
            DetectedPanel(
                rect: CGRect(x: 0.10, y: 0.10, width: 0.80, height: 0.80),
                confidence: 0.96,
                source: .coreML
            ),
            DetectedPanel(
                rect: CGRect(x: 0.14, y: 0.15, width: 0.34, height: 0.34),
                confidence: 0.84,
                source: .coreML
            ),
            DetectedPanel(
                rect: CGRect(x: 0.52, y: 0.15, width: 0.34, height: 0.34),
                confidence: 0.82,
                source: .coreML
            )
        ]

        let result = PanelCandidateFusion.resolve(
            geometry: [],
            model: model,
            contentBounds: CGRect(x: 0.10, y: 0.10, width: 0.80, height: 0.80),
            imageAspectRatio: 0.70
        )

        #expect(!result.usedVirtualFallback)
        #expect(result.panels.count == 2)
        #expect(result.panels.allSatisfy { $0.rect.width < 0.50 })
    }

    @Test func nestedWeakGeometryAndSingleModelChildDoNotFormFakeTwoPanelLayout() {
        let weakGeometry = DetectedPanel(
            rect: CGRect(x: 0.02, y: 0.02, width: 0.96, height: 0.96),
            confidence: 0.34,
            source: .pageGeometry
        )
        let learnedChild = DetectedPanel(
            rect: CGRect(x: 0.56, y: 0.56, width: 0.24, height: 0.22),
            confidence: 0.90,
            source: .coreML
        )

        let result = PanelCandidateFusion.resolve(
            geometry: [weakGeometry],
            model: [learnedChild],
            contentBounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            imageAspectRatio: 0.70
        )

        #expect(result.usedVirtualFallback)
        #expect(result.panels.allSatisfy { $0.source == .virtualPanel })
    }

    @Test func widelyDispersedDialogueRejectsWholePageSingleFrameCorroboration() {
        let geometric = DetectedPanel(
            rect: CGRect(x: 0.03, y: 0.03, width: 0.94, height: 0.94),
            confidence: 0.45,
            source: .pageGeometry
        )
        let learned = DetectedPanel(
            rect: CGRect(x: 0.04, y: 0.04, width: 0.92, height: 0.92),
            confidence: 0.94,
            source: .coreML
        )
        let balloons = [
            CGRect(x: 0.12, y: 0.10, width: 0.10, height: 0.08),
            CGRect(x: 0.72, y: 0.40, width: 0.10, height: 0.08),
            CGRect(x: 0.18, y: 0.78, width: 0.10, height: 0.08)
        ]

        let result = PanelCandidateFusion.resolve(
            geometry: [geometric],
            model: [learned],
            contentBounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            imageAspectRatio: 0.70,
            balloonRegions: balloons
        )

        #expect(result.usedVirtualFallback)
        #expect(result.reason == "virtual-panel-fallback")
    }

    @Test func contentBoundsHintCannotTrimMoreThanTenPercentOfARealFrame() {
        let geometry = [
            DetectedPanel(
                rect: CGRect(x: 0.02, y: 0.08, width: 0.46, height: 0.38),
                confidence: 0.82,
                source: .pageGeometry
            ),
            DetectedPanel(
                rect: CGRect(x: 0.52, y: 0.08, width: 0.46, height: 0.38),
                confidence: 0.82,
                source: .pageGeometry
            )
        ]

        let result = PanelCandidateFusion.resolve(
            geometry: geometry,
            model: [],
            contentBounds: CGRect(x: 0.10, y: 0.05, width: 0.80, height: 0.90),
            imageAspectRatio: 0.70
        )

        #expect(result.panels.count == 2)
        #expect(result.panels.contains { abs($0.rect.minX - 0.02) < 0.0001 })
        #expect(result.panels.contains { abs($0.rect.maxX - 0.98) < 0.0001 })
    }

    @Test func uncorroboratedSingleModelFrameUsesVirtualPanels() {
        let learned = DetectedPanel(
            rect: CGRect(x: 0.03, y: 0.03, width: 0.94, height: 0.94),
            confidence: 0.97,
            source: .coreML
        )

        let result = PanelCandidateFusion.resolve(
            geometry: [],
            model: [learned],
            contentBounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            imageAspectRatio: 0.70
        )

        #expect(result.usedVirtualFallback)
        #expect(result.reason == "virtual-panel-fallback")
        #expect(result.panels.count == 4)
        #expect(result.panels.allSatisfy { $0.source == .virtualPanel })
    }

    @Test func independentlyCorroboratedSinglePanelIsAccepted() {
        let geometric = DetectedPanel(
            rect: CGRect(x: 0.02, y: 0.02, width: 0.96, height: 0.96),
            confidence: 0.46,
            source: .pageGeometry
        )
        let learned = DetectedPanel(
            rect: CGRect(x: 0.04, y: 0.04, width: 0.92, height: 0.92),
            confidence: 0.91,
            source: .coreML
        )

        let result = PanelCandidateFusion.resolve(
            geometry: [geometric],
            model: [learned],
            contentBounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            imageAspectRatio: 0.70
        )

        #expect(!result.usedVirtualFallback)
        #expect(result.reason == "corroborated-single-panel")
        #expect(result.panels.count == 1)
    }

    @Test func uncertainPageUsesExplicitVirtualPanelsInsteadOfInventedFrames() {
        let result = PanelCandidateFusion.resolve(
            geometry: [],
            model: [],
            contentBounds: CGRect(x: 0.04, y: 0.03, width: 0.92, height: 0.94),
            imageAspectRatio: 0.70
        )

        #expect(result.usedVirtualFallback)
        #expect(result.reason == "virtual-panel-fallback")
        #expect(result.panels.count == 4)
        #expect(result.panels.allSatisfy { $0.source == .virtualPanel })
        #expect(PanelLayoutQuality.isUsable(result.panels))
    }

    @Test func veryTallPageFallsBackToVerticalReadingStrips() {
        let panels = VirtualPanelPlanner.panels(
            in: CGRect(x: 0, y: 0, width: 1, height: 1),
            imageAspectRatio: 0.40
        )

        #expect(panels.count == 3)
        #expect(panels.allSatisfy { abs($0.rect.width - 1) < 0.0001 })
        #expect(panels[0].rect.midY < panels[1].rect.midY)
        #expect(panels[1].rect.midY < panels[2].rect.midY)
    }

    private func fourGeometryPanels() -> [DetectedPanel] {
        [
            DetectedPanel(
                rect: CGRect(x: 0.04, y: 0.04, width: 0.43, height: 0.42),
                confidence: 0.84,
                source: .pageGeometry
            ),
            DetectedPanel(
                rect: CGRect(x: 0.53, y: 0.04, width: 0.43, height: 0.42),
                confidence: 0.85,
                source: .pageGeometry
            ),
            DetectedPanel(
                rect: CGRect(x: 0.04, y: 0.54, width: 0.43, height: 0.42),
                confidence: 0.83,
                source: .pageGeometry
            ),
            DetectedPanel(
                rect: CGRect(x: 0.53, y: 0.54, width: 0.43, height: 0.42),
                confidence: 0.86,
                source: .pageGeometry
            )
        ]
    }

    private func makeGridPage() -> UIImage {
        let size = CGSize(width: 700, height: 1_000)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))

            UIColor(white: 0.42, alpha: 1).setFill()
            let marginX: CGFloat = 28
            let marginY: CGFloat = 36
            let gutterX: CGFloat = 28
            let gutterY: CGFloat = 34
            let panelWidth = (size.width - marginX * 2 - gutterX) / 2
            let panelHeight = (size.height - marginY * 2 - gutterY) / 2

            let rects = [
                CGRect(x: marginX, y: marginY, width: panelWidth, height: panelHeight),
                CGRect(
                    x: marginX + panelWidth + gutterX,
                    y: marginY,
                    width: panelWidth,
                    height: panelHeight
                ),
                CGRect(
                    x: marginX,
                    y: marginY + panelHeight + gutterY,
                    width: panelWidth,
                    height: panelHeight
                ),
                CGRect(
                    x: marginX + panelWidth + gutterX,
                    y: marginY + panelHeight + gutterY,
                    width: panelWidth,
                    height: panelHeight
                )
            ]
            for rect in rects {
                context.fill(rect)
                UIColor.black.setStroke()
                let path = UIBezierPath(rect: rect)
                path.lineWidth = 4
                path.stroke()
                UIColor(white: 0.42, alpha: 1).setFill()
            }
        }
    }

    private func makeSinglePanelWithSpeechBalloon() -> UIImage {
        let size = CGSize(width: 700, height: 1_000)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            UIColor(white: 0.38, alpha: 1).setFill()
            UIRectFill(CGRect(origin: .zero, size: size))

            UIColor.white.setFill()
            UIBezierPath(
                ovalIn: CGRect(x: 220, y: 300, width: 260, height: 180)
            ).fill()

            UIColor.black.setStroke()
            let outline = UIBezierPath(
                ovalIn: CGRect(x: 220, y: 300, width: 260, height: 180)
            )
            outline.lineWidth = 4
            outline.stroke()
        }
    }
}
