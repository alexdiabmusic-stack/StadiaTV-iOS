import Foundation
import AVFoundation
import os

extension Notification.Name {
    /// Posted when a video stream starts, so audio-only players (podcasts) pause
    /// instead of playing over it.
    static let bannerVideoPlaybackWillStart = Notification.Name("bannertv.videoPlaybackWillStart")
}

/// Owns the app's AVAudioSession configuration for video.
///
/// The session calls can block for tens of milliseconds, so they run off the main thread.
nonisolated enum AudioSessionManager {
    /// Sets the video category once at launch so the first playback doesn't pay for it.
    static func configureAtLaunch() {
        #if os(iOS) || os(tvOS)
        Task.detached(priority: .utility) {
            applyVideoCategory()
        }
        #endif
    }

    /// Activates the session for video playback. The category is re-applied because the
    /// podcast player switches it to `.spokenAudio` while an episode plays.
    static func activateForVideo() {
        #if os(iOS) || os(tvOS)
        Task.detached(priority: .userInitiated) {
            applyVideoCategory()
            do {
                try AVAudioSession.sharedInstance().setActive(true)
            } catch {
                PlaybackMetrics.logger.error("Audio session activation failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        #endif
    }

    /// Activates the session for audio-only live sports (CarPlay driving mode, or any
    /// surface playing a confirmed broadcast with no video surface attached). Uses
    /// `.spokenAudio`, matching the podcast player's category, since this is routed
    /// through CarPlay/the car's audio system rather than a video presentation.
    static func activateForAudioOnly() {
        #if os(iOS) || os(tvOS)
        Task.detached(priority: .userInitiated) {
            applyAudioOnlyCategory()
            do {
                try AVAudioSession.sharedInstance().setActive(true)
            } catch {
                PlaybackMetrics.logger.error("Audio session activation failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        #endif
    }

    #if os(iOS) || os(tvOS)
    private static func applyVideoCategory() {
        let session = AVAudioSession.sharedInstance()
        guard session.category != .playback || session.mode != .moviePlayback || !session.categoryOptions.isEmpty else { return }
        do {
            // No .mixWithOthers: the video owns the session, so lock-screen, Control Center
            // and AirPods controls target it and other apps' audio is interrupted.
            try session.setCategory(.playback, mode: .moviePlayback, options: [])
        } catch {
            PlaybackMetrics.logger.error("Audio session category failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func applyAudioOnlyCategory() {
        let session = AVAudioSession.sharedInstance()
        guard session.category != .playback || session.mode != .spokenAudio || !session.categoryOptions.isEmpty else { return }
        do {
            try session.setCategory(.playback, mode: .spokenAudio, options: [])
        } catch {
            PlaybackMetrics.logger.error("Audio-only session category failed: \(error.localizedDescription, privacy: .public)")
        }
    }
    #endif
}
