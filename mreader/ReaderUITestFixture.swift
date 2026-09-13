import Foundation
import UIKit

/// 仅在 UI 测试通过 launch argument 请求时创建的本地 Reader fixture。
///
/// CI 不依赖开发机上的书库或 NAS：fixture 放在临时目录中，并通过普通安全范围
/// bookmark 交给既有 ComicManager 页面加载路径，Reader 本身仍走真实的加载、手势
/// 和保存生命周期。没有该 launch argument 时不会创建文件，也不会改变正常书架。
@MainActor
enum ReaderUITestFixture {
    static let launchArgument = "-mreader-ui-testing"

    static var isEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains(launchArgument)
    }

    static func makeComic(force: Bool = false) -> ComicBook? {
        guard force || isEnabled else { return nil }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MReaderUITestReader", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            for (index, color) in [UIColor.systemIndigo, UIColor.systemTeal].enumerated() {
                let pageURL = root.appendingPathComponent(String(format: "%02d.png", index + 1))
                if !FileManager.default.fileExists(atPath: pageURL.path) {
                    try pageData(color: color).write(to: pageURL, options: .atomic)
                }
            }
            let bookmarkData = try root.bookmarkData(
                options: [],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            let firstPage = root.appendingPathComponent("01.png")
            return ComicBook(
                id: UUID(uuidString: "A0D0C0DE-7E57-4D2C-9B2A-7D6F2C2B9E01")!,
                title: "UI Test Reader",
                bookmarkData: bookmarkData,
                totalPages: 2,
                coverImagePath: firstPage.path,
                fileSize: 2,
                libraryPath: root.path,
                libraryRelativePath: root.lastPathComponent,
                sourceTypeRaw: ComicSourceType.local.rawValue,
                chapterTypeRaw: ComicManager.ChapterType.folder.rawValue,
                chapterPath: root.path,
                currentPageIndex: 0,
                furthestPageIndex: 0,
                progressUpdatedAt: Date.distantPast,
                metadataUpdatedAt: Date.distantPast,
                hasBeenOpened: true,
                isOCREnabled: false,
                isAITranslationEnabled: false,
                hasInitializedReadingPreset: true,
                readingModeRaw: ReadingMode.horizontalPage.rawValue,
                pageTurnAnimationRaw: PageTurnAnimation.slide.rawValue,
                imageFitModeRaw: ImageFitMode.fitScreen.rawValue
            )
        } catch {
            return nil
        }
    }

    private static func pageData(color: UIColor) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 720, height: 1_080), format: format)
        return renderer.pngData { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 720, height: 1_080))
            UIColor.white.withAlphaComponent(0.86).setFill()
            context.fill(CGRect(x: 90, y: 180, width: 540, height: 720))
        }
    }
}
