from pathlib import Path

p = Path("mreader/ReaderView.swift")
s = p.read_text()

def replace_once(old, new, label):
    global s
    count = s.count(old)
    if count != 1:
        raise RuntimeError(f"{label}: expected one match, got {count}")
    s = s.replace(old, new, 1)

replace_once(
    '''    @State private var uiImage: UIImage? = nil
    @State private var isLoadingImage = true
''',
    '''    @State private var uiImage: UIImage? = nil
#if DEBUG
    @State private var mangaVisionDebugAnalysis: MangaPageAnalysis?
    @AppStorage("manga_vision_debug_panels") private var mangaVisionDebugPanels = true
    @AppStorage("manga_vision_debug_texts") private var mangaVisionDebugTexts = true
    @AppStorage("manga_vision_debug_faces") private var mangaVisionDebugFaces = true
    @AppStorage("manga_vision_debug_bodies") private var mangaVisionDebugBodies = true
    @AppStorage("manga_vision_debug_relations") private var mangaVisionDebugRelations = true
#endif
    @State private var isLoadingImage = true
''',
    "debug state",
)

replace_once(
    '''                                ocrMagnificationOverlay(in: geo.size)
                                ocrDebugOverlay(in: geo.size)
''',
    '''                                ocrMagnificationOverlay(in: geo.size)
                                ocrDebugOverlay(in: geo.size)
#if DEBUG
                                mangaVisionDebugOverlay(in: geo.size)
#endif
''',
    "debug overlay stack",
)

marker = '''    @ViewBuilder
    private func ocrDebugOverlay(in size: CGSize) -> some View {
'''
helper = '''#if DEBUG
    @ViewBuilder
    private func mangaVisionDebugOverlay(in size: CGSize) -> some View {
        if ocrShowDebugBoxes, let analysis = mangaVisionDebugAnalysis {
            MangaVisionDebugOverlay(
                analysis: analysis,
                semanticPage: MangaSemanticAnalyzer.makeSemanticPage(
                    from: analysis,
                    isRightToLeft: isRightToLeftReading
                ),
                imageRect: ocrDisplayTransform(in: size).imageRect,
                configuration: MangaVisionDebugOverlayConfiguration(
                    showsPanels: mangaVisionDebugPanels,
                    showsTexts: mangaVisionDebugTexts,
                    showsFaces: mangaVisionDebugFaces,
                    showsBodies: mangaVisionDebugBodies,
                    showsRelations: mangaVisionDebugRelations
                )
            )
        }
    }
#endif

'''
if marker not in s:
    raise RuntimeError("ocr debug overlay marker missing")
s = s.replace(marker, helper + marker, 1)

replace_once(
    '''        let localResult = try await OCRRuntimeService.recognize(for: cacheRequest)
        if let comicID, let pageIndex {
''',
    '''        let localResult = try await OCRRuntimeService.recognize(for: cacheRequest)
#if DEBUG
        if ocrShowDebugBoxes,
           let analysis = try? await MangaVisionService.shared.analysis(
                comicID: comicID,
                pageIndex: pageIndex,
                pageURL: url,
                image: image
           ) {
            await MainActor.run {
                self.mangaVisionDebugAnalysis = analysis
            }
        }
#endif
        if let comicID, let pageIndex {
''',
    "debug analysis capture",
)

p.write_text(s)
print("Manga Vision Reader debug overlay integrated")
