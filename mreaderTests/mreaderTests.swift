//
//  mreaderTests.swift
//  mreaderTests
//
//  Created by 郑云凯 on 2026/6/17.
//

import Testing
import Foundation
import CoreGraphics
import UIKit
import Vision
import ZIPFoundation
@testable import mreader

@Suite(.serialized)
struct mreaderTests {

    @Test func translationTargetsMigrateLegacyChineseWithoutDuplicateOption() {
        #expect(TranslationTargetLanguage.migrateLegacyValue("中文") == .simplifiedChinese)
        #expect(TranslationTargetLanguage.migrateLegacyValue("简体中文") == .simplifiedChinese)
        #expect(TranslationTargetLanguage.migrateLegacyValue("繁体中文") == .traditionalChinese)
        #expect(TranslationTargetLanguage.migrateLegacyValue("英文") == .english)
        #expect(TranslationTargetLanguage.migrateLegacyValue("日文") == .japanese)
        #expect(TranslationTargetLanguage.migrateLegacyValue("韩文") == .korean)
    }

    @Test func translationTargetsHaveStableUniqueIdentifiers() {
        let targets = TranslationTargetLanguage.allCases

        #expect(targets.count == 15)
        #expect(Set(targets.map(\.rawValue)).count == targets.count)
        #expect(targets.allSatisfy { $0.modelInstruction.contains($0.rawValue) })
    }

    @Test func aiModelCatalogMapsOpenCodeGoProtocolsAndPrefixes() {
        #expect(AIModelProtocolCatalog.descriptor(for: "mimo-v2.5").apiProtocol == .openAIChatCompletions)
        #expect(AIModelProtocolCatalog.descriptor(for: "muse-spark-1.2-contributor").apiProtocol == .openAIResponses)
        #expect(AIModelProtocolCatalog.descriptor(for: "minimax-m3").apiProtocol == .anthropicMessages)
        #expect(AIModelProtocolCatalog.descriptor(for: "qwen3.7-plus").apiProtocol == .anthropicMessages)
        #expect(AIModelProtocolCatalog.descriptor(for: "opencode-go/muse-spark-1.2-contributor").apiProtocol == .openAIResponses)
    }

    @Test func aiProviderProfileMigratesLegacyModelsToChatAndRoundTripsDescriptors() throws {
        let legacyProfile = AIProviderProfile.normalized(
            name: "legacy",
            baseURL: "https://api.example.test/v1",
            modelsText: "muse-spark-1.2-contributor\nmimo-v2.5",
            selectedTextModel: "mimo-v2.5",
            selectedVisionModel: "mimo-v2.5",
            modelDescriptors: [
                AIModelDescriptor(
                    id: "muse-spark-1.2-contributor",
                    apiProtocol: .openAIResponses,
                    supportsVision: true
                )
            ]
        )
        let encoded = try JSONEncoder().encode(legacyProfile)
        var legacyObject = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        legacyObject.removeValue(forKey: "modelDescriptors")
        let legacyData = try JSONSerialization.data(withJSONObject: legacyObject)
        let migrated = try JSONDecoder().decode(AIProviderProfile.self, from: legacyData)
        #expect(migrated.modelDescriptors.allSatisfy { $0.apiProtocol == .openAIChatCompletions })

        let roundTripData = try JSONEncoder().encode(legacyProfile)
        let roundTripped = try JSONDecoder().decode(AIProviderProfile.self, from: roundTripData)
        #expect(roundTripped.modelDescriptors.first?.apiProtocol == .openAIResponses)
        #expect(roundTripped.modelDescriptors.first?.supportsVision == true)
    }

    @Test func aiEndpointResolverReplacesEveryKnownEndpointFamily() {
        let base = "https://api.example.test/v1"
        #expect(AIEndpointResolver.endpointURL(for: .openAIChatCompletions, from: base)?.absoluteString == "https://api.example.test/v1/chat/completions")
        #expect(AIEndpointResolver.endpointURL(for: .openAIResponses, from: base)?.absoluteString == "https://api.example.test/v1/responses")
        #expect(AIEndpointResolver.endpointURL(for: .anthropicMessages, from: base)?.absoluteString == "https://api.example.test/v1/messages")
        #expect(AIEndpointResolver.endpointURL(for: .openAIResponses, from: "https://api.example.test/v1/chat/completions")?.absoluteString == "https://api.example.test/v1/responses")
        #expect(AIEndpointResolver.endpointURL(for: .anthropicMessages, from: "https://api.example.test/v1/messages")?.absoluteString == "https://api.example.test/v1/messages")
    }

    @Test func aiResponseDecoderSupportsChatResponsesAndAnthropic() throws {
        let chat = try JSONSerialization.data(withJSONObject: [
            "choices": [["message": ["content": "chat answer"], "finish_reason": "stop"]]
        ])
        let responses = try JSONSerialization.data(withJSONObject: [
            "output_text": "responses answer"
        ])
        let anthropic = try JSONSerialization.data(withJSONObject: [
            "content": [["type": "text", "text": "anthropic answer"]],
            "stop_reason": "end_turn"
        ])

        #expect(AIChatResponseDecoder.decode(chat).content == "chat answer")
        #expect(AIChatResponseDecoder.decode(responses).content == "responses answer")
        #expect(AIChatResponseDecoder.decode(anthropic).content == "anthropic answer")
        #expect(AIChatResponseDecoder.decode(anthropic).finishReason == "end_turn")
    }

