import Foundation

actor F1HTTPClient {
    static let shared = F1HTTPClient()
    private let session: URLSession
    private var notBefore: Date?
    init(session: URLSession? = nil) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        self.session = session ?? URLSession(configuration: configuration)
    }
    func data(_ url: URL) async throws -> Data {
        for attempt in 0...2 {
            try Task.checkCancellation()
            if let notBefore, notBefore > Date() { try await Task.sleep(for: .seconds(notBefore.timeIntervalSinceNow)) }
            do {
                var request = URLRequest(url: url, timeoutInterval: 20); request.setValue("BannerTV/1.0", forHTTPHeaderField: "User-Agent")
                let (data, response) = try await session.data(for: request)
                guard let response = response as? HTTPURLResponse else { throw F1LiveTimingError.invalidResponse }
                if response.statusCode == 429 {
                    let seconds = F1RetryPolicy.delay(response.value(forHTTPHeaderField: "Retry-After"))
                    notBefore = Date().addingTimeInterval(max(1, seconds))
                    throw F1LiveTimingError.http(429)
                }
                if response.statusCode >= 500 && attempt < 2 { try await Task.sleep(for: .seconds(pow(2, Double(attempt)))); continue }
                guard (200...299).contains(response.statusCode) else { throw F1LiveTimingError.http(response.statusCode) }
                try Task.checkCancellation(); return data
            } catch let error as URLError {
                if error.code == .cancelled || Task.isCancelled { throw CancellationError() }
                guard attempt < 2 else { throw error }
                try await Task.sleep(for: .seconds(pow(2, Double(attempt))))
            }
        }
        throw F1LiveTimingError.invalidResponse
    }
    func json(_ url: URL) async throws -> F1Value { try await JSONDecoder().decode(F1Value.self, from: data(url)) }
}
