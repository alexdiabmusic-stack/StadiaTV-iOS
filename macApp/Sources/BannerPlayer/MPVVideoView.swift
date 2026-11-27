import AppKit
import QuartzCore

/// The surface mpv draws into: an `NSView` whose backing layer is a `CAMetalLayer`.
/// mpv is handed the layer's address (`wid`) and renders through MoltenVK, as on iPhone.
public final class MPVVideoView: NSView {
    public let metalLayer: CAMetalLayer = {
        let layer = CAMetalLayer()
        layer.framebufferOnly = true
        layer.backgroundColor = NSColor.black.cgColor
        layer.wantsExtendedDynamicRangeContent = true
        layer.device = MTLCreateSystemDefaultDevice()
        return layer
    }()

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .duringViewResize
    }

    public required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    public override func makeBackingLayer() -> CALayer { metalLayer }
    public override var isOpaque: Bool { true }
    public override var acceptsFirstResponder: Bool { false }

    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        syncDrawableSize()
    }

    public override func layout() {
        super.layout()
        syncDrawableSize()
    }

    /// Keeps the drawable at the view's size in device pixels. A zero-sized drawable is never requested.
    private func syncDrawableSize() {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        guard size.width > 1, size.height > 1 else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        metalLayer.contentsScale = scale
        if metalLayer.drawableSize != size { metalLayer.drawableSize = size }
        CATransaction.commit()
    }
}
