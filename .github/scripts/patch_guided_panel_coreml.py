from pathlib import Path

source = Path('mreader/PanelDetectionService.swift')
text = source.read_text()
start = text.index('nonisolated struct CoreMLPanelDetector:')
end = text.index('nonisolated enum PanelPostProcessor', start)
replacement = r'''nonisolated struct CoreMLPanelDetector: PanelDetector, @unchecked Sendable {
    let identifier: String
    private let model: VNCoreMLModel

    private static let frameClassID = 0
    private static let minimumFrameConfidence: Float = 0.24
    private static let modelInputDimension: CGFloat = 640

    private init(model: VNCoreMLModel, identifier: String) {
        self.model = model
        self.identifier = identifier
    }

    static func bundled(bundle: Bundle = .main) -> CoreMLPanelDetector? {
        guard let modelURL = bundle.url(forResource: "PanelDetector", withExtension: "mlmodelc") else {
            return nil
        }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuAndNeuralEngine
        guard let mlModel = try? MLModel(contentsOf: modelURL, configuration: configuration),
              let visionModel = try? VNCoreMLModel(for: mlModel) else {
            return nil
        }
        return CoreMLPanelDetector(
            model: visionModel,
            identifier: "manga109-yolo26s-seg-coreml-fp16-640-v1"
        )
    }

    func detectPanels(in image: CGImage) throws -> [DetectedPanel] {
        let request = VNCoreMLRequest(model: model)
        request.imageCropAndScaleOption = .scaleFit
        let handler = VNImageRequestHandler(cgImage: image, orientation: .up, options: [:])
        try handler.perform([request])

        let featureObservations = (request.results ?? []).compactMap {
            $0 as? VNCoreMLFeatureValueObservation
        }
        guard let output = featureObservations
            .compactMap({ $0.featureValue.multiArrayValue })
            .first(where: Self.looksLikeDetectionTensor) else {
            return []
        }

        return Self.decodeFrames(
            output,
            imageSize: CGSize(width: image.width, height: image.height)
        )
    }

    nonisolated static func decodedPanelsForDiagnostics(
        _ output: MLMultiArray,
        imageSize: CGSize
    ) -> [DetectedPanel] {
        decodeFrames(output, imageSize: imageSize)
    }

    private static func looksLikeDetectionTensor(_ output: MLMultiArray) -> Bool {
        let shape = output.shape.map(\.intValue)
        guard shape.count == 3, shape.first == 1 else { return false }
        let dimensions = Array(shape.dropFirst())
        return dimensions.contains(where: { $0 >= 6 && $0 <= 128 })
            && dimensions.contains(where: { $0 >= 1 && $0 <= 1000 })
    }

    private static func decodeFrames(
        _ output: MLMultiArray,
        imageSize: CGSize
    ) -> [DetectedPanel] {
        let shape = output.shape.map(\.intValue)
        guard shape.count == 3,
              shape[0] == 1,
              imageSize.width > 0,
              imageSize.height > 0 else {
            return []
        }

        let rowMajor: Bool
        let instanceCount: Int
        let featureCount: Int
        if shape[2] >= 6, shape[2] <= 128 {
            rowMajor = true
            instanceCount = shape[1]
            featureCount = shape[2]
        } else if shape[1] >= 6, shape[1] <= 128 {
            rowMajor = false
            instanceCount = shape[2]
            featureCount = shape[1]
        } else {
            return []
        }
        guard featureCount >= 6 else { return [] }

        func value(instance: Int, feature: Int) -> Double {
            let indices: [NSNumber]
            if rowMajor {
                indices = [0, NSNumber(value: instance), NSNumber(value: feature)]
            } else {
                indices = [0, NSNumber(value: feature), NSNumber(value: instance)]
            }
            return output[indices].doubleValue
        }

        let inputSize = modelInputDimension
        let sourceWidth = imageSize.width
        let sourceHeight = imageSize.height
        let scale = min(inputSize / sourceWidth, inputSize / sourceHeight)
        let scaledWidth = sourceWidth * scale
        let scaledHeight = sourceHeight * scale
        let padX = (inputSize - scaledWidth) / 2
        let padY = (inputSize - scaledHeight) / 2
        let unit = CGRect(x: 0, y: 0, width: 1, height: 1)

        var panels: [DetectedPanel] = []
        panels.reserveCapacity(min(instanceCount, 32))

        for index in 0..<instanceCount {
            let confidence = Float(value(instance: index, feature: 4))
            guard confidence.isFinite, confidence >= minimumFrameConfidence else { continue }

            let classID = Int(value(instance: index, feature: 5).rounded())
            guard classID == frameClassID else { continue }

            var x1 = CGFloat(value(instance: index, feature: 0))
            var y1 = CGFloat(value(instance: index, feature: 1))
            var x2 = CGFloat(value(instance: index, feature: 2))
            var y2 = CGFloat(value(instance: index, feature: 3))
            guard x1.isFinite, y1.isFinite, x2.isFinite, y2.isFinite else { continue }

            let maximumCoordinate = max(abs(x1), abs(y1), abs(x2), abs(y2))
            if maximumCoordinate <= 2 {
                x1 *= inputSize
                y1 *= inputSize
                x2 *= inputSize
                y2 *= inputSize
            }

            let rect = CGRect(
                x: (x1 - padX) / scaledWidth,
                y: (y1 - padY) / scaledHeight,
                width: (x2 - x1) / scaledWidth,
                height: (y2 - y1) / scaledHeight
            ).standardized.intersection(unit)

            guard !rect.isNull,
                  rect.width > 0.01,
                  rect.height > 0.01 else {
                continue
            }

            panels.append(
                DetectedPanel(
                    rect: rect,
                    confidence: confidence,
                    source: .coreML
                )
            )
        }

        return panels
    }
}
'''
source.write_text(text[:start] + replacement + '\n\n' + text[end:])

