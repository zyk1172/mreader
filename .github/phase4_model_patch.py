from pathlib import Path
import re


def replace_once(text: str, old: str, new: str, label: str) -> str:
    if old not in text:
        raise SystemExit(f"missing anchor: {label}")
    return text.replace(old, new, 1)


path = Path("mreader/AITranslator.swift")
text = path.read_text()

# F10: preserve three separate meanings: source text, physical bubble, layout-safe region.
text = replace_once(
    text,
    "    var bubbleBox: CGRect?\n    /// textPolygon；保留旧属性名以兼容既有 OCR 调用。",
    "    /// Physical bubble bounds when a real bubble was detected. This is not a layout expansion hint.\n"
    "    var bubbleBox: CGRect?\n"
    "    /// Independent region in which translated text may be laid out. It may exist even when no physical bubble exists.\n"
    "    var layoutSafeRegion: CGRect?\n"
    "    /// textPolygon；保留旧属性名以兼容既有 OCR 调用。",
    "TextBlock region properties",
)
text = replace_once(
    text,
    "textColorHex: String? = nil, bubbleBox: CGRect? = nil, polygon: [CGPoint] = []",
    "textColorHex: String? = nil, bubbleBox: CGRect? = nil, layoutSafeRegion: CGRect? = nil, polygon: [CGPoint] = []",
    "TextBlock initializer parameter",
)
text = replace_once(
    text,
    "        self.bubbleBox = bubbleBox\n        self.polygon = polygon",
    "        self.bubbleBox = bubbleBox\n        self.layoutSafeRegion = layoutSafeRegion\n        self.polygon = polygon",
    "TextBlock initializer assignment",
)

# Translation vision prompt: bubble = physical object; layoutSafeRegion = placement contract.
for old, new, label in [
    (
        "并给出文字框和推荐显示气泡框坐标。",
        "并给出文字框、真实物理气泡（存在时）和独立的安全排版区域。",
        "vision task description",
    ),
    (
        "textBox、bubbleBox、textPolygon、bubblePolygon、confidence、classification",
        "textBox、bubbleBox、layoutSafeRegion、textPolygon、bubblePolygon、confidence、classification",
        "vision field list",
    ),
    (
        "textBox 必须紧贴原文字，bubbleBox 只表示译文允许扩展到的最大范围，不能代替 textBox。",
        "textBox 必须紧贴原文字；bubbleBox 只表示真实物理气泡，没有气泡（例如无框拟声词）时必须省略；layoutSafeRegion 表示译文允许排版的安全区域，不能把它伪装成气泡。",
        "vision region semantics",
    ),
    (
        '          "bubbleBox": {"x": 0.1, "y": 0.18, "width": 0.34, "height": 0.1},',
        '          "bubbleBox": {"x": 0.1, "y": 0.18, "width": 0.34, "height": 0.1},\n'
        '          "layoutSafeRegion": {"x": 0.11, "y": 0.19, "width": 0.32, "height": 0.08},',
        "vision JSON sample safe region",
    ),
    (
        "textBox 紧贴文字，bubbleBox 覆盖文字所在的完整原气泡；同时尽量返回对应的四点 textPolygon 和 bubblePolygon。",
        "textBox 紧贴文字；bubbleBox 只在能确认真实物理气泡时返回，无框拟声词必须省略；layoutSafeRegion 始终返回可安全摆放译文的区域；同时尽量返回对应的四点 textPolygon 和 bubblePolygon。",
        "recognition region semantics",
    ),
    (
        '\"bubbleBox\":{\"x\":0.08,\"y\":0.18,\"width\":0.24,\"height\":0.12},\"textPolygon\"',
        '\"bubbleBox\":{\"x\":0.08,\"y\":0.18,\"width\":0.24,\"height\":0.12},\"layoutSafeRegion\":{\"x\":0.09,\"y\":0.19,\"width\":0.22,\"height\":0.10},\"textPolygon\"',
        "recognition JSON sample safe region",
    ),
]:
    text = replace_once(text, old, new, label)

