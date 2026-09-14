from pathlib import Path


def replace_once(path: str, old: str, new: str) -> None:
    p = Path(path)
    text = p.read_text()
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{path}: expected exactly one match, found {count}\n--- old ---\n{old}")
    p.write_text(text.replace(old, new, 1))


# 1) Persist a Guided Panel-specific direction, inheriting the normal reading
# direction for existing comics and callers that do not specify it.
comic = "mreader/ComicBook.swift"
replace_once(
    comic,
    "    var readingDirectionRaw: String\n    var readingModeRaw: String\n",
    "    var readingDirectionRaw: String\n    /// Guided Panel keeps its own ordering direction so changing panel flow does not alter normal page turns.\n    var guidedPanelReadingDirectionRaw: String\n    var readingModeRaw: String\n",
)
replace_once(
    comic,
    'hasInitializedReadingPreset: Bool = false, readingDirectionRaw: String = "leftToRight", readingModeRaw: String = "horizontalPage"',
    'hasInitializedReadingPreset: Bool = false, readingDirectionRaw: String = "leftToRight", guidedPanelReadingDirectionRaw: String? = nil, readingModeRaw: String = "horizontalPage"',
)
replace_once(
    comic,
    "        self.readingDirectionRaw = readingDirectionRaw\n        self.readingModeRaw = readingModeRaw\n",
    "        self.readingDirectionRaw = readingDirectionRaw\n        self.guidedPanelReadingDirectionRaw = guidedPanelReadingDirectionRaw ?? readingDirectionRaw\n        self.readingModeRaw = readingModeRaw\n",
)
replace_once(
    comic,
    '        readingDirectionRaw = try container.decodeIfPresent(String.self, forKey: .readingDirectionRaw) ?? "leftToRight"\n        readingModeRaw = try container.decodeIfPresent(String.self, forKey: .readingModeRaw) ?? "horizontalPage"\n',
    '        readingDirectionRaw = try container.decodeIfPresent(String.self, forKey: .readingDirectionRaw) ?? "leftToRight"\n        guidedPanelReadingDirectionRaw = try container.decodeIfPresent(String.self, forKey: .guidedPanelReadingDirectionRaw) ?? readingDirectionRaw\n        readingModeRaw = try container.decodeIfPresent(String.self, forKey: .readingModeRaw) ?? "horizontalPage"\n',
)

# 2) Reader uses the dedicated direction and exposes it in settings.
reader = "mreader/ReaderView.swift"
replace_once(
    reader,
    "    private var readingDirection: ReadingDirection {\n        ReadingDirection(rawValue: comic.readingDirectionRaw) ?? .leftToRight\n    }\n\n    private var pageTurnAnimation: PageTurnAnimation {\n",
    "    private var readingDirection: ReadingDirection {\n        ReadingDirection(rawValue: comic.readingDirectionRaw) ?? .leftToRight\n    }\n\n    private var guidedPanelReadingDirection: ReadingDirection {\n        ReadingDirection(rawValue: comic.guidedPanelReadingDirectionRaw) ?? readingDirection\n    }\n\n    private var pageTurnAnimation: PageTurnAnimation {\n",
)
replace_once(
    reader,
    "    private var readingDirectionRaw: Binding<String> {\n        Binding(\n            get: { comic.readingDirectionRaw },\n            set: { newValue in updateComic { $0.readingDirectionRaw = newValue; $0.hasInitializedReadingPreset = true } }\n        )\n    }\n\n    private var scrollSpeedRaw: Binding<String> {\n",
    "    private var readingDirectionRaw: Binding<String> {\n        Binding(\n            get: { comic.readingDirectionRaw },\n            set: { newValue in updateComic { $0.readingDirectionRaw = newValue; $0.hasInitializedReadingPreset = true } }\n        )\n    }\n\n    private var guidedPanelReadingDirectionRaw: Binding<String> {\n        Binding(\n            get: { comic.guidedPanelReadingDirectionRaw },\n            set: { newValue in updateComic { $0.guidedPanelReadingDirectionRaw = newValue; $0.hasInitializedReadingPreset = true } }\n        )\n    }\n\n    private var scrollSpeedRaw: Binding<String> {\n",
)
replace_once(
    reader,
    "                    readingDirection: readingDirection,\n                    comic: comic,\n",
    "                    readingDirection: guidedPanelReadingDirection,\n                    comic: comic,\n",
)
replace_once(
    reader,
    "                    Picker(\"reader.scrollSpeed\".localized, selection: scrollSpeedRaw) {\n                        Label(\"reader.scrollSpeed.slow\".localized, systemImage: \"tortoise\").tag(ScrollSpeed.slow.rawValue)\n                        Label(\"reader.scrollSpeed.standard\".localized, systemImage: \"circle\").tag(ScrollSpeed.standard.rawValue)\n                        Label(\"reader.scrollSpeed.fast\".localized, systemImage: \"hare\").tag(ScrollSpeed.fast.rawValue)\n                    }\n                }\n            }\n",
    "                    Picker(\"reader.scrollSpeed\".localized, selection: scrollSpeedRaw) {\n                        Label(\"reader.scrollSpeed.slow\".localized, systemImage: \"tortoise\").tag(ScrollSpeed.slow.rawValue)\n                        Label(\"reader.scrollSpeed.standard\".localized, systemImage: \"circle\").tag(ScrollSpeed.standard.rawValue)\n                        Label(\"reader.scrollSpeed.fast\".localized, systemImage: \"hare\").tag(ScrollSpeed.fast.rawValue)\n                    }\n                }\n\n                Section(\n                    header: Text(\"reader.guidedPanel.settings\".localized),\n                    footer: Text(\"reader.guidedPanel.directionFooter\".localized)\n                ) {\n                    Picker(\"reader.guidedPanel.direction\".localized, selection: guidedPanelReadingDirectionRaw) {\n                        Label(\"reader.direction.leftToRight\".localized, systemImage: \"arrow.right\")\n                            .tag(ReadingDirection.leftToRight.rawValue)\n                        Label(\"reader.direction.rightToLeft\".localized, systemImage: \"arrow.left\")\n                            .tag(ReadingDirection.rightToLeft.rawValue)\n                    }\n                    .accessibilityIdentifier(\"mreader.reader.guidedPanelDirectionPicker\")\n                }\n            }\n",
)

