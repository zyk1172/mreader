import Foundation

/// Page-level annotation schema used to prepare human gold truth. Candidate
/// annotations may be machine/model-assisted, but they are never reportable
/// until a human reviewer explicitly marks them as `humanVerified`.
struct TranslationBenchmarkPageGold: Codable, Equatable, Sendable {
    enum VerificationStatus: String, Codable, Sendable {
        case candidate
        case humanVerified
    }

    let schemaVersion: Int
    let sampleID: String
    let verificationStatus: VerificationStatus
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

    var isReportableGold: Bool {
        verificationStatus == .humanVerified && isInternallyConsistent
    }
}
