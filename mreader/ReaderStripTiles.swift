import QuartzCore
import SwiftUI
import UIKit

/// The decoded source remains bounded by Reader's existing tier policy. Only
/// compositor tiles are allocated for a long strip, avoiding one giant texture.
struct ReaderStripTiles: UIViewRepresentable {
    let image: CGImage
    func makeUIView(context: Context) -> ReaderStripTileView { ReaderStripTileView() }
    func updateUIView(_ view: ReaderStripTileView, context: Context) { view.setImage(image) }
}

final class ReaderStripTileView: UIView {
    override class var layerClass: AnyClass { ReaderStripTileLayer.self }
    private var image: CGImage?
    func setImage(_ image: CGImage) {
        guard self.image !== image else { return }
        self.image = image
        updateSnapshot()
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        updateSnapshot()
    }
    private func updateSnapshot() {
        guard let layer = layer as? ReaderStripTileLayer, let image else { return }
        layer.update(image: image, size: bounds.size)
    }
}

/// CATiledLayer calls draw on background threads. Read one immutable snapshot
/// under a lock; never read UIKit view state or mutate layer contents there.
nonisolated final class ReaderStripTileLayer: CATiledLayer, @unchecked Sendable {
    private let snapshotLock = NSLock()
    private var snapshot: (image: CGImage, size: CGSize)?
    override init() {
        super.init()
        tileSize = CGSize(width: 512, height: 512)
        levelsOfDetail = 1
        levelsOfDetailBias = 2
    }
    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { super.init(coder: coder) }
    override class func fadeDuration() -> CFTimeInterval { 0 }

    func update(image: CGImage, size: CGSize) {
        let changed = snapshotLock.withLock {
            if let previous = snapshot, previous.image === image, previous.size == size { return false }
            snapshot = (image, size)
            return true
        }
        if changed { setNeedsDisplay() }
    }
    override func draw(in context: CGContext) {
        guard let state = snapshotLock.withLock({ snapshot }), state.size.width > 0, state.size.height > 0 else { return }
        let region = context.boundingBoxOfClipPath.intersection(CGRect(origin: .zero, size: state.size))
        guard !region.isNull, region.width > 0, region.height > 0 else { return }
        let sx = CGFloat(state.image.width) / state.size.width
        let sy = CGFloat(state.image.height) / state.size.height
        let pixels = CGRect(x: region.minX * sx, y: region.minY * sy, width: region.width * sx, height: region.height * sy)
            .integral.intersection(CGRect(x: 0, y: 0, width: state.image.width, height: state.image.height))
        guard let tile = state.image.cropping(to: pixels) else { return }
        let target = CGRect(x: pixels.minX / sx, y: pixels.minY / sy, width: pixels.width / sx, height: pixels.height / sy)
        context.saveGState()
        context.translateBy(x: target.minX, y: target.maxY)
        context.scaleBy(x: 1, y: -1)
        context.interpolationQuality = .medium
        context.draw(tile, in: CGRect(origin: .zero, size: target.size))
        context.restoreGState()
    }
}
