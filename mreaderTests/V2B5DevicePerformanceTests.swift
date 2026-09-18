import CoreML
import CoreVideo
import CryptoKit
import Darwin
import Foundation
import UIKit
import XCTest
import os

/// DEBUG/test-only model benchmark. This deliberately does not call any mReader
/// provider or decoder; it measures the frozen V2B5 Core ML artifacts directly.
@MainActor
final class V2B5DevicePerformanceTests: XCTestCase {
    func testFullFP32All() throws {
        try run(.fullFP32, computeUnits: .all)
    }

    func testFullFP32CPUAndNeuralEngine() throws {
        try run(.fullFP32, computeUnits: .cpuAndNeuralEngine)
    }

    func testFullFP32CPUAndGPU() throws {
        try run(.fullFP32, computeUnits: .cpuAndGPU)
    }

    func testFullFP32CPUOnly() throws {
        try run(.fullFP32, computeUnits: .cpuOnly)
    }

    func testMP5All() throws {
        try run(.mp5, computeUnits: .all)
    }

    func testFP16All() throws {
        try run(.fp16, computeUnits: .all)
    }

    private func run(
        _ modelKind: BenchModelKind,
        computeUnits: BenchComputeUnits
    ) throws {
        #if V2B5_DEVICE_BENCHMARK
        let enabledByCompileFlag = true
        #else
        let enabledByCompileFlag = false
        #endif
        let enabledByEnvironment = ProcessInfo.processInfo.environment["MREADER_V2B5_DEVICE_BENCHMARK"] == "1"
        let enabledBySchemeArgument = ProcessInfo.processInfo.arguments.contains("-MREADER_V2B5_DEVICE_BENCHMARK")
        guard enabledByCompileFlag || enabledByEnvironment || enabledBySchemeArgument else {
            throw XCTSkip("Use mreaderDeviceBench with -D V2B5_DEVICE_BENCHMARK for the physical-device benchmark")
        }

        let bundle = Bundle(for: Self.self)
        let runner = BenchRunner(modelKind: modelKind, computeUnits: computeUnits, bundle: bundle)
        do {
            let payload = try runner.execute()
            emit(payload)
        } catch {
            emit([
                "status": "FAILED",
                "model": modelKind.rawValue,
                "compute_units": computeUnits.rawValue,
                "error": String(describing: error),
                "device": DeviceSnapshot.current.json
            ])
            throw error
        }
    }

    private func emit(_ payload: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else {
            XCTFail("Could not serialize V2B5 benchmark result")
            return
        }
        print("V2B5_BENCHMARK_JSON=\(json)")
    }
}

private enum BenchModelKind: String {
    case fullFP32 = "FULL_FP32"
    case mp5 = "MP5_P3_PREFIX_FP32"
    case fp16 = "FP16"

    var resourceName: String {
        switch self {
        case .fullFP32: return "MangaVisionV2B5_FP32"
        case .mp5: return "MangaVisionV2B5_P3PrefixFP32"
        case .fp16: return "MangaVisionV2B5_FP16"
        }
    }

    var sourceTreeSHA256: String? {
        switch self {
        case .fullFP32:
            return "ebde3f514e2fb84e48f73bd194041da671337f7b770e3baeae637ed8c5dba4c5"
        case .mp5:
            return "66d748301674aac1b9510a8d6c5695ccbe537b380f9aa9dda53a8ff2107f9426"
        case .fp16:
            return "4f8722d22e4ad049b990b56a02c075c806ebd2e366277f04aef796ed60dba638"
        }
    }

    var sourceSizeBytes: Int? {
        switch self {
        case .fullFP32: return 5_908_245
        case .mp5: return 4_098_956
        case .fp16: return 3_165_210
        }
    }

    var isV2B5: Bool { true }
}

private enum BenchComputeUnits: String {
    case all
    case cpuAndNeuralEngine
    case cpuAndGPU
    case cpuOnly

    var coreMLValue: MLComputeUnits {
        switch self {
        case .all: return .all
        case .cpuAndNeuralEngine: return .cpuAndNeuralEngine
        case .cpuAndGPU: return .cpuAndGPU
        case .cpuOnly: return .cpuOnly
        }
    }
}

private struct BenchRunner {
    private static let warmupCount = 10
    private static let measuredCount = 100
    private static let inputSeed = UInt64(109)
    private static let signpostLog = OSLog(
        subsystem: "zhengyk.mreader",
        category: "V2B5DevicePerformance"
    )

