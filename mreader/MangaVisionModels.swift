import CoreGraphics
import Foundation

nonisolated enum MangaRegionType: String, Codable, CaseIterable, Sendable, Hashable {
    case panel
    case text
    case balloon
    case onomatopoeia
    case face
    case body
}

nonisolated struct MangaVisionPoint: Codable, Sendable, Hashable {
    let x: Double
    let y: Double

    init(_ point: CGPoint) {
        x = min(max(Double(point.x), 0), 1)
        y = min(max(Double(point.y), 0), 1)
    }

    var cgPoint: CGPoint {
        CGPoint(x: x, y: y)
    }
}

/// Compact normalized contour distilled from an instance-segmentation mask.
/// The provider caps the point count so persisted Manga Vision cache entries stay small.
nonisolated struct MangaVisionContour: Codable, Sendable, Hashable {
    static let maximumPointCount = 32

    let points: [MangaVisionPoint]

    init(points: [CGPoint]) {
        guard !points.isEmpty else {
            self.points = []
            return
        }
        let normalized = points.map(MangaVisionPoint.init)
        if normalized.count <= Self.maximumPointCount {
            self.points = normalized
            return
        }
        let stride = Double(normalized.count) / Double(Self.maximumPointCount)
        self.points = (0..<Self.maximumPointCount).map { index in
            normalized[min(Int((Double(index) * stride).rounded(.down)), normalized.count - 1)]
        }
    }

    var cgPoints: [CGPoint] {
        points.map(\.cgPoint)
    }

    var bounds: CGRect {
        guard let first = cgPoints.first else { return .zero }
        var minX = first.x
        var maxX = first.x
        var minY = first.y
        var maxY = first.y
        for point in cgPoints.dropFirst() {
            minX = min(minX, point.x)
            maxX = max(maxX, point.x)
            minY = min(minY, point.y)
            maxY = max(maxY, point.y)
        }
        return MangaPageCoordinateSpace.clampedNormalizedRect(
            CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        )
    }
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
    /// Primary mask-derived contour retained for compatibility with existing OCR/UI consumers.
    /// Bounding-box-only providers leave this nil.
    let contour: MangaVisionContour?
    /// Additional connected-component contours for instance masks. The adapter must not
    /// silently union or discard them; legacy consumers may continue to use `contour`.
    let secondaryContours: [MangaVisionContour]

    var contours: [MangaVisionContour] {
        if let contour { return [contour] + secondaryContours }
        return secondaryContours
    }

    init(
        id: UUID = UUID(),
        type: MangaRegionType,
        normalizedRect: CGRect,
        confidence: Float,
        contour: MangaVisionContour? = nil,
        secondaryContours: [MangaVisionContour] = []
    ) {
        self.id = id
        self.type = type
        self.normalizedRect = MangaPageCoordinateSpace.clampedNormalizedRect(normalizedRect)
        self.confidence = confidence
        self.contour = contour
        self.secondaryContours = secondaryContours
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id
            && lhs.type == rhs.type
            && lhs.normalizedRect == rhs.normalizedRect
            && lhs.confidence == rhs.confidence
            && lhs.contour == rhs.contour
            && lhs.secondaryContours == rhs.secondaryContours
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(type)
        hasher.combine(Double(normalizedRect.minX))
        hasher.combine(Double(normalizedRect.minY))
        hasher.combine(Double(normalizedRect.width))
        hasher.combine(Double(normalizedRect.height))
        hasher.combine(confidence)
        hasher.combine(contour)
        hasher.combine(secondaryContours)
    }

    private enum CodingKeys: String, CodingKey {
        case id, type, x, y, width, height, confidence, contour, secondaryContours
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
        contour = try container.decodeIfPresent(MangaVisionContour.self, forKey: .contour)
        secondaryContours = try container.decodeIfPresent(
            [MangaVisionContour].self,
            forKey: .secondaryContours
        ) ?? []
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
        try container.encodeIfPresent(contour, forKey: .contour)
        if !secondaryContours.isEmpty {
            try container.encode(secondaryContours, forKey: .secondaryContours)
        }
    }
}

/// The single page-vision contract consumed by reader/OCR/translation business code.
nonisolated struct MangaPageAnalysis: Codable, Sendable, Equatable {
    /// MangaLayout4 adds only backward-compatible optional fields. Keep the production
    /// analysis schema stable so the still-default V2B5 route does not invalidate its
    /// cache merely because the development adapter exists.
    static let schemaVersion = 4

    let schemaVersion: Int
    let pageIdentifier: MangaPageIdentifier
    let imageSize: CGSize
    let panels: [MangaVisionRegion]
    let texts: [MangaVisionRegion]
    let balloons: [MangaVisionRegion]
    let onomatopoeias: [MangaVisionRegion]
    let faces: [MangaVisionRegion]
    let bodies: [MangaVisionRegion]
    let modelIdentifier: String?
    let modelVersion: Int
    /// Full model/postprocess and analysis-demand identity used by downstream caches.
    var cacheRevision: String? = nil

    init(
        pageIdentifier: MangaPageIdentifier,
        imageSize: CGSize,
        panels: [MangaVisionRegion],
        texts: [MangaVisionRegion],
        balloons: [MangaVisionRegion] = [],
        onomatopoeias: [MangaVisionRegion] = [],
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
        self.onomatopoeias = onomatopoeias
        self.faces = faces
        self.bodies = bodies
        self.modelIdentifier = modelIdentifier
        self.modelVersion = modelVersion
    }

    var allRegions: [MangaVisionRegion] {
        panels + texts + balloons + onomatopoeias + faces + bodies
    }

    func regions(of type: MangaRegionType) -> [MangaVisionRegion] {
        switch type {
        case .panel: panels
        case .text: texts
        case .balloon: balloons
        case .onomatopoeia: onomatopoeias
        case .face: faces
        case .body: bodies
        }
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, pageIdentifier, imageWidth, imageHeight
        case panels, texts, balloons, onomatopoeias, faces, bodies, modelIdentifier, modelVersion, cacheRevision
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
        balloons = try container.decodeIfPresent([MangaVisionRegion].self, forKey: .balloons) ?? []
        onomatopoeias = try container.decodeIfPresent(
            [MangaVisionRegion].self,
            forKey: .onomatopoeias
        ) ?? []
        faces = try container.decode([MangaVisionRegion].self, forKey: .faces)
        bodies = try container.decode([MangaVisionRegion].self, forKey: .bodies)
        modelIdentifier = try container.decodeIfPresent(String.self, forKey: .modelIdentifier)
        modelVersion = try container.decode(Int.self, forKey: .modelVersion)
        cacheRevision = try container.decodeIfPresent(String.self, forKey: .cacheRevision)
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
        try container.encode(onomatopoeias, forKey: .onomatopoeias)
        try container.encode(faces, forKey: .faces)
        try container.encode(bodies, forKey: .bodies)
        try container.encodeIfPresent(modelIdentifier, forKey: .modelIdentifier)
        try container.encode(modelVersion, forKey: .modelVersion)
        try container.encodeIfPresent(cacheRevision, forKey: .cacheRevision)
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

