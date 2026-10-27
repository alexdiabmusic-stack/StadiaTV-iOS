import Foundation
import Testing
@testable import StreamEngineCore

@Suite("Native playback scheduling")
struct NativePlaybackTests {
    private let videoFormat = NativeVideoFormat(codec: .h264, parameterSets: [[0x67, 0x64], [0x68, 0xEB]], width: 1920, height: 1080,
                                                colour: nil, codecString: "avc1.640028")
    private let aac = AudioTrackFormat(codec: .aac, sampleRate: 48_000, channelCount: 2, samplesPerFrame: 1_024,
                                       configuration: [0x11, 0x90], codecString: "mp4a.40.2", bitrate: nil)

    /// `seconds` of 25 fps pictures (a keyframe every `gop`) and 48 kHz AAC from `start` on the output
    /// timeline, which is `programme` in programme time.
    private func segment(_ sequence: Int, start: Double, programme: Double, seconds: Double = 2, gop: Int = 50,
                         firstFrame: Int = 0, languages: [String] = ["eng"], video: Bool = true, audioSeconds: Double? = nil) -> NativeFeed.Item {
        var pictures: [NativeSample] = []
        let base = Int64((start * 90_000).rounded())
        for index in 0..<Int((seconds * 25).rounded()) {
            pictures.append(NativeSample(data: Data([UInt8(index & 0xFF)]), decodeTime: base + Int64(index) * 3_600, duration: 3_600,
                                         compositionOffset: 0, isSync: (firstFrame + index) % gop == 0))
        }
        let audio = languages.enumerated().map { rendition, language in
            let first = Int64((start * 48_000).rounded())
            let frames = Int(((audioSeconds ?? seconds) * 48_000 / 1_024).rounded(.down))
            let samples = (0..<frames).map {
                NativeSample(data: Data([1]), decodeTime: first + Int64($0) * 1_024, duration: 1_024, isSync: true)
            }
            return NativeAudioTrack(rendition: rendition, language: language, formatNumber: 1, format: aac, magicCookie: [0x03], samples: samples)
        }
        let samples = NativeSamples(timelineStart: start,
                                    video: video ? NativeVideoTrack(formatNumber: 1, format: videoFormat, samples: pictures) : nil,
                                    audio: audio)
        return .segment(.init(sequence: sequence, programmeStart: programme, duration: seconds, isDiscontinuity: false,
                              startsWithKeyframe: pictures.first?.isSync ?? true, samples: samples))
    }

    private func drainVideo(_ scheduler: inout NativePlaybackScheduler) -> (entries: [NativePlaybackScheduler.VideoEntry], commands: [NativePlaybackScheduler.Command]) {
        var entries: [NativePlaybackScheduler.VideoEntry] = []
        var commands: [NativePlaybackScheduler.Command] = []
        while let next = scheduler.nextVideo() {
            entries.append(next.entry)
            commands += next.commands
        }
        return (entries, commands)
    }

    @Test("The first keyframe shows at once with the clock still; the clock runs once a second is in hand")
    func start() {
        var scheduler = NativePlaybackScheduler()
        #expect(scheduler.receive([segment(0, start: 10, programme: 0, seconds: 0.8)]).isEmpty)
        let first = drainVideo(&scheduler)
        #expect(first.commands == [.setClock(time: 10, rate: 0)])
        #expect(scheduler.phase == .primed && scheduler.hasShownPicture && !scheduler.isPlaying)
        // 0.8 s isn't enough to start on.
        #expect(scheduler.update(clockTime: 10).isEmpty)
        _ = scheduler.receive([segment(1, start: 10.8, programme: 0.8, seconds: 1.2, firstFrame: 20)])
        #expect(scheduler.update(clockTime: 10) == [.setRate(1)])
        #expect(scheduler.isPlaying)
    }

    @Test("Catching up with what arrived stops the clock, holding the picture; a second's arrival restarts it")
    func stallAndResume() {
        var scheduler = NativePlaybackScheduler()
        _ = scheduler.receive([segment(0, start: 10, programme: 0)])
        _ = drainVideo(&scheduler)
        _ = scheduler.update(clockTime: 10)
        #expect(scheduler.isPlaying)
        #expect(scheduler.update(clockTime: 11.5).isEmpty)
        let end = scheduler.availableEnd ?? 0
        #expect(scheduler.update(clockTime: end - 0.02) == [.setRate(0)])
        #expect(scheduler.isWaiting && scheduler.phase == .stalled)
        _ = scheduler.receive([segment(1, start: 12, programme: 2, seconds: 0.5, firstFrame: 50)])
        #expect(scheduler.update(clockTime: end - 0.02).isEmpty)
        _ = scheduler.receive([segment(2, start: 12.5, programme: 2.5, seconds: 1, firstFrame: 62)])
        #expect(scheduler.update(clockTime: end - 0.02) == [.setRate(1)])
        #expect(!scheduler.isWaiting)
    }

