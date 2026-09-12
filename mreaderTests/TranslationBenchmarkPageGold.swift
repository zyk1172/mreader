import Foundation

/// Human-authored page-level ground truth. It deliberately lives outside the
/// runtime translation pipeline so model output can never become its own gold.
struct TranslationBenchmarkPageGold: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let sampleID: String
    let expectedPageState: TranslationBenchmarkPageState
    let regions: [TranslationBenchmarkRegion]
    let referenceTranslations: [String: String]
    let notes: String?

    var isInternallyConsistent: Bool {
        if expectedPageState == .noText {
            return regions.isEmpty && referenceTranslations.isEmpty
        }
        let regionIDs = Set(regions.map(\.id))
        return !regions.isEmpty && Set(referenceTranslations.keys).isSubset(of: regionIDs)
    }
}
