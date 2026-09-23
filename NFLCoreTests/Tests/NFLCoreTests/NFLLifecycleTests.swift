import Foundation
import Testing
@testable import NFLCore

private actor NFLDelayedService: NFLGameCenterServing {
    private var requests: [String: CheckedContinuation<NFLGameState, Error>] = [:]
    func load(gameID: String, date: Date, previous: NFLGameState?, details: Bool) async throws -> NFLGameState {
        try await withCheckedThrowingContinuation { requests[gameID] = $0 }
    }
    func contains(_ id: String) -> Bool { requests[id] != nil }
    func resolve(_ game: NFLGameState) { requests.removeValue(forKey: game.id)?.resume(returning: game) }
}
@Suite struct NFLLifecycleTests {
    private func game(_ id: String) throws -> NFLGameState {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/regular-final.json")
        let response = try JSONDecoder().decode(NFLWeeklyResponse.self, from: Data(contentsOf: url))
        var raw = try #require(response.games.first).object
        raw["id"] = .string(id)
        for key in ["summary", "driveChart"] {
            var nested = raw[key]?.object ?? [:]; nested["gameId"] = .string(id); raw[key] = .object(nested)
        }
        return try #require(NFLGameMapper.game(.object(raw)))
    }
    private func waitFor(_ id: String, service: NFLDelayedService) async throws {
        for _ in 0..<100 {
            if await service.contains(id) { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("Request did not start")
    }
    @MainActor @Test func switchingGamesRejectsLateResponse() async throws {
        let service = NFLDelayedService(), a = try game(UUID().uuidString), b = try game(UUID().uuidString)
        let model = NFLGameCenterViewModel(service: service)
        let first = Task { await model.run(id: a.id, date: a.start, active: true) }
        try await waitFor(a.id, service: service)
        let second = Task { await model.run(id: b.id, date: b.start, active: true) }
        try await waitFor(b.id, service: service)
        await service.resolve(b); await second.value
        await service.resolve(a); await first.value
        #expect(model.game?.id == b.id)
    }
    @MainActor @Test func backgroundRejectsInFlightResponseAndForegroundReloads() async throws {
        let service = NFLDelayedService(), game = try game(UUID().uuidString)
        let model = NFLGameCenterViewModel(service: service)
        let first = Task { await model.run(id: game.id, date: game.start, active: true) }
        try await waitFor(game.id, service: service)
        await model.run(id: game.id, date: game.start, active: false)
        await service.resolve(game); await first.value
        #expect(model.game == nil)
        let foreground = Task { await model.run(id: game.id, date: game.start, active: true) }
        try await waitFor(game.id, service: service)
        await service.resolve(game); await foreground.value
        #expect(model.game?.id == game.id)
    }
}
