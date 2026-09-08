import Foundation

// MARK: - HTTP client for news feeds with ETag/conditional-GET support

actor StadiaNewsHTTPClient {
    static let shared = StadiaNewsHTTPClient()

    enum HTTPError: Error, LocalizedError {
        case badURL
        case notModified
        case httpStatus(Int)
        case invalidResponse
        case timeout

        var errorDescription: String? {
            switch self {
            case .badURL: return "Bad URL"
            case .notModified: return "304 Not Modified"
            case .httpStatus(let c): return "HTTP \(c)"
            case .invalidResponse: return "Invalid response"
            case .timeout: return "Request timed out"
            }
        }
    }

    private var etags: [String: String] = [:]
    private var lastModified: [String: String] = [:]
    private var cachedResponses: [String: Data] = [:]

    private let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 15
        cfg.timeoutIntervalForResource = 30
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.httpAdditionalHeaders = [
            "User-Agent": "Stadia/1.0 NewsAggregator (iOS; like Safari)",
            "Accept-Encoding": "gzip, deflate, br",
        ]
        return URLSession(configuration: cfg)
    }()

    /// Fetch data from a URL, using conditional GET when an ETag/Last-Modified is cached.
    /// Returns cached data on 304. Throws on non-2xx excluding 304.
    func data(from url: URL, accept: String? = nil) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15

        let key = url.absoluteString

        if let etag = etags[key] { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        if let lm = lastModified[key] { request.setValue(lm, forHTTPHeaderField: "If-Modified-Since") }
        if let a = accept { request.setValue(a, forHTTPHeaderField: "Accept") }

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch let err as URLError where err.code == .timedOut {
            throw HTTPError.timeout
        }

        guard let http = response as? HTTPURLResponse else { throw HTTPError.invalidResponse }

        if http.statusCode == 304, let cached = cachedResponses[key] {
            return cached
        }

        guard (200..<300).contains(http.statusCode) else {
            throw HTTPError.httpStatus(http.statusCode)
        }

        // Store conditional GET headers for next request
        if let etag = http.value(forHTTPHeaderField: "ETag") { etags[key] = etag }
        if let lm = http.value(forHTTPHeaderField: "Last-Modified") { lastModified[key] = lm }
        cachedResponses[key] = data

        return data
    }

    /// Exponential backoff retry for transient errors.
    func dataWithRetry(from url: URL, accept: String? = nil, maxAttempts: Int = 3) async throws -> Data {
        var attempt = 0
        var lastError: Error = HTTPError.invalidResponse
        while attempt < maxAttempts {
            do {
                return try await data(from: url, accept: accept)
            } catch HTTPError.httpStatus(let code) where code == 429 || code >= 500 {
                lastError = HTTPError.httpStatus(code)
                attempt += 1
                if attempt < maxAttempts {
                    let delay = pow(2.0, Double(attempt)) * 0.5
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                }
            } catch HTTPError.timeout {
                lastError = HTTPError.timeout
                attempt += 1
                if attempt < maxAttempts {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
            } catch {
                throw error  // non-retryable
            }
        }
        throw lastError
    }

    func clearConditionalState(for url: URL) {
        let key = url.absoluteString
        etags.removeValue(forKey: key)
        lastModified.removeValue(forKey: key)
        cachedResponses.removeValue(forKey: key)
    }
}
