import CoreGraphics
import Foundation
import PDFKit
import Testing
import UIKit
@testable import mreader

@Suite(.serialized)
@MainActor
struct ComicAuditFixTests {
    @Test(arguments: [Float(0.95), Float(0.70)])
    func pageContainerCannotDeleteChildrenBeforeFusion(parentConfidence: Float) {
        let parent = region(CGRect(x: 0, y: 0, width: 1, height: 1), confidence: parentConfidence)
        let children = [CGFloat(0.05), 0.375, 0.70].map {
            region(CGRect(x: 0.05, y: $0, width: 0.90, height: 0.25), confidence: 0.90)
        }
        let kept = MangaVisionCalibrationProfile.bundled.deduplicated([parent] + children, type: .panel)
        #expect(kept.count == 4)
        let navigation = PanelCandidateFusion.resolve(geometry: [], model: kept.map {
            DetectedPanel(rect: $0.normalizedRect, confidence: $0.confidence, source: .coreML)
        }, contentBounds: CGRect(x: 0, y: 0, width: 1, height: 1))
        #expect(navigation.panels.count == 3)
        #expect(navigation.panels.allSatisfy { $0.source == .coreML })
        for child in children { #expect(navigation.panels.contains { $0.rect == child.normalizedRect }) }
    }

    @Test func genuineInsetSurvivesWhileRepeatedTileBoxDeduplicates() {
        let parent = region(CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8), confidence: 0.95)
        let inset = region(CGRect(x: 0.6, y: 0.6, width: 0.2, height: 0.2), confidence: 0.85)
        let duplicate = region(CGRect(x: 0.605, y: 0.60, width: 0.20, height: 0.20), confidence: 0.8)
        let kept = MangaVisionCalibrationProfile.bundled.deduplicated([parent, inset, duplicate], type: .panel)
        #expect(kept.count == 2)
        #expect(kept.contains { $0.normalizedRect == inset.normalizedRect })
    }

    @Test(arguments: [CGFloat(20_000), CGFloat(40_000)])
    func localPanelDoesNotDisappearWhenPageGetsLonger(height: CGFloat) {
        let size = CGSize(width: 800, height: height)
        let panel = DetectedPanel(rect: CGRect(x: 0.05, y: 1200/height, width: 0.9, height: 600/height),
                                  confidence: 0.9, source: .coreML)
        #expect(PanelPostProcessor.process([panel], pageSize: size).count == 1)
        let windows = LongPageGeometry.windows(sourceSize: size)
        #expect(windows.count > 6)
        #expect(windows.first?.minY == 0)
        #expect(abs((windows.last?.maxY ?? 0) - 1) < 0.000_001)
        #expect(windows.allSatisfy { $0.height * height / 800 <= 2.500_001 })
        for pair in zip(windows, windows.dropFirst()) { #expect(pair.0.maxY > pair.1.minY) }
    }

    @Test func geometryFindsRealPanelsInTwentyThousandPixelStrip() throws {
        let size = CGSize(width: 800, height: 20_000)
        let image = render(size: size) { context in
            UIColor.white.setFill(); context.fill(CGRect(origin: .zero, size: size))
            for y in stride(from: 100, to: 19_400, by: 750) {
                UIColor(white: 0.35, alpha: 1).setFill()
                context.fill(CGRect(x: 40, y: y, width: 720, height: 600))
                UIColor.black.setStroke()
                context.cgContext.setLineWidth(5)
                context.cgContext.stroke(CGRect(x: 40, y: y, width: 720, height: 600))
            }
        }
        let panels = try GeometryPanelDetector().detectPanels(in: #require(image.cgImage))
        #expect(panels.count >= 20)
        #expect(panels.allSatisfy { $0.source == .pageGeometry })
        #expect(panels.allSatisfy { $0.rect.height < 0.06 })
        #expect(PanelLayoutQuality.isUsable(panels, pageSize: size))
    }

    @Test func ellipseSafeRectangleExcludesBoundingBoxCornersAndFitsCompleteText() throws {
        let polygon = (0..<80).map { index in
            let theta = CGFloat(index) * .pi * 2 / 80
            return CGPoint(x: 100 + cos(theta)*100, y: 60 + sin(theta)*60)
        }
        let safe = try #require(BubbleContourGeometry.safeRectangle(polygon: polygon,
            bounds: CGRect(x: 0, y: 0, width: 200, height: 120)))
        for y in stride(from: safe.minY, through: safe.maxY, by: 2) {
            for x in stride(from: safe.minX, through: safe.maxX, by: 2) {
                #expect(pow((x-100)/100, 2) + pow((y-60)/60, 2) < 1)
            }
        }
        for orientation in [TextOrientation.horizontal, .vertical] {
            let measured = TranslationTypesetter.measurement(text: "完整译文", fontSize: 12,
                bounds: safe.size, orientation: orientation, lineSpacing: 2)
            #expect(measured.fitsAllText)
        }
    }

