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
    
    // 1. 使用 Apple 原生 Vision 框架进行 OCR 识别 (极低内存占用，全本地执行)
    static func recognizeText(in image: UIImage) async throws -> [TextBlock] {
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
                continuation.resume(returning: blocks)
            }
            
            // 专为漫画阅读设置高精度
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            // 支持日文、繁体中文、英文
            request.recognitionLanguages = ["ja-JP", "zh-Hant", "en-US"]
            
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
    
    // 2. 调用 OpenAI 兼容接口进行翻译
    static func translate(text: String, apiKey: String, baseURL: String, model: String, targetLanguage: String = "中文") async throws -> String {
        guard !apiKey.isEmpty else { return "未配置 API Key" }
        guard !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "未配置模型" }
        guard let url = chatCompletionsURL(from: baseURL) else { return "接口地址无效" }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let body: [String: Any] = [
            "model": model.trimmingCharacters(in: .whitespacesAndNewlines),
            "messages": [
                ["role": "system", "content": "你是一个专业的二次元漫画翻译。请将以下台词翻译成\(targetLanguage)，保持口语化。仅输出翻译结果，不要多余解释。"],
                ["role": "user", "content": text]
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
}
