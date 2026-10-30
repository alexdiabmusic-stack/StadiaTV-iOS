import Foundation
import AVFoundation
#if canImport(QuartzCore)
import QuartzCore
#endif
#if os(iOS)
import AVKit
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
    #if os(iOS)
    /// The layer's one picture-in-picture controller, kept as long as the layer. AVKit keeps an
    /// unretained pointer on a sample-buffer layer to the controller made for it: a second
    /// controller for the same layer, or one released while the layer lives on, leaves that pointer
    /// dangling, and the next change to the layer's bounds crashes in AVKit.
    private var pictureInPicture: AVPictureInPictureController?
    private var pictureInPicturePlayback: NativePictureInPicturePlayback?
    /// The surface that lets the window open by itself as the app leaves.
    private weak var pictureInPictureSurface: AnyObject?
    #endif

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
            // Every bounds change reaches picture in picture: only real ones are made.
            if layer.frame != hostLayer.bounds { layer.frame = hostLayer.bounds }
            if layer.videoGravity != host.gravity { layer.videoGravity = host.gravity }
        }
    }

    #if os(iOS)
    /// The layer's picture-in-picture controller, made the first time it's asked for; `setPlaying`
    /// takes the window's play and pause buttons.
    func pictureInPictureController(setPlaying: @escaping @MainActor @Sendable (Bool) -> Void) -> AVPictureInPictureController? {
        if let pictureInPicture { return pictureInPicture }
        guard AVPictureInPictureController.isPictureInPictureSupported() else { return nil }
        let playback = NativePictureInPicturePlayback(setPlaying: setPlaying)
        let controller = AVPictureInPictureController(contentSource: .init(sampleBufferDisplayLayer: layer, playbackDelegate: playback))
        controller.canStartPictureInPictureAutomaticallyFromInline = false
        pictureInPicturePlayback = playback
        pictureInPicture = controller
        return controller
    }

    /// Whether the window opens by itself as the app leaves. Surfaces come and go in either order,
    /// so only the surface that turned it on can turn it off.
    func setPictureInPictureStartsAutomatically(_ starts: Bool, for surface: AnyObject) {
        guard let pictureInPicture else { return }
        if starts {
            pictureInPictureSurface = surface
        } else if pictureInPictureSurface !== surface {
            return
        }
        pictureInPicture.canStartPictureInPictureAutomaticallyFromInline = starts
    }

    /// The viewer paused or played: the window's button follows.
    func setPictureInPicturePaused(_ paused: Bool) {
        guard let pictureInPicturePlayback, pictureInPicturePlayback.setPaused(paused) else { return }
        pictureInPicture?.invalidatePlaybackState()
    }
    #endif

    private func withoutAnimation(_ changes: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        changes()
        CATransaction.commit()
    }
}

#if os(iOS)
/// Picture in picture's controls for the native player, which has no AVPlayer for them to drive.
nonisolated final class NativePictureInPicturePlayback: NSObject, AVPictureInPictureSampleBufferPlaybackDelegate, @unchecked Sendable {
    private let setPlaying: @MainActor @Sendable (Bool) -> Void
    private let lock = NSLock()
    private var isPaused = false

    init(setPlaying: @escaping @MainActor @Sendable (Bool) -> Void) {
        self.setPlaying = setPlaying
    }

    /// Returns whether the state changed.
    func setPaused(_ paused: Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let changed = paused != isPaused
        isPaused = paused
        return changed
    }

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, setPlaying playing: Bool) {
        let setPlaying = setPlaying
        Task { @MainActor in setPlaying(playing) }
    }

    func pictureInPictureControllerTimeRangeForPlayback(_ pictureInPictureController: AVPictureInPictureController) -> CMTimeRange {
        // Live: nothing to scrub through.
        CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
    }

    func pictureInPictureControllerIsPlaybackPaused(_ pictureInPictureController: AVPictureInPictureController) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return isPaused
    }

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                    didTransitionToRenderSize newRenderSize: CMVideoDimensions) {}

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                    skipByInterval skipInterval: CMTime, completion completionHandler: @escaping () -> Void) {
        completionHandler()
    }
}
#endif
