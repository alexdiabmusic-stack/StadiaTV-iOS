import XCTest
#if canImport(PlaybackPolicy)
@testable import PlaybackPolicy
#else
@testable import Nuvio
#endif

final class PlaybackBackendPolicyTests: XCTestCase {
    private func traits(_ url: String = "https://cdn.example.com/movie.mkv", audio: String? = nil, subs: [String] = [], live: Bool = false, mpvOnly: Bool = false) -> PlaybackRequestTraits {
        .make(url: url, audioURL: audio, subtitleURLs: subs, isLive: live, needsMpvOnlyFeature: mpvOnly)
    }

    // MARK: selection

    func testLibmpvChoiceAlwaysUsesMpv() {
        let d = PlaybackBackendPolicy.decide(choice: .mpv, traits: traits(), aetherAvailable: true)
        XCTAssertEqual(d, .init(backend: .mpv, reason: .userChoseMpv))
    }

    func testAutomaticPrefersAetherForOrdinaryStreams() {
        for url in ["https://a.example/x.mp4", "https://a.example/x.mkv", "https://a.example/x.m3u8", "https://a.example/x.webm", "file:///var/x.mkv", "https://a.example/stream?token=abc"] {
            let d = PlaybackBackendPolicy.decide(choice: .automatic, traits: traits(url), aetherAvailable: true)
            XCTAssertEqual(d.backend, .aether, url)
        }
    }

    func testSelectionDoesNotDependOnTheFileExtension() {
        // An odd or missing extension must not push a normal HTTPS stream to mpv.
        for url in ["https://a.example/video", "https://a.example/play.php?id=7", "https://a.example/x.unknownext"] {
            XCTAssertEqual(PlaybackBackendPolicy.decide(choice: .automatic, traits: traits(url), aetherAvailable: true).backend, .aether, url)
        }
    }

    func testAetherUnavailableFallsToMpvWhateverTheChoice() {
        for choice in PlaybackEngineChoice.allCases where choice != .mpv {
            let d = PlaybackBackendPolicy.decide(choice: choice, traits: traits(), aetherAvailable: false)
            XCTAssertEqual(d, .init(backend: .mpv, reason: .aetherUnavailable))
        }
    }

    func testSeparateAudioGoesToMpvEvenWhenAetherIsChosen() {
        for choice in [PlaybackEngineChoice.automatic, .aether] {
            let d = PlaybackBackendPolicy.decide(choice: choice, traits: traits(audio: "https://a.example/audio.m4a"), aetherAvailable: true)
            XCTAssertEqual(d, .init(backend: .mpv, reason: .separateAudio))
        }
    }

    func testEmptySeparateAudioIsIgnored() {
        XCTAssertEqual(PlaybackBackendPolicy.decide(choice: .automatic, traits: traits(audio: ""), aetherAvailable: true).backend, .aether)
    }

    func testBitmapSubtitlesGoToMpv() {
        for ext in ["sup", "sub", "idx"] {
            let d = PlaybackBackendPolicy.decide(choice: .automatic, traits: traits(subs: ["https://s.example/x.\(ext)"]), aetherAvailable: true)
            XCTAssertEqual(d, .init(backend: .mpv, reason: .bitmapSubtitles), ext)
        }
    }

    func testStyledSubtitlesStayOnMpvUnderAutomaticOnly() {
        let t = traits(subs: ["https://s.example/x.ass"])
        XCTAssertEqual(PlaybackBackendPolicy.decide(choice: .automatic, traits: t, aetherAvailable: true), .init(backend: .mpv, reason: .styledSubtitles))
        XCTAssertEqual(PlaybackBackendPolicy.decide(choice: .aether, traits: t, aetherAvailable: true).backend, .aether)
    }

    func testTextSubtitlesDoNotBlockAether() {
        let t = traits(subs: ["https://s.example/en.srt", "https://s.example/fr.vtt"])
        XCTAssertEqual(PlaybackBackendPolicy.decide(choice: .automatic, traits: t, aetherAvailable: true).backend, .aether)
    }

