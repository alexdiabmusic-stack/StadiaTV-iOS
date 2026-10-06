import Foundation

/// Abstraction over how Sports Drive narration is voiced, so TTS (AVSpeechSynthesizer, or
/// a FoundationModels-generated script read aloud) can be added later without touching
/// `SportsDriveScriptBuilder` or `SportsDrivePlayer`. Today's default implementation is
/// silent-but-functional: it just waits a beat so the player's pacing is sensible even
/// before real narration exists.
protocol SportsDriveNarrator: Sendable {
    func speak(_ text: String) async
}

struct SilentSportsDriveNarrator: SportsDriveNarrator {
    func speak(_ text: String) async {
        try? await Task.sleep(for: .seconds(min(4, max(1.5, Double(text.count) / 18)))) // rough reading-pace stand-in
    }
}
