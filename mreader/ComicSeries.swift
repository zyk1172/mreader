import Foundation

struct ComicSeries: Identifiable, Codable, Hashable {
    var id: UUID
    var title: String
    var createdAt: Date
    var libraryPath: String?

    init(id: UUID = UUID(), title: String, createdAt: Date = Date(), libraryPath: String? = nil) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.libraryPath = libraryPath
    }
}