# 3) Make the Guided Panel camera movement explicit and directional. The existing
# transform already knows where the next panel is; the spring interpolation makes
# the page visibly pan/zoom from the old panel to the new one instead of snapping.
replace_once(
    reader,
    "struct GuidedPanelReader: View {\n    let pages: [ComicPage]\n",
    "struct GuidedPanelReader: View {\n    @Environment(\\.accessibilityReduceMotion) private var reduceMotion\n\n    let pages: [ComicPage]\n",
)
replace_once(
    reader,
    "    @State private var isDetecting = false\n    @State private var enterCurrentPageAtLastPanel = false\n\n    private var currentPage: ComicPage? {\n",
    "    @State private var isDetecting = false\n    @State private var enterCurrentPageAtLastPanel = false\n    @State private var panelNavigationDirection = 1\n\n    private var panelCameraAnimation: Animation? {\n        reduceMotion ? nil : .spring(response: 0.46, dampingFraction: 0.88)\n    }\n\n    private var pageTransition: AnyTransition {\n        guard !reduceMotion else { return .opacity }\n        let forward = panelNavigationDirection >= 0\n        let forwardInsertion: Edge = readingDirection == .rightToLeft ? .leading : .trailing\n        let forwardRemoval: Edge = readingDirection == .rightToLeft ? .trailing : .leading\n        return .asymmetric(\n            insertion: .move(edge: forward ? forwardInsertion : forwardRemoval).combined(with: .opacity),\n            removal: .move(edge: forward ? forwardRemoval : forwardInsertion).combined(with: .opacity)\n        )\n    }\n\n    private var currentPage: ComicPage? {\n",
)
replace_once(
    reader,
    "        GeometryReader { proxy in\n            ZStack {\n                if let page = currentPage {\n                    LocalImageView(\n",
    "        GeometryReader { proxy in\n            let camera = panelTransform(in: proxy.size)\n            ZStack {\n                if let page = currentPage {\n                    LocalImageView(\n",
)
replace_once(
    reader,
    "                    .id(page.url)\n                    .scaleEffect(panelTransform(in: proxy.size).scale)\n                    .offset(panelTransform(in: proxy.size).offset)\n                    .animation(.easeInOut(duration: 0.34), value: panelIndex)\n                    .animation(.easeInOut(duration: 0.28), value: currentPageIndex)\n                    .task(id: page.url) { await detectPanels(for: page) }\n",
    "                    .id(page.url)\n                    .scaleEffect(camera.scale)\n                    .offset(camera.offset)\n                    .transition(pageTransition)\n                    .animation(panelCameraAnimation, value: panelIndex)\n                    .animation(panelCameraAnimation, value: currentPageIndex)\n                    .task(id: \"\\(page.url.absoluteString)|\\(readingDirection.rawValue)\") {\n                        await detectPanels(for: page)\n                    }\n",
)
replace_once(
    reader,
    "    private func previousPanel() {\n        guard !isDetecting else { return }\n        if panelIndex > 0 {\n            panelIndex -= 1\n            HapticManager.shared.play(.light)\n        } else if currentPageIndex > 0 {\n            moveToPage(currentPageIndex - 1, enterAtLastPanel: true)\n        } else {\n            HapticManager.shared.play(.warning)\n        }\n    }\n\n    private func nextPanel() {\n        guard !isDetecting else { return }\n        let count = max(layout?.panels.count ?? 1, 1)\n        if panelIndex + 1 < count {\n            panelIndex += 1\n            HapticManager.shared.play(.light)\n        } else if currentPageIndex + 1 < pages.count {\n            moveToPage(currentPageIndex + 1, enterAtLastPanel: false)\n        } else {\n            HapticManager.shared.play(.warning)\n        }\n    }\n",
    "    private func previousPanel() {\n        guard !isDetecting else { return }\n        panelNavigationDirection = -1\n        if panelIndex > 0 {\n            withAnimation(panelCameraAnimation) {\n                panelIndex -= 1\n            }\n            HapticManager.shared.play(.light)\n        } else if currentPageIndex > 0 {\n            moveToPage(currentPageIndex - 1, enterAtLastPanel: true)\n        } else {\n            HapticManager.shared.play(.warning)\n        }\n    }\n\n    private func nextPanel() {\n        guard !isDetecting else { return }\n        panelNavigationDirection = 1\n        let count = max(layout?.panels.count ?? 1, 1)\n        if panelIndex + 1 < count {\n            withAnimation(panelCameraAnimation) {\n                panelIndex += 1\n            }\n            HapticManager.shared.play(.light)\n        } else if currentPageIndex + 1 < pages.count {\n            moveToPage(currentPageIndex + 1, enterAtLastPanel: false)\n        } else {\n            HapticManager.shared.play(.warning)\n        }\n    }\n",
)
replace_once(
    reader,
    "        layout = nil\n        sourceSize = .zero\n        panelIndex = 0\n        enterCurrentPageAtLastPanel = enterAtLastPanel\n        isDetecting = true\n        currentPageIndex = pageIndex\n        HapticManager.shared.play(.light)\n",
    "        panelNavigationDirection = pageIndex >= currentPageIndex ? 1 : -1\n        layout = nil\n        sourceSize = .zero\n        panelIndex = 0\n        enterCurrentPageAtLastPanel = enterAtLastPanel\n        isDetecting = true\n        withAnimation(panelCameraAnimation) {\n            currentPageIndex = pageIndex\n        }\n        HapticManager.shared.play(.light)\n",
)