    let modelKind: BenchModelKind
    let computeUnits: BenchComputeUnits
    let bundle: Bundle

    func execute() throws -> [String: Any] {
        let deviceBefore = DeviceSnapshot.current
        guard !deviceBefore.isThermallyBlocked else {
            throw BenchError.thermalTooHigh(deviceBefore.thermal)
        }

        guard let modelURL = modelURL() else {
            throw BenchError.modelResourceMissing(modelKind.resourceName)
        }

        let memoryBeforeLoad = physicalFootprint()
        let loadStart = ContinuousClock.now
        let loadSignpost = OSSignpostID(log: Self.signpostLog)
        os_signpost(.begin, log: Self.signpostLog, name: "model_load", signpostID: loadSignpost)
        let configuration = MLModelConfiguration()
        configuration.computeUnits = computeUnits.coreMLValue
        let model: MLModel
        do {
            model = try MLModel(contentsOf: modelURL, configuration: configuration)
        } catch {
            os_signpost(.end, log: Self.signpostLog, name: "model_load", signpostID: loadSignpost)
            throw BenchError.modelLoadFailed(String(describing: error))
        }
        os_signpost(.end, log: Self.signpostLog, name: "model_load", signpostID: loadSignpost)

        let loadMilliseconds = milliseconds(loadStart.duration(to: .now))
        let memoryAfterLoad = physicalFootprint()
        let input = try makeInput(model: model)
        let provider = try makeProvider(input: input)

        var maximumFootprint = max(memoryBeforeLoad, memoryAfterLoad)
        var lastOutput: MLFeatureProvider?
        for _ in 0..<Self.warmupCount {
            lastOutput = try predict(model: model, provider: provider)
            maximumFootprint = max(maximumFootprint, physicalFootprint())
        }
        let memoryAfterWarmup = physicalFootprint()
        maximumFootprint = max(maximumFootprint, memoryAfterWarmup)

        let outputContract = try validateOutputContract(
            model: model,
            output: lastOutput,
            isV2B5: modelKind.isV2B5
        )

        var durations: [Double] = []
        durations.reserveCapacity(Self.measuredCount)
        for _ in 0..<Self.measuredCount {
            let start = ContinuousClock.now
            lastOutput = try predict(model: model, provider: provider)
            durations.append(milliseconds(start.duration(to: .now)))
            maximumFootprint = max(maximumFootprint, physicalFootprint())
        }
        let memoryAfterBenchmark = physicalFootprint()
        maximumFootprint = max(maximumFootprint, memoryAfterBenchmark)
        let deviceAfter = DeviceSnapshot.current

        return [
            "status": "PASS",
            "device": deviceAfter.json,
            "model": modelKind.rawValue,
            "resource": modelKind.resourceName + ".mlmodelc",
            "artifact_tree_sha256": modelKind.sourceTreeSHA256 ?? directoryTreeSHA256(modelURL) ?? "",
            "artifact_size_bytes": modelKind.sourceSizeBytes ?? directorySizeBytes(modelURL),
            "configured_compute_units": computeUnits.rawValue,
            "input": input.json,
            "warmup": Self.warmupCount,
            "iterations": Self.measuredCount,
            "load_ms": loadMilliseconds,
            "latency_ms": statistics(durations),
            "sustained": [
                "first_20_median_ms": quantile(Array(durations.prefix(20)), 0.50),
                "last_20_median_ms": quantile(Array(durations.suffix(20)), 0.50),
                "drift_percent": driftPercent(durations)
            ],
            "memory_mb": [
                "before_load": megabytes(memoryBeforeLoad),
                "after_load": megabytes(memoryAfterLoad),
                "after_warmup": megabytes(memoryAfterWarmup),
                "after_benchmark": megabytes(memoryAfterBenchmark),
                "sampled_max": megabytes(maximumFootprint),
                "load_delta": megabytesDelta(memoryBeforeLoad, memoryAfterLoad),
                "warmup_delta": megabytesDelta(memoryAfterLoad, memoryAfterWarmup),
                "benchmark_end_delta": megabytesDelta(memoryAfterWarmup, memoryAfterBenchmark)
            ],
            "thermal": [
                "before": deviceBefore.thermal,
                "after": deviceAfter.thermal
            ],
            "prediction_failures": 0,
            "output_contract": outputContract
        ]
    }

