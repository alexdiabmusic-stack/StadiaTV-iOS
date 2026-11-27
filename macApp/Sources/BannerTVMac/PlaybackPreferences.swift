import Foundation

/// Playback choices that apply to every stream.
enum PlaybackPreferences {
    static let languages: [(name: String, code: String)] = [
        ("Automatic", ""), ("English", "eng,en"), ("Spanish", "spa,es"), ("French", "fre,fra,fr"), ("German", "ger,deu,de"),
        ("Italian", "ita,it"), ("Portuguese", "por,pt"), ("Arabic", "ara,ar"), ("Hindi", "hin,hi"), ("Japanese", "jpn,ja"),
        ("Korean", "kor,ko"), ("Chinese", "chi,zho,zh"),
    ]

    static var current: (audio: String?, subtitle: String?, subtitleScale: Double) {
        let d = UserDefaults.standard
        let audio = d.string(forKey: "mac_pref_audio") ?? ""
        let sub = d.string(forKey: "mac_pref_subtitle") ?? ""
        let scale = d.object(forKey: "mac_pref_sub_scale") as? Double ?? 1.0
        return (audio.isEmpty ? nil : audio, sub.isEmpty ? nil : sub, scale)
    }
}
