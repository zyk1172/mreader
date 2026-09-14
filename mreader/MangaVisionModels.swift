import CoreGraphics
import Foundation

nonisolated enum MangaRegionType: String, Codable, CaseIterable, Sendable, Hashable {
    case panel
    case text
    case balloon
    case face
    case body
}

/// Stable identity for a page analysis. `scope` is normally the comic UUID;
/// URL-derived scopes are used only by legacy callers that do not have book identity.
nonisolated struct MangaPageIdentifier: Codable, Sendable, Hashable {
    let scope: String
    let pageIndex: Int
    let sourceFingerprint: String
}

/// Business-level region. Coordinates are always top-left-origin normalized page
/// coordinates in 0...1. No model-input, Vision-bottom-left, or crop-local coordinates
/// are allowed above the provider/geometry layer.
nonisolated struct MangaVisionRegion: Identifiable, Codable, Sendable, Hashable {
    let id: UUID
    let type: MangaRegionType
    let normalizedRect: CGRect
    let confidence: Float

    init(
        id: UUID = UUID(),
        type: MangaRegionType,
        normalizedRect: CGRect,
        confidence: Float
    ) {
        self.id = id
        self.type = type
        self.normalizedRect = MangaPageCoordinateSpace.clampedNormalizedRect(normalizedRect)
        self.confidence = confidence
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id
            && lhs.type == rhs.type
            && lhs.normalizedRect == rhs.normalizedRect
            && lhs.confidence == rhs.confidence
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(type)
        hasher.combine(Double(normalizedRect.minX))
        hasher.combine(Double(normalizedRect.minY))
        hasher.combine(Double(normalizedRect.width))
        hasher.combine(Double(normalizedRect.height))
        hasher.combine(confidence)
    }

    private enum CodingKeys: String, CodingKey {
        case id, type, x, y, width, height, confidence
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        type = try container.decode(MangaRegionType.self, forKey: .type)
        confidence = try container.decode(Float.self, forKey: .confidence)
        normalizedRect = MangaPageCoordinateSpace.clampedNormalizedRect(CGRect(
            x: try container.decode(Double.self, forKey: .x),
            y: try container.decode(Double.self, forKey: .y),
            width: try container.decode(Double.self, forKey: .width),
            height: try container.decode(Double.self, forKey: .height)
        ))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(type, forKey: .type)
        try container.encode(Double(normalizedRect.minX), forKey: .x)
        try container.encode(Double(normalizedRect.minY), forKey: .y)
        try container.encode(Double(normalizedRect.width), forKey: .width)
        try container.encode(Double(normalizedRect.height), forKey: .height)
        try container.encode(confidence, forKey: .confidence)
    }
}

/// The single page-vision contract consumed by reader/OCR/translation business code.
nonisolated struct MangaPageAnalysis: Codable, Sendable, Equatable {
    /// v2 adds first-class balloon regions. Old cache entries deliberately fail the
    /// service's schema-version check so pages are re-analysed with balloon geometry.
    static let schemaVersion = 2

    let schemaVersion: Int
    let pageIdentifier: MangaPageIdentifier
    let imageSize: CGSize
    let panels: [MangaVisionRegion]
    let texts: [MangaVisionRegion]
    let balloons: [MangaVisionRegion]
    let faces: [MangaVisionRegion]
    let bodies: [MangaVisionRegion]
    let modelIdentifier: String?
    let modelVersion: Int

    init(
        pageIdentifier: MangaPageIdentifier,
        imageSize: CGSize,
        panels: [MangaVisionRegion],
        texts: [MangaVisionRegion],
        balloons: [MangaVisionRegion] = [],
        faces: [MangaVisionRegion],
        bodies: [MangaVisionRegion],
        modelIdentifier: String?,
        modelVersion: Int,
        schemaVersion: Int = MangaPageAnalysis.schemaVersion
    ) {
        self.schemaVersion = schemaVersion
        self.pageIdentifier = pageIdentifier
        self.imageSize = imageSize
        self.panels = panels
        self.texts = texts
        self.balloons = balloons
        self.faces = faces
        self.bodies = bodies
        self.modelIdentifier = modelIdentifier
        self.modelVersion = modelVersion
    }

    var allRegions: [MangaVisionRegion] {
        panels + texts + balloons + faces + bodies
    }

    func regions(of type: MangaRegionType) -> [MangaVisionRegion] {
        switch type {
        case .panel: panels
        case .text: texts
        case .balloon: balloons
        case .face: faces
        case .body: bodies
        }
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, pageIdentifier, imageWidth, imageHeight
        case panels, texts, balloons, faces, bodies, modelIdentifier, modelVersion
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        pageIdentifier = try container.decode(MangaPageIdentifier.self, forKey: .pageIdentifier)
        imageSize = CGSize(
            width: try container.decode(Double.self, forKey: .imageWidth),
            height: try container.decode(Double.self, forKey: .imageHeight)
        )
        panels = try container.decode([MangaVisionRegion].self, forKey: .panels)
        texts = try container.decode([MangaVisionRegion].self, forKey: .texts)
        // decodeIfPresent keeps hand-authored fixtures/source compatibility, while
        // MangaVisionService still rejects persisted v1 cache entries by schemaVersion.
        balloons = try container.decodeIfPresent([MangaVisionRegion].self, forKey: .balloons) ?? []
        faces = try container.decode([MangaVisionRegion].self, forKey: .faces)
        bodies = try container.decode([MangaVisionRegion].self, forKey: .bodies)
        modelIdentifier = try container.decodeIfPresent(String.self, forKey: .modelIdentifier)
        modelVersion = try container.decode(Int.self, forKey: .modelVersion)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(pageIdentifier, forKey: .pageIdentifier)
        try container.encode(Double(imageSize.width), forKey: .imageWidth)
        try container.encode(Double(imageSize.height), forKey: .imageHeight)
        try container.encode(panels, forKey: .panels)
        try container.encode(texts, forKey: .texts)
        try container.encode(balloons, forKey: .balloons)
        try container.encode(faces, forKey: .faces)
        try container.encode(bodies, forKey: .bodies)
        try container.encodeIfPresent(modelIdentifier, forKey: .modelIdentifier)
        try container.encode(modelVersion, forKey: .modelVersion)
    }
}

nonisolated struct MangaPersonCandidate: Identifiable, Sendable, Hashable {
    let id: UUID
    let panelID: UUID?
    let face: MangaVisionRegion?
    let body: MangaVisionRegion?
    let confidence: Float

    init(
        id: UUID = UUID(),
        panelID: UUID?,
        face: MangaVisionRegion?,
        body: MangaVisionRegion?,
        confidence: Float
    ) {
        self.id = id
        self.panelID = panelID
        self.face = face
        self.body = body
        self.confidence = confidence
    }
}

nonisolated struct MangaSpeakerCandidate: Sendable, Hashable {
    let person: MangaPersonCandidate
    /// Heuristic hint in 0...1. It is never a definitive speaker assignment.
    let score: Float
}

nonisolated struct MangaSemanticText: Sendable, Hashable {
    let region: MangaVisionRegion
    let speakerCandidates: [MangaSpeakerCandidate]
}

nonisolated struct MangaPanelAnalysis: Sendable, Hashable {
    let panel: MangaVisionRegion
    let texts: [MangaSemanticText]
    let persons: [MangaPersonCandidate]
}

nonisolated struct MangaSemanticPage: Sendable {
    let pageAnalysis: MangaPageAnalysis
    let panels: [MangaPanelAnalysis]
    let unassignedTexts: [MangaSemanticText]
    let unassignedPersons: [MangaPersonCandidate]
}