    private func modelURL() -> URL? {
        let bundles = [bundle, Bundle.main] + Bundle.allBundles + Bundle.allFrameworks
        for candidate in bundles {
            if let url = candidate.url(
                forResource: modelKind.resourceName,
                withExtension: "mlmodelc"
            ) {
                return url
            }
        }
        return nil
    }

    private func makeInput(model: MLModel) throws -> InputValue {
        guard let input = model.modelDescription.inputDescriptionsByName.sorted(by: { $0.key < $1.key }).first else {
            throw BenchError.inputMissing
        }
        switch input.value.type {
        case .multiArray:
            guard let constraint = input.value.multiArrayConstraint else {
                throw BenchError.inputUnsupported("multiArray constraint missing")
            }
            let array = try MLMultiArray(shape: constraint.shape, dataType: .float32)
            fillDeterministic(array)
            return .multiArray(name: input.key, value: array)
        case .image:
            let buffer = try makeDeterministicPixelBuffer(
                width: input.value.imageConstraint?.pixelsWide ?? 640,
                height: input.value.imageConstraint?.pixelsHigh ?? 640
            )
            return .image(name: input.key, value: buffer)
        default:
            throw BenchError.inputUnsupported(String(input.value.type.rawValue))
        }
    }

    private func makeProvider(input: InputValue) throws -> MLFeatureProvider {
        switch input {
        case let .multiArray(name, value):
            return try MLDictionaryFeatureProvider(dictionary: [
                name: MLFeatureValue(multiArray: value)
            ])
        case let .image(name, value):
            return try MLDictionaryFeatureProvider(dictionary: [
                name: MLFeatureValue(pixelBuffer: value)
            ])
        }
    }

    private func predict(model: MLModel, provider: MLFeatureProvider) throws -> MLFeatureProvider {
        let signpostID = OSSignpostID(log: Self.signpostLog)
        os_signpost(.begin, log: Self.signpostLog, name: "prediction", signpostID: signpostID)
        do {
            let output = try model.prediction(from: provider)
            os_signpost(.end, log: Self.signpostLog, name: "prediction", signpostID: signpostID)
            return output
        } catch {
            os_signpost(.end, log: Self.signpostLog, name: "prediction", signpostID: signpostID)
            throw BenchError.predictionFailed(String(describing: error))
        }
    }

    private func validateOutputContract(
        model: MLModel,
        output: MLFeatureProvider?,
        isV2B5: Bool
    ) throws -> [[String: Any]] {
        guard let output else { throw BenchError.outputMissing }
        let descriptions = model.modelDescription.outputDescriptionsByName
        guard !descriptions.isEmpty else { throw BenchError.outputMissing }
        let rows = descriptions.keys.sorted().map { name -> [String: Any] in
            let description = descriptions[name]!
            let shape = description.multiArrayConstraint?.shape.map(\.intValue) ?? []
            var row: [String: Any] = [
                "name": name,
                "type": description.type.rawValue,
                "shape": shape
            ]
            if let value = output.featureValue(for: name)?.multiArrayValue {
                row["runtime_shape"] = value.shape.map(\.intValue)
                row["dtype"] = value.dataType.rawValue
            }
            if isV2B5, let semantic = Self.v2b5Semantics[name] {
                row["semantic"] = semantic.semantic
                row["tensor"] = semantic.tensor
            }
            return row
        }
        if isV2B5 {
            guard descriptions.count == Self.v2b5Semantics.count else {
                throw BenchError.outputContract("expected 12 outputs, got \(descriptions.count)")
            }
            for (name, spec) in Self.v2b5Semantics {
                guard let description = descriptions[name],
                      let shape = description.multiArrayConstraint?.shape.map(\.intValue),
                      shape == spec.shape,
                      let runtime = output.featureValue(for: name)?.multiArrayValue,
                      runtime.shape.map(\.intValue) == spec.shape else {
                    throw BenchError.outputContract("invalid V2B5 output \(name)")
                }
            }
        }
        return rows
    }