# Strict structured-output schema: physical bubble is optional; safe region is required.
text = replace_once(
    text,
    '                "sourceText", "translation", "textBox", "bubbleBox", "confidence", "classification"',
    '                "sourceText", "translation", "textBox", "layoutSafeRegion", "confidence", "classification"',
    "schema required list",
)
text = replace_once(
    text,
    '                "bubbleBox": rect,\n                "textPolygon":',
    '                "bubbleBox": rect,\n                "layoutSafeRegion": rect,\n                "textPolygon":',
    "schema safe-region property",
)

# Strict parser follows the new contract.
text = replace_once(
    text,
    '''                guard rectValue(from: item["bubbleBox"]) != nil else {
                    throw VisionTranslationError.protocolViolation("缺少必需 bubbleBox")
                }''',
    '''                guard rectValue(from: item["layoutSafeRegion"] ?? item["layout_safe_region"]) != nil else {
                    throw VisionTranslationError.protocolViolation("缺少必需 layoutSafeRegion")
                }''',
    "strict safe-region validation",
)

# Translation parser data model.
text = replace_once(
    text,
    "            let bubbleRect: CGRect?\n            let rect: CGRect",
    "            let bubbleRect: CGRect?\n            let layoutSafeRect: CGRect?\n            let rect: CGRect",
    "RawVisionItem safe region",
)
text = replace_once(
    text,
    '            let bubbleRect = rectValue(from: item["bubbleBox"] ?? item["bubble_box"])\n            let localPolygon',
    '            let bubbleRect = rectValue(from: item["bubbleBox"] ?? item["bubble_box"])\n'
    '            let layoutSafeRect = rectValue(from: item["layoutSafeRegion"] ?? item["layout_safe_region"])\n'
    '            let localPolygon',
    "RawVisionItem parse safe region",
)
text = replace_once(
    text,
    "                bubbleRect: bubbleRect,\n                rect: localRect,",
    "                bubbleRect: bubbleRect,\n                layoutSafeRect: layoutSafeRect,\n                rect: localRect,",
    "RawVisionItem construction",
)
text = replace_once(
    text,
    "rects: parsedItems.flatMap { [$0.textRect, $0.bubbleRect, $0.rect].compactMap { $0 } },",
    "rects: parsedItems.flatMap { [$0.textRect, $0.bubbleRect, $0.layoutSafeRect, $0.rect].compactMap { $0 } },",
    "translation coordinate validation",
)
text = replace_once(
    text,
    "            let mappedBubbleRect = normalizedBubbleRect.map { mapVisionRect($0, from: sourceRect) }\n            let normalizedRect",
    "            let mappedBubbleRect = normalizedBubbleRect.map { mapVisionRect($0, from: sourceRect) }\n"
    "            let normalizedLayoutSafeRect = item.layoutSafeRect.map { normalizeVisionRect($0, divisor: coordinateDivisor) }\n"
    "            let mappedLayoutSafeRect = normalizedLayoutSafeRect.map { mapVisionRect($0, from: sourceRect) }\n"
    "            let normalizedRect",
    "translation safe-region mapping",
)
text = replace_once(
    text,
    "                bubbleBox: mappedBubbleRect.flatMap { isUsableVisionRect($0) ? $0 : nil },\n                polygon: mappedTextPolygon,",
    "                bubbleBox: mappedBubbleRect.flatMap { isUsableVisionRect($0) ? $0 : nil },\n"
    "                layoutSafeRegion: mappedLayoutSafeRect.flatMap { isUsableVisionRect($0) ? $0 : nil },\n"
    "                polygon: mappedTextPolygon,",
    "translation TextBlock safe region",
)

