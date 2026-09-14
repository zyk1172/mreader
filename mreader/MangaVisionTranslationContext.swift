import Foundation

nonisolated enum MangaVisionTranslationContext {
    static func context(
        for request: AITranslationPageRequest,
        blocks: [TextBlock]
    ) async -> String {
        guard let analysis = try? await MangaVisionService.shared.analysis(
            comicID: request.comicID,
            pageIndex: request.pageIndex,
            pageURL: request.pageURL,
            image: request.image
        ) else {
            return request.previousContext
        }
        let semanticPage = MangaSemanticAnalyzer.makeSemanticPage(
            from: analysis,
            isRightToLeft: request.isRightToLeft
        )
        let semanticContext = MangaSemanticAnalyzer.translationContext(
            semanticPage: semanticPage,
            blocks: blocks
        )
        return TranslationContextBuilder.mergeContexts([
            request.previousContext,
            semanticContext
        ])
    }
}
