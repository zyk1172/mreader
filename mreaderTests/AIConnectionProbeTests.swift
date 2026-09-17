import Testing
@testable import mreader

@Suite
struct AIConnectionProbeTests {
    @Test func textProbeAcceptsChallengeInsideMinimalFormatting() {
        let challenge = "MRABC234"
        #expect(AITextConnectionProbe.response("`MR-ABC234`", contains: challenge))
        #expect(!AITextConnectionProbe.response("OTHER", contains: challenge))
        #expect(!AITextConnectionProbe.response("ANYTHING", contains: ""))
    }

    @Test func visionProbeRequiresTheImageChallenge() {
        let challenge = "AB12CD"
        #expect(AIVisionConnectionProbe.response("AB12CD", contains: challenge))
        #expect(!AIVisionConnectionProbe.response("UNREADABLE", contains: challenge))
    }

    @Test func defaultVisionPromptKeepsSingleBubbleAndStrictGeometryContract() {
        let prompt = AITranslator.defaultVisionTranslationPromptTemplate
        #expect(prompt.contains("同一气泡"))
        #expect(prompt.contains("bubbleBox"))
        #expect(prompt.contains("null"))
        #expect(prompt.contains("layoutSafeRegion"))
        #expect(prompt.contains("translationLines"))
        #expect(prompt.contains("{targetLanguage}"))
        #expect(prompt.contains("{readingOrder}"))
    }
}