# Recognition parser carries the same semantics, while legacy/model responses can fall back locally.
text = replace_once(
    text,
    "            let bubbleRect: CGRect?\n            let textPolygon: [CGPoint]",
    "            let bubbleRect: CGRect?\n            let layoutSafeRect: CGRect?\n            let textPolygon: [CGPoint]",
    "RawRecognitionItem safe region",
)
text = replace_once(
    text,
    '                bubbleRect: rectValue(from: item["bubbleBox"] ?? item["bubble_box"]),\n                textPolygon:',
    '                bubbleRect: rectValue(from: item["bubbleBox"] ?? item["bubble_box"]),\n'
    '                layoutSafeRect: rectValue(from: item["layoutSafeRegion"] ?? item["layout_safe_region"]),\n'
    '                textPolygon:',
    "RawRecognitionItem parse safe region",
)
text = replace_once(
    text,
    "        let allRects = parsed.flatMap { [$0.textRect, $0.bubbleRect].compactMap { $0 } }",
    "        let allRects = parsed.flatMap { [$0.textRect, $0.bubbleRect, $0.layoutSafeRect].compactMap { $0 } }",
    "recognition coordinate validation",
)
text = replace_once(
    text,
    '''            let validBubbleRect = normalizedBubbleRect.flatMap { rect -> CGRect? in
                let mapped = mapVisionRect(rect, from: sourceRect)
                return isUsableVisionRect(mapped) ? mapped : nil
            }
            guard let mappedRect''',
    '''            let validBubbleRect = normalizedBubbleRect.flatMap { rect -> CGRect? in
                let mapped = mapVisionRect(rect, from: sourceRect)
                return isUsableVisionRect(mapped) ? mapped : nil
            }
            let validLayoutSafeRect = item.layoutSafeRect
                .map { normalizeVisionRect($0, divisor: coordinateDivisor) }
                .map { mapVisionRect($0, from: sourceRect) }
                .flatMap { isUsableVisionRect($0) ? $0 : nil }
            guard let mappedRect''',
    "recognition safe-region mapping",
)
text = replace_once(
    text,
    "                    bubbleBox: validBubbleRect,\n                    polygon: mappedTextPolygon,",
    "                    bubbleBox: validBubbleRect,\n"
    "                    layoutSafeRegion: validLayoutSafeRect ?? validBubbleRect ?? mappedRect,\n"
    "                    polygon: mappedTextPolygon,",
    "recognition TextBlock safe region",
)

# F12: deterministic image-driven seams instead of viewport-driven cuts.
pattern = re.compile(
    r"    private static func shouldSliceBeforeVision\(_ image: UIImage, viewportAspect: CGFloat\) -> Bool \{.*?\n"
    r"    \}\n\n"
    r"    private static func visionSlices\(from image: UIImage, viewportAspect: CGFloat\) -> \[VisionSlice\] \{.*?\n"
    r"    \}\n\n"
    r"    private static func parseVisionTranslationBlocks",
    re.S,
)
match = pattern.search(text)
if not match:
    raise SystemExit("missing anchor: vision slicing block")
