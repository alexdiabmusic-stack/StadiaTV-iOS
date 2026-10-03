import AuthenticationServices
import WebKit
#if canImport(UIKit)
import UIKit
#endif

/// Signs the user into ESPN inside a system-managed, secure browser session (`ASWebAuthenticationSession`)
/// instead of asking them to find and paste raw `espn_s2`/`SWID` cookie values. Banner never sees the
/// user's ESPN username or password — it only reads the resulting session cookies once ESPN sets them.
@MainActor
final class ESPNWebAuthenticator: NSObject {
    enum AuthError: LocalizedError {
        case cancelled
        case presentationFailed
        case sessionFailed(String)

        var errorDescription: String? {
            switch self {
            case .cancelled: return "ESPN sign-in was cancelled."
            case .presentationFailed: return "Banner couldn't open ESPN sign-in."
            case .sessionFailed(let message): return message
            }
        }
    }

    private var session: ASWebAuthenticationSession?
    private var pollTask: Task<Void, Never>?

    /// Presents ESPN's real login page, polls the shared cookie store for `espn_s2`/`SWID` after
    /// the user signs in, and resolves with them as soon as both appear — dismissing the browser
    /// automatically. ESPN never redirects to an app callback scheme, so completion is driven by
    /// cookie polling rather than the session's normal callback-URL mechanism.
    func signIn() async throws -> ESPNFantasyCredentials {
        try await withCheckedThrowingContinuation { continuation in
            var didResume = false
            let resume: (Result<ESPNFantasyCredentials, Error>) -> Void = { [weak self] result in
                guard !didResume else { return }
                didResume = true
                self?.pollTask?.cancel()
                self?.pollTask = nil
                self?.session = nil
                continuation.resume(with: result)
            }

            guard let loginURL = URL(string: "https://www.espn.com/login") else {
                resume(.failure(AuthError.sessionFailed("Invalid ESPN login URL.")))
                return
            }

            let session = ASWebAuthenticationSession(url: loginURL, callbackURLScheme: "bannertv-espn") { _, error in
                guard let error else { return }
                let nsError = error as NSError
                if nsError.domain == ASWebAuthenticationSessionErrorDomain,
                   nsError.code == ASWebAuthenticationSessionError.canceledLogin.rawValue {
                    resume(.failure(AuthError.cancelled))
                } else {
                    resume(.failure(error))
                }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            self.session = session

            self.pollTask = Task { [weak self] in
                while !Task.isCancelled {
                    if let credentials = await Self.readESPNCredentials() {
                        // ESPN's login goes through several redirects (Disney ID -> ESPN -> fantasy
                        // home); espn_s2/SWID can appear mid-chain before the session is fully
                        // established. Closing the browser the instant they're first seen cuts that
                        // chain short and ESPN reports the login as incomplete. Wait for the same
                        // cookies to still be present a couple seconds later before auto-closing.
                        try? await Task.sleep(nanoseconds: 2_500_000_000)
                        guard !Task.isCancelled else { return }
                        if let confirmed = await Self.readESPNCredentials(),
                           confirmed.espnS2 == credentials.espnS2, confirmed.swid == credentials.swid {
                            resume(.success(confirmed))
                            self?.session?.cancel()
                            return
                        }
                        // Cookies changed or disappeared during the settle window (still mid-redirect,
                        // or the user is retrying a failed login) — keep polling instead of giving up.
                    }
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                }
            }

            guard session.start() else {
                resume(.failure(AuthError.presentationFailed))
                return
            }
        }
    }

    private static func readESPNCredentials() async -> ESPNFantasyCredentials? {
        await withCheckedContinuation { continuation in
            WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
                let espnCookies = cookies.filter { $0.domain.contains("espn.com") }
                guard
                    let espnS2 = espnCookies.first(where: { $0.name == "espn_s2" })?.value,
                    let swid = espnCookies.first(where: { $0.name == "SWID" })?.value,
                    !espnS2.isEmpty, !swid.isEmpty
                else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: ESPNFantasyCredentials(espnS2: espnS2, swid: swid))
            }
        }
    }
}

extension ESPNWebAuthenticator: ASWebAuthenticationPresentationContextProviding {
    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            #if canImport(UIKit)
            let window = UIApplication.shared.connectedScenes
                .compactMap { ($0 as? UIWindowScene)?.windows.first { $0.isKeyWindow } }
                .first
            return window ?? ASPresentationAnchor()
            #else
            return ASPresentationAnchor()
            #endif
        }
    }
}