    private static let v2b5Semantics: [String: (tensor: String, semantic: String, shape: [Int])] = [
        "conv2d_77": ("p2_cls", "classification_logits", [1, 5, 160, 160]),
        "conv2d_78": ("p2_bbox", "bbox", [1, 4, 160, 160]),
        "conv2d_79": ("p2_centerness", "centerness", [1, 1, 160, 160]),
        "conv2d_88": ("p3_cls", "classification_logits", [1, 5, 80, 80]),
        "conv2d_89": ("p3_bbox", "bbox", [1, 4, 80, 80]),
        "conv2d_90": ("p3_centerness", "centerness", [1, 1, 80, 80]),
        "conv2d_99": ("p4_cls", "classification_logits", [1, 5, 40, 40]),
        "conv2d_100": ("p4_bbox", "bbox", [1, 4, 40, 40]),
        "conv2d_101": ("p4_centerness", "centerness", [1, 1, 40, 40]),
        "conv2d_110": ("p5_cls", "classification_logits", [1, 5, 20, 20]),
        "conv2d_111": ("p5_bbox", "bbox", [1, 4, 20, 20]),
        "conv2d_112": ("p5_centerness", "centerness", [1, 1, 20, 20])
    ]
}

private enum InputValue {
    case multiArray(name: String, value: MLMultiArray)
    case image(name: String, value: CVPixelBuffer)

    var json: [String: Any] {
        switch self {
        case let .multiArray(_, value):
            return [
                "type": "multiArray",
                "shape": value.shape.map(\.intValue),
                "dtype": "float32",
                "seed": 109
            ]
        case let .image(_, value):
            return [
                "type": "image",
                "width": CVPixelBufferGetWidth(value),
                "height": CVPixelBufferGetHeight(value),
                "pixel_format": CVPixelBufferGetPixelFormatType(value)
            ]
        }
    }
}

private struct DeviceSnapshot {
    let machine: String
    let operatingSystem: String
    let processorCount: Int
    let thermal: String
    let lowPowerModeEnabled: Bool

    static var current: DeviceSnapshot {
        DeviceSnapshot(
            machine: hardwareIdentifier(),
            operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
            processorCount: ProcessInfo.processInfo.processorCount,
            thermal: thermalState(ProcessInfo.processInfo.thermalState),
            lowPowerModeEnabled: ProcessInfo.processInfo.isLowPowerModeEnabled
        )
    }

    var isThermallyBlocked: Bool {
        thermal == "serious" || thermal == "critical"
    }

    var json: [String: Any] {
        [
            "model_identifier": machine,
            "os": operatingSystem,
            "processor_count": processorCount,
            "thermal_state": thermal,
            "low_power_mode": lowPowerModeEnabled
        ]
    }
}

private enum BenchError: Error, CustomStringConvertible {
    case thermalTooHigh(String)
    case modelResourceMissing(String)
    case modelLoadFailed(String)
    case inputMissing
    case inputUnsupported(String)
    case predictionFailed(String)
    case outputMissing
    case outputContract(String)

    var description: String {
        switch self {
        case let .thermalTooHigh(state): return "thermal state is too high: \(state)"
        case let .modelResourceMissing(name): return "model resource missing: \(name).mlmodelc"
        case let .modelLoadFailed(error): return "model load failed: \(error)"
        case .inputMissing: return "model input missing"
        case let .inputUnsupported(type): return "unsupported model input: \(type)"
        case let .predictionFailed(error): return "prediction failed: \(error)"
        case .outputMissing: return "model output missing"
        case let .outputContract(error): return "output contract failed: \(error)"
        }
    }
}

private func hardwareIdentifier() -> String {
    var size = 0
    guard sysctlbyname("hw.machine", nil, &size, nil, 0) == 0, size > 0 else {
        return "unknown"
    }
    var value = [CChar](repeating: 0, count: size)
    guard sysctlbyname("hw.machine", &value, &size, nil, 0) == 0 else {
        return "unknown"
    }
    return String(cString: value)
}

private func thermalState(_ state: ProcessInfo.ThermalState) -> String {
    switch state {
    case .nominal: return "nominal"
    case .fair: return "fair"
    case .serious: return "serious"
    case .critical: return "critical"
    @unknown default: return "unknown"
    }
}

private func physicalFootprint() -> UInt64 {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(
        MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size
    )
    let result = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), rebound, &count)
        }
    }
    guard result == KERN_SUCCESS else { return 0 }
    return UInt64(info.phys_footprint)
}

private func fillDeterministic(_ array: MLMultiArray) {
    let count = array.count
    let pointer = array.dataPointer.assumingMemoryBound(to: Float32.self)
    var state = UInt64(109)
    for index in 0..<count {
        state = state &* 6_364_136_223_846_793_005 &+ 1
        let unit = Float((state >> 32) & 0x00ff_ffff) / Float(0x00ff_ffff)
        pointer[index] = unit * 2 - 1
    }
}