    @Test func concaveSafeRectangleCannotBridgeTheNotch() throws {
        let points = [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0), CGPoint(x: 100, y: 100),
                      CGPoint(x: 60, y: 100), CGPoint(x: 60, y: 35), CGPoint(x: 40, y: 35),
                      CGPoint(x: 40, y: 100), CGPoint(x: 0, y: 100)]
        let safe = try #require(BubbleContourGeometry.safeRectangle(polygon: points,
            bounds: CGRect(x: 0, y: 0, width: 100, height: 100)))
        #expect(!safe.intersects(CGRect(x: 40, y: 35, width: 20, height: 65)))
    }

    @Test func closedLightBalloonUsesPixelContourAndOpenRegionDeclines() throws {
        let size = CGSize(width: 300, height: 400)
        let image = render(size: size) { context in
            UIColor(white: 0.3, alpha: 1).setFill(); context.fill(CGRect(origin: .zero, size: size))
            UIColor.white.setFill()
            let ellipse = UIBezierPath(ovalIn: CGRect(x: 60, y: 70, width: 180, height: 220))
            ellipse.fill(); UIColor.black.setStroke(); ellipse.lineWidth = 5; ellipse.stroke()
            UIColor.black.setFill(); context.fill(CGRect(x: 115, y: 145, width: 60, height: 10))
        }
        let balloon = CGRect(x: 0.15, y: 0.15, width: 0.70, height: 0.65)
        let text = CGRect(x: 115/300.0, y: 145/400.0, width: 60/300.0, height: 10/400.0)
        let contour = try #require(LocalBubbleContour.recover(in: #require(image.cgImage), balloon: balloon, textRegions: [text]))
        #expect(contour.count >= 8)
        #expect(contour.map(\.y).min()! < 0.20)
        #expect(contour.map(\.y).max()! < 0.75)
        let blank = render(size: size) { context in UIColor.white.setFill(); context.fill(CGRect(origin: .zero, size: size)) }
        #expect(LocalBubbleContour.recover(in: #require(blank.cgImage), balloon: balloon, textRegions: [text]) == nil)
    }

    @Test func cancelledImageEntryCannotBeJoinedAndReplacementHasOwnIdentity() async {
        let oldTask = Task<UIImage?, Never> { try? await Task.sleep(for: .seconds(60)); return nil }
        let old = ReaderImageLoadEntry(task: oldTask)
        oldTask.cancel()
        let replacement = ReaderImageLoadEntry(task: Task { nil })
        #expect(!old.canJoin)
        #expect(replacement.canJoin)
        #expect(old.id != replacement.id)
        _ = await oldTask.value
    }

    @Test func offlineRefinementPreservesIndependentSafeRegion() {
        let safe = CGRect(x: 0.15, y: 0.16, width: 0.30, height: 0.20)
        var vision = TextBlock(text: "hello", boundingBox: CGRect(x: 0.2, y: 0.2, width: 0.1, height: 0.05), translation: "你好")
        vision.layoutSafeRegion = safe
        vision.bubbleBox = CGRect(x: 0.1, y: 0.1, width: 0.4, height: 0.3)
        vision.bubblePolygon = [CGPoint(x: 0.1, y: 0.1), CGPoint(x: 0.5, y: 0.1), CGPoint(x: 0.3, y: 0.4)]
        let local = TextBlock(text: "hello", boundingBox: CGRect(x: 0.21, y: 0.20, width: 0.1, height: 0.05))
        let refined = TranslationGeometryRefiner.refine(visionBlocks: [vision], localOCRBlocks: [local], isRightToLeft: false)[0]
        #expect(refined.boundingBox == local.boundingBox)
        #expect(refined.layoutSafeRegion == safe)
        #expect(refined.bubblePolygon == vision.bubblePolygon)
        #expect(refined.translation == vision.translation)
        #expect(refined.id == vision.id)
    }

    @Test func unauthorizedHeaderCannotCreateOrWriteBodyFile() throws {
        enum Rejection: Error { case unauthorized }
        let state = HTTPRequestReceiveState { _ in throw Rejection.unauthorized }
        defer { state.cleanup() }
        var rejected = false
        do { try state.append(Data("POST /wrong/upload HTTP/1.1\r\nContent-Length: 4\r\n\r\nbody".utf8)) }
        catch Rejection.unauthorized { rejected = true }
        #expect(rejected)
        #expect(state.bodyFileURL == nil)
        #expect(state.receivedBodyBytes == 0)
    }

    @Test func pdfPageDescriptorsAreLazyAndReadOnly() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("book.pdf")
        let document = PDFDocument()
        let image = render(size: CGSize(width: 100, height: 150)) { context in
            UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 100, height: 150))
        }
        for i in 0..<20 { document.insert(try #require(PDFPage(image: image)), at: i) }
        #expect(document.write(to: url))
        let before = try Data(contentsOf: url)
        let pages = ComicManager.pdfPages(from: url)
        #expect(pages.count == 20)
        #expect(pages.allSatisfy { $0.url.scheme == "mreader-pdf" })
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["book.pdf"])
        #expect(ComicManager.imagePixelSizeForArchivePageURL(pages[7].url) != nil)
        #expect(ComicManager.imageData(forArchivePageURL: pages[7].url) != nil)
        #expect(try Data(contentsOf: url) == before)
    }

    @Test func veryLowHeadroomDoesNotForceCacheFloorsAboveAvailableMemory() {
        let budget = ReaderMemoryBudgetPlanner.budget(forPhysicalMemoryBytes: 8 * 1024 * 1024 * 1024,
            availableMemoryBytes: 32 * 1024 * 1024)
        #expect(budget.decodedImageCacheMB + budget.remotePageDataCacheMB < 32)
        #expect(budget.decodedImagePreloadMB < budget.decodedImageCacheMB)
        #expect(budget.remotePrefetchMB < 32)
    }

    private func region(_ rect: CGRect, confidence: Float) -> MangaVisionRegion {
        MangaVisionRegion(type: .panel, normalizedRect: rect, confidence: confidence)
    }
    private func render(size: CGSize, body: (UIGraphicsImageRendererContext) -> Void) -> UIImage {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image(actions: body)
    }
}