    @Test("A pause holds the clock without counting as waiting; the engine's pace applies while playing")
    func pauseAndPace() {
        var scheduler = NativePlaybackScheduler()
        _ = scheduler.receive([segment(0, start: 10, programme: 0, seconds: 4)])
        _ = drainVideo(&scheduler)
        _ = scheduler.update(clockTime: 10)
        #expect(scheduler.setTargetRate(0.98) == [.setRate(0.98)])
        #expect(scheduler.setPaused(true) == [.setRate(0)])
        #expect(scheduler.setTargetRate(1.01).isEmpty)
        #expect(!scheduler.isWaiting && !scheduler.isPlaying)
        // Paused at the end of what arrived isn't a stall.
        #expect(scheduler.update(clockTime: 13.99).isEmpty)
        #expect(scheduler.setPaused(false) == [.setRate(1.01)])
    }

    @Test("A restart flushes, carries on at its moment from the keyframe before it, and skips audio before it")
    func restart() {
        var scheduler = NativePlaybackScheduler()
        _ = scheduler.receive([segment(0, start: 10, programme: 0)])
        _ = drainVideo(&scheduler)
        _ = scheduler.update(clockTime: 10)
        let commands = scheduler.receive([.restart(programmeTime: 20.6), segment(10, start: 30, programme: 20, seconds: 2, firstFrame: 0)])
        #expect(commands == [.flush])
        #expect(scheduler.phase == .starting)
        let video = drainVideo(&scheduler)
        // Decoding starts at the keyframe; the clock at the restart's moment.
        #expect(video.entries.first?.sample.isSync == true)
        #expect(video.entries.first?.sample.decodeTime == Int64(30 * 90_000))
        #expect(video.commands == [.setClock(time: 30.6, rate: 0)])
        var audio: [NativePlaybackScheduler.AudioEntry] = []
        while let next = scheduler.nextAudio() { audio.append(next) }
        let firstEnd = Double((audio.first?.sample.decodeTime ?? 0) + 1_024) / 48_000
        #expect(firstEnd > 30.6 && firstEnd < 30.6 + 1_024.0 / 48_000 + 0.000_1)
        #expect(scheduler.update(clockTime: 30.6) == [.setRate(1)])
    }

    @Test("A start that lands inside a GOP waits for the next keyframe")
    func startMidGOP() {
        var scheduler = NativePlaybackScheduler()
        _ = scheduler.receive([segment(0, start: 10, programme: 0, seconds: 2, firstFrame: 30)])
        let video = drainVideo(&scheduler)
        // Frames 30-49 are skipped; frame 50 is the keyframe, 0.8 s in.
        #expect(video.entries.first?.sample.isSync == true)
        #expect(video.commands == [.setClock(time: 10.8, rate: 0)])
        #expect(video.entries.count == 30)
    }

    @Test("The audio track played is the preferred language's, else the first")
    func audioTrack() {
        var french = NativePlaybackScheduler(preferredLanguage: "fra")
        _ = french.receive([segment(0, start: 10, programme: 0, languages: ["eng", "fra"])])
        #expect(french.selectedRendition == 1)
        #expect(french.nextAudio()?.formatKey == .init(rendition: 1, formatNumber: 1))
        // The app's preference is a language tag; broadcasters' codes come in either ISO 639-2 form.
        var tagged = NativePlaybackScheduler(preferredLanguage: "fr-FR")
        _ = tagged.receive([segment(0, start: 10, programme: 0, languages: ["eng", "fre"])])
        #expect(tagged.selectedRendition == 1)
        var other = NativePlaybackScheduler(preferredLanguage: "deu")
        _ = other.receive([segment(0, start: 10, programme: 0, languages: ["eng", "fra"])])
        #expect(other.selectedRendition == 0)
        #expect(other.audioFormats[.init(rendition: 0, formatNumber: 1)]?.magicCookie == [0x03])
    }

    @Test("The playhead is reported in programme time, from the segment it's in")
    func programmeTime() {
        var scheduler = NativePlaybackScheduler()
        _ = scheduler.receive([segment(0, start: 10, programme: 0), segment(1, start: 12, programme: 2.5, firstFrame: 50)])
        #expect(scheduler.programmeTime(at: 11) == 1)
        #expect(scheduler.programmeTime(at: 12.5) == 3)
    }

    @Test("Radio: audio alone starts the clock")
    func radio() {
        var scheduler = NativePlaybackScheduler()
        _ = scheduler.receive([segment(0, start: 10, programme: 0, video: false)])
        #expect(scheduler.update(clockTime: 0) == [.setClock(time: 10, rate: 0)])
        #expect(scheduler.update(clockTime: 10) == [.setRate(1)])
        #expect(scheduler.isPlaying && !scheduler.hasVideo)
    }

    @Test("Audio that stops arriving doesn't hold the picture")
    func audioStops() {
        var scheduler = NativePlaybackScheduler()
        _ = scheduler.receive([segment(0, start: 10, programme: 0, seconds: 6, audioSeconds: 1)])
        #expect(abs((scheduler.availableEnd ?? 0) - 16) < 0.001)
        var close = NativePlaybackScheduler()
        _ = close.receive([segment(0, start: 10, programme: 0, seconds: 3, audioSeconds: 2)])
        #expect((close.availableEnd ?? 0) < 12.01)
    }
}