    @Test func aiTranslationClientBuildsChatCompletionsRequest() async throws {
        AITransportRecordingURLProtocol.configure(responseData: Data(#"{"output_text":"ok"}"#.utf8))
        let client = AITranslationClient(
            apiKey: "secret",
            baseURL: "https://api.example.test/v1",
            session: aiTransportRecordingSession()
        )
        _ = try await client.send(
            AITransportRequest(
                model: AIModelDescriptor(id: "mimo-v2.5", apiProtocol: .openAIChatCompletions),
                systemPrompt: "system",
                userPrompt: "hello",
                responseFormat: .jsonObject,
                temperature: 0.2,
                maxTokens: 32
            )
        )
        guard let request = AITransportRecordingURLProtocol.lastRequest(),
              let body = try JSONSerialization.jsonObject(with: try #require(request.httpBody)) as? [String: Any] else {
            Issue.record("没有捕获 Chat Completions 请求")
            return
        }
        #expect(request.url?.absoluteString == "https://api.example.test/v1/chat/completions")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer secret")
        #expect(request.value(forHTTPHeaderField: "x-api-key") == nil)
        #expect(body["model"] as? String == "mimo-v2.5")
        #expect((body["messages"] as? [[String: Any]])?.count == 2)
        #expect((body["response_format"] as? [String: Any])?["type"] as? String == "json_object")
        #expect(body["max_tokens"] as? Int == 32)
    }

    @Test func aiTranslationClientBuildsResponsesRequestWithImage() async throws {
        AITransportRecordingURLProtocol.configure(responseData: Data(#"{"output_text":"ok"}"#.utf8))
        let client = AITranslationClient(
            apiKey: "secret",
            baseURL: "https://api.example.test/v1/chat/completions",
            session: aiTransportRecordingSession()
        )
        _ = try await client.send(
            AITransportRequest(
                model: AIModelDescriptor(id: "opencode-go/muse-spark-1.2-contributor", apiProtocol: .openAIResponses),
                systemPrompt: "instructions",
                userPrompt: "read image",
                imageDataURL: "data:image/png;base64,QUJD",
                responseFormat: .jsonSchema(name: "answer", schema: Data(#"{"type":"object"}"#.utf8)),
                temperature: 0.2,
                maxTokens: 64
            )
        )
        guard let request = AITransportRecordingURLProtocol.lastRequest(),
              let body = try JSONSerialization.jsonObject(with: try #require(request.httpBody)) as? [String: Any] else {
            Issue.record("没有捕获 Responses 请求")
            return
        }
        #expect(request.url?.absoluteString == "https://api.example.test/v1/responses")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer secret")
        #expect(body["model"] as? String == "muse-spark-1.2-contributor")
        let input = body["input"] as? [[String: Any]]
        let content = input?.first?["content"] as? [[String: Any]]
        #expect(content?.map { $0["type"] as? String } == ["input_text", "input_image"])
        #expect(body["instructions"] as? String == "instructions")
        #expect(body["max_output_tokens"] as? Int == 64)
        #expect(body["temperature"] == nil)
        let format = (body["text"] as? [String: Any])?["format"] as? [String: Any]
        #expect(format?["type"] as? String == "json_schema")
    }

    @Test func aiTranslationClientBuildsAnthropicMessagesRequestWithBase64Image() async throws {
        AITransportRecordingURLProtocol.configure(responseData: Data(#"{"content":[{"type":"text","text":"ok"}]}"#.utf8))
        let client = AITranslationClient(
            apiKey: "secret",
            baseURL: "https://api.example.test/v1/responses",
            session: aiTransportRecordingSession()
        )
        _ = try await client.send(
            AITransportRequest(
                model: AIModelDescriptor(id: "minimax-m3", apiProtocol: .anthropicMessages),
                systemPrompt: "system",
                userPrompt: "read image",
                imageDataURL: "data:image/png;base64,QUJD",
                responseFormat: .jsonObject,
                maxTokens: 32
            )
        )
        guard let request = AITransportRecordingURLProtocol.lastRequest(),
              let body = try JSONSerialization.jsonObject(with: try #require(request.httpBody)) as? [String: Any] else {
            Issue.record("没有捕获 Anthropic Messages 请求")
            return
        }
        #expect(request.url?.absoluteString == "https://api.example.test/v1/messages")
        #expect(request.value(forHTTPHeaderField: "x-api-key") == "secret")
        #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(body["system"] as? String == "system")
        let messages = body["messages"] as? [[String: Any]]
        let content = messages?.first?["content"] as? [[String: Any]]
        let source = content?.first?["source"] as? [String: Any]
        #expect(source?["type"] as? String == "base64")
        #expect(source?["media_type"] as? String == "image/png")
        #expect(source?["data"] as? String == "QUJD")
        #expect(body["max_tokens"] as? Int == 32)
        #expect(body["response_format"] == nil)
    }

    @Test @MainActor func aiProviderStoreRejectsExplicitlyUnsupportedVisionModel() throws {
        let suiteName = "mreader-ai-provider-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let credentials = InMemoryAICredentialStore()
        let store = AIProviderStore(defaults: defaults, credentials: credentials)
        let profile = AIProviderProfile.normalized(
            name: "test",
            baseURL: "https://api.example.test/v1",
            modelsText: "vision-ok\ntext-only",
            selectedTextModel: "vision-ok",
            selectedVisionModel: "vision-ok",
            modelDescriptors: [
                AIModelDescriptor(id: "vision-ok", supportsVision: true),
                AIModelDescriptor(id: "text-only", supportsVision: false)
            ]
        )
        try store.save(profile: profile, apiKey: "secret", activate: true)
        do {
            try store.setSelectedVisionModel("text-only", for: profile.id)
            Issue.record("不支持视觉的模型不应被设为视觉模型")
        } catch AIProviderStoreError.unsupportedVisionModel {
            // expected
        }
    }

    @Test func startupRemoteSyncDoesNotScanLocalLibrary() {
        #expect(LibrarySyncScope.startupRemote.contains(.komga))
        #expect(LibrarySyncScope.startupRemote.contains(.opds))
        #expect(LibrarySyncScope.startupRemote.contains(.prewarmKomga))
        #expect(!LibrarySyncScope.startupRemote.contains(.local))
    }

    @Test func remoteCoverPathPrefersCurrentCacheOverPersistedSandboxPath() {
        let sourceID = UUID()
        let bookID = "cover-path-test-\(UUID().uuidString)"
        let stalePath = "/var/mobile/Containers/Data/Application/old/MReaderRemoteCovers/cover.img"
        let cachedPath = RemoteImageLoader.cacheCoverData(Data([0x01, 0x02, 0x03]), sourceID: sourceID, bookID: bookID)
        defer { RemoteImageLoader.removeCachedImages(sourceID: sourceID, bookID: bookID) }

        #expect(cachedPath != nil)
        #expect(
            RemoteImageLoader.resolvedCoverPath(
                persistedPath: stalePath,
                sourceID: sourceID,
                bookID: bookID
            ) == cachedPath
        )
    }

    @Test func remoteCoverCacheReportsSuccessfulWriteForRefreshPropagation() {
        let sourceID = UUID()
        let bookID = "cover-refresh-test-\(UUID().uuidString)"
        defer { RemoteImageLoader.removeCachedImages(sourceID: sourceID, bookID: bookID) }

        let result = RemoteImageLoader.cacheCoverDataWithResult(
            Data([0x04, 0x05, 0x06]),
            sourceID: sourceID,
            bookID: bookID
        )

        #expect(result?.didWrite == true)
        #expect(result?.path == RemoteImageLoader.cachedCoverPath(sourceID: sourceID, bookID: bookID))
    }

    @Test @MainActor func remoteCoverRefreshPublishesEvenWhenComicFieldsAreUnchanged() {
        let comic = ComicBook(title: "cover-refresh", bookmarkData: Data(), totalPages: 1)

        #expect(!ComicLibraryStore.shouldPublishRemoteComicUpdate(
            existing: comic,
            merged: comic,
            coverWasRefreshed: false
        ))
        #expect(ComicLibraryStore.shouldPublishRemoteComicUpdate(
            existing: comic,
            merged: comic,
            coverWasRefreshed: true
        ))
    }

    @Test func pageTranslationParserRestoresRequestOrderAndKeepsPartialResults() throws {
        let expected = [
            AIPageTranslationItem(id: "bubble-a", sourceText: "遅かったね", order: 0),
            AIPageTranslationItem(id: "bubble-b", sourceText: "ごめん", order: 1),
            AIPageTranslationItem(id: "bubble-c", sourceText: "行こう", order: 2)
        ]
        let response = """
        ```json
        {"items":[
          {"id":"bubble-b","translation":"对不起"},
          {"id":"unknown","translation":"不能出现"},
          {"id":"bubble-a","translation":"你来晚了"},
          {"id":"bubble-a","translation":"重复结果"}
        ]}
        ```
        """

        let result = try AIPageTranslationParser.parse(
            response,
            expectedItems: expected,
            target: .simplifiedChinese
        )

        #expect(result.items.map(\.id) == ["bubble-a", "bubble-b"])
        #expect(result.items.map(\.translation) == ["你来晚了", "对不起"])
        #expect(result.missingIDs == ["bubble-c"])
    }

    @Test func pageTranslationValidatorRejectsClearlyWrongScript() {
        #expect(TranslationOutputValidator.isCompatible("This is correct.", target: .english))
        #expect(!TranslationOutputValidator.isCompatible("これは英語ではありません", target: .english))
        #expect(TranslationOutputValidator.isCompatible("这是正确的译文", target: .simplifiedChinese))
        #expect(!TranslationOutputValidator.isCompatible("이것은 중국어가 아닙니다", target: .simplifiedChinese))
        // 短对白也必须经过脚本冲突检查，不能因为少于 3 字而漏过目标中文校验。
        #expect(!TranslationOutputValidator.isCompatible("はい", target: .simplifiedChinese))
        #expect(!TranslationOutputValidator.isCompatible("안녕", target: .simplifiedChinese))
    }

    @Test func translationValidatorAllowsStableTokensButRejectsUntranslatedSentences() {
        #expect(TranslationOutputValidator.isAcceptableTranslation(
            "NASA", sourceText: "NASA", target: .english
        ))
        #expect(TranslationOutputValidator.isAcceptableTranslation(
            "OK", sourceText: "OK", target: .simplifiedChinese
        ))
        #expect(TranslationOutputValidator.isAcceptableTranslation(
            "iPhone", sourceText: "iPhone", target: .simplifiedChinese
        ))
        #expect(!TranslationOutputValidator.isAcceptableTranslation(
            "ありがとう", sourceText: "ありがとう", target: .simplifiedChinese
        ))
        #expect(!TranslationOutputValidator.isAcceptableTranslation(
            "这是中文", sourceText: "这是中文", target: .english
        ))
        #expect(TranslationOutputValidator.isAcceptableTranslation(
            "山田", sourceText: "山田", target: .simplifiedChinese
        ))
        #expect(!TranslationOutputValidator.isAcceptableTranslation(
            "大丈夫", sourceText: "大丈夫", target: .korean
        ))
        #expect(!TranslationOutputValidator.isAcceptableTranslation(
            "没有", sourceText: "没有", target: .japanese
        ))
    }

    @Test func translationValidatorNormalizesChineseTargetGlyphs() {
        #expect(TranslationOutputValidator.normalizedAcceptableTranslation(
            "這是測試", sourceText: "これはテストです", target: .simplifiedChinese
        ) == "这是测试")
        #expect(TranslationOutputValidator.normalizedAcceptableTranslation(
            "这是测试", sourceText: "これはテストです", target: .traditionalChinese
        ) == "這是測試")
    }

    @Test func komgaBookContentRevisionUsesFileMetadata() throws {
        let data = Data("""
        {
          "id": "book-1",
          "pageCount": 200,
          "fileSize": 12345,
          "fileHash": "sha256:abc",
          "fileLastModified": "2026-08-22T08:00:00Z"
        }
        """.utf8)
        let book = try JSONDecoder().decode(KomgaBookDTO.self, from: data)
        #expect(book.contentRevision?.contains("sha256:abc") == true)
        #expect(book.contentRevision?.contains("pages=200") == true)
    }

    @Test func opdsRevisionRequiresAContentIdentityHeader() {
        #expect(OPDSRemoteRevision.value(
            etag: nil,
            lastModified: nil,
            contentDigest: nil,
            contentLength: "48123456"
        ) == nil)
        #expect(OPDSRemoteRevision.value(
            etag: "\"book-v2\"",
            lastModified: nil,
            contentDigest: nil,
            contentLength: "48123456"
        )?.contains("etag=") == true)
        #expect(OPDSRemoteRevision.value(
            etag: nil,
            lastModified: "Fri, 22 Aug 2026 09:00:00 GMT",
            contentDigest: nil,
            contentLength: nil
        )?.contains("last=") == true)
    }

    @Test func pageTranslationParserAcceptsStableIdenticalTokens() throws {
        let expected = [
            AIPageTranslationItem(id: "b0", sourceText: "NASA", order: 0),
            AIPageTranslationItem(id: "b1", sourceText: "ありがとう", order: 1)
        ]
        let result = try AIPageTranslationParser.parse(
            "{\"items\":[{\"id\":\"b0\",\"translation\":\"NASA\"},{\"id\":\"b1\",\"translation\":\"ありがとう\"}]}",
            expectedItems: expected,
            target: .simplifiedChinese
        )
        #expect(result.items.map(\.id) == ["b0"])
        #expect(result.missingIDs == ["b1"])
    }

    @Test func offlineTranslationLanguageConsensusNeedsMultiplePageVotes() {
        var consensus = OfflineTranslationSourceLanguageConsensus()
        consensus.register(languageCode: "en", confidence: 0.95)
        #expect(consensus.resolvedLanguageCode == nil)
        consensus.register(languageCode: "ja", confidence: 0.95)
        #expect(consensus.resolvedLanguageCode == nil)
        consensus.register(languageCode: "ja", confidence: 0.95)
        #expect(consensus.resolvedLanguageCode == "ja")
    }

    @Test func offlineTranslationBackgroundStateWhitelistExcludesPausedAndConfiguration() {
        #expect(OfflineTranslationJobState.queued.isBackgroundResumable)
        #expect(OfflineTranslationJobState.interrupted.isBackgroundResumable)
        #expect(OfflineTranslationJobState.running.isBackgroundResumable)
        #expect(!OfflineTranslationJobState.paused.isBackgroundResumable)
        #expect(!OfflineTranslationJobState.needsConfiguration.isBackgroundResumable)
        #expect(!OfflineTranslationJobState.completed.isBackgroundResumable)
        #expect(!OfflineTranslationJobState.cancelled.isBackgroundResumable)
    }

    @Test func pageTranslationPromptContainsStableIDsAndExplicitTarget() throws {
        let prompt = try AIPageTranslationPromptBuilder.prompt(
            items: [
                AIPageTranslationItem(id: "b0", sourceText: "遅い", order: 0),
                AIPageTranslationItem(id: "b1", sourceText: "ごめん", order: 1)
            ],
            sourceLanguage: .japanese,
            target: .simplifiedChinese,
            styleInstructions: "保持自然口语"
        )

        #expect(prompt.contains("zh-Hans"))
        #expect(prompt.contains("ja"))
        #expect(prompt.contains("禁止修改、合并、拆分"))

        // 生产 JSON 用 sortedKeys（无 pretty-printed 空格），测试不得依赖空白格式（项15）。
        // 直接从 Prompt 中抽出输入 JSON 解析，验证 items 的 id 与顺序。
        guard let jsonStart = prompt.range(of: "输入：\n")?.upperBound,
              let jsonEnd = prompt.range(of: "\n\n输出格式：")?.lowerBound else {
            Issue.record("Prompt 中找不到输入 JSON 区块")
            return
        }
        let jsonText = String(prompt[jsonStart..<jsonEnd])
        let object = try JSONSerialization.jsonObject(with: Data(jsonText.utf8)) as? [String: Any]
        let items = object?["items"] as? [[String: Any]]
        let ids = items?.compactMap { $0["id"] as? String }
        #expect(ids == ["b0", "b1"])
        #expect(items?.first?["sourceText"] as? String == "遅い")
    }

    @Test func visionRecognitionFiltersNonContentAndFallsBackToTextGeometry() throws {
        let response = """
        {"coordinateSpace":"normalized","items":[
          {
            "id":"dialogue-1",
            "text":"こんにちは",
            "classification":"dialogue",
            "textBox":{"x":0.2,"y":0.3,"width":0.2,"height":0.08},
            "bubbleBox":{"x":0.2,"y":0.3,"width":0.2,"height":0.08},
            "confidence":0.92
          },
          {
            "id":"url-1",
            "text":"https://example.com",
            "classification":"url",
            "textBox":{"x":0.1,"y":0.9,"width":0.4,"height":0.03},
            "confidence":0.99
          }
        ]}
        """

        let blocks = try AITranslator.parseVisionRecognitionBlocksForDiagnostics(
            from: response,
            inputPixelSize: CGSize(width: 1_000, height: 2_000)
        )

        #expect(blocks.count == 1)
        #expect(blocks[0].text == "こんにちは")
        #expect(abs(blocks[0].boundingBox.minX - 0.2) < 0.000_1)
        #expect(abs(blocks[0].boundingBox.width - 0.2) < 0.000_1)
        #expect(blocks[0].translation == nil)
    }

    @Test func visionRecognitionPromptDoesNotAskModelToTranslate() {
        let prompt = AITranslator.visionRecognitionPromptForDiagnostics(
            isRightToLeft: true,
            additionalInstructions: "优先保留竖排文字方向"
        )

        #expect(prompt.contains("只识别原文"))
        #expect(prompt.contains("从右到左"))
        #expect(prompt.contains("不要翻译"))
        #expect(prompt.contains("优先保留竖排文字方向"))
        #expect(prompt.lowercased().contains("coordinatespace"))
    }

    @Test func iPhoneShelfUsesTwoFullWidthColumns() {
        let result = ShelfCardMetrics.gridLayout(for: 393, idiom: .phone)

        #expect(result.columns.count == 2)
        #expect(result.cardWidth == 170)
    }

    @Test func iPadShelfUsesAdditionalColumns() {
        let result = ShelfCardMetrics.gridLayout(for: 744, idiom: .pad)

        #expect(result.columns.count >= 3)
        #expect(result.cardWidth >= 160)
    }

    @Test func ocrCoordinateMapperUsesVisibleAspectFitRect() {
        let transform = OCRCoordinateMapper.displayTransform(
            sourcePixelSize: CGSize(width: 1_000, height: 2_000),
            containerSize: CGSize(width: 1_000, height: 1_000),
            fitMode: .fitScreen
        )

        #expect(transform.imageRect == CGRect(x: 250, y: 0, width: 500, height: 1_000))
        #expect(
            OCRCoordinateMapper.displayRect(
                forNormalizedPageRect: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.1),
                using: transform
            ) == CGRect(x: 300, y: 200, width: 150, height: 100)
        )
    }

    @Test func ocrCoordinateMapperRestoresSliceCoordinates() {
        let mapped = OCRCoordinateMapper.normalizedPageRect(
            forSliceRect: CGRect(x: 0.2, y: 0.5, width: 0.4, height: 0.2),
            sourceRect: CGRect(x: 0, y: 0.4, width: 1, height: 0.3)
        )

        #expect(abs(mapped.minX - 0.2) < 0.000_1)
        #expect(abs(mapped.minY - 0.55) < 0.000_1)
        #expect(abs(mapped.width - 0.4) < 0.000_1)
        #expect(abs(mapped.height - 0.06) < 0.000_1)
    }

    @Test func ocrCoordinateMapperAppliesZoomAndPanToImageAndBoxes() {
        let transform = OCRCoordinateMapper.displayTransform(
            sourcePixelSize: CGSize(width: 100, height: 100),
            containerSize: CGSize(width: 200, height: 200),
            fitMode: .fitScreen,
            zoomScale: 2,
            panOffset: CGSize(width: 10, height: -20)
        )

        #expect(transform.imageRect == CGRect(x: -90, y: -120, width: 400, height: 400))
        #expect(
            OCRCoordinateMapper.displayRect(
                forNormalizedPageRect: CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5),
                using: transform
            ) == CGRect(x: 10, y: -20, width: 200, height: 200)
        )
    }

    @Test func ocrCandidateResolverPrefersVariantConsensus() {
        let box = CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.05)
        let result = OCRCandidateResolver.resolve([
            TextBlock(text: "你回来了", boundingBox: box, confidence: 0.82, ocrSource: "original"),
            TextBlock(text: "你回来了", boundingBox: box.offsetBy(dx: 0.002, dy: 0), confidence: 0.78, ocrSource: "enhanced"),
            TextBlock(text: "你问来了", boundingBox: box, confidence: 0.86, ocrSource: "inverted")
        ], isRightToLeft: false)

        #expect(result.resolvedBlocks.count == 1)
        #expect(result.resolvedBlocks[0].text == "你回来了")
        #expect(result.rejectedBlocks.count == 2)
    }

    @Test func ocrCandidateResolverKeepsNearbyDistinctText() {
        let result = OCRCandidateResolver.resolve([
            TextBlock(text: "等等", boundingBox: CGRect(x: 0.1, y: 0.1, width: 0.10, height: 0.04), confidence: 0.9),
            TextBlock(text: "快走", boundingBox: CGRect(x: 0.205, y: 0.1, width: 0.10, height: 0.04), confidence: 0.9)
        ], isRightToLeft: false)

        #expect(result.resolvedBlocks.map(\.text).sorted() == ["快走", "等等"])
    }

    @Test func mangaSegmenterDoesNotTransitivelyMergeThreeBubbles() {
        let blocks = [
            TextBlock(text: "第一句", boundingBox: CGRect(x: 0.05, y: 0.10, width: 0.20, height: 0.04), estimatedFontScale: 0.04),
            TextBlock(text: "第二句", boundingBox: CGRect(x: 0.27, y: 0.10, width: 0.20, height: 0.04), estimatedFontScale: 0.04),
            TextBlock(text: "第三句", boundingBox: CGRect(x: 0.49, y: 0.10, width: 0.20, height: 0.04), estimatedFontScale: 0.04)
        ]

        let result = MangaTextSegmenter.segment(blocks, isRightToLeft: false)

        #expect(result.bubbles.count == 3)
    }

    @Test func mangaSegmenterMergesCloseSameStyleFragments() {
        let result = MangaTextSegmenter.segment([
            TextBlock(
                text: "这是",
                boundingBox: CGRect(x: 0.1, y: 0.1, width: 0.15, height: 0.04),
                estimatedFontScale: 0.04,
                textColorHex: "#181818"
            ),
            TextBlock(
                text: "一句话",
                boundingBox: CGRect(x: 0.255, y: 0.1, width: 0.18, height: 0.041),
                estimatedFontScale: 0.041,
                textColorHex: "#202020"
            )
        ], isRightToLeft: false)

        #expect(result.bubbles.count == 1)
        #expect(result.bubbles[0].text == "这是一句话")
    }

    @Test func mangaSegmenterSeparatesDifferentFontOrColor() {
        let result = MangaTextSegmenter.segment([
            TextBlock(
                text: "对白",
                boundingBox: CGRect(x: 0.1, y: 0.1, width: 0.12, height: 0.04),
                estimatedFontScale: 0.04,
                textColorHex: "#111111"
            ),
            TextBlock(
                text: "标注",
                boundingBox: CGRect(x: 0.225, y: 0.1, width: 0.12, height: 0.06),
                estimatedFontScale: 0.06,
                textColorHex: "#F02020"
            )
        ], isRightToLeft: false)

        #expect(result.bubbles.count == 2)
    }

    @Test func mangaSegmenterRetainsSharedVisualBubbleAfterMultiLineMerge() {
        let bubble = CGRect(x: 0.10, y: 0.15, width: 0.42, height: 0.24)
        let polygon = [CGPoint(x: 0.10, y: 0.15), CGPoint(x: 0.52, y: 0.15)]
        let result = MangaTextSegmenter.segment([
            TextBlock(
                text: "我不知道",
                boundingBox: CGRect(x: 0.18, y: 0.20, width: 0.20, height: 0.04),
                estimatedFontScale: 0.06,
                bubbleBox: bubble,
                bubblePolygon: polygon
            ),
            TextBlock(
                text: "你在说什么",
                boundingBox: CGRect(x: 0.18, y: 0.27, width: 0.24, height: 0.04),
                estimatedFontScale: 0.06,
                bubbleBox: bubble,
                bubblePolygon: polygon
            )
        ], isRightToLeft: false)

        #expect(result.bubbles.count == 1)
        #expect(result.bubbles[0].bubbleBox == bubble)
        #expect(result.bubbles[0].bubblePolygon == polygon)
    }

    @Test func mangaSegmenterDoesNotMergeBlocksWithDistinctVisualBubbles() {
        let result = MangaTextSegmenter.segment([
            TextBlock(
                text: "第一句",
                boundingBox: CGRect(x: 0.18, y: 0.20, width: 0.20, height: 0.04),
                estimatedFontScale: 0.06,
                bubbleBox: CGRect(x: 0.10, y: 0.15, width: 0.34, height: 0.09)
            ),
            TextBlock(
                text: "第二句",
                boundingBox: CGRect(x: 0.18, y: 0.27, width: 0.20, height: 0.04),
                estimatedFontScale: 0.06,
                bubbleBox: CGRect(x: 0.10, y: 0.25, width: 0.34, height: 0.09)
            )
        ], isRightToLeft: false)

        #expect(result.bubbles.count == 2)
    }

    @Test func mangaSegmenterKeepsPureOCRMergeBehaviorWithoutVisualBubbles() {
        let result = MangaTextSegmenter.segment([
            TextBlock(
                text: "第一行",
                boundingBox: CGRect(x: 0.18, y: 0.20, width: 0.20, height: 0.04),
                estimatedFontScale: 0.06
            ),
            TextBlock(
                text: "第二行",
                boundingBox: CGRect(x: 0.18, y: 0.27, width: 0.20, height: 0.04),
                estimatedFontScale: 0.06
            )
        ], isRightToLeft: false)

        #expect(result.bubbles.count == 1)
        #expect(result.bubbles[0].bubbleBox == nil)
    }

    @Test func ocrLanguagePassesSeparateJapaneseFromChineseKorean() {
        let passes = OCRPreprocessor.languagePassesForDiagnostics()

        #expect(passes.contains(["zh-Hans", "zh-Hant", "ko-KR", "en-US"]))
        #expect(passes.contains(["ja-JP", "en-US"]))
        #expect(!passes.contains(["zh-Hans", "zh-Hant", "ja-JP", "ko-KR", "en-US"]))
    }

    @Test func ocrAdaptiveLanguagePlanPrioritizesDetectedScript() {
        let japanese = OCRPreprocessor.preferredLanguagePassesForDiagnostics(
            detectedTexts: ["こんにちは、先生"]
        )
        let chinese = OCRPreprocessor.preferredLanguagePassesForDiagnostics(
            detectedTexts: ["今天一起看漫画"]
        )
        let korean = OCRPreprocessor.preferredLanguagePassesForDiagnostics(
            detectedTexts: ["안녕하세요"]
        )
        let english = OCRPreprocessor.preferredLanguagePassesForDiagnostics(
            detectedTexts: ["Hello world"]
        )

        #expect(japanese.first == ["ja-JP", "en-US"])
        #expect(chinese.first == ["zh-Hans", "zh-Hant", "en-US"])
        #expect(korean.first == ["ko-KR", "en-US"])
        #expect(english.first == ["en-US"])
    }

    @Test func localOCRCacheKeyTracksRecognitionSettings() {
        let pageURL = URL(fileURLWithPath: "/tmp/mreader-ocr-cache-test.jpg")
        let image = UIImage()
        let base = OCRRecognitionCacheRequest(
            pageURL: pageURL,
            fallbackImage: image,
            options: OCRPreprocessor.Options(isRightToLeft: false, minimumTextHeight: 0.006)
        )
        let changedDirection = OCRRecognitionCacheRequest(
            pageURL: pageURL,
            fallbackImage: image,
            options: OCRPreprocessor.Options(isRightToLeft: true, minimumTextHeight: 0.006)
        )
        let changedThreshold = OCRRecognitionCacheRequest(
            pageURL: pageURL,
            fallbackImage: image,
            options: OCRPreprocessor.Options(isRightToLeft: false, minimumTextHeight: 0.01)
        )
        let changedMode = OCRRecognitionCacheRequest(
            pageURL: pageURL,
            fallbackImage: image,
            options: OCRPreprocessor.Options(
                isRightToLeft: false,
                minimumTextHeight: 0.006,
                recognitionMode: .maximumAccuracy
            )
        )

        #expect(base.cacheKey != changedDirection.cacheKey)
        #expect(base.cacheKey != changedThreshold.cacheKey)
        #expect(base.cacheKey != changedMode.cacheKey)
    }

    @Test func mangaOCRPipelineKeepsEveryDiagnosticStage() {
        let raw = [
            TextBlock(text: "你", boundingBox: CGRect(x: 0.1, y: 0.1, width: 0.04, height: 0.04), confidence: 0.8, ocrSource: "original:zh-ko"),
            TextBlock(text: "你", boundingBox: CGRect(x: 0.1, y: 0.1, width: 0.04, height: 0.04), confidence: 0.76, ocrSource: "enhanced:zh-ko"),
            TextBlock(text: "好", boundingBox: CGRect(x: 0.145, y: 0.1, width: 0.04, height: 0.04), confidence: 0.9, ocrSource: "original:zh-ko")
        ]

        let result = MangaOCRPipeline.resolveForDiagnostics(raw, isRightToLeft: false)

        #expect(result.rawBlocks.count == 3)
        #expect(result.resolvedBlocks.count == 2)
        #expect(result.lineBlocks.count == 1)
        #expect(result.bubbleBlocks.map(\.text) == ["你好"])
        #expect(result.rejectedBlocks.count == 1)
    }

    @Test func ocrBubbleLayoutStaysInsideVisibleImageBounds() {
        let bounds = CGRect(x: 100, y: 0, width: 200, height: 400)
        let rect = OCRBubbleLayoutEngine.clamped(
            CGRect(x: 40, y: -20, width: 120, height: 80),
            to: bounds,
            margin: 8
        )

        #expect(rect.minX >= bounds.minX + 8)
        #expect(rect.minY >= bounds.minY + 8)
        #expect(rect.maxX <= bounds.maxX - 8)
        #expect(rect.maxY <= bounds.maxY - 8)
    }

    @Test func ocrBubbleLayoutAvoidsExistingBubbleNearAnchor() {
        let bounds = CGRect(x: 0, y: 0, width: 390, height: 844)
        let original = CGRect(x: 130, y: 200, width: 130, height: 70)
        let occupied = [original.insetBy(dx: -4, dy: -4)]
        let placed = OCRBubbleLayoutEngine.nonOverlappingRect(
            original,
            anchor: CGPoint(x: 195, y: 235),
            occupiedRects: occupied,
            bounds: bounds
        )

        #expect(!placed.intersects(occupied[0]))
        #expect(bounds.contains(placed))
        #expect(hypot(placed.midX - 195, placed.midY - 235) < 220)
    }

    @Test func translationBubbleAvoidanceDoesNotShrinkMeasuredBubbleAtImageEdge() {
        let bounds = CGRect(x: 0, y: 0, width: 390, height: 844)
        // 已按文本实际尺寸测量出的气泡恰好贴近页面边缘时，避让阶段只能移动，不能裁掉内边距。
        let original = CGRect(x: 0, y: 186, width: 214, height: 84)
        let placed = OCRBubbleLayoutEngine.nonOverlappingRect(
            original,
            anchor: CGPoint(x: original.midX, y: original.midY),
            occupiedRects: [],
            bounds: bounds,
            margin: 0
        )

        #expect(placed.width == original.width)
        #expect(placed.height == original.height)
        #expect(bounds.contains(placed))
    }

    @Test @MainActor func translationBubbleMeasurementFitsDenseTextInsideImage() {
        let bounds = CGRect(x: 40, y: 0, width: 310, height: 780)
        let source = CGRect(x: 250, y: 680, width: 70, height: 40)
        let rect = OCRBubbleLayoutEngine.measuredBubbleRect(
            text: "这是一段需要自然换行且不能跑出屏幕边缘的漫画翻译对白。",
            fontSize: 17,
            sourceRect: source,
            bounds: bounds,
            maximumWidth: 220,
            lineSpacing: 2
        )

        #expect(bounds.insetBy(dx: 12, dy: 12).contains(rect))
        #expect(rect.height > source.height)
        #expect(rect.width <= 220)
    }

    @Test func translatedFontStartsAtSourceScaleWithoutGlobalClamp() {
        #expect(abs(OCRBubbleLayoutEngine.preferredTranslationFontSize(sourceFontSize: 16) - 16) < 0.01)
        #expect(abs(OCRBubbleLayoutEngine.preferredTranslationFontSize(sourceFontSize: 30) - 30) < 0.01)
        #expect(abs(OCRBubbleLayoutEngine.preferredTranslationFontSize(sourceFontSize: 6) - 6) < 0.01)
    }

    @Test func sourceFontSizeUsesTheMatchingDisplayAxisForTextDirection() {
        let displayedPage = CGRect(x: 0, y: 0, width: 390, height: 780)
        let horizontal = TextBlock(
            text: "横排对白",
            boundingBox: CGRect(x: 0.2, y: 0.3, width: 0.32, height: 0.04),
            estimatedFontScale: 0.04,
            textOrientation: .horizontal
        )
        let vertical = TextBlock(
            text: "竖排",
            boundingBox: CGRect(x: 0.2, y: 0.3, width: 0.04, height: 0.32),
            estimatedFontScale: 0.04,
            textOrientation: .vertical
        )

        #expect(abs(horizontal.sourceFontSize(in: displayedPage) - 31.2) < 0.001)
        #expect(abs(vertical.sourceFontSize(in: displayedPage) - 15.6) < 0.001)
    }

    @Test func localOCRGeometryUsesPhysicalObservationAxis() {
        let geometry = OCRPreprocessor.localOCRGeometryForDiagnostics(
            observationRect: CGRect(x: 0, y: 0, width: 20.0 / 390.0, height: 40.0 / 780.0),
            observationPixelSize: CGSize(width: 390, height: 780),
            normalizedPageRect: CGRect(x: 0.2, y: 0.3, width: 20.0 / 390.0, height: 40.0 / 780.0)
        )

        #expect(geometry.orientation == .vertical)
        #expect(abs(geometry.fontScale - 20.0 / 390.0) < 0.0001)
    }

    @Test @MainActor func anchoredTranslationLayoutKeepsSourceCenterAndExpandsBeforeShrinking() {
        let source = CGRect(x: 130, y: 210, width: 80, height: 34)
        let allowed = CGRect(x: 70, y: 145, width: 210, height: 170)
        let layout = OCRBubbleLayoutEngine.anchoredTranslationLayout(
            text: "这是一段需要比原始文字区域更宽才能自然排下的中文译文。",
            sourceFontSize: 16,
            sourceRect: source,
            allowedBounds: allowed,
            lineSpacing: 2
        )

        #expect(abs(layout.rect.midX - source.midX) < 0.01)
        #expect(abs(layout.rect.midY - source.midY) < 0.01)
        #expect(layout.rect.width >= source.width)
        #expect(layout.fontSize <= 16)
        #expect(layout.fontSize >= 9.6)
        #expect(allowed.contains(layout.rect))
    }

    @Test @MainActor func translationLayoutMovesMinimallyBeforeShrinkingFont() {
        let source = CGRect(x: 8, y: 34, width: 30, height: 24)
        let allowed = CGRect(x: 0, y: 0, width: 220, height: 110)
        let layout = OCRBubbleLayoutEngine.anchoredTranslationLayout(
            text: "这是一段应当优先向右扩展而不是过早缩小字号的译文。",
            sourceFontSize: 20,
            sourceRect: source,
            allowedBounds: allowed,
            lineSpacing: 2
        )

        #expect(abs(layout.fontSize - 20) < 0.01)
        #expect(layout.rect.midX > source.midX)
        #expect(allowed.contains(layout.rect))
    }

    @Test @MainActor func translationLayoutContinuesShrinkingUntilTextActuallyFits() {
        let source = CGRect(x: 24, y: 10, width: 22, height: 20)
        let allowed = CGRect(x: 0, y: 0, width: 70, height: 45)
        let layout = OCRBubbleLayoutEngine.anchoredTranslationLayout(
            text: String(repeating: "超长译文", count: 42),
            sourceFontSize: 20,
            sourceRect: source,
            allowedBounds: allowed,
            lineSpacing: 2
        )

        #expect(layout.fontSize < 12)
        #expect(allowed.contains(layout.rect))
        #expect(layout.rect.height <= allowed.height)
    }

    @Test @MainActor func translationLayoutNeverEscapesAllowedBoundsForPathologicalText() {
        let allowed = CGRect(x: 0, y: 0, width: 28, height: 18)
        let layout = OCRBubbleLayoutEngine.anchoredTranslationLayout(
            text: Array(repeating: String(repeating: "非常长的译文\\n", count: 100), count: 20).joined(),
            sourceFontSize: 22,
            sourceRect: CGRect(x: 3, y: 3, width: 12, height: 8),
            allowedBounds: allowed,
            lineSpacing: 2
        )

        #expect(allowed.contains(layout.rect))
        #expect(layout.rect == allowed)
        #expect(layout.fontSize == 0.1)
    }

    @Test @MainActor func translationLayoutPrefersNaturalWrappingOverNeedlessSuggestedBreaks() {
        let source = CGRect(x: 45, y: 30, width: 42, height: 18)
        let allowed = CGRect(x: 0, y: 0, width: 140, height: 78)
        let translation = "I really do not know what you are talking about"
        let suggestedLines = ["I really", "do not", "know what", "you are", "talking", "about"]
        let natural = OCRBubbleLayoutEngine.anchoredTranslationLayout(
            text: translation,
            sourceFontSize: 18,
            sourceRect: source,
            allowedBounds: allowed,
            lineSpacing: 2
        )
        let suggested = OCRBubbleLayoutEngine.anchoredTranslationLayout(
            text: suggestedLines.joined(separator: "\n"),
            sourceFontSize: 18,
            sourceRect: source,
            allowedBounds: allowed,
            lineSpacing: 2
        )
        let choice = OCRBubbleLayoutEngine.preferredTranslationLayout(
            translation: translation,
            translationLines: suggestedLines,
            sourceFontSize: 18,
            sourceRect: source,
            allowedBounds: allowed,
            lineSpacing: 2
        )

        #expect(natural.fontSize > suggested.fontSize)
        #expect(choice.usesSuggestedLineBreaks == false)
        #expect(choice.text == translation)
        #expect(abs(choice.layout.fontSize - natural.fontSize) < 0.001)
    }

    @Test func translationBubbleBoxAllowsSmallOCRMappingTolerance() {
        let bubble = CGRect(x: 40, y: 80, width: 140, height: 90)
        let text = CGRect(x: 38, y: 82, width: 68, height: 32)

        #expect(!OCRBubbleLayoutEngine.acceptsTranslationTextRect(text, in: bubble, toleranceX: 0, toleranceY: 0))
        #expect(OCRBubbleLayoutEngine.acceptsTranslationTextRect(text, in: bubble, toleranceX: 3, toleranceY: 3))
    }

    @Test func translationGeometryRefinerUsesLocalOCRTextBoxButRetainsModelBubbleBox() {
        let modelBubble = CGRect(x: 0.08, y: 0.10, width: 0.55, height: 0.24)
        let vision = TextBlock(
            text: "こんにちは",
            boundingBox: CGRect(x: 0.36, y: 0.44, width: 0.18, height: 0.06),
            translation: "你好",
            estimatedFontScale: 0.02,
            bubbleBox: modelBubble
        )
        let local = TextBlock(
            text: "こんにちは",
            boundingBox: CGRect(x: 0.15, y: 0.22, width: 0.30, height: 0.08),
            confidence: 0.94,
            ocrSource: "local",
            estimatedFontScale: 0.052
        )

        let refined = TranslationGeometryRefiner.refine(
            visionBlocks: [vision],
            localOCRBlocks: [local],
            isRightToLeft: false
        )

        #expect(refined.count == 1)
        #expect(refined[0].boundingBox == local.boundingBox)
        #expect(refined[0].estimatedFontScale == local.estimatedFontScale)
        #expect(refined[0].bubbleBox == modelBubble)
        #expect(refined[0].translation == "你好")
    }

    @Test func translationGeometryRefinerUnionsMultipleLocalLinesAndKeepsOrientation() {
        let vision = TextBlock(
            text: "あいうえ",
            boundingBox: CGRect(x: 0.2, y: 0.2, width: 0.30, height: 0.18),
            translation: "你好",
            estimatedFontScale: 0.03
        )
        let firstLine = TextBlock(
            text: "あい",
            boundingBox: CGRect(x: 0.2, y: 0.2, width: 0.30, height: 0.05),
            ocrSource: "local-line",
            estimatedFontScale: 0.05,
            textOrientation: .horizontal
        )
        let secondLine = TextBlock(
            text: "うえ",
            boundingBox: CGRect(x: 0.2, y: 0.27, width: 0.30, height: 0.05),
            ocrSource: "local-line",
            estimatedFontScale: 0.05,
            textOrientation: .horizontal
        )

        let refined = TranslationGeometryRefiner.refine(
            visionBlocks: [vision],
            localOCRBlocks: [firstLine, secondLine],
            isRightToLeft: false
        )

        #expect(refined.count == 1)
        #expect(refined[0].boundingBox == CGRect(x: 0.2, y: 0.2, width: 0.30, height: 0.12))
        #expect(refined[0].textOrientation == .horizontal)
        #expect(refined[0].estimatedFontScale == 0.05)
    }

    @Test func translationGeometryRefinerRejectsAdjacentRepeatedShortText() {
        let vision = TextBlock(
            text: "あいう",
            boundingBox: CGRect(x: 0.2, y: 0.2, width: 0.30, height: 0.15),
            translation: "你好",
            estimatedFontScale: 0.03
        )
        let firstLine = TextBlock(
            text: "あ",
            boundingBox: CGRect(x: 0.2, y: 0.2, width: 0.30, height: 0.04),
            ocrSource: "local-line",
            estimatedFontScale: 0.04,
            textOrientation: .horizontal
        )
        let secondLine = TextBlock(
            text: "い",
            boundingBox: CGRect(x: 0.2, y: 0.255, width: 0.30, height: 0.04),
            ocrSource: "local-line",
            estimatedFontScale: 0.04,
            textOrientation: .horizontal
        )
        let thirdLine = TextBlock(
            text: "う",
            boundingBox: CGRect(x: 0.2, y: 0.31, width: 0.30, height: 0.04),
            ocrSource: "local-line",
            estimatedFontScale: 0.04,
            textOrientation: .horizontal
        )
        let adjacentBubble = TextBlock(
            text: "あ",
            boundingBox: CGRect(x: 0.62, y: 0.22, width: 0.08, height: 0.04),
            ocrSource: "local-line",
            estimatedFontScale: 0.04,
            textOrientation: .horizontal
        )

        let refined = TranslationGeometryRefiner.refine(
            visionBlocks: [vision],
            localOCRBlocks: [firstLine, secondLine, thirdLine, adjacentBubble],
            isRightToLeft: false
        )

        #expect(refined.count == 1)
        #expect(abs(refined[0].boundingBox.minX - 0.2) < 0.0001)
        #expect(abs(refined[0].boundingBox.minY - 0.2) < 0.0001)
        #expect(abs(refined[0].boundingBox.width - 0.30) < 0.0001)
        #expect(abs(refined[0].boundingBox.height - 0.15) < 0.0001)
        #expect(refined[0].estimatedFontScale == 0.04)
    }

    @Test func ocrTranslationUsesBoundedTimeoutAndFastFallbackPolicy() {
        #expect(AITranslationRequestPolicy.pageModelAttempts == 1)
        #expect(AITranslationRequestPolicy.pageRequestTimeout == 25)
        #expect(AITranslationRequestPolicy.fallbackModelAttempts == 1)
        #expect(AITranslationRequestPolicy.fallbackRequestTimeout == 30)
        #expect(!AITranslationRequestPolicy.shouldUsePageTranslation(blockCount: 1))
        #expect(AITranslationRequestPolicy.shouldUsePageTranslation(blockCount: 2))
        #expect(AITranslationRequestPolicy.maximumOCRWaitBeforeResult <= 85)
    }

    @Test func visualOCRVerificationSelectsOnlyUncertainBlocks() {
        let blocks = [
            TextBlock(text: "清楚", boundingBox: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.05), confidence: 0.91),
            TextBlock(text: "�??", boundingBox: CGRect(x: 0.5, y: 0.2, width: 0.2, height: 0.05), confidence: 0.41)
        ]

        let regions = AITranslator.visualVerificationRegionsForDiagnostics(blocks)

        #expect(regions.count == 1)
        #expect(regions[0].blockID == blocks[1].id)
        #expect(regions[0].sourceRect.minX < blocks[1].boundingBox.minX)
        #expect(regions[0].sourceRect.maxX > blocks[1].boundingBox.maxX)
    }

    @Test func visualOCRVerificationMatchesNearbyTextAndMapsCropFontScale() {
        let sourceRect = CGRect(x: 0.3, y: 0.3, width: 0.4, height: 0.1)
        let original = TextBlock(
            text: "甲",
            boundingBox: CGRect(x: 0.4, y: 0.31, width: 0.12, height: 0.02),
            estimatedFontScale: 0.02,
            textOrientation: .horizontal
        )
        let matchingCandidate = TextBlock(
            text: "甲",
            boundingBox: CGRect(x: 0.25, y: 0.1, width: 0.3, height: 0.2),
            confidence: 0.55,
            estimatedFontScale: 0.20,
            bubbleBox: CGRect(x: 0.20, y: 0.0, width: 0.4, height: 0.4),
            bubblePolygon: [CGPoint(x: 0.2, y: 0), CGPoint(x: 0.6, y: 0)],
            textOrientation: .horizontal
        )
        let nearbyDifferentText = TextBlock(
            text: "乙",
            boundingBox: CGRect(x: 0.75, y: 0.1, width: 0.15, height: 0.2),
            confidence: 0.99,
            estimatedFontScale: 0.20,
            textOrientation: .horizontal
        )

        let match = AITranslator.visualVerificationMatch(
            for: original,
            candidates: [matchingCandidate, nearbyDifferentText],
            sourceRect: sourceRect
        )
        #expect(match?.block.id == matchingCandidate.id)
        #expect(abs((match?.pageBoundingBox.height ?? 0) - 0.02) < 0.0001)
        #expect(abs(AITranslator.visualVerificationMappedFontScale(
            for: matchingCandidate,
            sourceRect: sourceRect,
            correctedBox: match?.pageBoundingBox ?? .zero
        ) - 0.02) < 0.0001)
        let mappedBubble = AITranslator.visualVerificationMappedBubbleGeometry(
            for: matchingCandidate,
            sourceRect: sourceRect,
            correctedBox: match?.pageBoundingBox ?? .zero
        )
        #expect(abs((mappedBubble.bubbleBox?.minX ?? 0) - 0.38) < 0.0001)
        #expect(abs((mappedBubble.bubbleBox?.minY ?? 0) - 0.3) < 0.0001)
        #expect(abs((mappedBubble.bubbleBox?.width ?? 0) - 0.16) < 0.0001)
        #expect(abs((mappedBubble.bubbleBox?.height ?? 0) - 0.04) < 0.0001)
        #expect(mappedBubble.bubblePolygon == [CGPoint(x: 0.38, y: 0.3), CGPoint(x: 0.54, y: 0.3)])

        let verticalCandidate = TextBlock(
            text: "縦",
            boundingBox: CGRect(x: 0.2, y: 0.1, width: 0.1, height: 0.4),
            estimatedFontScale: 0.20,
            textOrientation: .vertical
        )
        #expect(abs(AITranslator.visualVerificationMappedFontScale(
            for: verticalCandidate,
            sourceRect: sourceRect,
            correctedBox: .zero
        ) - 0.08) < 0.0001)

        let invalidBubble = TextBlock(
            text: "甲",
            boundingBox: matchingCandidate.boundingBox,
            bubbleBox: CGRect(x: 0.8, y: 0.8, width: 0.1, height: 0.1)
        )
        #expect(AITranslator.visualVerificationMappedBubbleGeometry(
            for: invalidBubble,
            sourceRect: sourceRect,
            correctedBox: match?.pageBoundingBox ?? .zero
        ).bubbleBox == nil)
    }

    @Test func visualOCRVerificationRejectsUnqualifiedNearbyCandidateButAllowsStrongGeometry() {
        let sourceRect = CGRect(x: 0.3, y: 0.3, width: 0.4, height: 0.1)
        let original = TextBlock(
            text: "甲",
            boundingBox: CGRect(x: 0.4, y: 0.31, width: 0.12, height: 0.02)
        )
        let unrelated = TextBlock(
            text: "完全不同",
            boundingBox: CGRect(x: 0.75, y: 0.1, width: 0.15, height: 0.2),
            confidence: 0.99
        )
        #expect(AITranslator.visualVerificationMatch(
            for: original,
            candidates: [unrelated],
            sourceRect: sourceRect
        ) == nil)

        let geometryMatch = TextBlock(
            text: "识别有误",
            boundingBox: CGRect(x: 0.25, y: 0.1, width: 0.3, height: 0.2),
            confidence: 0.55
        )
        #expect(AITranslator.visualVerificationMatch(
            for: original,
            candidates: [geometryMatch],
            sourceRect: sourceRect
        )?.block.id == geometryMatch.id)
    }

    @Test @MainActor func backgroundTaskCenterTracksAndFinishesTasks() {
        let center = BackgroundTaskCenter()
        let id = center.begin(title: "解析 PDF", detail: "large.pdf", progress: 0.2)

        #expect(center.isActive)
        #expect(center.tasks.count == 1)
        #expect(center.tasks[0].progress == 0.2)

        center.update(id, detail: "第 5 页", progress: 0.5)
        #expect(center.tasks[0].detail == "第 5 页")
        #expect(center.tasks[0].progress == 0.5)

        center.finish(id)
        #expect(!center.isActive)
    }

    @Test func opdsOneAtomCatalogParsesAcquisitionAndCover() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <feed xmlns="http://www.w3.org/2005/Atom">
          <entry>
            <id>book-1</id>
            <title>第一册</title>
            <link rel="http://opds-spec.org/acquisition" href="books/one.epub" type="application/epub+zip"/>
            <link rel="http://opds-spec.org/image/thumbnail" href="covers/one.jpg" type="image/jpeg"/>
          </entry>
        </feed>
        """

        let publications = try OPDSProvider.parseCatalogForDiagnostics(
            data: Data(xml.utf8),
            baseURL: URL(string: "https://example.com/opds/root.xml")!,
            contentType: "application/atom+xml;profile=opds-catalog"
        )

        #expect(publications.count == 1)
        #expect(publications[0].title == "第一册")
        #expect(publications[0].acquisitionURL.absoluteString == "https://example.com/opds/books/one.epub")
        #expect(publications[0].coverURL?.absoluteString == "https://example.com/opds/covers/one.jpg")
    }

    @Test func opdsTwoJSONCatalogParsesPublication() throws {
        let json = """
        {
          "metadata": { "title": "漫画库" },
          "publications": [{
            "metadata": { "identifier": "book-2", "title": "第二册" },
            "links": [
              { "rel": "http://opds-spec.org/acquisition", "href": "/files/two.cbz", "type": "application/vnd.comicbook+zip" },
              { "rel": "http://opds-spec.org/image", "href": "/covers/two.jpg", "type": "image/jpeg" }
            ]
          }]
        }
        """

        let publications = try OPDSProvider.parseCatalogForDiagnostics(
            data: Data(json.utf8),
            baseURL: URL(string: "https://example.com/opds/v2")!,
            contentType: "application/opds+json"
        )

        #expect(publications.count == 1)
        #expect(publications[0].id == "book-2")
        #expect(publications[0].acquisitionURL.absoluteString == "https://example.com/files/two.cbz")
    }

    @Test func visiblePageUsesLargestVisibleArea() {
        let frames = [
            0: CGRect(x: 0, y: -700, width: 390, height: 800),
            1: CGRect(x: 0, y: 100, width: 390, height: 800),
            2: CGRect(x: 0, y: 900, width: 390, height: 800)
        ]

        let result = ReaderVisiblePageDetector.visiblePageIndex(
            frames: frames,
            viewport: CGRect(x: 0, y: 0, width: 390, height: 844)
        )

        #expect(result == 1)
    }

    @Test func visiblePageUsesCenterDistanceAsTieBreaker() {
        let frames = [
            4: CGRect(x: 0, y: -200, width: 390, height: 600),
            5: CGRect(x: 0, y: 300, width: 390, height: 400)
        ]

        let result = ReaderVisiblePageDetector.visiblePageIndex(
            frames: frames,
            viewport: CGRect(x: 0, y: 0, width: 390, height: 700)
        )

        #expect(result == 5)
    }

    @Test func progressDoesNotResetWhenReaderPagesAreReleasedDuringDismiss() {
        let result = ReaderProgressPolicy.clampedPageIndex(
            7,
            loadedPageCount: 0,
            declaredPageCount: 102
        )

        #expect(result == 7)
    }

    @Test func aiProviderKeepsIndependentTextAndVisionModels() {
        let profile = AIProviderProfile.normalized(
            name: " 中转服务 ",
            baseURL: " https://example.com/v1/ ",
            modelsText: "gpt-4.1-mini\n qwen-vl ,gpt-4.1-mini",
            selectedTextModel: "gpt-4.1-mini",
            selectedVisionModel: "qwen-vl"
        )

        #expect(profile.name == "中转服务")
        #expect(profile.baseURL == "https://example.com/v1")
        #expect(profile.models == ["gpt-4.1-mini", "qwen-vl"])
        #expect(profile.selectedTextModel == "gpt-4.1-mini")
        #expect(profile.selectedVisionModel == "qwen-vl")
    }

    @Test func legacyAISettingsMigrateIntoOneParentWithChildModels() {
        let profile = AIProviderProfile.fromLegacySettings(
            apiDisplayName: "默认接口",
            baseURL: "https://example.com/v1",
            defaultModel: "primary-model",
            poolText: "secondary-model\nprimary-model"
        )

        #expect(profile.models == ["primary-model", "secondary-model"])
        #expect(profile.selectedTextModel == "primary-model")
        #expect(profile.selectedVisionModel == "primary-model")
    }

    @Test @MainActor func aiProviderStoreResolvesOnlySelectedParentAndChild() throws {
        let suiteName = "AIProviderStoreTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let credentials = InMemoryAICredentialStore()
        let store = AIProviderStore(defaults: defaults, credentials: credentials)
        let first = AIProviderProfile.normalized(
            name: "接口 A",
            baseURL: "https://a.example/v1",
            modelsText: "text-a\nvision-a",
            selectedTextModel: "text-a",
            selectedVisionModel: "vision-a"
        )
        let second = AIProviderProfile.normalized(
            name: "接口 B",
            baseURL: "https://b.example/v1",
            modelsText: "model-b",
            selectedTextModel: "model-b",
            selectedVisionModel: "model-b"
        )
        try store.save(profile: first, apiKey: "key-a")
        try store.save(profile: second, apiKey: "key-b")
        store.setActiveProfile(id: first.id)

        let active = try #require(store.activeConfiguration())
        #expect(active.profileID == first.id)
        #expect(active.textModel == "text-a")
        #expect(active.visionModel == "vision-a")
        #expect(active.apiKey == "key-a")
    }

    @Test @MainActor func aiProviderStoreSwitchesSelectedChildModelAndActivatesProfile() throws {
        let suiteName = "AIProviderSwitchTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let credentials = InMemoryAICredentialStore()
        let store = AIProviderStore(defaults: defaults, credentials: credentials)
        let first = AIProviderProfile.normalized(
            name: "接口 A",
            baseURL: "https://a.example/v1",
            modelsText: "ocr-a\nvision-a",
            selectedTextModel: "ocr-a",
            selectedVisionModel: "vision-a"
        )
        let second = AIProviderProfile.normalized(
            name: "接口 B",
            baseURL: "https://b.example/v1",
            modelsText: "ocr-b\nvision-b",
            selectedTextModel: "ocr-b",
            selectedVisionModel: "vision-b"
        )
        try store.save(profile: first, apiKey: "key-a")
        try store.save(profile: second, apiKey: "key-b")
        store.setActiveProfile(id: first.id)

        try store.setSelectedModel("vision-b", for: second.id, activate: true)

        let active = try #require(store.activeConfiguration())
        #expect(active.profileID == second.id)
        #expect(active.textModel == "vision-b")
        #expect(active.visionModel == "vision-b")
        #expect(active.apiKey == "key-b")
    }

    @Test func settingsBackupPreservesAIProvidersAndSharedSelectedModel() throws {
        let profile = AIProviderProfile.normalized(
            name: "中转接口",
            baseURL: "https://relay.example/v1",
            modelsText: "ocr-model\nvision-model\nshared-model",
            selectedTextModel: "ocr-model",
            selectedVisionModel: "vision-model"
        )
        let backup = MReaderSettingsBackup(
            openAIAPIKey: "legacy-key",
            openAIBaseURL: "https://legacy.example/v1",
            openAIModel: "legacy-model",
            aiModelPool: nil,
            isAIModelPoolEnabled: false,
            translationTargetLanguage: "简体中文",
            translationPromptTemplate: nil,
            visionTranslationPromptTemplate: nil,
            isHapticFeedbackEnabled: true,
            mediaSources: nil,
            translationColorStyle: nil,
            isAITranslationBorderProgressEnabled: true,
            isOCRDebugBoxesEnabled: false,
            isOCRVisualVerificationEnabled: true,
            ocrLocalRecognitionMode: OCRRecognitionMode.maximumAccuracy.rawValue,
            readingDailyPageGoal: 100,
            isBurnInProtectionEnabled: true,
            isICloudMetadataSyncEnabled: true,
            aiProviders: [AIProviderBackup(profile: profile, apiKey: "provider-key")],
            activeAIProviderID: profile.id
        )

        let decoded = try JSONDecoder().decode(
            MReaderSettingsBackup.self,
            from: JSONEncoder().encode(backup)
        )
        let provider = try #require(decoded.aiProviders?.first)

        #expect(decoded.version == 10)
        #expect(decoded.isOCRVisualVerificationEnabled == true)
        #expect(decoded.ocrLocalRecognitionMode == OCRRecognitionMode.maximumAccuracy.rawValue)
        #expect(decoded.isICloudMetadataSyncEnabled == true)
        #expect(decoded.activeAIProviderID == profile.id)
        #expect(provider.profile.id == profile.id)
        #expect(provider.profile.models == ["ocr-model", "vision-model", "shared-model"])
        #expect(provider.profile.selectedTextModel == "ocr-model")
        #expect(provider.profile.selectedVisionModel == "vision-model")
        #expect(provider.apiKey == "provider-key")
    }

    @Test func komgaBookDecodesEmbeddedReadProgress() throws {
        let json = """
        {
          "id": "book-1",
          "seriesId": "series-1",
          "libraryId": "library-1",
          "name": "Chapter 1",
          "readProgress": {
            "page": 12,
            "completed": false,
            "readDate": "2026-06-24T00:00:00Z",
            "created": "2026-06-24T00:00:00Z",
            "lastModified": "2026-06-24T00:00:00Z",
            "deviceId": "",
            "deviceName": ""
          },
          "media": { "pagesCount": 30 }
        }
        """

        let book = try JSONDecoder().decode(KomgaBookDTO.self, from: Data(json.utf8))

        #expect(book.readProgress?.resolvedPageIndex == 11)
        #expect(book.pageCount == 30)
    }

    @Test func komgaProgressPayloadConvertsZeroBasedIndexToOneBasedPage() throws {
        let payload = KomgaReadProgressUpdateDTO(pageIndex: 12, completed: false)
        let data = try JSONEncoder().encode(payload)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(object["page"] as? Int == 13)
        #expect(object["completed"] as? Bool == false)
        #expect(object["pageIndex"] == nil)
    }

    @Test func komgaUsesOfficialProgressAndDeleteEndpoints() {
        #expect(KomgaAPIEndpoint.readProgress(bookID: "abc") == "/api/v1/books/abc/read-progress")
        #expect(KomgaAPIEndpoint.deleteBookFile(bookID: "abc") == "/api/v1/books/abc/file")
    }

    @Test func unreadComicHasZeroDisplayedProgress() {
        let comic = ComicBook(
            title: "Unread",
            bookmarkData: Data(),
            totalPages: 100,
            currentPageIndex: 0,
            hasBeenOpened: false
        )

        #expect(ComicReadingProgress.completedPages(for: comic) == 0)
        #expect(ComicReadingProgress.fraction(for: comic) == 0)
    }

    @Test func finishedComicUsesGrassGreenProgressTint() {
        let comic = ComicBook(
            title: "Finished",
            bookmarkData: Data(),
            totalPages: 10,
            currentPageIndex: 9,
            hasBeenOpened: true
        )

        #expect(ComicReadingProgress.isFinished(comic))
    }

    @Test func readingActivityClampsInactiveTimeAndCountsForwardPages() {
        let start = Date(timeIntervalSince1970: 1_782_345_600)
        let update = ReadingActivityAccumulator.increment(
            previousDate: start,
            now: start.addingTimeInterval(3_600),
            previousPageIndex: 4,
            currentPageIndex: 9
        )

        #expect(update.seconds == 60)
        #expect(update.pages == 5)
    }

    @Test func ocrFragmentsMergeOnlyWhenFontScaleIsCompatible() {
        let first = TextBlock(
            text: "这是",
            boundingBox: CGRect(x: 0.1, y: 0.1, width: 0.15, height: 0.04),
            confidence: 0.9,
            estimatedFontScale: 0.04,
            textColorHex: "#111111"
        )
        let continuation = TextBlock(
            text: "一句话",
            boundingBox: CGRect(x: 0.255, y: 0.1, width: 0.18, height: 0.041),
            confidence: 0.9,
            estimatedFontScale: 0.041,
            textColorHex: "#111111"
        )
        let differentStyle = TextBlock(
            text: "广告",
            boundingBox: CGRect(x: 0.44, y: 0.1, width: 0.12, height: 0.07),
            confidence: 0.9,
            estimatedFontScale: 0.07,
            textColorHex: "#FF0000"
        )

        let grouped = AITranslator.groupedMangaTextBlocks(
            [first, continuation, differentStyle],
            isRightToLeft: false
        )

        #expect(grouped.count == 2)
        #expect(grouped[0].text == "这是一句话")
        #expect(grouped[1].text == "广告")
    }

    @Test func verticalMangaColumnsMergeIntoSingleDialogue() {
        // 竖排日文：同一气泡里两列长度不同（顶端对齐），列宽≈字号
        let rightColumn = TextBlock(
            text: "きみのことが",
            boundingBox: CGRect(x: 0.60, y: 0.10, width: 0.035, height: 0.20),
            confidence: 0.9
        )
        let leftColumn = TextBlock(
            text: "すきだ",
            boundingBox: CGRect(x: 0.555, y: 0.10, width: 0.035, height: 0.11),
            confidence: 0.9
        )

        let grouped = AITranslator.groupedMangaTextBlocks(
            [rightColumn, leftColumn],
            isRightToLeft: true
        )

        #expect(grouped.count == 1)
        #expect(grouped[0].text == "きみのことがすきだ")
    }

    @Test func webtoonRowsSortByReadingOrderDespiteTinyNormalizedHeights() {
        // 长条漫画：整页归一化后行高极小，纵向相邻的行必须按从上到下排序
        let line1 = TextBlock(text: "第一行", boundingBox: CGRect(x: 0.30, y: 0.100, width: 0.4, height: 0.004))
        let line2 = TextBlock(text: "第二行", boundingBox: CGRect(x: 0.10, y: 0.108, width: 0.4, height: 0.004))
        let line3 = TextBlock(text: "第三行", boundingBox: CGRect(x: 0.50, y: 0.116, width: 0.4, height: 0.004))

        let sorted = AITranslator.sortedTextBlocks([line3, line1, line2], isRightToLeft: false)

        #expect(sorted.map(\.text) == ["第一行", "第二行", "第三行"])
    }

    @Test func pageContextIsRenderedIntoTranslationPrompt() {
        let blocks = [
            TextBlock(text: "第一句", boundingBox: CGRect(x: 0.1, y: 0.1, width: 0.3, height: 0.05)),
            TextBlock(text: "第二句", boundingBox: CGRect(x: 0.1, y: 0.3, width: 0.3, height: 0.05))
        ]

        let context = AITranslator.pageContextDescription(blocks: blocks, currentIndex: 1)
        #expect(context == "1. 第一句\n2. 第二句（当前要翻译的句子）")

        // 生产单气泡 fallback 使用固定协议（项1/16），上下文与原文必须进 prompt
        let prompt = AITranslator.singleBubbleTranslationPrompt(
            text: "第二句",
            target: .simplifiedChinese,
            pageContext: context,
            ocrMetadata: "",
            styleInstructions: AITranslator.defaultTranslationStyleInstructions
        )
        #expect(prompt.contains("1. 第一句"))
        #expect(prompt.contains("第二句"))
        #expect(!prompt.contains("{pageContext}"))
    }

    @Test func visionImageResizePreservesAspectRatioAndFits2048() {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(
            size: CGSize(width: 4_096, height: 1_024),
            format: format
        ).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 4_096, height: 1_024))
        }

        let size = AITranslator.preparedVisionImagePixelSize(image)

        #expect(size.width == 2_048)
        #expect(size.height == 512)
        #expect(abs((size.width / size.height) - 4) < 0.001)
    }

    @Test func normalizedVisionCoordinatesDoNotChangeAfterImageCompression() {
        let rect = CGRect(x: 0.25, y: 0.2, width: 0.5, height: 0.4)

        let normalized = AITranslator.normalizedVisionRectForDiagnostics(
            rect,
            inputPixelSize: CGSize(width: 2_048, height: 512)
        )

        #expect(normalized == rect)
    }

    @Test func visionSmallPixelCoordinatesWithoutMarkerAreRejected() throws {
        // 报告中的场景：2048×2048 输入上模型返回 x=20,y=25,width=40,height=30（全部小于 100 的像素）。
        // 新协议不再猜测“是百分比/是像素”，缺少显式 normalized 标记即整条拒绝，避免被放大几十倍。
        let response = """
        {"items": [{"text": "原文", "translation": "译文", "bubbleBox": {"x": 20, "y": 25, "width": 40, "height": 30}}]}
        """

        do {
            _ = try AITranslator.parseVisionTranslationBlocksForDiagnostics(
                from: response,
                inputPixelSize: CGSize(width: 2_048, height: 2_048)
            )
            Issue.record("缺少 normalized 标记的像素坐标应被拒绝")
        } catch {
            // 期望：抛出坐标协议错误
        }
    }

    @Test func openAICompatibleContentArrayIsAccepted() throws {
        let response: [String: Any] = [
            "choices": [[
                "message": [
                    "content": [
                        ["type": "output_text", "text": "第一行"],
                        ["type": "output_text", "text": "第二行"]
                    ]
                ]
            ]]
        ]
        let data = try JSONSerialization.data(withJSONObject: response)

        #expect(AITranslator.assistantContentForDiagnostics(from: data) == "第一行\n第二行")
    }

    @Test func translationSanitizerRejectsReasoningLeak() {
        let leaked = """
        analysis: 根据用户提示词先分析人物关系
        _output = "こんにちは"
        """

        #expect(
            AITranslator.sanitizedTranslationTextForDiagnostics(
                leaked,
                sourceText: "你好"
            ) == nil
        )
        #expect(
            AITranslator.sanitizedTranslationTextForDiagnostics(
                "译文：こんにちは",
                sourceText: "你好",
                target: .japanese
            ) == "こんにちは"
        )
    }

    @Test func fuzzyOCRDuplicatesAreCollapsed() {
        let original = TextBlock(
            text: "没想到你还到了",
            boundingBox: CGRect(x: 0.62, y: 0.18, width: 0.23, height: 0.08),
            confidence: 0.63,
            ocrSource: "original"
        )
        let enhanced = TextBlock(
            text: "没想到你迟到了",
            boundingBox: CGRect(x: 0.615, y: 0.182, width: 0.235, height: 0.081),
            confidence: 0.76,
            ocrSource: "enhanced"
        )

        let result = AITranslator.deduplicatedMangaTextBlocks(
            [original, enhanced],
            isRightToLeft: false
        )

        #expect(result.count == 1)
        #expect(result[0].ocrSource == "enhanced")
    }

    @Test func visionJSONRepairsRawNewlinesAndMapsCompressedPixels() throws {
        let response = """
        ```json
        {
          "coordinateSpace": "normalized",
          "items": [{
            "text": "原文",
            "translation": "第一行
        第二行",
            "bubbleBox": {"x": 0.25, "y": 0.25, "width": 0.5, "height": 0.5}
          }]
        }
        ```
        """

        let blocks = try AITranslator.parseVisionTranslationBlocksForDiagnostics(
            from: response,
            inputPixelSize: CGSize(width: 2_048, height: 512)
        )

        #expect(blocks.count == 1)
        #expect(blocks[0].translation == "第一行\n第二行")
        #expect(abs(blocks[0].boundingBox.minX - 0.25) < 0.000_1)
        #expect(abs(blocks[0].boundingBox.minY - 0.25) < 0.000_1)
        #expect(abs(blocks[0].boundingBox.width - 0.5) < 0.000_1)
        #expect(abs(blocks[0].boundingBox.height - 0.5) < 0.000_1)
    }

    @Test func visionThousandScaleCoordinatesWithoutMarkerAreRejected() throws {
        // 0~1000 归一化不再被自动猜测；没有显式 normalized 标记的 100/700 等坐标（值 > 1）应被拒绝
        let response = """
        {"items": [{"text": "原文", "translation": "译文", "bubbleBox": {"x": 100, "y": 700, "width": 800, "height": 250}}]}
        """

        do {
            _ = try AITranslator.parseVisionTranslationBlocksForDiagnostics(
                from: response,
                inputPixelSize: CGSize(width: 900, height: 600)
            )
            Issue.record("0~1000 坐标缺少 normalized 标记应被拒绝")
        } catch {
            // 期望：抛出坐标协议错误
        }
    }

    @Test func visionAllItemsShareExplicitNormalizedSpace() throws {
        // 同一响应内所有坐标都在显式 normalized 空间内，统一按 0...1 解析
        let response = """
        {"coordinateSpace": "normalized", "items": [
          {"text": "杂点", "translation": "杂点译文", "bubbleBox": {"x": 0.01, "y": 0.01, "width": 0.05, "height": 0.05}},
          {"text": "对白", "translation": "对白译文", "bubbleBox": {"x": 0.25, "y": 0.25, "width": 0.5, "height": 0.5}}
        ]}
        """

        let blocks = try AITranslator.parseVisionTranslationBlocksForDiagnostics(
            from: response,
            inputPixelSize: CGSize(width: 2_048, height: 512)
        )

        #expect(blocks.count == 2)
        #expect(blocks[1].translation == "对白译文")
        #expect(abs(blocks[1].boundingBox.minX - 0.25) < 0.000_1)
    }

    @Test func translationSanitizerStripsAnnouncementPrefixInsteadOfRejecting() {
        #expect(
            AITranslator.sanitizedTranslationTextForDiagnostics(
                "以下是翻译：你来晚了",
                sourceText: "遅かったな"
            ) == "你来晚了"
        )
    }

    @Test func burnInProtectionUsesFourHourTimeout() {
        #expect(BurnInProtectionPolicy.timeout == 14_400)
    }

    @Test func versionFourSettingsBackupRemainsDecodable() throws {
        let json = """
        {
          "version": 4,
          "openAIAPIKey": "test-key",
          "openAIBaseURL": "https://example.com/v1",
          "openAIModel": "model",
          "translationTargetLanguage": "中文",
          "isHapticFeedbackEnabled": true
        }
        """

        let backup = try JSONDecoder().decode(MReaderSettingsBackup.self, from: Data(json.utf8))

        #expect(backup.version == 4)
        #expect(backup.translationColorStyle == nil)
        #expect(backup.readingDailyPageGoal == nil)
    }

    @Test func imageOnlyEPUBUsesSpineXHTMLImagesAsPages() throws {
        let fileManager = FileManager.default
        let temporaryRoot = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let sourceRoot = temporaryRoot.appendingPathComponent("source", isDirectory: true)
        let epubURL = temporaryRoot.appendingPathComponent("fixture.epub")
        defer { try? fileManager.removeItem(at: temporaryRoot) }

        try fileManager.createDirectory(at: sourceRoot.appendingPathComponent("META-INF"), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: sourceRoot.appendingPathComponent("OEBPS/Text"), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: sourceRoot.appendingPathComponent("OEBPS/Images"), withIntermediateDirectories: true)
        try Data("application/epub+zip".utf8).write(to: sourceRoot.appendingPathComponent("mimetype"))
        try Data("""
        <?xml version="1.0"?>
        <container>
          <rootfiles>
            <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
          </rootfiles>
        </container>
        """.utf8).write(to: sourceRoot.appendingPathComponent("META-INF/container.xml"))
        try Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <package version="3.0">
          <manifest>
            <item id="p1" href="Text/001.xhtml" media-type="application/xhtml+xml"/>
            <item id="p2" href="Text/002.xhtml" media-type="application/xhtml+xml"/>
            <item id="p3" href="Text/003.xhtml" media-type="application/xhtml+xml"/>
            <item id="i1" href="Images/001.jpg" media-type="image/jpeg"/>
            <item id="i2" href="Images/002.jpg" media-type="image/jpeg"/>
            <item id="i3" href="Images/003.jpg" media-type="image/jpeg"/>
          </manifest>
          <spine>
            <itemref idref="p1"/>
            <itemref idref="p2"/>
            <itemref idref="p3"/>
          </spine>
        </package>
        """.utf8).write(to: sourceRoot.appendingPathComponent("OEBPS/content.opf"))

        for index in 1...3 {
            let name = String(format: "%03d", index)
            try Data("<html><body><img src=\"../Images/\(name).jpg\"/></body></html>".utf8)
                .write(to: sourceRoot.appendingPathComponent("OEBPS/Text/\(name).xhtml"))
            try Data([0xFF, 0xD8, 0xFF, 0xD9])
                .write(to: sourceRoot.appendingPathComponent("OEBPS/Images/\(name).jpg"))
        }

        try fileManager.zipItem(at: sourceRoot, to: epubURL, shouldKeepParent: false)

        #expect(try ComicManager.archivePageCountForDiagnostics(at: epubURL) == 3)
    }

    @Test func providedRedChamberEPUBParsesAllImagePagesWhenInstalled() throws {
        let epubURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mreader-real-epub-diagnostic.epub")
        guard FileManager.default.fileExists(atPath: epubURL.path) else { return }

        #expect(try ComicManager.archivePageCountForDiagnostics(at: epubURL) == 174)
    }

    @Test func providedBaoYuEPUBFirstPageDecodesWhenInstalled() throws {
        let epubURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mreader-baoyu-epub-diagnostic.epub")
        guard FileManager.default.fileExists(atPath: epubURL.path) else { return }

        #expect(try ComicManager.archivePageCountForDiagnostics(at: epubURL) == 126)
        let data = try ComicManager.archiveFirstPageDataForDiagnostics(at: epubURL)
        let source = CGImageSourceCreateWithData(data as CFData, nil)
        #expect(source != nil)
        #expect(CGImageSourceGetCount(source!) == 1)
        #expect(CGImageSourceCreateThumbnailAtIndex(
            source!,
            0,
            [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 2_048
            ] as CFDictionary
        ) != nil)

        let pageURL = try ComicManager.archiveFirstPageURLForDiagnostics(at: epubURL)
        #expect(ComicManager.isArchivePageURL(pageURL))
        let pageData = try #require(ComicManager.imageData(forArchivePageURL: pageURL))
        #expect(pageData == data)

        let secondPageData = try ComicManager.archivePageDataForDiagnostics(at: epubURL, index: 1)
        let secondPageSource = try #require(CGImageSourceCreateWithData(secondPageData as CFData, nil))
        #expect(CGImageSourceCreateThumbnailAtIndex(
            secondPageSource,
            0,
            [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 2_048
            ] as CFDictionary
        ) != nil)
    }

    @Test func remotePageCacheRetainsOnlyTheActiveWindow() async {
        let cache = RemotePageCache.shared
        await cache.clearMemoryCache()
        let sourceID = UUID()
        let oldPage = PageCacheKey(sourceID: sourceID, bookID: "book", pageIndex: 1)
        let currentPage = PageCacheKey(sourceID: sourceID, bookID: "book", pageIndex: 2)
        let prefetchedPage = PageCacheKey(sourceID: sourceID, bookID: "book", pageIndex: 3)

        await cache.storeForDiagnostics(Data([1]), for: oldPage)
        await cache.storeForDiagnostics(Data([2]), for: currentPage)
        await cache.storeForDiagnostics(Data([3]), for: prefetchedPage)
        await cache.retainMemoryPages([currentPage, prefetchedPage])

        let hasOldPage = await cache.containsInMemoryForDiagnostics(oldPage)
        let hasCurrentPage = await cache.containsInMemoryForDiagnostics(currentPage)
        let hasPrefetchedPage = await cache.containsInMemoryForDiagnostics(prefetchedPage)
        #expect(!hasOldPage)
        #expect(hasCurrentPage)
        #expect(hasPrefetchedPage)
        await cache.clearMemoryCache()
    }

    @Test func librarySyncCoordinatorCoalescesConcurrentRefreshes() async {
        let coordinator = LibrarySyncCoordinator()
        let probe = LibrarySyncProbe()
        let gate = LibrarySyncGate()

        let firstRefresh = Task {
            await coordinator.perform(scope: .local) { scope in
                await probe.record(scope)
                await gate.wait()
            }
        }
        while await coordinator.activeRequestCountForDiagnostics() < 1 {
            await Task.yield()
        }

        await withTaskGroup(of: Void.self) { group in
            for scope in [LibrarySyncScope.komga, .opds, .komga] {
                group.addTask {
                    await coordinator.perform(scope: scope) { requestedScope in
                        await probe.record(requestedScope)
                    }
                }
            }

            // Hold the first refresh until every concurrent caller has reached
            // the actor, so the test does not depend on task scheduling.
            while await coordinator.activeRequestCountForDiagnostics() < 4 {
                await Task.yield()
            }
            await gate.open()
        }
        await firstRefresh.value

        let scopes = await probe.invocationScopes
        #expect(scopes.count == 2)
        #expect(scopes.first == .local)
        #expect(scopes.last?.contains(.komga) == true)
        #expect(scopes.last?.contains(.opds) == true)
        #expect(!(await coordinator.isRefreshingForDiagnostics()))
    }

    @Test func encryptedSettingsBackupHidesCredentialsAndRoundTrips() throws {
        let secret = "integration-secret-value"
        let profile = AIProviderProfile.normalized(
            name: "Test",
            baseURL: "https://example.com/v1",
            modelsText: "model-a",
            selectedTextModel: "model-a",
            selectedVisionModel: "model-a"
        )
        let backup = MReaderSettingsBackup(
            openAIAPIKey: secret,
            openAIBaseURL: profile.baseURL,
            openAIModel: profile.selectedTextModel,
            aiModelPool: nil,
            isAIModelPoolEnabled: false,
            translationTargetLanguage: "简体中文",
            translationPromptTemplate: nil,
            visionTranslationPromptTemplate: nil,
            isHapticFeedbackEnabled: true,
            mediaSources: nil,
            translationColorStyle: nil,
            isAITranslationBorderProgressEnabled: true,
            isOCRDebugBoxesEnabled: false,
            readingDailyPageGoal: 40,
            isBurnInProtectionEnabled: true,
            aiProviders: [AIProviderBackup(profile: profile, apiKey: secret)],
            activeAIProviderID: profile.id,
            containsCredentials: true
        )

        let encrypted = try SettingsBackupCodec.encodeEncrypted(backup, password: "valid-password")
        #expect(SettingsBackupCodec.isEncrypted(encrypted))
        #expect(!(String(data: encrypted, encoding: .utf8) ?? "").contains(secret))

        let restored = try SettingsBackupCodec.decode(encrypted, password: "valid-password")
        #expect(restored.openAIAPIKey == secret)
        #expect(restored.aiProviders?.first?.apiKey == secret)
        #expect(throws: (any Error).self) {
            _ = try SettingsBackupCodec.decode(encrypted, password: "wrong-password")
        }
    }

    @Test func plainSettingsBackupRejectsCredentials() throws {
        let secret = "must-not-be-plain-text"
        var backup = MReaderSettingsBackup(
            openAIAPIKey: secret,
            openAIBaseURL: "https://example.com/v1",
            openAIModel: "model-a",
            aiModelPool: nil,
            isAIModelPoolEnabled: false,
            translationTargetLanguage: "简体中文",
            translationPromptTemplate: nil,
            visionTranslationPromptTemplate: nil,
            isHapticFeedbackEnabled: true,
            mediaSources: nil,
            translationColorStyle: nil,
            isAITranslationBorderProgressEnabled: true,
            isOCRDebugBoxesEnabled: false,
            readingDailyPageGoal: 40,
            isBurnInProtectionEnabled: true,
            aiProviders: nil,
            activeAIProviderID: nil,
            containsCredentials: true
        )

        #expect(throws: SettingsBackupCodecError.self) {
            _ = try SettingsBackupCodec.encodePlain(backup)
        }

        backup.openAIAPIKey = nil
        backup.containsCredentials = false
        let plainData = try SettingsBackupCodec.encodePlain(backup)
        #expect(!SettingsBackupCodec.isEncrypted(plainData))
        #expect(!(String(data: plainData, encoding: .utf8) ?? "").contains(secret))
    }

    @Test func remoteProgressKeepsLatestLocationAndHighestCompletion() {
        let now = Date()
        let existing = ComicBook(
            title: "Remote",
            bookmarkData: Data(),
            totalPages: 100,
            currentPageIndex: 40,
            furthestPageIndex: 70,
            progressUpdatedAt: now
        )
        let olderRemote = ComicBook(
            title: "Remote",
            bookmarkData: Data(),
            totalPages: 100,
            currentPageIndex: 60,
            furthestPageIndex: 60,
            progressUpdatedAt: now.addingTimeInterval(-60)
        )
        let resolution = ReadingProgressMergePolicy.resolve(
            existing: existing,
            incoming: olderRemote,
            totalPages: 100
        )

        #expect(resolution.currentPageIndex == 40)
        #expect(resolution.furthestPageIndex == 70)
        #expect(!resolution.usesIncomingLocation)
        #expect(ReadingProgressMergePolicy.serverPageIndex(for: existing) == 70)
    }

    @Test @MainActor func legacyComicProgressMigratesFurthestPageFromCurrentLocation() throws {
        let legacy = """
        {
          "id":"\(UUID().uuidString)",
          "title":"Legacy",
          "bookmarkData":"",
          "totalPages":50,
          "sourceTypeRaw":"local",
          "currentPageIndex":12
        }
        """
        let comic = try JSONDecoder().decode(ComicBook.self, from: Data(legacy.utf8))

        #expect(comic.currentPageIndex == 12)
        #expect(comic.furthestPageIndex == 12)
        #expect(comic.progressUpdatedAt == .distantPast)
    }

    @Test func translationPrefetchRequiresAutoTranslationAndStaysAhead() {
        #expect(AITranslationPrefetchPolicy.pageIndices(
            currentPageIndex: 3,
            pageCount: 10,
            isAutoTranslationEnabled: false
        ).isEmpty)
        #expect(AITranslationPrefetchPolicy.pageIndices(
            currentPageIndex: 3,
            pageCount: 10,
            isAutoTranslationEnabled: true
        ) == [4, 5])
        #expect(AITranslationPrefetchPolicy.pageIndices(
            currentPageIndex: 8,
            pageCount: 10,
            isAutoTranslationEnabled: true
        ) == [9])
        #expect(AITranslationPrefetchPolicy.pageIndices(
            currentPageIndex: 9,
            pageCount: 10,
            isAutoTranslationEnabled: true
        ).isEmpty)
    }

    @Test func guidedPanelOrderingFollowsReadingDirection() {
        let left = CGRect(x: 0.05, y: 0.05, width: 0.4, height: 0.35)
        let right = CGRect(x: 0.55, y: 0.05, width: 0.4, height: 0.35)
        let bottom = CGRect(x: 0.1, y: 0.55, width: 0.8, height: 0.35)

        #expect(PanelDetectionService.sortedPanelsForDiagnostics([bottom, right, left], isRightToLeft: false) == [left, right, bottom])
        #expect(PanelDetectionService.sortedPanelsForDiagnostics([bottom, left, right], isRightToLeft: true) == [right, left, bottom])
    }

    @Test @MainActor func comicSyncIdentityIsStableAcrossComicIDs() {
        let first = ComicBook(
            title: "Chapter 1",
            bookmarkData: Data(),
            totalPages: 20,
            libraryPath: "/private/device-a/MReader/Series/Chapter 1.cbz"
        )
        var second = first
        second.id = UUID()
        second.libraryPath = "/private/device-b/MReader/Series/Chapter 1.cbz"

        #expect(ComicSyncIdentity.value(for: first) == ComicSyncIdentity.value(for: second))
    }

    @Test func offlineComicRecordRoundTrips() throws {
        let record = OfflineComicRecord(
            comicID: UUID(),
            sourceID: UUID(),
            sourceTypeRaw: ComicSourceType.komga.rawValue,
            remoteID: "book-42",
            pageCount: 128,
            fileName: nil,
            completedAt: Date(timeIntervalSince1970: 1234)
        )
        let decoded = try JSONDecoder().decode(OfflineComicRecord.self, from: JSONEncoder().encode(record))
        #expect(decoded.comicID == record.comicID)
        #expect(decoded.remoteID == "book-42")
        #expect(decoded.pageCount == 128)
    }

    @Test func continuousPrefetchFollowsScrollDirectionWithinBounds() {
        let down = ReaderPrefetchPolicy.pageIndices(
            currentPageIndex: 5,
            pageCount: 20,
            readingDirection: .rightToLeft,
            readingMode: .continuousScroll,
            scrollDirection: 1,
            forwardCount: 3,
            backwardCount: 1,
            includesCurrentPage: true
        )
        let up = ReaderPrefetchPolicy.pageIndices(
            currentPageIndex: 1,
            pageCount: 4,
            readingDirection: .leftToRight,
            readingMode: .continuousScroll,
            scrollDirection: -1,
            forwardCount: 3,
            backwardCount: 1,
            includesCurrentPage: false
        )

        #expect(down == [5, 6, 7, 8, 4])
        #expect(up == [0, 2])
    }

}

