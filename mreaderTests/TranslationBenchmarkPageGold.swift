import Foundation

/// Page-level annotation schema used to prepare human gold truth. Candidate
/// annotations may be machine/model-assisted, but they are never reportable
/// until a human reviewer explicitly marks them as `humanVerified` and resolves
/// the expected page state.
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
        let regionIDs = Set(regions.map(\.id))
        guard Set(referenceTranslations.keys).isSubset(of: regionIDs) else {
            return false
        }

        switch expectedPageState {
        case .unknown:
            // Candidate state: zero or more machine-assisted regions are valid,
            // but this state can never become reportable benchmark truth.
            return true
        case .noText:
            return regions.isEmpty && referenceTranslations.isEmpty
        case .completed, .partial, .failed:
            return !regions.isEmpty
        }
    }

    var isReportableGold: Bool {
        verificationStatus == .humanVerified
            && expectedPageState != .unknown
            && isInternallyConsistent
    }
}