replacement = '''    private static func shouldSliceBeforeVision(_ image: UIImage, viewportAspect: CGFloat) -> Bool {
        guard let cgImage = image.cgImage, cgImage.width > 0 else { return false }
        _ = viewportAspect // Image content, not viewport size, determines slice boundaries.
        let ratio = CGFloat(cgImage.height) / CGFloat(cgImage.width)
        return ratio > 2.2
    }

    private static func horizontalSeamScores(for image: UIImage) -> [Double]? {
        guard let source = image.cgImage, source.width > 0, source.height > 0 else { return nil }
        let sampleWidth = min(max(source.width / 8, 64), 256)
        let sampleHeight = max(
            Int((Double(source.height) / Double(source.width) * Double(sampleWidth)).rounded()),
            1
        )
        var pixels = [UInt8](repeating: 255, count: sampleWidth * sampleHeight)
        let rendered = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: sampleWidth,
                height: sampleHeight,
                bitsPerComponent: 8,
                bytesPerRow: sampleWidth,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            context.interpolationQuality = .low
            context.draw(source, in: CGRect(x: 0, y: 0, width: sampleWidth, height: sampleHeight))
            return true
        }
        guard rendered else { return nil }

        var rawScores = [Double](repeating: 0, count: sampleHeight)
        for y in 0..<sampleHeight {
            var sum = 0.0
            var sumSquares = 0.0
            var gradient = 0.0
            for x in 0..<sampleWidth {
                let value = Double(pixels[y * sampleWidth + x]) / 255.0
                sum += value
                sumSquares += value * value
                if y > 0 {
                    let previous = Double(pixels[(y - 1) * sampleWidth + x]) / 255.0
                    gradient += abs(value - previous)
                }
            }
            let count = Double(sampleWidth)
            let mean = sum / count
            let variance = max(sumSquares / count - mean * mean, 0)
            let edge = gradient / count
            // Low-detail gutters beat text/line-art rows. Light gutters get a
            // small preference without excluding uniform dark panel separators.
            rawScores[y] = variance * 1.4 + edge * 0.8 + (1 - mean) * 0.05
        }
        guard sampleHeight >= 3 else { return rawScores }
        return rawScores.indices.map { y in
            let lower = max(0, y - 1)
            let upper = min(sampleHeight - 1, y + 1)
            return rawScores[lower...upper].reduce(0.0, +) / Double(upper - lower + 1)
        }
    }

    private static func contentAwareHorizontalSeam(
        near target: Int,
        imageHeight: Int,
        imageWidth: Int,
        scores: [Double]?
    ) -> Int {
        guard let scores, scores.count > 1, imageHeight > 1 else { return target }
        let radius = max(Int(Double(imageWidth) * 0.28), 80)
        let lower = max(1, target - radius)
        let upper = min(imageHeight - 1, target + radius)
        guard lower < upper else { return min(max(target, 1), imageHeight - 1) }
        let span = max(upper - lower, 1)
        var best = min(max(target, lower), upper)
        var bestScore = Double.greatestFiniteMagnitude
        for y in lower...upper {
            let sampleY = min(
                max(Int(Double(y) / Double(imageHeight) * Double(scores.count)), 0),
                scores.count - 1
            )
            let distancePenalty = Double(abs(y - target)) / Double(span) * 0.08
            let score = scores[sampleY] + distancePenalty
            if score < bestScore {
                bestScore = score
                best = y
            }
        }
        return best
    }

    private static func visionSlices(from image: UIImage, viewportAspect: CGFloat) -> [VisionSlice] {
        guard let cgImage = image.cgImage, cgImage.width > 0, cgImage.height > 0 else {
            return []
        }
        let width = cgImage.width
        let height = cgImage.height
        guard shouldSliceBeforeVision(image, viewportAspect: viewportAspect) else {
            return [VisionSlice(image: image, sourceRect: CGRect(x: 0, y: 0, width: 1, height: 1))]
        }

        let targetSliceHeight = min(max(Int(CGFloat(width) * 1.8), 1000), 3200)
        let overlap = max(Int(Double(targetSliceHeight) * 0.10), 96)
        let scores = horizontalSeamScores(for: image)
        var boundaries = [0]
        var cursor = 0
        while height - cursor > Int(Double(targetSliceHeight) * 1.25) {
            let target = min(cursor + targetSliceHeight, height - 1)
            var seam = contentAwareHorizontalSeam(
                near: target,
                imageHeight: height,
                imageWidth: width,
                scores: scores
            )
            let minimumAdvance = max(Int(Double(targetSliceHeight) * 0.62), 1)
            if seam - cursor < minimumAdvance {
                seam = min(cursor + minimumAdvance, height - 1)
            }
            guard seam > cursor else { break }
            boundaries.append(seam)
            cursor = seam
        }
        boundaries.append(height)

        var slices: [VisionSlice] = []
        for index in 0..<(boundaries.count - 1) {
            let coreStart = boundaries[index]
            let coreEnd = boundaries[index + 1]
            let y0 = max(0, coreStart - (index == 0 ? 0 : overlap / 2))
            let y1 = min(height, coreEnd + (index == boundaries.count - 2 ? 0 : overlap / 2))
            let currentHeight = max(y1 - y0, 1)
            let cropRect = CGRect(
                x: 0,
                y: CGFloat(y0),
                width: CGFloat(width),
                height: CGFloat(currentHeight)
            )
            guard let cropped = cgImage.cropping(to: cropRect) else { continue }
            let normalized = CGRect(
                x: 0,
                y: CGFloat(y0) / CGFloat(height),
                width: 1,
                height: CGFloat(currentHeight) / CGFloat(height)
            )
            let croppedImage = UIImage(cgImage: cropped, scale: 1, orientation: image.imageOrientation)
            slices.append(VisionSlice(
                image: resizedImageForVision(croppedImage, maxDimension: 2560),
                sourceRect: normalized
            ))
        }
        return slices
    }

    static func visionSliceRectsForDiagnostics(
        _ image: UIImage,
        viewportAspect: CGFloat = 2.0
    ) -> [CGRect] {
        visionSlices(from: image, viewportAspect: viewportAspect).map(\.sourceRect)
    }

    private static func parseVisionTranslationBlocks'''
