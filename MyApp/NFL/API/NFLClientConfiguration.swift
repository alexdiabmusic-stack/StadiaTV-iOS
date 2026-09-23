import Foundation

/// Public WEB_DESKTOP configuration distributed by NFL's web application and SportsDataverse.
/// This is not a user account credential. Temporary bearer tokens stay in memory only.
nonisolated struct NFLClientConfiguration: Sendable {
    var host = "https://api.nfl.com"
    var clientKey = "4cFUW6DmwJpzT9L7LrG3qRAcABG5s04g"
    var clientSecret = "CZuvCL49d9OwfGsR"
    var deviceInfo = "eyJtb2RlbCI6ImRlc2t0b3AiLCJvc05hbWUiOiJXaW5kb3dzIiwib3NWZXJzaW9uIjoiMTAiLCJ2ZXJzaW9uIjoiQ2hyb21lIn0="
    var userAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36"
    func headers(token: String? = nil) -> [String: String] {
        var result = ["User-Agent": userAgent, "Accept": "application/json", "X-Domain-Id": "100",
                      "Origin": "https://www.nfl.com", "Referer": "https://www.nfl.com/"]
        if let token { result["Authorization"] = "Bearer \(token)" }
        return result
    }
    func tokenRequest() throws -> URLRequest {
        guard let url = URL(string: host + "/identity/v3/token") else { throw NFLAPIError.invalidURL }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.allHTTPHeaderFields = headers()
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let fields = ["clientKey": clientKey, "clientSecret": clientSecret, "deviceId": UUID().uuidString,
                      "deviceInfo": deviceInfo, "networkType": "other"]
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        request.httpBody = fields.sorted { $0.key < $1.key }.map {
            "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")"
        }.joined(separator: "&").data(using: .utf8)
        return request
    }
}
