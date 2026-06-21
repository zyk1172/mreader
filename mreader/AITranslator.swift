import Foundation
import Vision
import UIKit

// 定义识别出的文本块模型
struct TextBlock: Identifiable {
    let id: UUID
    let text: String
    let boundingBox: CGRect // 原图中的相对坐标 (0.0 ~ 1.0)
    var translation: String?

    init(id: UUID = UUID(), text: String, boundingBox: CGRect, translation: String? = nil) {
        self.id = id
        self.text = text
        self.boundingBox = boundingBox
        self.translation = translation
    }
}

class AITranslator {
    nonisolated static let defaultTranslationPromptTemplate = """
    你是一个漫画对白翻译助手。请只翻译我提供的 OCR 文本，不要续写、总结、评价或添加剧情。
    请保持原文的语气、称呼、人物关系、情绪和漫画对白的自然口语感。
    如果原文有断句、气泡顺序或拟声词，请尽量保留对应结构。
    不要记录、记忆、推断用户身份，也不要输出与翻译无关的内容。
    如果文本包含成人、暴力、敏感或私人内容，只进行中性、准确翻译，不要扩写、润色成更露骨内容，也不要添加新的细节。
    请将以下文本翻译为：{targetLanguage}

    OCR 文本：
    {ocrText}

    输出要求：
    只输出翻译结果。
    """
    
    // 1. 使用 Apple 原生 Vision 框架进行 OCR 识别 (极低内存占用，全本地执行)
    static func recognizeText(in image: UIImage, isRightToLeft: Bool = false) async throws -> [TextBlock] {
        let languagePasses = [
            ["ja-JP", "zh-Hans", "zh-Hant", "ko-KR", "en-US"],
            ["zh-Hans", "zh-Hant", "en-US"],
            ["ja-JP", "en-US"],
            ["en-US"]
        ]

        var lastError: Error?
        for languages in languagePasses {
            do {
                let blocks = try await recognizeText(in: image, languages: languages, isRightToLeft: isRightToLeft)
                if !blocks.isEmpty {
                    return blocks
                }
            } catch {
                lastError = error
            }
        }
        if let lastError {
            throw lastError
        }
        return []
    }

    private static func recognizeText(in image: UIImage, languages: [String], isRightToLeft: Bool) async throws -> [TextBlock] {
        return try await withCheckedThrowingContinuation { continuation in
            guard let cgImage = image.cgImage else {
                continuation.resume(returning: [])
                return
            }
            
            let request = VNRecognizeTextRequest { request, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }
                
                var blocks: [TextBlock] = []
                let observations = request.results as? [VNRecognizedTextObservation] ?? []
                
                for obs in observations {
                    if let topCandidate = obs.topCandidates(1).first {
                        // Apple Vision 的坐标系左下角是 (0,0)
                        // SwiftUI 的坐标系左上角是 (0,0)，我们需要翻转 Y 轴
                        let visionRect = obs.boundingBox
                        let swiftUIRect = CGRect(
                            x: visionRect.origin.x,
                            y: 1.0 - visionRect.origin.y - visionRect.size.height,
                            width: visionRect.size.width,
                            height: visionRect.size.height
                        )
                        blocks.append(TextBlock(text: topCandidate.string, boundingBox: swiftUIRect))
                    }
                }
                continuation.resume(returning: sortedTextBlocks(blocks, isRightToLeft: isRightToLeft))
            }
            
            // 专为漫画阅读设置高精度
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false
            request.minimumTextHeight = 0.008
            request.recognitionLanguages = supportedRecognitionLanguages(from: languages, request: request)
            
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
    
    // 2. 调用 OpenAI 兼容接口进行翻译
    static func translate(text: String, apiKey: String, baseURL: String, model: String, targetLanguage: String = "中文", promptTemplate: String = defaultTranslationPromptTemplate) async throws -> String {
        guard !apiKey.isEmpty else { return "未配置 API Key" }
        guard !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "未配置模型" }
        guard let url = chatCompletionsURL(from: baseURL) else { return "接口地址无效" }
        let prompt = renderPrompt(template: promptTemplate, text: text, targetLanguage: targetLanguage)
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let body: [String: Any] = [
            "model": model.trimmingCharacters(in: .whitespacesAndNewlines),
            "messages": [
                ["role": "system", "content": "你是一个只输出翻译结果的漫画对白翻译助手。不要续写、总结、评价、添加剧情、保存信息或推断用户身份。"],
                ["role": "user", "content": prompt]
            ],
            "temperature": 0.3
        ]
        
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = json["error"] as? [String: Any],
           let message = error["message"] as? String {
            return "接口错误：\(message)"
        }

        if let httpResponse = response as? HTTPURLResponse,
           !(200..<300).contains(httpResponse.statusCode) {
            return "接口错误：HTTP \(httpResponse.statusCode)"
        }

        if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
           let choices = json["choices"] as? [[String: Any]],
           let message = choices.first?["message"] as? [String: Any],
           let content = message["content"] as? String {
            return content.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        
        return "翻译失败"
    }

    private static func chatCompletionsURL(from baseURL: String) -> URL? {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.hasSuffix("/chat/completions") {
            return URL(string: trimmed)
        }

        let withoutTrailingSlash = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return URL(string: "\(withoutTrailingSlash)/chat/completions")
    }

    private static func renderPrompt(template: String, text: String, targetLanguage: String) -> String {
        let usableTemplate = template.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? defaultTranslationPromptTemplate : template
        return usableTemplate
            .replacingOccurrences(of: "{targetLanguage}", with: targetLanguage)
            .replacingOccurrences(of: "{ocrText}", with: text)
    }

    private static func supportedRecognitionLanguages(from preferredLanguages: [String], request: VNRecognizeTextRequest) -> [String] {
        let supported = (try? request.supportedRecognitionLanguages()) ?? preferredLanguages
        let filtered = preferredLanguages.filter { supported.contains($0) }
        return filtered.isEmpty ? preferredLanguages : filtered
    }

    static func filteredMangaTextBlocks(_ blocks: [TextBlock], safeAreaInset: Double, isRightToLeft: Bool) -> [TextBlock] {
        let inset = min(max(CGFloat(safeAreaInset), 0), 0.3)
        let safeRect = CGRect(x: inset, y: inset, width: max(0, 1 - inset * 2), height: max(0, 1 - inset * 2))

        let filtered = blocks.filter { block in
            let text = block.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return false }
            guard safeRect.contains(CGPoint(x: block.boundingBox.midX, y: block.boundingBox.midY)) else { return false }
            guard !isLikelyEdgeNoise(text) else { return false }

            let height = block.boundingBox.height
            let area = block.boundingBox.width * block.boundingBox.height
            if text.count <= 2 && height < 0.022 {
                return false
            }
            if height < 0.014 || area < 0.00012 {
                return false
            }
            return true
        }

        return sortedTextBlocks(filtered, isRightToLeft: isRightToLeft)
    }