text = text[:match.start()] + replacement + text[match.end():]
path.write_text(text)

# Offline strict prompt uses the same region contract.
prompt_path = Path("mreader/OfflineTranslationPrompt.swift")
prompt = prompt_path.read_text()
prompt = replace_once(
    prompt,
    'static let revision = "offline-vision-v4-context"',
    'static let revision = "offline-vision-v5-region-semantics"',
    "offline prompt revision",
)
prompt = replace_once(
    prompt,
    "每个 item 必须包含 sourceText、translation、textBox、bubbleBox、confidence、classification。id、translationLines、textPolygon、bubblePolygon 都是可选字段；不要使用 text、lines、polygon 或任何别名。",
    "每个 item 必须包含 sourceText、translation、textBox、layoutSafeRegion、confidence、classification。bubbleBox、id、translationLines、textPolygon、bubblePolygon 都是可选字段；不要使用 text、lines、polygon 或任何别名。",
    "offline required fields",
)
prompt = replace_once(
    prompt,
    "textBox 是紧贴原文字的必填字段，用于原文字号与位置；bubbleBox 只表示译文可扩展到的最大范围，不能代替 textBox。polygon 若提供，分别对应两个框。",
    "textBox 是紧贴原文字的必填字段；bubbleBox 只表示真实物理气泡，没有气泡的拟声词必须省略；layoutSafeRegion 是独立的安全排版区域，即使没有物理气泡也必须提供。polygon 若提供，分别对应真实文字与物理气泡。",
    "offline region semantics",
)
prompt = replace_once(
    prompt,
    '{"coordinateSpace":"normalized","items":[{"sourceText":"原文","translation":"译文","textBox":{"x":0.1,"y":0.2,"width":0.2,"height":0.08},"bubbleBox":{"x":0.08,"y":0.18,"width":0.24,"height":0.12},"confidence":0.9,"classification":"dialogue"}]}',
    '{"coordinateSpace":"normalized","items":[{"sourceText":"原文","translation":"译文","textBox":{"x":0.1,"y":0.2,"width":0.2,"height":0.08},"bubbleBox":{"x":0.08,"y":0.18,"width":0.24,"height":0.12},"layoutSafeRegion":{"x":0.09,"y":0.19,"width":0.22,"height":0.10},"confidence":0.9,"classification":"dialogue"}]}',
    "offline JSON sample",
)
prompt_path.write_text(prompt)