    func testEmbeddedPreviewsKeepTheExistingPlayer() {
        var t = traits()
        t.isEmbeddedPreview = true
        for choice in [PlaybackEngineChoice.automatic, .aether] {
            XCTAssertEqual(PlaybackBackendPolicy.decide(choice: choice, traits: t, aetherAvailable: true), .init(backend: .mpv, reason: .embeddedPreview))
        }
    }

    func testEmergencyFallbackSettingDefaultsOff() {
        let defaults = UserDefaults(suiteName: "PlaybackEngineEmergency-\(UUID().uuidString)")!
        XCTAssertFalse(PlaybackEngineChoice.emergencyFallbackEnabled(in: defaults))
        defaults.set(true, forKey: PlaybackEngineChoice.emergencyFallbackKey)
        XCTAssertTrue(PlaybackEngineChoice.emergencyFallbackEnabled(in: defaults))
    }

    func testMpvOnlyFeatureGoesToMpv() {
        let d = PlaybackBackendPolicy.decide(choice: .automatic, traits: traits(mpvOnly: true), aetherAvailable: true)
        XCTAssertEqual(d, .init(backend: .mpv, reason: .mpvOnlyFeature))
    }

    func testUnsupportedSchemesGoToMpv() {
        for url in ["rtmp://a.example/live", "rtsp://a.example/x", "udp://239.0.0.1:1234", "magnet:?xt=urn:btih:abc"] {
            let d = PlaybackBackendPolicy.decide(choice: .automatic, traits: traits(url), aetherAvailable: true)
            XCTAssertEqual(d.backend, .mpv, url)
        }
    }

    func testPreviousAetherFailureSendsAutomaticToMpvButNotAnExplicitChoice() {
        XCTAssertEqual(PlaybackBackendPolicy.decide(choice: .automatic, traits: traits(), aetherAvailable: true, aetherFailedBefore: true),
                       .init(backend: .mpv, reason: .previousAetherFailure))
        XCTAssertEqual(PlaybackBackendPolicy.decide(choice: .aether, traits: traits(), aetherAvailable: true, aetherFailedBefore: true).backend, .aether)
    }

    func testSubtitleFormatHints() {
        XCTAssertEqual(PlaybackRequestTraits.subtitleFormat(forURL: "https://s/x.SRT?lang=en"), .text)
        XCTAssertEqual(PlaybackRequestTraits.subtitleFormat(forURL: "https://s/x.ssa"), .styled)
        XCTAssertEqual(PlaybackRequestTraits.subtitleFormat(forURL: "https://s/x.sup"), .bitmap)
        XCTAssertEqual(PlaybackRequestTraits.subtitleFormat(forURL: "https://s/x"), .unknown)
    }

    func testStoredChoiceDefaultsToAutomaticAndIgnoresGarbage() {
        let defaults = UserDefaults(suiteName: "PlaybackEngineChoiceTests-\(UUID().uuidString)")!
        XCTAssertEqual(PlaybackEngineChoice.stored(in: defaults), .automatic)
        defaults.set("aether", forKey: PlaybackEngineChoice.defaultsKey)
        XCTAssertEqual(PlaybackEngineChoice.stored(in: defaults), .aether)
        defaults.set("nonsense", forKey: PlaybackEngineChoice.defaultsKey)
        XCTAssertEqual(PlaybackEngineChoice.stored(in: defaults), .automatic)
    }

    // MARK: failure classification

    func testCancellationIsNeverAFailure() {
        XCTAssertEqual(AetherFailureClassifier.classify(kind: "sourceOpenFailed", isCancellation: true), .ignore)
        XCTAssertEqual(AetherFailureClassifier.classify(kind: nil, isCancellation: true), .ignore)
    }