private final class AITransportRecordingURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var responseData = Data(#"{"output_text":"ok"}"#.utf8)
    private static var lastCapturedRequest: URLRequest?

    static func configure(responseData: Data) {
        lock.lock()
        self.responseData = responseData
        lastCapturedRequest = nil
        lock.unlock()
    }

    static func lastRequest() -> URLRequest? {
        lock.lock()
        defer { lock.unlock() }
        return lastCapturedRequest
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "api.example.test"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.lock.lock()
        Self.lastCapturedRequest = request
        let data = Self.responseData
        Self.lock.unlock()

        guard let url = request.url,
              let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
              ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private func aiTransportRecordingSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [AITransportRecordingURLProtocol.self]
    return URLSession(configuration: configuration)
}

private actor LibrarySyncProbe {
    private(set) var invocationScopes: [LibrarySyncScope] = []

    var invocationCount: Int {
        invocationScopes.count
    }

    func record(_ scope: LibrarySyncScope) {
        invocationScopes.append(scope)
    }

    // MARK: - 代码审查回归测试

    @Test func opdsAuthorizationNotForwardedToCrossOriginHost() {
        // OPDS feed 可能给出指向第三方域名的 cover/acquisition URL：
        // 同源（scheme+host+port 一致）才转发凭据，跨域绝不携带 Authorization。
        #expect(
            OPDSAuthorizationPolicy.shouldForward(
                sourceBaseURL: "https://my-komga.example.com",
                to: URL(string: "https://my-komga.example.com/book.cbz")!
            )
        )
        #expect(
            OPDSAuthorizationPolicy.shouldForward(
                sourceBaseURL: "https://my-komga.example.com",
                to: URL(string: "https://evil.example.com/book.cbz")!
            ) == false
        )
        #expect(
            OPDSAuthorizationPolicy.shouldForward(
                sourceBaseURL: "http://my-komga.example.com:8080",
                to: URL(string: "http://my-komga.example.com/book.cbz")!
            ) == false
        )
        #expect(
            OPDSAuthorizationPolicy.shouldForward(
                sourceBaseURL: "http://my-komga.example.com:8080",
                to: URL(string: "http://my-komga.example.com:8080/book.cbz")!
            )
        )
        #expect(
            OPDSAuthorizationPolicy.shouldForward(
                sourceBaseURL: "https://my-komga.example.com",
                to: URL(string: "http://my-komga.example.com/book.cbz")!
            ) == false
        )
    }

    @Test func readingProgressMergePreservesBackwardReRead() {
        // Komga 之前记录到 300 页，用户在本地重读到 50 页（updatedAt 更新）。
        // 合并必须保留 50 作为当前阅读位置，而不是 max(300, 50) = 300。
        let existing = ComicBook(
            title: "test",
            bookmarkData: Data(),
            totalPages: 400,
            currentPageIndex: 50,
            furthestPageIndex: 300,
            progressUpdatedAt: Date(timeIntervalSince1970: 2_000)
        )
        let incoming = ComicBook(
            title: "test",
            bookmarkData: Data(),
            totalPages: 400,
            currentPageIndex: 300,
            furthestPageIndex: 300,
            progressUpdatedAt: Date(timeIntervalSince1970: 1_000)
        )
        let resolution = ReadingProgressMergePolicy.resolve(
            existing: existing,
            incoming: incoming,
            totalPages: 400
        )
        #expect(resolution.currentPageIndex == 50)
        #expect(resolution.furthestPageIndex == 300)
    }

    @Test func readingProgressMergeTakesNewerRemoteWhenAhead() {
        // 反向场景：远端更新晚于本地且更靠后时，当前页取远端位置。
        let existing = ComicBook(
            title: "test",
            bookmarkData: Data(),
            totalPages: 400,
            currentPageIndex: 50,
            furthestPageIndex: 300,
            progressUpdatedAt: Date(timeIntervalSince1970: 1_000)
        )
        let incoming = ComicBook(
            title: "test",
            bookmarkData: Data(),
            totalPages: 400,
            currentPageIndex: 320,
            furthestPageIndex: 320,
            progressUpdatedAt: Date(timeIntervalSince1970: 2_000)
        )
        let resolution = ReadingProgressMergePolicy.resolve(
            existing: existing,
            incoming: incoming,
            totalPages: 400
        )
        #expect(resolution.currentPageIndex == 320)
        #expect(resolution.furthestPageIndex == 320)
    }

    @Test @MainActor func ocrCoordinateMapperOriginalDoesNotUpscale() {
        // “原始尺寸”语义：小图 1:1（1 image pixel = 1 point），不再等同 fitScreen。
        let transform = OCRCoordinateMapper.displayTransform(
            sourcePixelSize: CGSize(width: 400, height: 300),
            containerSize: CGSize(width: 1_000, height: 1_000),
            fitMode: .original
        )
        #expect(transform.imageRect.width == 400)
        #expect(transform.imageRect.height == 300)

        // 大图则等比缩小到容器内，而不是溢出
        let large = OCRCoordinateMapper.displayTransform(
            sourcePixelSize: CGSize(width: 2_000, height: 4_000),
            containerSize: CGSize(width: 1_000, height: 1_000),
            fitMode: .original
        )
        #expect(large.imageRect.width == 500)
        #expect(large.imageRect.height == 1_000)
    }

    @Test func settingsBackupPlainEncodeRefusesCredentials() {
        // 明文设置备份不允许携带任何 API Key / 凭据；带凭据必须走加密。
        let backup = MReaderSettingsBackup(
            openAIAPIKey: "sk-test",
            openAIBaseURL: "https://api.openai.com/v1",
            openAIModel: "gpt-4o-mini",
            translationTargetLanguage: "中文",
            isHapticFeedbackEnabled: true,
            containsCredentials: true
        )
        #expect(throws: (any Error).self) {
            _ = try SettingsBackupCodec.encodePlain(backup)
        }

        // 不带凭据的备份可以明文编码
        let plain = MReaderSettingsBackup(
            openAIAPIKey: nil,
            openAIBaseURL: "https://api.openai.com/v1",
            openAIModel: "gpt-4o-mini",
            translationTargetLanguage: "中文",
            isHapticFeedbackEnabled: true,
            containsCredentials: false
        )
        #expect((try? SettingsBackupCodec.encodePlain(plain)) != nil)
    }

    // MARK: - 第二份审查报告回归测试（源语言 + 模型拆分）

    @Test func legacySelectedModelMigratesToBothRoles() throws {
        let json = """
        {
          "id": "00000000-0000-0000-0000-000000000001",
          "name": "旧接口",
          "baseURL": "https://example.com/v1",
          "models": ["old-model"],
          "selectedModel": "old-model",
          "createdAt": 1000,
          "updatedAt": 1000
        }
        """
        let profile = try JSONDecoder().decode(
            AIProviderProfile.self,
            from: Data(json.utf8)
        )
        #expect(profile.selectedTextModel == "old-model")
        #expect(profile.selectedVisionModel == "old-model")
    }

    @Test @MainActor func replaceProfilesWithEmptyListClearsActiveID() throws {
        let suiteName = "ReplaceProfilesClearTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = AIProviderStore(defaults: defaults, credentials: InMemoryAICredentialStore())
        let profile = AIProviderProfile.normalized(
            name: "接口",
            baseURL: "https://a.example/v1",
            modelsText: "model-a",
            selectedTextModel: "model-a",
            selectedVisionModel: "model-a"
        )
        try store.save(profile: profile, apiKey: "k")
        store.setActiveProfile(id: profile.id)
        #expect(store.activeProfileID() == profile.id)

        try store.replaceProfiles([], activeProfileID: profile.id)
        #expect(store.activeProfileID() == nil)
    }

    @Test func translationSourceLanguageDefaultsToAutomatic() {
        let comic = ComicBook(title: "t", bookmarkData: Data(), totalPages: 1)
        #expect(comic.translationSourceLanguage == .automatic)
    }

    @Test func translationSourceResolverUsesManualPreferenceFirst() {
        let decision = TranslationSourceResolver.resolve(
            preference: .english,
            blocks: [TextBlock(text: "No!", boundingBox: .zero, confidence: 0.9, ocrSource: "original:en")],
            previousStableLanguage: nil
        )
        #expect(decision?.languageCode == "en")
        #expect(decision?.confidence == 1)
    }

    @Test func translationSourceResolverFallsBackToPreviousWhenUncertain() {
        let decision = TranslationSourceResolver.resolve(
            preference: .automatic,
            blocks: [],
            previousStableLanguage: "ja"
        )
        #expect(decision?.languageCode == "ja")
    }

    @Test func translationSourceResolverReturnsNilWhenUnknownAndNoPrevious() {
        let decision = TranslationSourceResolver.resolve(
            preference: .automatic,
            blocks: [],
            previousStableLanguage: nil
        )
        #expect(decision == nil)
    }

    @Test func translationOutputValidatorPageLevelRejectsDifferentLatinLanguage() {
        // 目标英语：整页译文若是清晰的其它拉丁语言（法语），应判定不兼容
        let french = "Bonjour, comment allez-vous aujourd'hui? Je vais tres bien, merci beaucoup."
        #expect(
            TranslationOutputValidator.pageIsCompatible(
                [french],
                target: .english
            ) == false
        )
        let english = "Hello, how are you doing today? I am doing very well, thank you."
        #expect(
            TranslationOutputValidator.pageIsCompatible(
                [english],
                target: .english
            )
        )
    }

    @Test func translationPageCacheKeyTracksModelRoles() {
        // 纯 OCR 翻译：只依赖 textModel；visionModel 变化不应改变缓存 key
        let ocrA = makeTestPageRequest(mode: .ocr, textModel: "text-a", visionModel: "vision-a", visualVerify: false)
        let ocrB = makeTestPageRequest(mode: .ocr, textModel: "text-a", visionModel: "vision-b", visualVerify: false)
        #expect(ocrA.cacheKey == ocrB.cacheKey)

        let ocrC = makeTestPageRequest(mode: .ocr, textModel: "text-b", visionModel: "vision-a", visualVerify: false)
        #expect(ocrA.cacheKey != ocrC.cacheKey)

        // 开启视觉复核：visionModel 变化必须使缓存 key 变化
        let verifyA = makeTestPageRequest(mode: .ocr, textModel: "text-a", visionModel: "vision-a", visualVerify: true)
        let verifyB = makeTestPageRequest(mode: .ocr, textModel: "text-a", visionModel: "vision-b", visualVerify: true)
        #expect(verifyA.cacheKey != verifyB.cacheKey)

        // Vision 模式：visionModel 与 textModel 都进入缓存 key
        let visionA = makeTestPageRequest(mode: .vision, textModel: "text-a", visionModel: "vision-a", visualVerify: false)
        let visionB = makeTestPageRequest(mode: .vision, textModel: "text-a", visionModel: "vision-b", visualVerify: false)
        #expect(visionA.cacheKey != visionB.cacheKey)
        let visionC = makeTestPageRequest(mode: .vision, textModel: "text-b", visionModel: "vision-a", visualVerify: false)
        #expect(visionA.cacheKey != visionC.cacheKey)
    }
}

