import Foundation

/// Page-level annotation schema used to prepare human gold truth. Candidate
/// annotations may be machine/model-assisted, but they are never reportable
/// until a human reviewer explicitly marks them as `humanVerified`, resolves
/// the expected page state, and records a review receipt for the exact image.
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
    let review: TranslationGoldReviewReceipt?
    let notes: String?

    init(
        schemaVersion: Int,
        sampleID: String,
        verificationStatus: VerificationStatus,
        expectedPageState: TranslationBenchmarkPageState,
        regions: [TranslationBenchmarkRegion],
        referenceTranslations: [String: String],
        review: TranslationGoldReviewReceipt? = nil,
        notes: String?
    ) {
        self.schemaVersion = schemaVersion
        self.sampleID = sampleID
        self.verificationStatus = verificationStatus
        self.expectedPageState = expectedPageState
        self.regions = regions
        self.referenceTranslations = referenceTranslations
        self.review = review
        self.notes = notes
    }

    var isInternallyConsistent: Bool {
        TranslationGoldReviewValidator.structuralIssues(for: self).isEmpty
    }

    var isReportableGold: Bool {
        verificationStatus == .humanVerified
            && TranslationGoldReviewValidator.reportabilityIssues(for: self).isEmpty
    }
}