    func testEngineFormatFailuresFallBack() {
        for kind in ["sourceOpenFailed", "hlsFormatUnsupported", "hlsIngestFailed", "nativeItemFailed", "softwarePipelineFailed", "audioBridgeProducedNoOutput", "dolbyVisionRequiresHardware", "noPlayableTrackWithinBudget"] {
            XCTAssertEqual(AetherFailureClassifier.classify(kind: kind), .fallBackToMpv, kind)
        }
    }

    func testSourceAccountAndDeviceProblemsAreReportedNotHandedOff() {
        for kind in ["sourceRateLimited", "sourceRefused", "sourceCertificateRejected", "storageExhausted", "vodSourceFailed", "liveSourceUnavailable", "audioSessionFailed"] {
            XCTAssertEqual(AetherFailureClassifier.classify(kind: kind), .report, kind)
        }
    }

    func testUnknownAndMissingKindsFallBackOnce() {
        XCTAssertEqual(AetherFailureClassifier.classify(kind: "someFutureKind"), .fallBackToMpv)
        XCTAssertEqual(AetherFailureClassifier.classify(kind: nil), .fallBackToMpv)
    }

    func testClassifierListsDoNotOverlap() {
        XCTAssertTrue(AetherFailureClassifier.reportKinds.isDisjoint(with: AetherFailureClassifier.fallbackKinds))
    }

    // MARK: fallback decisions

    private func attempt(_ ledger: PlaybackSessionLedger = PlaybackSessionLedger(), backend: PlaybackBackendKind = .aether) -> (PlaybackAttempt, PlaybackSessionLedger) {
        let token = ledger.begin()
        return (PlaybackAttempt(token: token, backend: backend), ledger)
    }

    func testAutomaticFallsBackOnceOnEngineFailure() {
        var (a, ledger) = attempt()
        let first = PlaybackFallbackPolicy.decide(choice: .automatic, failedBackend: .aether, action: .fallBackToMpv, attempt: a, sessionIsCurrent: ledger.isCurrent(a.token))
        XCTAssertEqual(first.outcome, .fallBack)
        a.markFellBack()
        XCTAssertEqual(a.backend, .mpv)
        let second = PlaybackFallbackPolicy.decide(choice: .automatic, failedBackend: .aether, action: .fallBackToMpv, attempt: a, sessionIsCurrent: true)
        XCTAssertEqual(second.outcome, .fail(.alreadyFellBack), "never loops")
    }

    func testExplicitAetherChoiceReportsInsteadOfSwitching() {
        let (a, ledger) = attempt()
        let d = PlaybackFallbackPolicy.decide(choice: .aether, failedBackend: .aether, action: .fallBackToMpv, attempt: a, sessionIsCurrent: ledger.isCurrent(a.token))
        XCTAssertEqual(d.outcome, .fail(.choiceForbidsFallback))
        let emergency = PlaybackFallbackPolicy.decide(choice: .aether, failedBackend: .aether, action: .fallBackToMpv, attempt: a, sessionIsCurrent: true, emergencyFallbackEnabled: true)
        XCTAssertEqual(emergency.outcome, .fallBack)
    }

    func testSourceProblemsAreNotHandedOff() {
        let (a, _) = attempt()
        let d = PlaybackFallbackPolicy.decide(choice: .automatic, failedBackend: .aether, action: .report, attempt: a, sessionIsCurrent: true)
        XCTAssertEqual(d.outcome, .fail(.sourceProblem))
    }

    func testMpvFailuresNeverFallBack() {
        let (a, _) = attempt(backend: .mpv)
        let d = PlaybackFallbackPolicy.decide(choice: .automatic, failedBackend: .mpv, action: .fallBackToMpv, attempt: a, sessionIsCurrent: true)
        XCTAssertEqual(d.outcome, .fail(.wrongBackend))
    }

    func testCancellationNeverFallsBack() {
        let (a, _) = attempt()
        let d = PlaybackFallbackPolicy.decide(choice: .automatic, failedBackend: .aether, action: .ignore, attempt: a, sessionIsCurrent: true)
        XCTAssertEqual(d.outcome, .fail(.notAFailure))
    }

