import Testing
import Foundation
import zlib
@testable import BannerTV

/// Compresses `Data` into a real gzip stream (header + deflate + CRC),
/// mirroring `PGAPayloadDecoder`'s expected wire format, so tests exercise
/// the exact same container format production code decodes rather than a
/// stand-in.
private func gzipCompress(_ data: Data) -> Data {
    var stream = z_stream()
    deflateInit2_(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, MAX_WBITS + 16, 8, Z_DEFAULT_STRATEGY, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
    defer { deflateEnd(&stream) }
    var output = Data()
    data.withUnsafeBytes { (input: UnsafeRawBufferPointer) in
        stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: Bytef.self).baseAddress)
        stream.avail_in = uInt(data.count)
        var chunk = [UInt8](repeating: 0, count: 4096)
        repeat {
            let count = chunk.count
            let status = chunk.withUnsafeMutableBytes { buffer -> Int32 in
                stream.next_out = buffer.bindMemory(to: Bytef.self).baseAddress
                stream.avail_out = uInt(count)
                return deflate(&stream, Z_FINISH)
            }
            output.append(contentsOf: chunk.prefix(count - Int(stream.avail_out)))
            if status == Z_STREAM_END { break }
        } while true
    }
    return output
}

private func gzipBase64(_ json: String) -> String {
    gzipCompress(json.data(using: .utf8)!).base64EncodedString()
}

@Suite("PGAPayloadDecoder")
struct PGAPayloadDecoderTests {
    @Test func decodesValidCompressedPayload() throws {
        let payload = gzipBase64("""
        {"players":[{"id":"1","player":{"id":"1","displayName":"Test Golfer"}}]}
        """)
        let decoded = try PGAPayloadDecoder.decode(payload)
        #expect(decoded["players"][0]["player"]["displayName"].string == "Test Golfer")
    }

    @Test func throwsOnInvalidBase64() {
        #expect(throws: (any Error).self) {
            _ = try PGAPayloadDecoder.decode("not-valid-base64!!! ###")
        }
    }

    @Test func throwsOnInvalidGzip() {
        // Valid base64, but the decoded bytes are not a gzip stream at all.
        let garbage = Data([0x00, 0x01, 0x02, 0x03, 0x04]).base64EncodedString()
        #expect(throws: (any Error).self) {
            _ = try PGAPayloadDecoder.decode(garbage)
        }
    }

    @Test func throwsOnMalformedJSONAfterDecompression() {
        let payload = gzipCompress("this is not json".data(using: .utf8)!).base64EncodedString()
        #expect(throws: (any Error).self) {
            _ = try PGAPayloadDecoder.decode(payload)
        }
    }

    @Test func throwsOnEmptyPayload() {
        #expect(throws: (any Error).self) {
            _ = try PGAPayloadDecoder.decode("")
        }
    }

    @Test func rejectsOversizedPayload() {
        let big = String(repeating: "a", count: 200)
        let payload = gzipBase64("{\"value\":\"\(big)\"}")
        #expect(throws: (any Error).self) {
            _ = try PGAPayloadDecoder.decode(payload, limit: 8)
        }
    }
}

@Suite("GolfScore")
struct GolfScoreTests {
    @Test func parsesUnderPar() {
        #expect(GolfScore(raw: "-12").display == "-12")
        #expect(GolfScore(raw: "-12").sortValue == -12)
    }

    @Test func parsesEven() {
        #expect(GolfScore(raw: "E").display == "E")
        #expect(GolfScore(raw: "0").display == "E")
    }

    @Test func parsesOverPar() {
        #expect(GolfScore(raw: "+3").display == "+3")
        #expect(GolfScore(raw: "+3").sortValue == 3)
    }

    @Test func blankAndDashAreUnknownNotZero() {
        #expect(GolfScore(raw: nil).display == "")
        #expect(GolfScore(raw: "-").display == "-")
        #expect(GolfScore(raw: "-").sortValue == Int.max)
    }
}