# 4) Localized setting labels.
for path, marker, addition in [
    (
        "mreader/zh-Hans.lproj/Localizable.strings",
        '"reader.direction.rightToLeft" = "从右到左";\n',
        '"reader.direction.rightToLeft" = "从右到左";\n"reader.guidedPanel.settings" = "分镜阅读";\n"reader.guidedPanel.direction" = "分镜阅读方向";\n"reader.guidedPanel.directionFooter" = "仅影响分镜的识别排序和切换方向，不改变普通翻页的阅读方向。";\n',
    ),
    (
        "mreader/en.lproj/Localizable.strings",
        '"reader.direction.rightToLeft" = "Right to Left";\n',
        '"reader.direction.rightToLeft" = "Right to Left";\n"reader.guidedPanel.settings" = "Guided Panel";\n"reader.guidedPanel.direction" = "Guided Panel Direction";\n"reader.guidedPanel.directionFooter" = "Controls panel ordering and Guided Panel navigation only. Normal page-turn direction is unchanged.";\n',
    ),
]:
    replace_once(path, marker, addition)

# 5) Small regression test for independent/default direction persistence.
tests = "mreaderTests/GuidedPanelFoundationTests.swift"
replace_once(
    tests,
    "    @Test func viewportAddsContextWithoutLeavingPageBounds() {\n",
    "    @Test func guidedPanelDirectionDefaultsToNormalDirectionButCanBeIndependent() {\n        let inherited = ComicBook(\n            title: \"Direction Test\",\n            bookmarkData: Data(),\n            totalPages: 1,\n            readingDirectionRaw: ReadingDirection.rightToLeft.rawValue\n        )\n        #expect(inherited.guidedPanelReadingDirectionRaw == ReadingDirection.rightToLeft.rawValue)\n\n        let independent = ComicBook(\n            title: \"Direction Test\",\n            bookmarkData: Data(),\n            totalPages: 1,\n            readingDirectionRaw: ReadingDirection.leftToRight.rawValue,\n            guidedPanelReadingDirectionRaw: ReadingDirection.rightToLeft.rawValue\n        )\n        #expect(independent.readingDirectionRaw == ReadingDirection.leftToRight.rawValue)\n        #expect(independent.guidedPanelReadingDirectionRaw == ReadingDirection.rightToLeft.rawValue)\n    }\n\n    @Test func viewportAddsContextWithoutLeavingPageBounds() {\n",
)

print("guided panel direction + motion patch applied")