private func makeDeterministicPixelBuffer(width: Int, height: Int) throws -> CVPixelBuffer {
    var pixelBuffer: CVPixelBuffer?
    let attributes: [CFString: Any] = [
        kCVPixelBufferCGImageCompatibilityKey: true,
        kCVPixelBufferCGBitmapContextCompatibilityKey: true
    ]
    let status = CVPixelBufferCreate(
        kCFAllocatorDefault,
        width,
        height,
        kCVPixelFormatType_32BGRA,
        attributes as CFDictionary,
        &pixelBuffer
    )
    guard status == kCVReturnSuccess, let pixelBuffer else {
        throw BenchError.inputUnsupported("could not create pixel buffer")
    }
    CVPixelBufferLockBaseAddress(pixelBuffer, [])
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
    guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
        throw BenchError.inputUnsupported("pixel buffer has no base address")
    }
    let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
    let pointer = baseAddress.assumingMemoryBound(to: UInt8.self)
    for y in 0..<height {
        for x in 0..<width {
            let offset = y * bytesPerRow + x * 4
            let value = UInt8((x * 17 + y * 31) & 0xff)
            pointer[offset] = value
            pointer[offset + 1] = value &+ 53
            pointer[offset + 2] = value &+ 107
            pointer[offset + 3] = 255
        }
    }
    return pixelBuffer
}

private func milliseconds(_ duration: Duration) -> Double {
    let components = duration.components
    return Double(components.seconds) * 1_000
        + Double(components.attoseconds) / 1_000_000_000_000_000
}

private func statistics(_ values: [Double]) -> [String: Any] {
    let sorted = values.sorted()
    let mean = values.reduce(0, +) / Double(values.count)
    let variance = values.reduce(0) { partial, value in
        partial + (value - mean) * (value - mean)
    } / Double(values.count)
    return [
        "mean": mean,
        "median": quantile(sorted, 0.50),
        "p50": quantile(sorted, 0.50),
        "p90": quantile(sorted, 0.90),
        "p95": quantile(sorted, 0.95),
        "p99": quantile(sorted, 0.99),
        "min": sorted.first ?? 0,
        "max": sorted.last ?? 0,
        "stddev": variance.squareRoot()
    ]
}

private func quantile(_ values: [Double], _ probability: Double) -> Double {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted()
    let index = min(sorted.count - 1, max(0, Int(ceil(probability * Double(sorted.count))) - 1))
    return sorted[index]
}

private func driftPercent(_ values: [Double]) -> Double {
    guard values.count >= 40 else { return 0 }
    let first = quantile(Array(values.prefix(20)), 0.50)
    let last = quantile(Array(values.suffix(20)), 0.50)
    guard first > 0 else { return 0 }
    return (last - first) / first * 100
}

private func megabytes(_ bytes: UInt64) -> Double {
    Double(bytes) / 1_048_576
}

private func megabytesDelta(_ before: UInt64, _ after: UInt64) -> Double {
    Double(after > before ? after - before : 0) / 1_048_576
}

private func directorySizeBytes(_ root: URL) -> UInt64 {
    guard let enumerator = FileManager.default.enumerator(
        at: root,
        includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
        options: [.skipsHiddenFiles]
    ) else { return 0 }
    return enumerator.reduce(into: UInt64(0)) { total, item in
        guard let url = item as? URL,
              let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true else { return }
        total += UInt64(values.fileSize ?? 0)
    }
}

private func directoryTreeSHA256(_ root: URL) -> String? {
    guard let enumerator = FileManager.default.enumerator(
        at: root,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles]
    ) else { return nil }
    let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
    var files: [(String, URL)] = []
    for case let url as URL in enumerator {
        guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
            continue
        }
        let relative = url.path.hasPrefix(prefix)
            ? String(url.path.dropFirst(prefix.count))
            : url.lastPathComponent
        files.append((relative, url))
    }
    guard !files.isEmpty else { return nil }
    var hasher = SHA256()
    for (relative, url) in files.sorted(by: { $0.0 < $1.0 }) {
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else { return nil }
        hasher.update(data: Data(relative.utf8))
        hasher.update(data: Data([0]))
        hasher.update(data: data)
        hasher.update(data: Data([0xff]))
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}