@Suite("GolfPlayerState")
struct GolfPlayerStateTests {
    @Test func cutWithdrawnDisqualifiedComeFromPositionField() {
        #expect(GolfPlayerState(playerStateRaw: nil, positionDisplay: "CUT") == .cut)
        #expect(GolfPlayerState(playerStateRaw: nil, positionDisplay: "WD") == .withdrawn)
        #expect(GolfPlayerState(playerStateRaw: nil, positionDisplay: "DQ") == .disqualified)
        #expect(GolfPlayerState(playerStateRaw: nil, positionDisplay: "MDF") == .missedCut)
    }

    @Test func activeAndCompleteComeFromPlayerStateField() {
        #expect(GolfPlayerState(playerStateRaw: "ACTIVE", positionDisplay: "T5") == .active)
        #expect(GolfPlayerState(playerStateRaw: "COMPLETE", positionDisplay: "1") == .finished)
    }

    @Test func nonScoringStatesAreNotScoring() {
        #expect(GolfPlayerState.cut.isScoring == false)
        #expect(GolfPlayerState.withdrawn.isScoring == false)
        #expect(GolfPlayerState.active.isScoring == true)
    }
}

@Suite("GolfHoleScoreSymbol")
struct GolfHoleScoreSymbolTests {
    @Test func classifiesRelativeToPar() {
        #expect(GolfHoleScoreSymbol(strokes: 3, par: 5) == .eagleOrBetter)
        #expect(GolfHoleScoreSymbol(strokes: 3, par: 4) == .birdie)
        #expect(GolfHoleScoreSymbol(strokes: 4, par: 4) == .par)
        #expect(GolfHoleScoreSymbol(strokes: 5, par: 4) == .bogey)
        #expect(GolfHoleScoreSymbol(strokes: 7, par: 4) == .doubleBogeyOrWorse)
        #expect(GolfHoleScoreSymbol(strokes: nil, par: 4) == .unknown)
    }
}

@Suite("PGALeaderboardMapper")
struct PGALeaderboardMapperTests {
    @Test func mapsLeaderboardRowFields() {
        let raw: PGAValue = .object([
            "players": .array([
                .object([
                    "player": .object([
                        "id": .string("39971"),
                        "firstName": .string("Sungjae"),
                        "lastName": .string("Im"),
                        "displayName": .string("Sungjae Im"),
                        "country": .string("KOR")
                    ]),
                    "scoringData": .object([
                        "position": .string("1"),
                        "total": .string("-7"),
                        "totalSort": .number(-7),
                        "thru": .string("F*"),
                        "score": .string("-7"),
                        "currentRound": .number(1),
                        "rounds": .array([.string("64"), .string("-"), .string("-"), .string("-")]),
                        "playerState": .string("COMPLETE")
                    ])
                ])
            ])
        ])
        let entries = PGALeaderboardMapper.leaderboard(raw, tournamentID: "R2026475")
        #expect(entries.count == 1)
        let entry = try! #require(entries.first)
        #expect(entry.player.displayName == "Sungjae Im")
        #expect(entry.total.display == "-7")
        #expect(entry.playerState == .finished)
        #expect(entry.roundScores.first?.strokes == 64)
    }

    @Test func cutAndWithdrawnDoNotBreakSorting() {
        let raw: PGAValue = .object([
            "players": .array([
                .object(["player": .object(["id": .string("1")]), "scoringData": .object(["position": .string("CUT"), "total": .string("+5")])]),
                .object(["player": .object(["id": .string("2")]), "scoringData": .object(["position": .string("WD")])])
            ])
        ])
        let entries = PGALeaderboardMapper.leaderboard(raw, tournamentID: "R2026475")
        #expect(entries[0].playerState == .cut)
        #expect(entries[1].playerState == .withdrawn)
        #expect(entries[0].playerState.isScoring == false)
        #expect(entries[1].playerState.isScoring == false)
    }
}

