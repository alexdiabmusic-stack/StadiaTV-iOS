import Foundation

/// Single shared transport for every PGA TOUR GraphQL, REST, and config
/// request. Owning one actor for all three means one throttle and one
/// request-coalescing table governs the whole provider, so Overview,
/// Leaderboard, and Following tabs that all need `LeaderboardCompressedV3`
/// in the same moment share a single in-flight network call instead of each
/// firing their own.
///
/// Reference clients (pgatouR/pgatourPY) voluntarily throttle at 10 req/s;
/// this app deliberately uses much less headroom below that ceiling since a
/// mobile client polling in the background has no reason to approach it.
actor PGATourClient {
    static let shared = PGATourClient()

    private let session: URLSession
    private let minimumInterval: TimeInterval
    /// Keyed by host, since a 429 on data-api.pgatour.com shouldn't also gate
    /// requests to orchestrator-config.pgatour.com.
    private var notBefore: [String: Date] = [:]
    private var lastDispatch: Date = .distantPast
    private var inflight: [String: Task<PGAValue, Error>] = [:]

    init(session: URLSession? = nil, minimumInterval: TimeInterval = 0.4) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 30
        self.session = session ?? URLSession(configuration: configuration)
        self.minimumInterval = minimumInterval
    }

    // MARK: - GraphQL

    /// Runs a centrally-stored GraphQL query document and returns its `data`
    /// object (already unwrapped past the `{data, errors}` envelope).
    func graphQL(operation: String, document: String, variables: PGAValue) async throws -> PGAValue {
        let key = "gql:\(operation):\(Self.canonicalKey(variables))"
        if let existing = inflight[key] { return try await existing.value }
        let task = Task<PGAValue, Error> { [session] in
            let configuration = await PGATourProviderConfigurationStore.shared.current()
            var request = URLRequest(url: configuration.graphqlHost)
            request.httpMethod = "POST"
            PGATourRequestHeaders.apply(to: &request, configuration: configuration)
            request.httpBody = try JSONEncoder().encode(
                PGAGraphQLRequestBody(query: document, variables: variables, operationName: operation)
            )
            let envelope = try await self.send(request, session: session)
            if case .array(let errors) = envelope["errors"], !errors.isEmpty {
                let message = errors.compactMap { $0["message"].string }.joined(separator: "; ")
                throw PGATourError.graphQLError(message.isEmpty ? "unknown GraphQL error (\(operation))" : message)
            }
            return envelope["data"]
        }
        inflight[key] = task
        defer { inflight[key] = nil }
        return try await task.value
    }

    // MARK: - REST

    func rest(path: String) async throws -> PGAValue {
        let key = "rest:\(path)"
        if let existing = inflight[key] { return try await existing.value }
        let task = Task<PGAValue, Error> { [session] in
            let configuration = await PGATourProviderConfigurationStore.shared.current()
            let url = configuration.restHost.appendingPathComponent(path)
            var request = URLRequest(url: url)
            PGATourRequestHeaders.apply(to: &request, configuration: configuration, accept: "application/json")
            return try await self.send(request, session: session)
        }
        inflight[key] = task
        defer { inflight[key] = nil }
        return try await task.value
    }

    // MARK: - Config (orchestrator-config.pgatour.com)

    func config(path: String) async throws -> PGAValue {
        let key = "cfg:\(path)"
        if let existing = inflight[key] { return try await existing.value }
        let task = Task<PGAValue, Error> { [session] in
            let configuration = await PGATourProviderConfigurationStore.shared.current()
            let url = configuration.configHost.appendingPathComponent(path)
            var request = URLRequest(url: url)
            PGATourRequestHeaders.apply(to: &request, configuration: configuration, accept: "application/json")
            return try await self.send(request, session: session)
        }
        inflight[key] = task
        defer { inflight[key] = nil }
        return try await task.value
    }

    // MARK: - Shared send/retry/throttle

    private func waitForThrottleSlot() async {
        let now = Date()
        let earliest = lastDispatch.addingTimeInterval(minimumInterval)
        if earliest > now {
            try? await Task.sleep(for: .seconds(earliest.timeIntervalSince(now)))
        }
        lastDispatch = Date()
    }

    private func send(_ request: URLRequest, session: URLSession) async throws -> PGAValue {
        let host = request.url?.host ?? ""
        for attempt in 0..<3 {
            try Task.checkCancellation()
            if let gate = notBefore[host], gate > Date() {
                try await Task.sleep(for: .seconds(gate.timeIntervalSinceNow))
            }
            await waitForThrottleSlot()
            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else { throw PGATourError.invalidResponse }

                if http.statusCode == 429 {
                    let seconds = PGARetryPolicy.delay(http.value(forHTTPHeaderField: "Retry-After"))
                    notBefore[host] = Date().addingTimeInterval(max(1, seconds))
                    if attempt < 2 { continue }
                    throw PGATourError.rateLimited(until: notBefore[host] ?? Date())
                }
                if PGATourError.isTransient(httpStatus: http.statusCode) && attempt < 2 {
                    try await Task.sleep(for: .seconds(pow(2, Double(attempt))))
                    continue
                }
                if http.statusCode == 401 || http.statusCode == 403 {
                    throw PGATourError.authenticationFailed
                }
                guard (200...299).contains(http.statusCode) else {
                    throw PGATourError.http(http.statusCode)
                }
                try Task.checkCancellation()
                do {
                    return try JSONDecoder().decode(PGAValue.self, from: data)
                } catch {
                    throw PGATourError.decoding("\(error)")
                }
            } catch let error as URLError {
                if error.code == .cancelled || Task.isCancelled { throw CancellationError() }
                guard attempt < 2 else { throw error }
                try await Task.sleep(for: .seconds(pow(2, Double(attempt))))
            }
        }
        throw PGATourError.invalidResponse
    }

    private static func canonicalKey(_ value: PGAValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(value)).flatMap { String(data: $0, encoding: .utf8) } ?? UUID().uuidString
    }
}

private struct PGAGraphQLRequestBody: Encodable, Sendable {
    let query: String
    let variables: PGAValue
    let operationName: String
}

private nonisolated enum PGARetryPolicy {
    static func delay(_ header: String?, now: Date = Date()) -> Double {
        if let seconds = header.flatMap(Double.init), seconds.isFinite { return max(1, seconds) }
        if let header {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
            if let date = formatter.date(from: header) { return max(1, date.timeIntervalSince(now)) }
        }
        return 30
    }
}