private actor LibrarySyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            waiters.append(continuation)
        }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let continuations = waiters
        waiters.removeAll()
        for continuation in continuations {
            continuation.resume()
        }
    }
}

private func makeTestPageRequest(
    mode: AITranslationMode,
    textModel: String,
    visionModel: String,
    visualVerify: Bool
) -> AITranslationPageRequest {
    AITranslationPageRequest(
        pageURL: URL(fileURLWithPath: "/tmp/page.png"),
        image: UIImage(),
        mode: mode,
        configuration: AIActiveConfiguration(
            profileID: UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!,
            profileName: "p",
            baseURL: "https://example.com/v1",
            apiKey: "k",
            textModel: textModel,
            visionModel: visionModel
        ),
        target: .simplifiedChinese,
        translationPromptTemplate: "t",
        visionPromptTemplate: "v",
        isRightToLeft: false,
        minimumTextHeight: 0.002,
        ocrRecognitionMode: .adaptive,
        safeAreaInset: 0,
        usesVisualOCRVerification: visualVerify,
        viewportAspect: 1.5,
        sourceLanguagePreference: nil,
        previousContext: ""
    )
}

    // MARK: - 第四份审查报告回归测试

    @Test func chatResponseDecoderChatCompletionsString() throws {
        let data = Data(#"{"choices":[{"message":{"content":"你好"}}]}"#.utf8)
        let decoded = AIChatResponseDecoder.decode(data)
        #expect(decoded.content == "你好")
        #expect(!decoded.hasReasoningOnly)
    }

    @Test func chatResponseDecoderContentArray() throws {
        let data = Data(#"{"choices":[{"message":{"content":[{"type":"text","text":"a"},{"type":"text","text":"b"}]}}]}"#.utf8)
        let decoded = AIChatResponseDecoder.decode(data)
        #expect(decoded.content == "a\nb")
    }

    @Test func chatResponseDecoderLegacyText() throws {
        let data = Data(#"{"choices":[{"text":"legacy"}]}"#.utf8)
        let decoded = AIChatResponseDecoder.decode(data)
        #expect(decoded.content == "legacy")
    }

    @Test func chatResponseDecoderResponsesOutputText() throws {
        let data = Data(#"{"output_text":"top-level"}"#.utf8)
        let decoded = AIChatResponseDecoder.decode(data)
        #expect(decoded.content == "top-level")
    }

    @Test func chatResponseDecoderResponsesNestedOutput() throws {
        let data = Data(#"{"output":[{"content":[{"type":"output_text","text":"nested"}]}]}"#.utf8)
        let decoded = AIChatResponseDecoder.decode(data)
        #expect(decoded.content == "nested")
    }

    @Test func chatResponseDecoderReasoningOnly() throws {
        let data = Data(#"{"choices":[{"message":{"reasoning_content":"thinking...","content":null},"finish_reason":"length"}]}"#.utf8)
        let decoded = AIChatResponseDecoder.decode(data)
        #expect(decoded.content == nil)
        #expect(decoded.hasReasoningOnly)
        #expect(decoded.finishReason == "length")
    }

    @Test func chatResponseDecoderMalformed() {
        let decoded = AIChatResponseDecoder.decode(Data("not json".utf8))
        #expect(decoded.content == nil)
        #expect(!decoded.hasReasoningOnly)
    }

    @Test func singleBubblePromptAlwaysIncludesOcrTextAndTarget() {
        let prompt = AITranslator.singleBubbleTranslationPrompt(
            text: "こんにちは",
            target: .simplifiedChinese,
            pageContext: "1. 遅いね\n2. ごめん",
            ocrMetadata: "textBox=(0.1,0.2,0.3,0.1)",
            styleInstructions: "保持自然口语"
        )
        #expect(prompt.contains("こんにちは"))
        #expect(prompt.contains("简体中文"))
        #expect(prompt.contains("保持自然口语"))
        #expect(prompt.contains("1. 遅いね"))
        #expect(prompt.contains("textBox=(0.1,0.2,0.3,0.1)"))
        // 不能出现未替换的旧占位符
        #expect(!prompt.contains("{ocrText}"))
        #expect(!prompt.contains("{targetLanguage}"))
    }

    @Test func settingsBackupV10RoundTripsStyleInstructions() throws {
        let profile = AIProviderProfile.normalized(
            name: "接口",
            baseURL: "https://a.example/v1",
            modelsText: "model-a",
            selectedTextModel: "model-a",
            selectedVisionModel: "model-a"
        )
        let backup = MReaderSettingsBackup(
            openAIAPIKey: "key",
            openAIBaseURL: "https://a.example/v1",
            openAIModel: "model-a",
            translationTargetLanguage: "简体中文",
            translationStyleInstructions: "人名保留日文原名",
            isHapticFeedbackEnabled: true,
            aiProviders: [AIProviderBackup(profile: profile, apiKey: "key")]
        )
        let decoded = try JSONDecoder().decode(
            MReaderSettingsBackup.self,
            from: JSONEncoder().encode(backup)
        )
        #expect(decoded.version == 10)
        #expect(decoded.translationStyleInstructions == "人名保留日文原名")
    }

    @Test func settingsBackupV9LegacyPromptIsSeparateField() throws {
        let json = """
        {
          "version": 9,
          "openAIBaseURL": "https://a.example/v1",
          "openAIModel": "model-a",
          "translationTargetLanguage": "简体中文",
          "isHapticFeedbackEnabled": true,
          "translationPromptTemplate": "我是漫画翻译助手……{ocrText}……"
        }
        """
        let decoded = try JSONDecoder().decode(MReaderSettingsBackup.self, from: Data(json.utf8))
        #expect(decoded.version == 9)
        #expect(decoded.translationPromptTemplate?.contains("{ocrText}") == true)
        #expect(decoded.translationStyleInstructions == nil)
    }

    @Test func ocrManualFrenchUsesFrenchPassFirst() {
        let passes = OCRPreprocessor.preferredLanguagePassesForDiagnostics(
            detectedTexts: ["Bonjour, comment ça va?"],
            sourceLanguagePreference: .french
        )
        #expect(passes.first?.contains("fr-FR") == true)
    }

    @Test func ocrManualRussianUsesRussianPassFirst() {
        let passes = OCRPreprocessor.preferredLanguagePassesForDiagnostics(
            detectedTexts: ["Привет, как дела?"],
            sourceLanguagePreference: .russian
        )
        #expect(passes.first?.contains("ru-RU") == true)
    }

    @Test func ocrMaximumAccuracyRespectsManualLanguage() {
        let passes = OCRPreprocessor.maximumAccuracyPassesForDiagnostics(
            sourceLanguagePreference: .french
        )
        #expect(passes.first?.contains("fr-FR") == true)
    }

    @Test func supportedRecognitionLanguagesNeverReturnsUnsupported() throws {
        let preferred = ["ar-SA", "ru-RU", "fr-FR", "en-US"]
        let result = OCRPreprocessor.supportedRecognitionLanguagesForDiagnostics(
            preferredLanguages: preferred
        )
        let supported = (try? VNRecognizeTextRequest().supportedRecognitionLanguages()) ?? []
        if !supported.isEmpty {
            // 结果只能是 supported 的子集；不能把已知不支持的塞回去（项10）
            #expect(result.allSatisfy { supported.contains($0) })
        }
    }

    @Test func aiEndpointResolverNormalizesChatCompletionsURL() {
        #expect(
            AIEndpointResolver.chatCompletionsURL(from: "https://api.xxx/v1")?
                .absoluteString == "https://api.xxx/v1/chat/completions"
        )
        #expect(
            AIEndpointResolver.chatCompletionsURL(from: "https://api.xxx/v1/chat/completions")?
                .absoluteString == "https://api.xxx/v1/chat/completions"
        )
    }

    // MARK: - 整本离线翻译回归测试

    @Test func offlineTranslationSelectionUsesZeroBasedIndexesAndValidatesRanges() throws {
        #expect(try OfflineTranslationSelection.entireComic.pageIndexes(totalPages: 4) == [0, 1, 2, 3])
        #expect(try OfflineTranslationSelection.fromPage(2).pageIndexes(totalPages: 4) == [2, 3])
        #expect(try OfflineTranslationSelection.range(start: 1, end: 2).pageIndexes(totalPages: 4) == [1, 2])
        #expect(
            try OfflineTranslationSelection.missingPages.pageIndexes(
                totalPages: 4,
                existingStates: [0: .completed, 1: .failed, 2: .noText]
            ) == [1, 3]
        )
        #expect(try OfflineTranslationSelection.failedPages.pageIndexes(totalPages: 4, existingStates: [1: .failed]) == [1])
        #expect(throws: OfflineTranslationSelectionError.self) {
            try OfflineTranslationSelection.range(start: 3, end: 1).pageIndexes(totalPages: 4)
        }
        #expect(throws: OfflineTranslationSelectionError.self) {
            try OfflineTranslationSelection.fromPage(4).pageIndexes(totalPages: 4)
        }
    }

    @Test func offlineTranslationPageFactsRetryPartialAndFailedPagesFromDiskState() {
        let planned = [0, 1, 2, 3]
        let states: [Int: OfflineTranslationPageState] = [
            0: .completed,
            1: .noText,
            2: .partial,
            3: .failed
        ]
        #expect(
            OfflineTranslationPageFacts.remainingPageIndexes(
                plannedPageIndexes: planned,
                states: states
            ) == [2, 3]
        )
        #expect(
            OfflineTranslationPageFacts.remainingPageIndexes(
                plannedPageIndexes: planned,
                states: states,
                excluding: [2]
            ) == [3]
        )
        #expect(
            OfflineTranslationPageFacts.processedPageCount(
                plannedPageIndexes: planned,
                states: states
            ) == 4
        )
    }

    @Test @MainActor func offlineTranslationDisplayPreferenceIsPerComicAndLegacyDefaultsToEnabled() throws {
        let comic = ComicBook(title: "test", bookmarkData: Data(), totalPages: 1)
        #expect(comic.isOfflineTranslationOverlayEnabled)

        var hidden = comic
        hidden.isOfflineTranslationOverlayEnabled = false
        let decoded = try JSONDecoder().decode(
            ComicBook.self,
            from: JSONEncoder().encode(hidden)
        )
        #expect(!decoded.isOfflineTranslationOverlayEnabled)

        var legacyObject = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(comic)) as? [String: Any]
        )
        legacyObject.removeValue(forKey: "isOfflineTranslationOverlayEnabled")
        let legacy = try JSONDecoder().decode(
            ComicBook.self,
            from: JSONSerialization.data(withJSONObject: legacyObject)
        )
        #expect(legacy.isOfflineTranslationOverlayEnabled)
    }

    @Test func offlineTranslationPromptKeepsProtocolSeparateFromStyle() {
        let prompt = OfflineTranslationPromptBuilder.make(
            sourceLanguage: .japanese,
            targetLanguage: .simplifiedChinese,
            isRightToLeft: true,
            styleInstructions: "保持自然口语",
            previousContext: "前页：先走吧"
        )
        #expect(prompt.contains("保持自然口语"))
        #expect(prompt.contains("coordinateSpace=\"normalized\""))
        #expect(prompt.contains("前页：先走吧"))
        #expect(prompt.contains("右到左"))
        #expect(prompt.contains("sourceText"))
        #expect(prompt.contains("translationLines"))
        #expect(prompt.contains("textBox"))
        #expect(prompt.contains("bubblePolygon"))
        #expect(!prompt.contains("{targetLanguage}"))
    }

    @Test func offlineVisionTranslationRequiresTextBoxAndPreservesCoordinateDiagnostics() throws {
        let valid = """
        {"coordinateSpace":"normalized","items":[{
          "id":"a","sourceText":"こんにちは","translation":"你好","translationLines":["你好"],
          "textBox":{"x":0.2,"y":0.3,"width":0.2,"height":0.08},
          "bubbleBox":{"x":0.1,"y":0.2,"width":0.5,"height":0.3},
          "textPolygon":[{"x":0.2,"y":0.3},{"x":0.4,"y":0.3},{"x":0.4,"y":0.38},{"x":0.2,"y":0.38}],
          "bubblePolygon":[{"x":0.1,"y":0.2},{"x":0.6,"y":0.2},{"x":0.6,"y":0.5},{"x":0.1,"y":0.5}],"confidence":0.9,"classification":"dialogue"
        }]}
        """
        let blocks = try AITranslator.parseVisionTranslationBlocksForDiagnostics(
            from: valid,
            inputPixelSize: CGSize(width: 2_048, height: 1_024),
            requiresTextBox: true
        )
        #expect(blocks.first?.boundingBox == CGRect(x: 0.2, y: 0.3, width: 0.2, height: 0.08))

        let unmatchedMultiLine = """
        {"coordinateSpace":"normalized","items":[{"sourceText":"一二三四五六七八九十一二三四五六","translation":"多行译文","textBox":{"x":0.2,"y":0.25,"width":0.16,"height":0.24},"bubbleBox":{"x":0.1,"y":0.2,"width":0.4,"height":0.35},"confidence":0.9,"classification":"dialogue"}]}
        """
        let unmatchedBlocks = try AITranslator.parseVisionTranslationBlocksForDiagnostics(
            from: unmatchedMultiLine,
            inputPixelSize: CGSize(width: 2_048, height: 1_024),
            requiresTextBox: true
        )
        // 没有本地 OCR line 可校准时，多行 Vision textBox 也不能把整个短边当单行字号。
        #expect((unmatchedBlocks.first?.estimatedFontScale ?? 1) < 0.07)
        #expect((unmatchedBlocks.first?.estimatedFontScale ?? 0) > 0.04)

        let verticalVision = """
        {"coordinateSpace":"normalized","items":[{"sourceText":"上下","translation":"上下","textBox":{"x":0.2,"y":0.25,"width":20.0/390.0,"height":40.0/780.0},"bubbleBox":{"x":0.1,"y":0.2,"width":0.2,"height":0.2},"confidence":0.9,"classification":"dialogue"}]}
        """.replacingOccurrences(of: "20.0/390.0", with: "0.05128205")
            .replacingOccurrences(of: "40.0/780.0", with: "0.05128205")
        let verticalVisionBlock = try AITranslator.parseVisionTranslationBlocksForDiagnostics(
            from: verticalVision,
            inputPixelSize: CGSize(width: 390, height: 780),
            requiresTextBox: true
        ).first
        #expect(verticalVisionBlock?.textOrientation == .vertical)
        #expect(abs((verticalVisionBlock?.estimatedFontScale ?? 0) - 20.0 / 390.0) < 0.001)

        let emptyLines = """
        {"coordinateSpace":"normalized","items":[{"sourceText":"こんにちは","translation":"你好","translationLines":[],"textBox":{"x":0.2,"y":0.3,"width":0.2,"height":0.08},"bubbleBox":{"x":0.1,"y":0.2,"width":0.5,"height":0.3},"confidence":0.9,"classification":"dialogue"}]}
        """
        let emptyLineBlocks = try AITranslator.parseVisionTranslationBlocksForDiagnostics(
            from: emptyLines,
            inputPixelSize: CGSize(width: 2_048, height: 1_024),
            requiresTextBox: true
        )
        #expect(emptyLineBlocks.first?.translation == "你好")
        #expect(emptyLineBlocks.first?.translationLines.isEmpty == true)

        let missingTextBox = """
        {"coordinateSpace":"normalized","items":[{"sourceText":"こんにちは","translation":"你好","translationLines":["你好"],"bubbleBox":{"x":0.1,"y":0.2,"width":0.5,"height":0.3},"textPolygon":[{"x":0.2,"y":0.3},{"x":0.4,"y":0.3},{"x":0.4,"y":0.38},{"x":0.2,"y":0.38}],"bubblePolygon":[{"x":0.1,"y":0.2},{"x":0.6,"y":0.2},{"x":0.6,"y":0.5},{"x":0.1,"y":0.5}],"confidence":0.9,"classification":"dialogue"}]}
        """
        do {
            _ = try AITranslator.parseVisionTranslationBlocksForDiagnostics(
                from: missingTextBox,
                inputPixelSize: CGSize(width: 2_048, height: 1_024),
                requiresTextBox: true
            )
            Issue.record("离线视觉翻译不应以 bubbleBox 代替必需 textBox")
        } catch {
            #expect(error.localizedDescription.contains("textBox"))
        }

        let emptyTranslation = """
        {"coordinateSpace":"normalized","items":[{"sourceText":"https://example.com","translation":"","textBox":{"x":0.1,"y":0.2,"width":0.3,"height":0.05}}]}
        """
        do {
            _ = try AITranslator.parseVisionTranslationBlocksForDiagnostics(
                from: emptyTranslation,
                inputPixelSize: CGSize(width: 2_048, height: 1_024),
                requiresTextBox: true
            )
            Issue.record("离线视觉协议不应接受带空译文的 item")
        } catch {
            #expect(error.localizedDescription.contains("缺少必需译文"))
        }

        let invalidCoordinates = """
        {"coordinateSpace":"normalized","items":[{"sourceText":"こんにちは","translation":"你好","translationLines":["你好"],"textBox":{"x":2,"y":0.3,"width":0.2,"height":0.08},"bubbleBox":{"x":0.1,"y":0.2,"width":0.5,"height":0.3},"textPolygon":[{"x":2,"y":0.3},{"x":0.4,"y":0.3},{"x":0.4,"y":0.38},{"x":0.2,"y":0.38}],"bubblePolygon":[{"x":0.1,"y":0.2},{"x":0.6,"y":0.2},{"x":0.6,"y":0.5},{"x":0.1,"y":0.5}],"confidence":0.9,"classification":"dialogue"}]}
        """
        do {
            _ = try AITranslator.parseVisionTranslationBlocksForDiagnostics(
                from: invalidCoordinates,
                inputPixelSize: CGSize(width: 2_048, height: 1_024),
                requiresTextBox: true
            )
            Issue.record("无效坐标不应被改写为有效结果")
        } catch {
            #expect(error.localizedDescription.contains("坐标"))
        }

        let emptyPage = """
        {"coordinateSpace":"normalized","items":[]}
        """
        #expect(try AITranslator.parseVisionTranslationBlocksForDiagnostics(
            from: emptyPage,
            inputPixelSize: CGSize(width: 2_048, height: 1_024),
            requiresTextBox: true
        ).isEmpty)

        for malformed in ["{}", "{\"coordinateSpace\":\"normalized\"}", "{\"coordinateSpace\":\"pixels\",\"items\":[]}"] {
            do {
                _ = try AITranslator.parseVisionTranslationBlocksForDiagnostics(
                    from: malformed,
                    inputPixelSize: CGSize(width: 2_048, height: 1_024),
                    requiresTextBox: true
                )
                Issue.record("strict 离线视觉协议不应接受缺失或错误的顶层字段")
            } catch {
                #expect(error.localizedDescription.contains("协议错误"))
            }
        }
    }

    @Test func offlineTranslationPageDTOConvertsWithoutTextBlockJSON() throws {
        let block = TextBlock(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            text: "こんにちは",
            boundingBox: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.1),
            translation: "你好",
            confidence: 0.91,
            ocrSource: "vision",
            estimatedFontScale: 0.04,
            bubbleBox: CGRect(x: 0.05, y: 0.15, width: 0.4, height: 0.2),
            polygon: [CGPoint(x: 0.1, y: 0.2), CGPoint(x: 0.4, y: 0.2)]
        )
        let dto = OfflineTranslatedBlock(block: block, id: "b0")
        let decoded = try JSONDecoder().decode(
            OfflineTranslatedBlock.self,
            from: JSONEncoder().encode(dto)
        )
        let roundTrip = decoded.textBlock()
        #expect(decoded.id == "b0")
        #expect(roundTrip.text == "こんにちは")
        #expect(roundTrip.translation == "你好")
        #expect(abs(roundTrip.boundingBox.minX - 0.1) < 0.0001)
        #expect(abs((roundTrip.bubbleBox?.minX ?? 0) - 0.05) < 0.0001)
    }

    @Test func offlineTranslationDTOWritesCanonicalGeometryKeysAndReadsLegacyKeys() throws {
        let block = TextBlock(
            text: "原文",
            boundingBox: CGRect(x: 0.2, y: 0.3, width: 0.2, height: 0.08),
            translation: "译文",
            bubbleBox: CGRect(x: 0.1, y: 0.2, width: 0.5, height: 0.3),
            polygon: [CGPoint(x: 0.2, y: 0.3)],
            bubblePolygon: [CGPoint(x: 0.1, y: 0.2)],
            translationLines: ["译文"]
        )
        let encoded = try JSONEncoder().encode(OfflineTranslatedBlock(block: block))
        let object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        #expect(object?["translationLines"] != nil)
        #expect(object?["textPolygon"] != nil)
        #expect(object?["bubblePolygon"] != nil)
        #expect(object?["lines"] == nil)
        #expect(object?["polygon"] == nil)

        let legacy = """
        {"id":"legacy","sourceText":"原文","translation":"译文","lines":["译文"],
        "textBox":{"x":0.2,"y":0.3,"width":0.2,"height":0.08},"polygon":[{"x":0.2,"y":0.3}],
        "confidence":0.9,"classification":"dialogue","estimatedFontScale":0.04}
        """
        let decoded = try JSONDecoder().decode(OfflineTranslatedBlock.self, from: Data(legacy.utf8))
        #expect(decoded.translationLines == ["译文"])
        #expect(decoded.textPolygon.count == 1)
    }

    @Test func offlineTranslationStoragePersistsPageBeforeManifestAndSurvivesReload() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mreader-offline-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = OfflineTranslationStorageManager(rootURL: root)
        let comicID = UUID()
        let providerID = UUID()
        let set = OfflineTranslationSetManifest(
            comicID: comicID,
            sourceLanguage: .japanese,
            targetLanguage: .simplifiedChinese,
            providerID: providerID,
            providerName: "test",
            baseURL: "https://example.com/v1",
            visionModel: "vision-test",
            promptRevision: OfflineTranslationPromptBuilder.revision,
            promptSnapshot: "fixed",
            totalPages: 2
        )
        try await storage.saveManifest(set, activate: true)
        let page = OfflineTranslatedPage(
            comicID: comicID,
            setID: set.id,
            pageIndex: 0,
            sourceFingerprint: "fingerprint-a",
            pixelWidth: 1200,
            pixelHeight: 1800,
            blocks: [],
            state: .noText,
            providerID: providerID,
            visionModel: "vision-test"
        )
        try await storage.savePageAndUpdateManifest(page)
        let reloaded = await storage.page(comicID: comicID, setID: set.id, pageIndex: 0)
        let manifest = await storage.manifest(comicID: comicID, setID: set.id)
        #expect(reloaded?.sourceFingerprint == "fingerprint-a")
        #expect(reloaded?.state == .noText)
        #expect(manifest?.noTextPageCount == 1)
        #expect(manifest?.coverage == 0.5)
        #expect((await storage.activeManifest(for: comicID))?.id == set.id)
    }

    @Test func offlineTranslationStorageMarksFingerprintMismatchStaleAndSwitchesSets() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mreader-offline-switch-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = OfflineTranslationStorageManager(rootURL: root)
        let comicID = UUID()
        let providerID = UUID()
        func makeSet() -> OfflineTranslationSetManifest {
            OfflineTranslationSetManifest(
                comicID: comicID,
                sourceLanguage: .automatic,
                targetLanguage: .english,
                providerID: providerID,
                providerName: "test",
                baseURL: "https://example.com/v1",
                visionModel: "vision-test",
                promptRevision: OfflineTranslationPromptBuilder.revision,
                promptSnapshot: "fixed",
                totalPages: 1
            )
        }
        let setA = makeSet()
        let setB = makeSet()
        try await storage.saveManifest(setA, activate: true)
        try await storage.saveManifest(setB)
        try await storage.setActive(comicID: comicID, setID: setB.id)
        #expect((await storage.activeManifest(for: comicID))?.id == setB.id)
        let page = OfflineTranslatedPage(
            comicID: comicID,
            setID: setB.id,
            pageIndex: 0,
            sourceFingerprint: "before",
            pixelWidth: 100,
            pixelHeight: 100,
            blocks: [],
            state: .completed,
            providerID: providerID,
            visionModel: "vision-test"
        )
        try await storage.savePageAndUpdateManifest(page)
        await storage.markPageStale(comicID: comicID, setID: setB.id, pageIndex: 0)
        #expect((await storage.page(comicID: comicID, setID: setB.id, pageIndex: 0))?.state == .stale)
        try await storage.deleteSet(comicID: comicID, setID: setA.id)
        #expect((await storage.summaries(for: comicID)).count == 1)
        try await storage.deleteComicTranslations(comicID: comicID)
        #expect(await storage.index(for: comicID) == nil)
    }

    @Test func offlineTranslationKeepsAnActiveSetPerTargetLanguage() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mreader-offline-active-target-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = OfflineTranslationStorageManager(rootURL: root)
        let comicID = UUID()
        func makeSet(_ target: TranslationTargetLanguage) -> OfflineTranslationSetManifest {
            OfflineTranslationSetManifest(
                comicID: comicID,
                sourceLanguage: .automatic,
                targetLanguage: target,
                providerID: UUID(),
                providerName: "test",
                baseURL: "https://example.com/v1",
                visionModel: "vision",
                promptRevision: OfflineTranslationPromptBuilder.revision,
                promptSnapshot: "fixed",
                totalPages: 1
            )
        }
        let chinese = makeSet(.simplifiedChinese)
        let english = makeSet(.english)
        try await storage.saveManifest(chinese, activate: true)
        try await storage.saveManifest(english, activate: true)
        #expect((await storage.activeManifest(for: comicID, targetLanguage: .simplifiedChinese))?.id == chinese.id)
        #expect((await storage.activeManifest(for: comicID, targetLanguage: .english))?.id == english.id)
    }

    @Test func offlineTranslationDeletingActiveSetRestoresUsableSameTargetFallback() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mreader-offline-delete-active-target-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = OfflineTranslationStorageManager(rootURL: root)
        let comicID = UUID()
        let providerID = UUID()

        func makeSet(_ target: TranslationTargetLanguage) -> OfflineTranslationSetManifest {
            OfflineTranslationSetManifest(
                comicID: comicID,
                sourceLanguage: .japanese,
                targetLanguage: target,
                providerID: providerID,
                providerName: "test",
                baseURL: "https://example.com/v1",
                visionModel: "vision",
                promptRevision: OfflineTranslationPromptBuilder.revision,
                promptSnapshot: "fixed",
                totalPages: 1
            )
        }

        func makeUsable(_ set: OfflineTranslationSetManifest) async throws {
            try await storage.saveManifest(set, activate: true)
            try await storage.savePageAndUpdateManifest(
                OfflineTranslatedPage(
                    comicID: comicID,
                    setID: set.id,
                    pageIndex: 0,
                    sourceFingerprint: set.id.uuidString,
                    pixelWidth: 100,
                    pixelHeight: 100,
                    blocks: [],
                    state: .noText,
                    providerID: providerID,
                    visionModel: "vision"
                )
            )
        }

        let chinesePrevious = makeSet(.simplifiedChinese)
        let english = makeSet(.english)
        let chineseCurrent = makeSet(.simplifiedChinese)
        try await makeUsable(chinesePrevious)
        try await makeUsable(english)
        try await makeUsable(chineseCurrent)

        #expect((await storage.activeManifest(for: comicID, targetLanguage: .simplifiedChinese))?.id == chineseCurrent.id)
        try await storage.deleteSet(comicID: comicID, setID: chineseCurrent.id)

        #expect((await storage.activeManifest(for: comicID, targetLanguage: .simplifiedChinese))?.id == chinesePrevious.id)
        #expect((await storage.activeManifest(for: comicID, targetLanguage: .english))?.id == english.id)
        #expect((await storage.activeManifest(for: comicID))?.id == chinesePrevious.id)
    }

    @Test func offlineTranslationRenderableSetLookupRequiresSourceAndTargetLanguage() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mreader-offline-running-language-(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = OfflineTranslationStorageManager(rootURL: root)
        let comicID = UUID()
        let providerID = UUID()

        func makeManifest(source: TranslationSourceLanguage) -> OfflineTranslationSetManifest {
            OfflineTranslationSetManifest(
                comicID: comicID,
                sourceLanguage: source,
                targetLanguage: .english,
                providerID: providerID,
                providerName: "test",
                baseURL: "https://example.com/v1",
                visionModel: "vision",
                promptRevision: OfflineTranslationPromptBuilder.revision,
                promptSnapshot: "fixed",
                totalPages: 1
            )
        }

        let japanese = makeManifest(source: .japanese)
        let korean = makeManifest(source: .korean)
        try await storage.saveManifest(japanese)
        try await storage.saveManifest(korean)
        for manifest in [japanese, korean] {
            var job = OfflineTranslationJobRecord(
                comicID: comicID,
                setID: manifest.id,
                selection: .entireComic,
                pageIndexes: [0],
                providerID: providerID,
                providerName: "test",
                baseURL: manifest.baseURL,
                visionModel: manifest.visionModel,
                sourceLanguage: manifest.sourceLanguage,
                targetLanguage: manifest.targetLanguage,
                promptRevision: manifest.promptRevision,
                promptSnapshot: manifest.promptSnapshot,
                readingDirectionRaw: "leftToRight",
                totalPages: 1
            )
            job.state = manifest.id == japanese.id ? .paused : .completedWithFailures
            try await storage.saveJob(job)
        }

        #expect(
            (await storage.latestRenderableManifest(
                for: comicID,
                sourceLanguage: .japanese,
                targetLanguage: .english
            ))?.id == japanese.id
        )
        #expect(
            await storage.latestRenderableManifest(
                for: comicID,
                sourceLanguage: .french,
                targetLanguage: .english
            ) == nil
        )
        #expect(
            (await storage.latestRenderableManifest(
                for: comicID,
                sourceLanguage: .korean,
                targetLanguage: .english
            ))?.id == korean.id
        )
    }

    @Test func offlineTranslationCompletedRangeRemainsRenderable() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mreader-offline-range-visible-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = OfflineTranslationStorageManager(rootURL: root)
        let comicID = UUID()
        let providerID = UUID()
        let set = OfflineTranslationSetManifest(
            comicID: comicID,
            sourceLanguage: .japanese,
            targetLanguage: .simplifiedChinese,
            providerID: providerID,
            providerName: "test",
            baseURL: "https://example.com/v1",
            visionModel: "vision",
            promptRevision: OfflineTranslationPromptBuilder.revision,
            promptSnapshot: "fixed",
            totalPages: 100
        )
        try await storage.saveManifest(set)
        let page = OfflineTranslatedPage(
            comicID: comicID,
            setID: set.id,
            pageIndex: 49,
            sourceFingerprint: "range-page",
            pixelWidth: 100,
            pixelHeight: 100,
            blocks: [OfflineTranslatedBlock(block: TextBlock(
                text: "原文",
                boundingBox: CGRect(x: 0.2, y: 0.2, width: 0.2, height: 0.08),
                translation: "译文"
            ))],
            state: .completed,
            providerID: providerID,
            visionModel: "vision"
        )
        try await storage.savePageAndUpdateManifest(page)
        var job = OfflineTranslationJobRecord(
            comicID: comicID,
            setID: set.id,
            selection: .range(start: 49, end: 99),
            pageIndexes: Array(49...99),
            providerID: providerID,
            providerName: "test",
            baseURL: "https://example.com/v1",
            visionModel: "vision",
            sourceLanguage: .japanese,
            targetLanguage: .simplifiedChinese,
            promptRevision: OfflineTranslationPromptBuilder.revision,
            promptSnapshot: "fixed",
            readingDirectionRaw: "leftToRight",
            totalPages: 100
        )
        job.state = .completed
        job.updatedAt = Date()
        try await storage.saveJob(job)

        #expect((await storage.latestRenderableManifest(
            for: comicID,
            sourceLanguage: .japanese,
            targetLanguage: .simplifiedChinese
        ))?.id == set.id)
    }

    @Test func offlineTranslationStoppedJobKeepsCompletedPagesRenderable() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mreader-offline-stop-keep-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = OfflineTranslationStorageManager(rootURL: root)
        let comicID = UUID()
        let providerID = UUID()
        let baseDate = Date()

        func makeSet() -> OfflineTranslationSetManifest {
            OfflineTranslationSetManifest(
                comicID: comicID,
                sourceLanguage: .japanese,
                targetLanguage: .simplifiedChinese,
                providerID: providerID,
                providerName: "test",
                baseURL: "https://example.com/v1",
                visionModel: "vision",
                promptRevision: OfflineTranslationPromptBuilder.revision,
                promptSnapshot: "fixed",
                totalPages: 2
            )
        }
        func saveCompletedPage(to set: OfflineTranslationSetManifest) async throws {
            try await storage.savePageAndUpdateManifest(
                OfflineTranslatedPage(
                    comicID: comicID,
                    setID: set.id,
                    pageIndex: 0,
                    sourceFingerprint: "page-0",
                    pixelWidth: 100,
                    pixelHeight: 100,
                    blocks: [OfflineTranslatedBlock(block: TextBlock(
                        text: "原文",
                        boundingBox: CGRect(x: 0.2, y: 0.2, width: 0.2, height: 0.08),
                        translation: "译文"
                    ))],
                    state: .completed,
                    providerID: providerID,
                    visionModel: "vision"
                )
            )
        }

        var active = makeSet()
        active.updatedAt = baseDate.addingTimeInterval(10)
        try await storage.saveManifest(active, activate: true)

        let stopped = makeSet()
        try await storage.saveManifest(stopped)
        try await saveCompletedPage(to: stopped)
        let savedStoppedManifest = await storage.manifest(comicID: comicID, setID: stopped.id)
        var stoppedManifest = try #require(savedStoppedManifest)
        stoppedManifest.updatedAt = baseDate.addingTimeInterval(20)
        try await storage.saveManifest(stoppedManifest)
        var stoppedJob = OfflineTranslationJobRecord(
            comicID: comicID,
            setID: stopped.id,
            selection: .entireComic,
            pageIndexes: [0, 1],
            providerID: providerID,
            providerName: "test",
            baseURL: stopped.baseURL,
            visionModel: stopped.visionModel,
            sourceLanguage: .japanese,
            targetLanguage: .simplifiedChinese,
            promptRevision: stopped.promptRevision,
            promptSnapshot: stopped.promptSnapshot,
            readingDirectionRaw: "leftToRight",
            totalPages: 2
        )
        stoppedJob.state = .cancelled
        stoppedJob.updatedAt = baseDate.addingTimeInterval(20)
        try await storage.saveJob(stoppedJob)

        #expect((await storage.latestRenderableManifest(
            for: comicID,
            sourceLanguage: .japanese,
            targetLanguage: .simplifiedChinese
        ))?.id == stopped.id)

        var newerActive = makeSet()
        newerActive.updatedAt = baseDate.addingTimeInterval(30)
        try await storage.saveManifest(newerActive, activate: true)
        #expect(await storage.latestRenderableManifest(
            for: comicID,
            sourceLanguage: .japanese,
            targetLanguage: .simplifiedChinese
        ) == nil)
    }

    @Test func offlineTranslationRangeJobsInheritLatestRenderablePages() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mreader-offline-range-inheritance-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = OfflineTranslationStorageManager(rootURL: root)
        let comicID = UUID()
        let providerID = UUID()
        func makeSet(derivedFromSetID: UUID? = nil) -> OfflineTranslationSetManifest {
            OfflineTranslationSetManifest(
                comicID: comicID,
                sourceLanguage: .japanese,
                targetLanguage: .simplifiedChinese,
                providerID: providerID,
                providerName: "test",
                baseURL: "https://example.com/v1",
                visionModel: "vision",
                promptRevision: OfflineTranslationPromptBuilder.revision,
                promptSnapshot: "fixed",
                totalPages: 30,
                derivedFromSetID: derivedFromSetID,
                sourceRevision: "revision-1"
            )
        }
        func savePage(_ pageIndex: Int, to set: OfflineTranslationSetManifest, label: String) async throws {
            try await storage.savePageAndUpdateManifest(
                OfflineTranslatedPage(
                    comicID: comicID,
                    setID: set.id,
                    pageIndex: pageIndex,
                    sourceFingerprint: "page-\(pageIndex)",
                    pixelWidth: 100,
                    pixelHeight: 100,
                    blocks: [OfflineTranslatedBlock(block: TextBlock(
                        text: "原文",
                        boundingBox: CGRect(x: 0.2, y: 0.2, width: 0.2, height: 0.08),
                        translation: label
                    ))],
                    state: .completed,
                    providerID: providerID,
                    visionModel: "vision"
                )
            )
        }

        let first = makeSet()
        try await storage.saveManifest(first)
        for pageIndex in 0...9 {
            try await savePage(pageIndex, to: first, label: "第一次范围")
        }
        var firstJob = OfflineTranslationJobRecord(
            comicID: comicID,
            setID: first.id,
            selection: .range(start: 0, end: 9),
            pageIndexes: Array(0...9),
            providerID: providerID,
            providerName: "test",
            baseURL: first.baseURL,
            visionModel: first.visionModel,
            sourceLanguage: .japanese,
            targetLanguage: .simplifiedChinese,
            promptRevision: first.promptRevision,
            promptSnapshot: first.promptSnapshot,
            readingDirectionRaw: "leftToRight",
            totalPages: 30
        )
        firstJob.state = .completed
        try await storage.saveJob(firstJob)

        let inheritedSource = await storage.latestRenderableManifest(
            for: comicID,
            sourceLanguage: .japanese,
            targetLanguage: .simplifiedChinese
        )
        #expect(inheritedSource?.id == first.id)

        let second = makeSet(derivedFromSetID: inheritedSource?.id)
        try await storage.saveManifest(second)
        _ = try await storage.copyValidPages(
            from: try #require(inheritedSource).id,
            to: second,
            excludingPageIndexes: Set(20...29)
        )
        for pageIndex in 20...29 {
            try await savePage(pageIndex, to: second, label: "第二次范围")
        }
        var secondJob = OfflineTranslationJobRecord(
            comicID: comicID,
            setID: second.id,
            selection: .range(start: 20, end: 29),
            pageIndexes: Array(20...29),
            providerID: providerID,
            providerName: "test",
            baseURL: second.baseURL,
            visionModel: second.visionModel,
            sourceLanguage: .japanese,
            targetLanguage: .simplifiedChinese,
            promptRevision: second.promptRevision,
            promptSnapshot: second.promptSnapshot,
            readingDirectionRaw: "leftToRight",
            totalPages: 30
        )
        secondJob.state = .completed
        try await storage.saveJob(secondJob)

        #expect(await storage.page(comicID: comicID, setID: second.id, pageIndex: 0)?.blocks.first?.translation == "第一次范围")
        #expect(await storage.page(comicID: comicID, setID: second.id, pageIndex: 20)?.blocks.first?.translation == "第二次范围")
        #expect(await storage.page(comicID: comicID, setID: second.id, pageIndex: 10) == nil)
        #expect((await storage.latestRenderableManifest(
            for: comicID,
            sourceLanguage: .japanese,
            targetLanguage: .simplifiedChinese
        ))?.id == second.id)
    }

    @Test func offlineTranslationNewActiveSuppressesOlderStoppedJob() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mreader-offline-active-precedence-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = OfflineTranslationStorageManager(rootURL: root)
        let comicID = UUID()
        let providerID = UUID()
        let baseDate = Date(timeIntervalSince1970: 1_000)

        func makeSet(createdAt: Date) -> OfflineTranslationSetManifest {
            OfflineTranslationSetManifest(
                comicID: comicID,
                sourceLanguage: .japanese,
                targetLanguage: .simplifiedChinese,
                providerID: providerID,
                providerName: "test",
                baseURL: "https://example.com/v1",
                visionModel: "vision",
                promptRevision: OfflineTranslationPromptBuilder.revision,
                promptSnapshot: "fixed",
                totalPages: 2,
                createdAt: createdAt
            )
        }

        var oldSet = makeSet(createdAt: baseDate)
        oldSet.updatedAt = baseDate.addingTimeInterval(10)
        try await storage.saveManifest(oldSet)
        var oldJob = OfflineTranslationJobRecord(
            comicID: comicID,
            setID: oldSet.id,
            selection: .entireComic,
            pageIndexes: [0, 1],
            providerID: providerID,
            providerName: "test",
            baseURL: "https://example.com/v1",
            visionModel: "vision",
            sourceLanguage: .japanese,
            targetLanguage: .simplifiedChinese,
            promptRevision: OfflineTranslationPromptBuilder.revision,
            promptSnapshot: "fixed",
            readingDirectionRaw: "leftToRight",
            totalPages: 2,
            createdAt: baseDate
        )
        oldJob.state = .needsConfiguration
        oldJob.updatedAt = baseDate.addingTimeInterval(10)
        try await storage.saveJob(oldJob)

        var activeSet = makeSet(createdAt: baseDate.addingTimeInterval(20))
        activeSet.updatedAt = baseDate.addingTimeInterval(30)
        try await storage.saveManifest(activeSet, activate: true)

        #expect(await storage.latestRenderableManifest(
            for: comicID,
            sourceLanguage: .japanese,
            targetLanguage: .simplifiedChinese
        ) == nil)
    }

    @Test func offlineTranslationFingerprintIsStableAndChangesWithSourceBytes() {
        let first = OfflineTranslationFingerprint.sha256(for: Data("page-a".utf8))
        let same = OfflineTranslationFingerprint.sha256(for: Data("page-a".utf8))
        let changed = OfflineTranslationFingerprint.sha256(for: Data("page-b".utf8))
        #expect(first == same)
        #expect(first != changed)
        #expect(first.count == 64)
    }

    @Test func offlineTranslationStreamingSHA256MatchesInMemorySHA256() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mreader-streaming-sha256-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let data = Data("abcdefghijklmnopqrstuvwxyz0123456789".utf8)
        try data.write(to: fileURL)

        let memoryDigest = OfflineTranslationFingerprint.sha256(for: data)
        let streamingDigest = try OfflineTranslationFingerprint.sha256(
            fileAt: fileURL,
            chunkSize: 7
        )

        #expect(streamingDigest == memoryDigest)
    }

    @Test func offlineTranslationStreamingSHA256HandlesEmptyFile() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mreader-streaming-sha256-empty-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: fileURL) }

        try Data().write(to: fileURL)

        #expect(
            try OfflineTranslationFingerprint.sha256(fileAt: fileURL)
                == OfflineTranslationFingerprint.sha256(for: Data())
        )
    }

    @Test func offlineTranslationStreamingSHA256CooperatesWithCancellation() async throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mreader-streaming-sha256-cancel-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: fileURL) }

        try Data(repeating: 0x5A, count: 4 * 1024 * 1024).write(to: fileURL)
        let worker = Task.detached(priority: .utility) { () throws -> String in
            await Task.yield()
            return try OfflineTranslationFingerprint.sha256(fileAt: fileURL, chunkSize: 1)
        }
        worker.cancel()

        do {
            _ = try await worker.value
            Issue.record("已取消的 streaming SHA256 不应继续完成")
        } catch is CancellationError {
            // expected
        }
    }

    @Test func offlineTranslationBackgroundPreparationSurvivesStartupDeadline() {
        let jobID = UUID()
        let otherJobID = UUID()
        #expect(
            OfflineTranslationCoordinatorWaitDecision.resolve(
                targetJobID: jobID,
                preparingJobID: jobID,
                activeTaskJobID: jobID,
                currentJobID: jobID,
                isRunning: false,
                canStart: false,
                didTimeout: true
            ) == .wait
        )
        #expect(
            OfflineTranslationCoordinatorWaitDecision.resolve(
                targetJobID: jobID,
                preparingJobID: nil,
                activeTaskJobID: nil,
                currentJobID: nil,
                isRunning: false,
                canStart: true,
                didTimeout: false
            ) == .startupFailed
        )
        #expect(
            OfflineTranslationCoordinatorWaitDecision.resolve(
                targetJobID: jobID,
                preparingJobID: otherJobID,
                activeTaskJobID: otherJobID,
                currentJobID: jobID,
                isRunning: false,
                canStart: false,
                didTimeout: true
            ) == .finished
        )
        #expect(
            OfflineTranslationCoordinatorWaitDecision.resolve(
                targetJobID: jobID,
                preparingJobID: nil,
                activeTaskJobID: nil,
                currentJobID: jobID,
                isRunning: false,
                canStart: true,
                didTimeout: true
            ) == .finished
        )
    }

    @Test func offlineTranslationCancellationKeepsSystemInterruptionResumable() {
        #expect(
            OfflineTranslationCancellationDisposition.resolve(stopMode: .systemInterruption)
                == .interrupted
        )
        #expect(
            OfflineTranslationCancellationDisposition.resolve(stopMode: .cancel)
                == .cancelled
        )
        #expect(
            OfflineTranslationCancellationDisposition.resolve(stopMode: .pause)
                == .paused
        )
    }

    @Test func offlineTranslationExpirationCannotInterruptAnotherJob() {
        let jobA = UUID()
        let jobB = UUID()
        #expect(
            OfflineTranslationExpirationDecision.resolve(
                expiredJobID: jobA,
                activeTaskJobID: jobB
            ) == .ignore
        )
        #expect(
            OfflineTranslationExpirationDecision.resolve(
                expiredJobID: jobB,
                activeTaskJobID: jobB
            ) == .interrupt
        )
    }

    @Test func offlineTranslationFolderRevisionTracksBytesWhenMetadataIsRestored() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mreader-folder-revision-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let pageURL = root.appendingPathComponent("001.jpg")
        let originalDate = Date(timeIntervalSince1970: 1_234_567)
        try Data("AAAAA".utf8).write(to: pageURL)
        try FileManager.default.setAttributes([.modificationDate: originalDate], ofItemAtPath: pageURL.path)
        let first = OfflineTranslationPageProvider.localFolderSourceRevision(
            at: root,
            fallbackPath: root.path,
            pageCount: 1
        )
        try Data("BBBBB".utf8).write(to: pageURL)
        try FileManager.default.setAttributes([.modificationDate: originalDate], ofItemAtPath: pageURL.path)
        let second = OfflineTranslationPageProvider.localFolderSourceRevision(
            at: root,
            fallbackPath: root.path,
            pageCount: 1
        )
        #expect(first != second)
        #expect(OfflineTranslationPageProvider.fingerprint(
            for: Data("AAAAA".utf8),
            pageURL: pageURL
        ) != OfflineTranslationPageProvider.fingerprint(
            for: Data("BBBBB".utf8),
            pageURL: pageURL
        ))
    }

    @Test func offlineTranslationFolderRevisionFailsClosedWhenSourceIsUnavailable() {
        let missingRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("mreader-missing-folder-\(UUID().uuidString)", isDirectory: true)
        let revision = OfflineTranslationPageProvider.localFolderSourceRevision(
            at: missingRoot,
            fallbackPath: missingRoot.path,
            pageCount: 1
        )

        #expect(revision.hasPrefix("local-folder-unverified:"))
        #expect(!OfflineTranslationPageProvider.isReliableSourceRevision(revision))
        #expect(!OfflineTranslationPageProvider.isReliableSourceRevision(
            "local-folder:\(missingRoot.path)#unavailable#pages=1"
        ))
    }

    @Test func offlineTranslationFolderRevisionFailsClosedForInvalidImageCandidate() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mreader-invalid-folder-revision-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("001.jpg", isDirectory: true),
            withIntermediateDirectories: true
        )

        let revision = OfflineTranslationPageProvider.localFolderSourceRevision(
            at: root,
            fallbackPath: root.path,
            pageCount: 1
        )

        #expect(revision.hasPrefix("local-folder-unverified:"))
        #expect(!OfflineTranslationPageProvider.isReliableSourceRevision(revision))
    }

    @Test func offlineTranslationFolderRevisionRequiresCompleteEnumeration() {
        #expect(
            !OfflineTranslationPageProvider.isCompleteFolderRevision(
                enumerationFailed: true,
                descriptorCount: 100,
                pageCount: 100
            )
        )
        #expect(
            !OfflineTranslationPageProvider.isCompleteFolderRevision(
                enumerationFailed: false,
                descriptorCount: 0,
                pageCount: 0
            )
        )
        #expect(
            !OfflineTranslationPageProvider.isCompleteFolderRevision(
                enumerationFailed: false,
                descriptorCount: 99,
                pageCount: 100
            )
        )
        #expect(
            OfflineTranslationPageProvider.isCompleteFolderRevision(
                enumerationFailed: false,
                descriptorCount: 100,
                pageCount: 100
            )
        )
    }

    @Test func offlineTranslationEmptyFolderRevisionFailsClosed() throws {
        let emptyRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("mreader-empty-folder-revision-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: emptyRoot) }
        try FileManager.default.createDirectory(at: emptyRoot, withIntermediateDirectories: true)

        let revision = OfflineTranslationPageProvider.localFolderSourceRevision(
            at: emptyRoot,
            fallbackPath: emptyRoot.path,
            pageCount: 0
        )

        #expect(revision.hasPrefix("local-folder-unverified:"))
        #expect(!OfflineTranslationPageProvider.isReliableSourceRevision(revision))
    }

    @Test func offlineTranslationFolderRevisionUsesComicManagerPageExtensions() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mreader-folder-page-extensions-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let supportedPage = root.appendingPathComponent("001.jpg")
        try Data("page".utf8).write(to: supportedPage)
        for fileExtension in ["bmp", "tif", "tiff"] {
            try Data("ignored".utf8).write(to: root.appendingPathComponent("ignored.\(fileExtension)"))
        }

        #expect(ComicManager.isSupportedImageFile(supportedPage))
        #expect(!ComicManager.isSupportedImageFile(root.appendingPathComponent("ignored.bmp")))
        #expect(!ComicManager.isSupportedImageFile(root.appendingPathComponent("ignored.tif")))
        #expect(!ComicManager.isSupportedImageFile(root.appendingPathComponent("ignored.tiff")))

        let revision = OfflineTranslationPageProvider.localFolderSourceRevision(
            at: root,
            fallbackPath: root.path,
            pageCount: 1
        )
        #expect(OfflineTranslationPageProvider.isReliableSourceRevision(revision))
    }

    @Test func offlineTranslationSingleFileRevisionTracksBytesWhenMetadataIsRestored() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mreader-single-file-revision-\(UUID().uuidString).cbz")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let originalDate = Date(timeIntervalSince1970: 1_234_567)
        try Data("AAAAA".utf8).write(to: fileURL)
        try FileManager.default.setAttributes([.modificationDate: originalDate], ofItemAtPath: fileURL.path)
        let first = OfflineTranslationPageProvider.localFileSourceRevision(
            at: fileURL,
            fallbackPath: fileURL.path,
            pageCount: 1
        )

        try Data("BBBBB".utf8).write(to: fileURL)
        try FileManager.default.setAttributes([.modificationDate: originalDate], ofItemAtPath: fileURL.path)
        let second = OfflineTranslationPageProvider.localFileSourceRevision(
            at: fileURL,
            fallbackPath: fileURL.path,
            pageCount: 1
        )

        #expect(first != second)
        #expect(OfflineTranslationPageProvider.isReliableSourceRevision(first))
        #expect(OfflineTranslationPageProvider.isReliableSourceRevision(second))
    }

    @Test func offlineTranslationTreatsLocalSingleFileAsExpensiveRevision() {
        let comic = ComicBook(
            title: "local.cbz",
            bookmarkData: Data(),
            totalPages: 1,
            libraryPath: "/tmp/local.cbz",
            chapterTypeRaw: "cbz"
        )
        #expect(
            OfflineTranslationPageProvider.usesExpensiveSourceRevision(for: comic)
        )
        #expect(
            !OfflineTranslationPageProvider.shouldPeriodicallyValidateSourceRevision(for: comic)
        )
    }

    @Test func offlineTranslationPendingRecoveryDistinguishesLoadingMissingAndResumable() {
        #expect(
            OfflineTranslationPendingRecoveryDecision.resolve(
                libraryLoaded: false,
                comicExists: false,
                job: nil
            ) == .waitForLibrary
        )
        #expect(
            OfflineTranslationPendingRecoveryDecision.resolve(
                libraryLoaded: true,
                comicExists: false,
                job: nil
            ) == .clearPending
        )

        var job = OfflineTranslationJobRecord(
            comicID: UUID(),
            setID: UUID(),
            selection: .entireComic,
            pageIndexes: [0],
            providerID: UUID(),
            providerName: "test",
            baseURL: "https://example.com/v1",
            visionModel: "vision",
            sourceLanguage: .japanese,
            targetLanguage: .simplifiedChinese,
            promptRevision: "test",
            promptSnapshot: "test",
            readingDirectionRaw: "leftToRight",
            totalPages: 1
        )
        #expect(
            OfflineTranslationPendingRecoveryDecision.resolve(
                libraryLoaded: true,
                comicExists: true,
                job: job
            ) == .resume
        )
        job.state = .paused
        #expect(
            OfflineTranslationPendingRecoveryDecision.resolve(
                libraryLoaded: true,
                comicExists: true,
                job: job
        ) == .clearPending
        )
    }

    @Test func offlineTranslationDiscardUncommittedSetRemovesManifestAndIndexEntry() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mreader-offline-orphan-set-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = OfflineTranslationStorageManager(rootURL: root)
        let comicID = UUID()
        let setID = UUID()
        let manifest = OfflineTranslationSetManifest(
            id: setID,
            comicID: comicID,
            sourceLanguage: .japanese,
            targetLanguage: .simplifiedChinese,
            providerID: UUID(),
            providerName: "test",
            baseURL: "https://example.com/v1",
            visionModel: "vision",
            promptRevision: "test",
            promptSnapshot: "test",
            totalPages: 1,
            sourceRevision: "local-file:test#pages=1",
            processingMode: .ocrText,
            textModel: "text",
            ocrRecognitionMode: .adaptive,
            usesVisualOCRVerification: false
        )
        try await storage.saveManifest(manifest)
        #expect((await storage.index(for: comicID))?.setIDs == [setID])

        try await storage.discardUncommittedSet(comicID: comicID, setID: setID)

        #expect(await storage.manifest(comicID: comicID, setID: setID) == nil)
        #expect(await storage.index(for: comicID) == nil)
    }

    @Test func offlineTranslationMigratesLegacyActiveSetByTargetLanguage() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mreader-offline-active-migration-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = OfflineTranslationStorageManager(rootURL: root)
        let comicID = UUID()
        func makeSet(_ target: TranslationTargetLanguage) -> OfflineTranslationSetManifest {
            OfflineTranslationSetManifest(
                comicID: comicID,
                sourceLanguage: .automatic,
                targetLanguage: target,
                providerID: UUID(),
                providerName: "test",
                baseURL: "https://example.com/v1",
                visionModel: "vision",
                promptRevision: OfflineTranslationPromptBuilder.revision,
                promptSnapshot: "fixed",
                totalPages: 1
            )
        }
        let chinese = makeSet(.simplifiedChinese)
        let english = makeSet(.english)
        try await storage.saveManifest(chinese, activate: true)
        try await storage.saveManifest(english, activate: true)
        let legacyIndex = OfflineTranslationIndex(
            comicID: comicID,
            activeSetID: chinese.id,
            activeSetIDsByTargetLanguage: [TranslationTargetLanguage.english.rawValue: english.id],
            setIDs: [chinese.id, english.id]
        )
        try JSONEncoder().encode(legacyIndex).write(
            to: root.appendingPathComponent(comicID.uuidString).appendingPathComponent("index.json"),
            options: .atomic
        )

        #expect((await storage.activeManifest(for: comicID, targetLanguage: .simplifiedChinese))?.id == chinese.id)
        #expect((await storage.index(for: comicID))?.activeSetIDsByTargetLanguage[TranslationTargetLanguage.simplifiedChinese.rawValue] == chinese.id)
        #expect((await storage.activeManifest(for: comicID, targetLanguage: .english))?.id == english.id)
    }

    @Test func offlineTranslationReconcilesManifestFromPageFiles() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mreader-offline-reconcile-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = OfflineTranslationStorageManager(rootURL: root)
        let comicID = UUID()
        let set = OfflineTranslationSetManifest(
            comicID: comicID,
            sourceLanguage: .japanese,
            targetLanguage: .simplifiedChinese,
            providerID: UUID(),
            providerName: "test",
            baseURL: "https://example.com/v1",
            visionModel: "vision",
            promptRevision: OfflineTranslationPromptBuilder.revision,
            promptSnapshot: "fixed",
            totalPages: 1
        )
        try await storage.saveManifest(set)
        try await storage.savePageAndUpdateManifest(
            OfflineTranslatedPage(
                comicID: comicID,
                setID: set.id,
                pageIndex: 0,
                sourceFingerprint: "stable",
                pixelWidth: 100,
                pixelHeight: 100,
                blocks: [],
                state: .partial,
                providerID: set.providerID,
                visionModel: set.visionModel
            )
        )
        try await storage.saveManifest(set)
        let repaired = try await storage.reconcileManifest(comicID: comicID, setID: set.id)
        #expect(repaired?.partialPageCount == 1)
        #expect(repaired?.coveredPageCount == 1)
    }

    @Test func offlineTranslationDerivedSetCopiesOnlyOutsideSelectedPagesAndSwitchesAfterCompletion() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mreader-offline-derived-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = OfflineTranslationStorageManager(rootURL: root)
        let comicID = UUID()
        let providerID = UUID()
        let sourcePageProviderID = UUID()
        func makeManifest(id: UUID, derivedFromSetID: UUID? = nil) -> OfflineTranslationSetManifest {
            OfflineTranslationSetManifest(
                id: id,
                comicID: comicID,
                sourceLanguage: .japanese,
                targetLanguage: .simplifiedChinese,
                providerID: providerID,
                providerName: "test",
                baseURL: "https://example.com/v1",
                visionModel: "vision-test",
                promptRevision: OfflineTranslationPromptBuilder.revision,
                promptSnapshot: "fixed",
                totalPages: 2,
                derivedFromSetID: derivedFromSetID,
                sourceRevision: "revision-1"
            )
        }
        let source = makeManifest(id: UUID())
        let derived = makeManifest(id: UUID(), derivedFromSetID: source.id)
        try await storage.saveManifest(source, activate: true)
        for pageIndex in 0..<2 {
            try await storage.savePageAndUpdateManifest(
                OfflineTranslatedPage(
                    comicID: comicID,
                    setID: source.id,
                    pageIndex: pageIndex,
                    sourceFingerprint: "source-\(pageIndex)",
                    pixelWidth: 100,
                    pixelHeight: 100,
                    blocks: [],
                    state: .noText,
                    providerID: sourcePageProviderID,
                    visionModel: "source-vision"
                )
            )
        }
        try await storage.saveManifest(derived)
        _ = try await storage.copyValidPages(
            from: source.id,
            to: derived,
            excludingPageIndexes: [1]
        )
        #expect((await storage.activeManifest(for: comicID))?.id == source.id)
        #expect(await storage.page(comicID: comicID, setID: derived.id, pageIndex: 0)?.providerID == sourcePageProviderID)
        #expect(await storage.page(comicID: comicID, setID: derived.id, pageIndex: 0)?.visionModel == "source-vision")
        #expect(await storage.page(comicID: comicID, setID: derived.id, pageIndex: 1) == nil)

        try await storage.savePageAndUpdateManifest(
            OfflineTranslatedPage(
                comicID: comicID,
                setID: derived.id,
                pageIndex: 1,
                sourceFingerprint: "new-1",
                pixelWidth: 100,
                pixelHeight: 100,
                blocks: [],
                state: .noText,
                providerID: providerID,
                visionModel: "vision-test"
            )
        )
        try await storage.setActive(comicID: comicID, setID: derived.id)
        #expect((await storage.activeManifest(for: comicID))?.id == derived.id)
    }

    @Test func offlineTranslationStatesTreatNoTextAsSuccessfulCoverage() {
        #expect(OfflineTranslationPageState.noText.countsAsCoverage)
        #expect(OfflineTranslationPageState.noText.isUsableOverlay)
        #expect(!OfflineTranslationPageState.failed.countsAsCoverage)
        #expect(!OfflineTranslationPageState.stale.isUsableOverlay)
        #expect(OfflineTranslationJobState.interrupted.isTerminal == false)
        #expect(OfflineTranslationJobState.completedWithFailures.isTerminal)
        #expect(OfflineTranslationJobState.completionState(failedPageCount: 0, partialPageCount: 0) == .completed)
        #expect(OfflineTranslationJobState.completionState(failedPageCount: 0, partialPageCount: 1) == .completedWithFailures)
        #expect(OfflineTranslationPageState.partial.needsTranslationWork)
        #expect(!OfflineTranslationPageState.completed.needsTranslationWork)
    }

    @Test func offlineTranslationFreezesOCRConfigurationAndRoundTripsIt() throws {
        let job = OfflineTranslationJobRecord(
            comicID: UUID(),
            setID: UUID(),
            selection: .entireComic,
            pageIndexes: [0, 1],
            providerID: UUID(),
            providerName: "test",
            baseURL: "https://example.com/v1",
            visionModel: "vision-model",
            sourceLanguage: .japanese,
            targetLanguage: .english,
            promptRevision: "test",
            promptSnapshot: "snapshot",
            styleInstructions: "natural",
            readingDirectionRaw: "leftToRight",
            totalPages: 2,
            processingMode: .ocrText,
            textModel: "text-model",
            ocrRecognitionMode: .maximumAccuracy,
            usesVisualOCRVerification: false
        )
        let decoded = try JSONDecoder().decode(
            OfflineTranslationJobRecord.self,
            from: JSONEncoder().encode(job)
        )
        #expect(decoded.processingMode == .ocrText)
        #expect(decoded.textModel == "text-model")
        #expect(decoded.ocrRecognitionMode == .maximumAccuracy)
        #expect(decoded.usesVisualOCRVerification == false)
    }

    @Test func offlineTranslationBlocksPreserveBubbleBoxThroughDTO() throws {
        let bubbleBox = CGRect(x: 0.12, y: 0.2, width: 0.5, height: 0.24)
        let block = TextBlock(
            text: "原文",
            boundingBox: CGRect(x: 0.2, y: 0.28, width: 0.2, height: 0.08),
            translation: "translated",
            bubbleBox: bubbleBox
        )
        let decoded = try JSONDecoder().decode(
            OfflineTranslatedBlock.self,
            from: JSONEncoder().encode(OfflineTranslatedBlock(block: block))
        )
        #expect(decoded.textBlock().bubbleBox == bubbleBox)
        #expect(decoded.textBlock().boundingBox != bubbleBox)
    }

    @Test func offlineTranslationPreservesClassificationAfterGeometryRefinement() {
        let block = TextBlock(
            text: "旁白",
            boundingBox: CGRect(x: 0.2, y: 0.2, width: 0.2, height: 0.08),
            translation: "Narration",
            ocrSource: "vision-model:narration+local-geometry"
        )

        #expect(OfflineTranslatedBlock(block: block).classification == "narration")
    }

    @Test func offlineTranslationPartialPagePrefersMatchingCompleteFallback() {
        let comicID = UUID()
        let newSetID = UUID()
        let parentSetID = UUID()
        let providerID = UUID()
        let partial = OfflineTranslatedPage(
            comicID: comicID,
            setID: newSetID,
            pageIndex: 0,
            sourceFingerprint: "same-page",
            pixelWidth: 100,
            pixelHeight: 100,
            blocks: [OfflineTranslatedBlock(block: TextBlock(
                text: "第一句",
                boundingBox: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.08),
                translation: "new"
            ))],
            state: .partial,
            providerID: providerID,
            visionModel: "vision"
        )
        let completeFallback = OfflineTranslatedPage(
            comicID: comicID,
            setID: parentSetID,
            pageIndex: 0,
            sourceFingerprint: "same-page",
            pixelWidth: 100,
            pixelHeight: 100,
            blocks: [OfflineTranslatedBlock(block: TextBlock(
                text: "第一句",
                boundingBox: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.08),
                translation: "old"
            ))],
            state: .completed,
            providerID: providerID,
            visionModel: "vision"
        )

        let preferred = OfflineTranslationOverlayProvider.preferredOverlayPage(
            primary: partial,
            fallbackPages: [completeFallback]
        )
        #expect(preferred.setID == parentSetID)
        #expect(preferred.blocks.first?.translation == "old")
    }

    @Test func offlineTranslationPersistsExplicitTextOrientationThroughDTO() throws {
        let block = TextBlock(
            text: "多行横排对白",
            boundingBox: CGRect(x: 0.42, y: 0.18, width: 0.08, height: 0.28),
            estimatedFontScale: 0.04,
            textOrientation: .horizontal
        )
        let decoded = try JSONDecoder().decode(
            OfflineTranslatedBlock.self,
            from: JSONEncoder().encode(OfflineTranslatedBlock(block: block))
        )

        #expect(decoded.textOrientation == .horizontal)
        #expect(decoded.textBlock().textOrientation == .horizontal)
    }

    @Test func offlineTranslationIntentAndPolicyCircuitAreExplicit() {
        #expect(OfflineTranslationStartIntent.fromCurrent.sourceSetID == nil)
        let explicitIndexes = try? OfflineTranslationSelection.explicitPages([1, 3]).pageIndexes(totalPages: 4)
        #expect(explicitIndexes == [1, 3])
        let refusal = AITranslationRequestError.server(
            model: "vision",
            statusCode: 400,
            message: "[1301] content policy refusal"
        )
        #expect(OfflineTranslationPolicyCircuit.isProviderRefusal(refusal))
        #expect(OfflineTranslationPolicyCircuit.refusalThreshold == 3)
    }

    @Test func offlineTranslationRetryPolicyStopsAtFiniteBackoffAndPausesForAuth() {
        let unauthorized = AITranslationRequestError.server(
            model: "vision",
            statusCode: 401,
            message: "unauthorized"
        )
        let rateLimited = AITranslationRequestError.server(
            model: "vision",
            statusCode: 429,
            message: "too many requests"
        )
        let serverRetryAfter = AITranslationRequestError.serverWithRetryAfter(
            model: "vision",
            statusCode: 503,
            message: "temporarily unavailable",
            retryAfterSeconds: 8
        )
        #expect(OfflineTranslationRetryPolicy.decision(for: unauthorized, attempt: 0) == .needsConfiguration)
        #expect(OfflineTranslationRetryPolicy.decision(for: rateLimited, attempt: 0) == .retry(afterSeconds: 2))
        #expect(OfflineTranslationRetryPolicy.decision(for: rateLimited, attempt: 2) == .retry(afterSeconds: 15))
        #expect(OfflineTranslationRetryPolicy.decision(for: rateLimited, attempt: 3) == .fail)
        #expect(OfflineTranslationRetryPolicy.decision(for: serverRetryAfter, attempt: 0) == .retry(afterSeconds: 8))
        #expect(
            OfflineTranslationRetryPolicy.decision(
                for: AITranslationRequestError.invalidTranslationJSON(model: "vision", excerpt: "{}"),
                attempt: 0
            ) == .retry(afterSeconds: 2)
        )
        let moderation = AITranslationRequestError.server(
            model: "vision",
            statusCode: 403,
            message: "content policy refusal"
        )
        #expect(OfflineTranslationRetryPolicy.decision(for: moderation, attempt: 0) == .fail)
        #expect(OfflineTranslationPolicyCircuit.isProviderRefusal(moderation))
        let forbidden = AITranslationRequestError.server(
            model: "vision",
            statusCode: 403,
            message: "invalid API key"
        )
        #expect(OfflineTranslationRetryPolicy.decision(for: forbidden, attempt: 0) == .needsConfiguration)
    }

    @Test func offlineTranslationJobJSONNeverContainsAPIKey() throws {
        let job = OfflineTranslationJobRecord(
            comicID: UUID(),
            setID: UUID(),
            selection: .fromPage(2),
            pageIndexes: [2, 3],
            providerID: UUID(),
            providerName: "test",
            baseURL: "https://example.com/v1",
            visionModel: "vision-test",
            sourceLanguage: .automatic,
            targetLanguage: .simplifiedChinese,
            promptRevision: OfflineTranslationPromptBuilder.revision,
            promptSnapshot: "fixed",
            styleInstructions: "保持自然",
            readingDirectionRaw: "leftToRight",
            totalPages: 4
        )
        let data = try JSONEncoder().encode(job)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(!json.contains("apiKey"))
        #expect(json.contains("styleInstructions"))
    }

    @Test func offlineTranslationRestartMarksRunningJobsInterruptedWithoutDeletingPages() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mreader-offline-interruption-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = OfflineTranslationStorageManager(rootURL: root)
        let comicID = UUID()
        let providerID = UUID()
        let set = OfflineTranslationSetManifest(
            comicID: comicID,
            sourceLanguage: .japanese,
            targetLanguage: .simplifiedChinese,
            providerID: providerID,
            providerName: "test",
            baseURL: "https://example.com/v1",
            visionModel: "vision-test",
            promptRevision: OfflineTranslationPromptBuilder.revision,
            promptSnapshot: "fixed",
            totalPages: 2
        )
        try await storage.saveManifest(set, activate: true)
        let page = OfflineTranslatedPage(
            comicID: comicID,
            setID: set.id,
            pageIndex: 0,
            sourceFingerprint: "stable",
            pixelWidth: 100,
            pixelHeight: 100,
            blocks: [],
            state: .noText,
            providerID: providerID,
            visionModel: "vision-test"
        )
        try await storage.savePageAndUpdateManifest(page)
        var job = OfflineTranslationJobRecord(
            comicID: comicID,
            setID: set.id,
            selection: .entireComic,
            pageIndexes: [0, 1],
            providerID: providerID,
            providerName: "test",
            baseURL: "https://example.com/v1",
            visionModel: "vision-test",
            sourceLanguage: .japanese,
            targetLanguage: .simplifiedChinese,
            promptRevision: OfflineTranslationPromptBuilder.revision,
            promptSnapshot: "fixed",
            readingDirectionRaw: "leftToRight",
            totalPages: 2
        )
        job.state = .running
        try await storage.saveJob(job)
        #expect(try await storage.markRunningJobsInterrupted() == 1)
        #expect((await storage.job(comicID: comicID, jobID: job.id))?.state == .interrupted)
        #expect((await storage.page(comicID: comicID, setID: set.id, pageIndex: 0))?.state == .noText)
    }

    @Test func offlineTranslationCorruptPageJSONIsIgnoredForRegeneration() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mreader-offline-corrupt-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = OfflineTranslationStorageManager(rootURL: root)
        let comicID = UUID()
        let setID = UUID()
        let manifest = OfflineTranslationSetManifest(
            id: setID,
            comicID: comicID,
            sourceLanguage: .automatic,
            targetLanguage: .english,
            providerID: UUID(),
            providerName: "test",
            baseURL: "https://example.com/v1",
            visionModel: "vision-test",
            promptRevision: OfflineTranslationPromptBuilder.revision,
            promptSnapshot: "fixed",
            totalPages: 1
        )
        try await storage.saveManifest(manifest, activate: true)
        let pagesURL = root
            .appendingPathComponent(comicID.uuidString)
            .appendingPathComponent("sets")
            .appendingPathComponent(setID.uuidString)
            .appendingPathComponent("pages")
        try FileManager.default.createDirectory(at: pagesURL, withIntermediateDirectories: true)
        try Data("{not-json".utf8).write(
            to: pagesURL.appendingPathComponent("000000.json"),
            options: .atomic
        )
        #expect(await storage.page(comicID: comicID, setID: setID, pageIndex: 0) == nil)
        #expect(await storage.pageStates(comicID: comicID, setID: setID).isEmpty)
    }

    @MainActor
    private final class InMemoryAICredentialStore: AICredentialStoring {
    private var values: [UUID: String] = [:]

    func apiKey(for profileID: UUID) -> String? {
        values[profileID]
    }

    func saveAPIKey(_ apiKey: String, for profileID: UUID) throws {
        values[profileID] = apiKey
    }

    func removeAPIKey(for profileID: UUID) {
        values[profileID] = nil
    }
}
