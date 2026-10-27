import Foundation
import AVFoundation
#if canImport(QuartzCore)
import QuartzCore
#endif

/// The native player's picture: one display layer shared by every video surface of a controller.
///
/// A layer has one place on screen, so the surface that attached most recently shows it (the
/// guide's preview over the full-screen player, say) and hands it back as it goes. The layer is
/// hidden unless the native player is playing, so it never covers AVPlayer's picture.
@MainActor
final class NativeVideoOutput {
    let layer = AVSampleBufferDisplayLayer()
    private(set) lazy var renderers = NativeRenderers(displayLayer: layer)
    private var hosts: [Host] = []

    private struct Host {
        weak var layer: CALayer?
        var gravity: AVLayerVideoGravity
    }

    init() {
        layer.videoGravity = .resizeAspect
        layer.isHidden = true
        #if os(macOS)
        layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        #endif
    }

    var isActive = false {
        didSet {
            guard isActive != oldValue else { return }
            withoutAnimation { layer.isHidden = !isActive }
        }
    }

    /// Shows the picture in `hostLayer` (a surface's own layer), above whatever it draws.
    func attach(to hostLayer: CALayer, gravity: AVLayerVideoGravity) {
        hosts.removeAll { $0.layer == nil || $0.layer === hostLayer }
        hosts.append(Host(layer: hostLayer, gravity: gravity))
        place()
    }

    /// The surface is going: the picture moves back to the one before it.
    func detach(from hostLayer: CALayer) {
        hosts.removeAll { $0.layer == nil || $0.layer === hostLayer }
        if layer.superlayer === hostLayer { withoutAnimation { layer.removeFromSuperlayer() } }
        place()
    }

    /// The surface was resized or its gravity changed.
    func update(_ hostLayer: CALayer, gravity: AVLayerVideoGravity) {
        guard let index = hosts.firstIndex(where: { $0.layer === hostLayer }) else { return }
        hosts[index].gravity = gravity
        if layer.superlayer === hostLayer { place() }
    }

    private func place() {
        guard let host = hosts.last(where: { $0.layer != nil }), let hostLayer = host.layer else { return }
        withoutAnimation {
            if layer.superlayer !== hostLayer { hostLayer.addSublayer(layer) }
            layer.frame = hostLayer.bounds
            if layer.videoGravity != host.gravity { layer.videoGravity = host.gravity }
        }
    }

    private func withoutAnimation(_ changes: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        changes()
        CATransaction.commit()
    }
}
