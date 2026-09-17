import CoreGraphics
import Foundation
import Testing
import UIKit
@testable import mreader

@Suite
struct GuidedPanelFocusTests {
    @Test func panelExpansionStaysInsidePage() {
        let expanded = GuidedPanelFocusGeometry.expandedNormalizedPanel(
            CGRect(x: 0.01, y: 0.02, width: 0.30, height: 0.20),
            expansionRatio: 0.10
        )

        #expect(expanded.minX >= 0)
        #expect(expanded.minY >= 0)
        #expect(expanded.maxX <= 1)
        #expect(expanded.maxY <= 1)
        #expect(expanded.width > 0.30)
        #expect(expanded.height > 0.20)
    }

    @Test func pageFocusRectUsesAspectFitCoordinates() {
        let rect = GuidedPanelFocusGeometry.pageFocusRect(
            normalizedPanel: CGRect(x: 0.25, y: 0.10, width: 0.50, height: 0.20),
            sourceSize: CGSize(width: 500, height: 1000),
            viewportSize: CGSize(width: 1000, height: 1000),
            expansionRatio: 0
        )

        #expect(abs(rect.minX - 375) < 0.001)
        #expect(abs(rect.minY - 100) < 0.001)
        #expect(abs(rect.width - 250) < 0.001)
        #expect(abs(rect.height - 200) < 0.001)
    }

    @Test func screenFocusRectFollowsCameraTransform() {
        let rect = GuidedPanelFocusGeometry.screenFocusRect(
            normalizedPanel: CGRect(x: 0.20, y: 0.25, width: 0.30, height: 0.50),
            sourceSize: CGSize(width: 1000, height: 800),
            viewportSize: CGSize(width: 1000, height: 800),
            cameraScale: 2,
            cameraOffset: CGSize(width: 10, height: -20),
            expansionRatio: 0
        )

        #expect(abs(rect.minX - (-90)) < 0.001)
        #expect(abs(rect.minY - (-20)) < 0.001)
        #expect(abs(rect.width - 600) < 0.001)
        #expect(abs(rect.height - 800) < 0.001)
    }

    @Test func liquidGlassModeIsStableAcrossPowerAndThermalStates() {
        #expect(
            GuidedPanelFocusPolicy.mode(
                isLowPowerModeEnabled: false,
                thermalState: .nominal
            ) == .liquidGlass
        )
        #expect(
            GuidedPanelFocusPolicy.mode(
                isLowPowerModeEnabled: true,
                thermalState: .nominal
            ) == .liquidGlass
        )
        #expect(
            GuidedPanelFocusPolicy.mode(
                isLowPowerModeEnabled: false,
                thermalState: .serious
            ) == .liquidGlass
        )
        #expect(
            GuidedPanelFocusPolicy.mode(
                isLowPowerModeEnabled: true,
                thermalState: .critical
            ) == .liquidGlass
        )
    }

    @Test func featherCurveIsContinuousAndAcceleratesOutward() {
        let a0 = GuidedPanelFocusPolicy.acceleratedFeatherAlpha(0)
        let a1 = GuidedPanelFocusPolicy.acceleratedFeatherAlpha(0.25)
        let a2 = GuidedPanelFocusPolicy.acceleratedFeatherAlpha(0.50)
        let a3 = GuidedPanelFocusPolicy.acceleratedFeatherAlpha(0.75)
        let a4 = GuidedPanelFocusPolicy.acceleratedFeatherAlpha(1)

        #expect(a0 == 0)
        #expect(abs(a1 - 0.015625) < 0.000001)
        #expect(abs(a2 - 0.125) < 0.000001)
        #expect(abs(a3 - 0.421875) < 0.000001)
        #expect(a4 == 1)

        let increments = [a1 - a0, a2 - a1, a3 - a2, a4 - a3]
        #expect(increments[0] < increments[1])
        #expect(increments[1] < increments[2])
        #expect(increments[2] < increments[3])

        #expect(GuidedPanelFocusPolicy.acceleratedFeatherAlpha(-1) == 0)
        #expect(GuidedPanelFocusPolicy.acceleratedFeatherAlpha(2) == 1)
    }

    @MainActor
    @Test func liquidGlassPrewarmDoesNotGenerateCompetingPageBitmap() async {
        let source = UIGraphicsImageRenderer(size: CGSize(width: 96, height: 96)).image { context in
            UIColor.black.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 48, height: 96))
            UIColor.white.setFill()
            context.fill(CGRect(x: 48, y: 0, width: 48, height: 96))
        }
        let url = URL(fileURLWithPath: "/tmp/guided-panel-focus-render-test.png")
        let store = GuidedPanelFocusPreviewStore()

        store.prewarm(url: url, image: source, modeOverride: .liquidGlass)
        try? await Task.sleep(for: .milliseconds(40))

        #expect(store.preview(for: url) == nil)
        #expect(store.previews.isEmpty)
    }
}
