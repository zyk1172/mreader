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

    @Test func spotlightModeIsStableAcrossPowerAndThermalStates() {
        #expect(
            GuidedPanelFocusPolicy.mode(
                isLowPowerModeEnabled: false,
                thermalState: .nominal
            ) == .spotlight
        )
        #expect(
            GuidedPanelFocusPolicy.mode(
                isLowPowerModeEnabled: true,
                thermalState: .nominal
            ) == .spotlight
        )
        #expect(
            GuidedPanelFocusPolicy.mode(
                isLowPowerModeEnabled: false,
                thermalState: .serious
            ) == .spotlight
        )
        #expect(
            GuidedPanelFocusPolicy.mode(
                isLowPowerModeEnabled: true,
                thermalState: .critical
            ) == .spotlight
        )
    }

    @MainActor
    @Test func spotlightDoesNotGenerateGaussianPreviewCopies() async {
        let source = UIGraphicsImageRenderer(size: CGSize(width: 96, height: 96)).image { context in
            UIColor.black.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 48, height: 96))
            UIColor.white.setFill()
            context.fill(CGRect(x: 48, y: 0, width: 48, height: 96))
        }
        let url = URL(fileURLWithPath: "/tmp/guided-panel-focus-render-test.png")
        let store = GuidedPanelFocusPreviewStore()

        store.prewarm(url: url, image: source, modeOverride: .spotlight)
        #expect(store.preview(for: url) == nil)
        #expect(store.previews.isEmpty)
    }
}
