import Foundation

nonisolated enum F1StreamEvent: Sendable {
    case connection(F1ConnectionState, Int), snapshot([F1TopicUpdate]), update(F1TopicUpdate), activity(Date), error(String)
}
protocol F1Streaming: Sendable {
    nonisolated func run(deliver: @escaping @Sendable (F1StreamEvent) async -> Void) async
}
actor F1SignalRClient: F1Streaming {
    private let session: URLSession
    private let topics: [String]
    private var socket: URLSessionWebSocketTask?
    private var lastMessage = Date.distantPast
    private var activeRun = UUID()
    init(session: URLSession? = nil, topics: [String] = F1LiveTimingEndpoint.topics) {
        self.topics = topics
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = HTTPCookieStorage.shared
        configuration.httpShouldSetCookies = true
        configuration.timeoutIntervalForRequest = 20
        self.session = session ?? URLSession(configuration: configuration)
    }
    private func request(_ url: URL, method: String = "GET") -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: 20); request.httpMethod = method
        request.setValue("BestHTTP", forHTTPHeaderField: "User-Agent")
        request.setValue("https://www.formula1.com", forHTTPHeaderField: "Origin")
        return request
    }
    func run(deliver: @escaping @Sendable (F1StreamEvent) async -> Void) async {
        let runID = UUID()
        activeRun = runID
        socket?.cancel(with: .goingAway, reason: nil)
        var attempts = 0
        var accessDenied = false
        while !Task.isCancelled {
            do {
                await deliver(.connection(attempts == 0 ? .negotiating : .reconnecting, attempts))
                let optionsURL = try F1LiveTimingEndpoint.url(path: "/signalrcore/negotiate")
                let (_, optionsResponse) = try await session.data(for: request(optionsURL, method: "OPTIONS"))
                guard let http = optionsResponse as? HTTPURLResponse else { throw F1LiveTimingError.invalidResponse }
                // Some deployments reject OPTIONS while still setting affinity cookies.
                guard (200...299).contains(http.statusCode) || http.statusCode == 405 else { throw F1LiveTimingError.http(http.statusCode) }
                let negotiateURL = try F1LiveTimingEndpoint.url(path: "/signalrcore/negotiate", query: ["negotiateVersion": "1"])
                var negotiate = request(negotiateURL, method: "POST"); negotiate.setValue("text/plain", forHTTPHeaderField: "Content-Type")
                let (data, response) = try await session.data(for: negotiate)
                guard let response = response as? HTTPURLResponse else { throw F1LiveTimingError.invalidResponse }
                if response.statusCode == 429 { throw F1LiveTimingError.rateLimited(until: Date().addingTimeInterval(F1RetryPolicy.delay(response.value(forHTTPHeaderField: "Retry-After")))) }
                guard (200...299).contains(response.statusCode) else { throw F1LiveTimingError.http(response.statusCode) }
                let payload = try JSONDecoder().decode(F1Value.self, from: data)
                guard let token = payload["connectionToken"].string else { throw F1LiveTimingError.invalidResponse }
                let url = try F1LiveTimingEndpoint.url(path: "/signalrcore", websocket: true, query: ["id": token])
                guard runID == activeRun, !Task.isCancelled else { return }
                let task = session.webSocketTask(with: request(url)); task.maximumMessageSize = 16 * 1024 * 1024
                socket = task; lastMessage = Date()
                await deliver(.connection(.connecting, attempts)); task.resume()
                let currentAttempt = attempts
                try await withTaskCancellationHandler {
                    try await task.send(.string(F1SignalRProtocol.handshake))
                    try await withThrowingTaskGroup(of: Void.self) { group in
                        group.addTask { try await self.receive(task, runID: runID, attempts: currentAttempt, deliver: deliver) }
                        group.addTask {
                            while !Task.isCancelled {
                                try await Task.sleep(for: .seconds(10))
                                if await self.isStale() { task.cancel(with: .goingAway, reason: nil); throw F1LiveTimingError.staleConnection }
                                try await task.send(.string("{\"type\":6}\u{1e}"))
                            }
                        }
                        defer { group.cancelAll(); task.cancel(with: .goingAway, reason: nil) }
                        _ = try await group.next()
                    }
                } onCancel: { task.cancel(with: .goingAway, reason: nil) }
            } catch {
                guard runID == activeRun else { return }
                socket?.cancel(with: .goingAway, reason: nil); socket = nil
                guard !Task.isCancelled else { break }
                await deliver(.error(error.localizedDescription))
                if case F1LiveTimingError.http(let code) = error, code == 401 || code == 403 {
                    accessDenied = true; break
                }
                attempts += 1
                await deliver(.connection(.reconnecting, attempts))
                let delay: Double
                if case F1LiveTimingError.rateLimited(let until) = error { delay = max(Self.backoff(attempts), until.timeIntervalSinceNow) }
                else { delay = Self.backoff(attempts) }
                do { try await Task.sleep(for: .seconds(delay)) } catch { break }
            }
        }
        guard runID == activeRun else { return }
        socket?.cancel(with: .goingAway, reason: nil); socket = nil
        await deliver(.connection(accessDenied ? .failed : .disconnected, attempts))
    }
    /// Rebuild a full snapshot after a detected connectivity interruption.
    func reconnect() { socket?.cancel(with: .goingAway, reason: nil) }
    nonisolated static func backoff(_ attempts: Int) -> Double { min(30, pow(2, Double(min(5, max(1, attempts))))) }
    private func isStale() -> Bool { Date().timeIntervalSince(lastMessage) > 40 }
    private func receive(_ task: URLSessionWebSocketTask, runID: UUID, attempts: Int, deliver: @escaping @Sendable (F1StreamEvent) async -> Void) async throws {
        var parser = F1SignalRProtocol()
        var sessionKey: String?
        var sessionPath: String?
        while !Task.isCancelled {
            let message = try await task.receive()
            guard runID == activeRun, !Task.isCancelled else { return }
            let data: Data
            switch message { case .data(let value): data = value; case .string(let value): data = Data(value.utf8); @unknown default: continue }
            lastMessage = Date(); await deliver(.activity(lastMessage))
            for event in try parser.receive(data) {
                switch event {
                case .handshake:
                    await deliver(.connection(.subscribing, attempts)); try await task.send(.string(F1SignalRProtocol.subscription(topics: topics)))
                case .subscribed(let updates):
                    let info = updates.first { $0.topic == "SessionInfo" }?.payload
                    sessionKey = info?["Key"].string; sessionPath = info?["Path"].string
                    await deliver(.snapshot(updates)); await deliver(.connection(.connected, attempts))
                case .update(let update):
                    if update.topic == "SessionInfo" {
                        let key = update.payload["Key"].string, path = update.payload["Path"].string
                        if (key != nil && sessionKey != nil && key != sessionKey) || (path != nil && sessionPath != nil && path != sessionPath) {
                            // A new session needs its complete snapshot, not deltas
                            // applied over the previous session's timing dictionary.
                            throw F1LiveTimingError.protocolFailure("Timing session changed; refreshing its snapshot.")
                        }
                    }
                    await deliver(.update(update))
                case .ping: break
                case .closed(let reason): throw F1LiveTimingError.protocolFailure(reason)
                }
            }
        }
    }
}