    static func groupedMangaTextBlocks(_ blocks: [TextBlock], isRightToLeft: Bool) -> [TextBlock] {
        let sorted = sortedTextBlocks(blocks, isRightToLeft: isRightToLeft)
        guard sorted.count > 1 else { return sorted }

        var groups: [TextBlock] = []
        for block in sorted {
            guard let last = groups.last else {
                groups.append(block)
                continue
            }

            if shouldMerge(last.boundingBox, with: block.boundingBox) {
                let merged = TextBlock(
                    id: last.id,
                    text: joinedOCRText(last.text, block.text),
                    boundingBox: last.boundingBox.union(block.boundingBox),
                    translation: last.translation
                )
                groups[groups.count - 1] = merged
            } else {
                groups.append(block)
            }
        }

        return sortedTextBlocks(groups, isRightToLeft: isRightToLeft)
    }

    private static func isLikelyEdgeNoise(_ text: String) -> Bool {
        let lowercased = text.lowercased()
        let noiseFragments = ["http://", "https://", "www.", ".com", ".net", ".org", "@", "copyright", "©", "sample"]
        return noiseFragments.contains { lowercased.contains($0) }
    }

    private static func shouldMerge(_ lhs: CGRect, with rhs: CGRect) -> Bool {
        let expanded = lhs.insetBy(dx: -0.045, dy: -0.035)
        if expanded.intersects(rhs) {
            return lhs.union(rhs).width < 0.78 && lhs.union(rhs).height < 0.34
        }

        let horizontalGap = max(0, max(lhs.minX, rhs.minX) - min(lhs.maxX, rhs.maxX))
        let verticalGap = max(0, max(lhs.minY, rhs.minY) - min(lhs.maxY, rhs.maxY))
        let sameLine = abs(lhs.midY - rhs.midY) < 0.055 && horizontalGap < 0.09
        let sameBalloonColumn = abs(lhs.midX - rhs.midX) < 0.13 && verticalGap < 0.06
        let union = lhs.union(rhs)
        return (sameLine || sameBalloonColumn) && union.width < 0.78 && union.height < 0.34
    }

    private static func joinedOCRText(_ lhs: String, _ rhs: String) -> String {
        let left = lhs.trimmingCharacters(in: .whitespacesAndNewlines)
        let right = rhs.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !left.isEmpty else { return right }
        guard !right.isEmpty else { return left }

        if left.hasSuffix("-") {
            return String(left.dropLast()) + right
        }
        if containsCJK(left) || containsCJK(right) {
            return left + right
        }
        let noSpaceBefore = CharacterSet(charactersIn: ".,!?;:)]}」』》）！？。，、；：")
        if let first = right.unicodeScalars.first, noSpaceBefore.contains(first) {
            return left + right
        }
        return left + " " + right
    }

    private static func containsCJK(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            let value = scalar.value
            return (0x4E00...0x9FFF).contains(value)
                || (0x3040...0x30FF).contains(value)
                || (0xAC00...0xD7AF).contains(value)
        }
    }

    private static func sortedTextBlocks(_ blocks: [TextBlock], isRightToLeft: Bool) -> [TextBlock] {
        let validBlocks = blocks.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard validBlocks.count > 1 else { return validBlocks }

        let verticalCount = validBlocks.filter { block in
            block.boundingBox.height > block.boundingBox.width * 1.35
        }.count
        let isMostlyVertical = verticalCount > validBlocks.count / 2

        if isMostlyVertical {
            return validBlocks.sorted { lhs, rhs in
                let columnDistance = abs(lhs.boundingBox.midX - rhs.boundingBox.midX)
                if columnDistance > 0.045 {
                    return isRightToLeft ? lhs.boundingBox.midX > rhs.boundingBox.midX : lhs.boundingBox.midX < rhs.boundingBox.midX
                }
                return lhs.boundingBox.midY < rhs.boundingBox.midY
            }
        }

        return validBlocks.sorted { lhs, rhs in
            let rowDistance = abs(lhs.boundingBox.midY - rhs.boundingBox.midY)
            if rowDistance > 0.035 {
                return lhs.boundingBox.midY < rhs.boundingBox.midY
            }
            return isRightToLeft ? lhs.boundingBox.midX > rhs.boundingBox.midX : lhs.boundingBox.midX < rhs.boundingBox.midX
        }
    }
}