@Suite("PGAShotMapper")
struct PGAShotMapperTests {
    @Test func mapsCoordinatesFromOverviewNesting() {
        let raw: PGAValue = .object([
            "holes": .array([
                .object([
                    "holeNumber": .number(14),
                    "par": .number(4),
                    "strokes": .array([
                        .object([
                            "strokeNumber": .number(1),
                            "distance": .number(312),
                            "fromLocation": .string("Tee"),
                            "toLocation": .string("Fairway"),
                            "finalStroke": .bool(false),
                            "overview": .object([
                                "leftToRightCoords": .object([
                                    "fromCoords": .object(["x": .number(0.1), "y": .number(0.2), "tourcastX": .number(100), "tourcastY": .number(200), "tourcastZ": .number(5)]),
                                    "toCoords": .object(["x": .number(0.4), "y": .number(0.5)])
                                ])
                            ])
                        ])
                    ])
                ])
            ])
        ])
        let round = PGAShotMapper.shotRound(raw, tournamentID: "R2026475", playerID: "39971", round: 1)
        let shot = try! #require(round.holes.first?.shots.first)
        #expect(shot.fromLie == .tee)
        #expect(shot.toLie == .fairway)
        #expect(shot.coordinates?.leftToRight?.from?.x == 0.1)
        #expect(shot.coordinates?.leftToRight?.to?.x == 0.4)
    }

    @Test func missingCoordinatesDegradeGracefully() {
        let raw: PGAValue = .object([
            "holes": .array([
                .object(["holeNumber": .number(1), "strokes": .array([.object(["strokeNumber": .number(1)])])])
            ])
        ])
        let round = PGAShotMapper.shotRound(raw, tournamentID: "t", playerID: "p", round: 1)
        let shot = try! #require(round.holes.first?.shots.first)
        #expect(shot.coordinates == nil)
    }
}

@Suite("Leaderboard merge / stale-response protection")
struct LeaderboardMergeTests {
    private func entry(id: String, total: String) -> GolfLeaderboardEntry {
        GolfLeaderboardEntry(
            tournamentID: "t", player: GolfPlayerReference(id: id, displayName: "Player \(id)"),
            positionDisplay: nil, positionSort: nil, totalDisplay: total, totalSort: nil, totalStrokes: nil,
            currentRoundScoreDisplay: nil, thruDisplay: nil, holesCompleted: nil, currentRound: nil, teeTime: nil,
            playerStateRaw: "ACTIVE", courseID: nil, groupNumber: nil, startingNine: nil, roundScores: [], movement: nil,
            official: nil, projected: nil
        )
    }

    @Test func emptyRefreshKeepsCachedLeaderboardVisible() {
        let existing = [entry(id: "1", total: "-5")]
        let merged = PGATournamentCentreService.merge(existing: existing, incoming: [])
        #expect(merged == existing)
    }

    @Test func newResponseUpdatesKnownPlayersAndKeepsUnseenOnes() {
        let existing = [entry(id: "1", total: "-5"), entry(id: "2", total: "-2")]
        let incoming = [entry(id: "1", total: "-6")]
        let merged = PGATournamentCentreService.merge(existing: existing, incoming: incoming)
        #expect(merged.first { $0.id == "1" }?.totalDisplay == "-6")
        #expect(merged.contains { $0.id == "2" })
    }
}

@Suite("GolfTournamentStatus")
struct GolfTournamentStatusTests {
    @Test func recognizesSuspendedAndComplete() {
        #expect(GolfTournamentStatus(tournamentStatusRaw: nil, roundStatusRaw: "Suspended").isLive)
        #expect(GolfTournamentStatus(tournamentStatusRaw: "Official", roundStatusRaw: nil) == .tournamentComplete)
        #expect(GolfTournamentStatus(tournamentStatusRaw: nil, roundStatusRaw: "IN_PROGRESS").isLive)
    }
}