updated = source.read_text()
updated = updated.replace('static let modelVersion = 1', 'static let modelVersion = 2', 1)
source.write_text(updated)

tests = Path('mreaderTests/GuidedPanelFoundationTests.swift')
test_text = tests.read_text()
if 'import CoreML\n' not in test_text:
    test_text = test_text.replace('import CoreGraphics\n', 'import CoreGraphics\nimport CoreML\n', 1)

anchor = '    @Test func layoutQualityRejectsImplausibleResults() {'
test_block = r'''    @Test func coreMLDecoderKeepsFramesAndRejectsTextAndBalloons() throws {
        let output = try MLMultiArray(shape: [1, 3, 38], dataType: .float32)

        func set(_ instance: Int, _ feature: Int, _ value: Double) {
            let flatIndex = instance * 38 + feature
            output[flatIndex] = NSNumber(value: value)
        }

        set(0, 0, 176)
        set(0, 1, 64)
        set(0, 2, 464)
        set(0, 3, 320)
        set(0, 4, 0.93)
        set(0, 5, 0)

        set(1, 0, 220)
        set(1, 1, 120)
        set(1, 2, 340)
        set(1, 3, 190)
        set(1, 4, 0.99)
        set(1, 5, 1)

        set(2, 0, 210)
        set(2, 1, 200)
        set(2, 2, 360)
        set(2, 3, 300)
        set(2, 4, 0.98)
        set(2, 5, 2)

        let panels = CoreMLPanelDetector.decodedPanelsForDiagnostics(
            output,
            imageSize: CGSize(width: 400, height: 800)
        )

        #expect(panels.count == 1)
        #expect(panels[0].source == .coreML)
        #expect(abs(panels[0].confidence - 0.93) < 0.001)
        #expect(panels[0].rect.minX >= 0)
        #expect(panels[0].rect.maxX <= 1)
        #expect(panels[0].rect.minY >= 0)
        #expect(panels[0].rect.maxY <= 1)
    }

    @Test func coreMLDecoderAcceptsTransposedDetectionTensor() throws {
        let output = try MLMultiArray(shape: [1, 38, 1], dataType: .float32)

        func set(_ feature: Int, _ value: Double) {
            output[feature] = NSNumber(value: value)
        }

        set(0, 160)
        set(1, 80)
        set(2, 480)
        set(3, 400)
        set(4, 0.88)
        set(5, 0)

        let panels = CoreMLPanelDetector.decodedPanelsForDiagnostics(
            output,
            imageSize: CGSize(width: 640, height: 640)
        )

        #expect(panels.count == 1)
        #expect(abs(panels[0].rect.width - 0.5) < 0.001)
    }

'''
if 'coreMLDecoderKeepsFramesAndRejectsTextAndBalloons' not in test_text:
    test_text = test_text.replace(anchor, test_block + anchor, 1)
tests.write_text(test_text)

metadata = Path('docs/GUIDED_PANEL_MODEL.md')
metadata.write_text('''# Guided Panel Core ML model\n\nThe bundled `mreader/PanelDetector.mlpackage` is an FP16 Core ML export of `ShadowB/Manga109-panel-balloon-text-yolov26-segmentation` (`best.pt`).\n\n- Upstream model: https://huggingface.co/ShadowB/Manga109-panel-balloon-text-yolov26-segmentation\n- Upstream checkpoint SHA-256: `0b4376e426fa96af3976afa6a2602421dacf2dec96ef87b4a44f5e8d4971cb6f`\n- Architecture: YOLO26s instance segmentation\n- Classes: `frame`, `text`, `balloon`\n- App export: Core ML ML Program, static 640x640 input, batch 1, FP16, NMS-free/end-to-end output\n- Runtime use: Guided Panel consumes only class `0` (`frame`). `text` and `balloon` detections are intentionally excluded.\n- Upstream model repository declares MIT. Dataset and Ultralytics terms remain independently applicable; review them before redistribution/commercial release.\n\nThe original PyTorch checkpoint is not bundled in the app. Xcode compiles the `.mlpackage` into `PanelDetector.mlmodelc` for the application bundle.\n''')
