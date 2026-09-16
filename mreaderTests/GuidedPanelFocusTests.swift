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

    @Test func lowPowerAndThermalPressureDisableBlurDisplayAndNewWork() {
        #expect(
            GuidedPanelFocusPolicy.mode(
                isLowPowerModeEnabled: false,
                thermalState: .nominal
            ) == .blurred
        )
        #expect(
            GuidedPanelFocusPolicy.mode(
                isLowPowerModeEnabled: true,
                thermalState: .nominal
            ) == .dimOnly
        )
        #expect(
            GuidedPanelFocusPolicy.mode(
                isLowPowerModeEnabled: false,
                thermalState: .serious
            ) == .dimOnly
        )
        #expect(
            GuidedPanelFocusPolicy.mode(
                isLowPowerModeEnabled: false,
                thermalState: .critical
            ) == .dimOnly
        )
        #expect(
            GuidedPanelFocusPolicy.shouldDisplayBlur(
                previewAvailable: true,
                mode: .blurred
            )
        )
        #expect(
            !GuidedPanelFocusPolicy.shouldDisplayBlur(
                previewAvailable: true,
                mode: .dimOnly
            )
        )
    }

    @MainActor
    @Test func gaussianPreviewIsActuallyRenderedAndDiffersFromSource() async throws {
        let size = CGSize(width: 96, height: 96)
        let source = UIGraphicsImageRenderer(size: size).image { context in
            UIColor.black.setFill()
            context.fill(CGRect(x: 0, y: 0, width: size.width / 2, height: size.height))
            UIColor.white.setFill()
            context.fill(CGRect(x: size.width / 2, y: 0, width: size.width / 2, height: size.height))
        }
        let url = URL(fileURLWithPath: "/tmp/guided-panel-focus-render-test.png")
        let store = GuidedPanelFocusPreviewStore()

        store.prewarm(url: url, image: source, modeOverride: .blurred)

        var preview: UIImage?
        for _ in 0..<100 {
            if let rendered = store.preview(for: url) {
                preview = rendered
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }

        let rendered = try #require(preview)
        #expect(rendered.cgImage?.width == source.cgImage?.width)
        #expect(rendered.cgImage?.height == source.cgImage?.height)
        #expect(rendered.pngData() != source.pngData())
    }
}