    // MARK: sessions and races

    func testANewSessionMakesEveryOlderTokenStale() {
        let ledger = PlaybackSessionLedger()
        let first = ledger.begin()
        let second = ledger.begin() // rapid episode change
        XCTAssertFalse(ledger.isCurrent(first))
        XCTAssertTrue(ledger.isCurrent(second))
        let (a, _) = (PlaybackAttempt(token: first, backend: .aether), ledger)
        // A late failure from the first attempt must not start a fallback.
        let d = PlaybackFallbackPolicy.decide(choice: .automatic, failedBackend: .aether, action: .fallBackToMpv, attempt: a, sessionIsCurrent: ledger.isCurrent(a.token))
        XCTAssertEqual(d.outcome, .fail(.staleSession))
    }

    func testClosingThePlayerInvalidatesTheSession() {
        let ledger = PlaybackSessionLedger()
        let token = ledger.begin()
        ledger.invalidate() // the user left the screen while loading
        XCTAssertFalse(ledger.isCurrent(token))
        let a = PlaybackAttempt(token: token, backend: .aether)
        XCTAssertEqual(PlaybackFallbackPolicy.decide(choice: .automatic, failedBackend: .aether, action: .fallBackToMpv, attempt: a, sessionIsCurrent: ledger.isCurrent(token)).outcome, .fail(.staleSession))
    }

    func testAFailureReportedTwoWaysIsCountedOnce() {
        var a = PlaybackAttempt(token: PlaybackSessionToken(generation: 1), backend: .aether)
        XCTAssertTrue(a.recordFailure(id: "load-1"))   // thrown from load()
        XCTAssertFalse(a.recordFailure(id: "load-1"))  // and again through the published state
    }

    func testFailureCountResetsForTheReplacementBackend() {
        var a = PlaybackAttempt(token: PlaybackSessionToken(generation: 1), backend: .aether)
        _ = a.recordFailure(id: "x")
        a.markFellBack()
        XCTAssertTrue(a.recordFailure(id: "x"))
    }

    // MARK: handoff

    func testHandoffCarriesPositionAndIntent() {
        let h = PlaybackHandoff.make(lastPositionSeconds: 1234.5, durationSeconds: 7200, wantsPlaying: false, sourceIsSeekable: true)
        XCTAssertEqual(h, PlaybackHandoff(resumeSeconds: 1234.5, wantsPlaying: false))
    }

    func testHandoffDistrustsBadPositions() {
        for position in [nil, Double.nan, -3, 0.2, Double.infinity] as [Double?] {
            let h = PlaybackHandoff.make(lastPositionSeconds: position, durationSeconds: 7200, wantsPlaying: true, sourceIsSeekable: true)
            XCTAssertNil(h.resumeSeconds, "\(String(describing: position))")
            XCTAssertTrue(h.wantsPlaying)
        }
    }

    func testHandoffRestartsAnUnseekableSourceAndAnAlreadyFinishedOne() {
        XCTAssertNil(PlaybackHandoff.make(lastPositionSeconds: 500, durationSeconds: 7200, wantsPlaying: true, sourceIsSeekable: false).resumeSeconds)
        XCTAssertNil(PlaybackHandoff.make(lastPositionSeconds: 7199.5, durationSeconds: 7200, wantsPlaying: true, sourceIsSeekable: true).resumeSeconds)
    }

    // MARK: failure memory

    func testFailureMemoryIgnoresQueryAndCredentials() {
        let memory = AetherFailureMemory()
        memory.remember(URL(string: "https://user:pw@cdn.example.com/movie.mkv?token=old"))
        XCTAssertTrue(memory.hasFailed(URL(string: "https://cdn.example.com/movie.mkv?token=new")))
        XCTAssertFalse(memory.hasFailed(URL(string: "https://cdn.example.com/other.mkv")))
        XCTAssertFalse(memory.hasFailed(nil))
    }
}
