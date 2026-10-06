#if canImport(WebKit)
import WebKit
#endif
#if canImport(UIKit)
import UIKit
#endif

/// Signs the user into ESPN inside an embedded web view instead of asking them to find and paste
/// raw `espn_s2`/`SWID` cookie values. Banner never sees the user's ESPN username or password — it
/// only reads the resulting session cookies once ESPN sets them.
///
/// This can't use `ASWebAuthenticationSession`: ESPN has no OAuth-style redirect back to an app
/// callback scheme, so completion has to be detected by polling for session cookies, and
/// `ASWebAuthenticationSession` only shares cookies with Safari's browsing session — never with
/// the host app's own `WKWebsiteDataStore`. Hosting the login page in a `WKWebView` configured
/// with `.default()` keeps the cookies visible to the same store this class polls, so sign-in can
/// be detected and the sheet dismissed automatically instead of leaving the user stuck on
/// espn.com until they force-close it.
///
/// WebKit doesn't exist on tvOS/watchOS, so there this always fails immediately with
/// `.presentationFailed` — the same degraded behavior UIKit-less platforms already got before
/// WebKit availability was considered.
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

    private var pollTask: Task<Void, Never>?
    #if canImport(UIKit)
    private weak var presentedController: UIViewController?
    #endif

    func signIn() async throws -> ESPNFantasyCredentials {
        try await withCheckedThrowingContinuation { continuation in
            var didResume = false
            let resume: (Result<ESPNFantasyCredentials, Error>) -> Void = { [weak self] result in
                guard !didResume else { return }
                didResume = true
                self?.pollTask?.cancel()
                self?.pollTask = nil
                #if canImport(UIKit)
                self?.presentedController?.dismiss(animated: true)
                self?.presentedController = nil
                #endif
                continuation.resume(with: result)
            }

            guard let loginURL = URL(string: "https://www.espn.com/login") else {
                resume(.failure(AuthError.sessionFailed("Invalid ESPN login URL.")))
                return
            }

            #if canImport(UIKit) && canImport(WebKit)
            guard let presenter = Self.topViewController() else {
                resume(.failure(AuthError.presentationFailed))
                return
            }

            let loginController = ESPNLoginViewController(url: loginURL) {
                resume(.failure(AuthError.cancelled))
            }
            let navController = UINavigationController(rootViewController: loginController)
            presentedController = navController
            presenter.present(navController, animated: true)
            #else
            resume(.failure(AuthError.presentationFailed))
            return
            #endif

            #if canImport(WebKit)
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
                            return
                        }
                        // Cookies changed or disappeared during the settle window (still mid-redirect,
                        // or the user is retrying a failed login) — keep polling instead of giving up.
                    }
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                }
            }
            #endif
        }
    }

    #if canImport(WebKit)
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
    #endif

    #if canImport(UIKit)
    private static func topViewController() -> UIViewController? {
        let window = UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.windows.first { $0.isKeyWindow } }
            .first
        var top = window?.rootViewController
        while let presented = top?.presentedViewController {
            top = presented
        }
        return top
    }
    #endif
}

#if canImport(UIKit) && canImport(WebKit)
/// Hosts the ESPN login page in a `WKWebView` backed by the app's default (non-ephemeral) data
/// store, so cookies ESPN sets on successful sign-in are immediately visible to
/// `WKWebsiteDataStore.default()` — and therefore to `ESPNWebAuthenticator`'s cookie poll.
private final class ESPNLoginViewController: UIViewController {
    private let url: URL
    private let onCancel: () -> Void
    private var webView: WKWebView?

    init(url: URL, onCancel: @escaping () -> Void) {
        self.url = url
        self.onCancel = onCancel
        super.init(nibName: nil, bundle: nil)
        title = "Sign in to ESPN"
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .cancel,
            target: self,
            action: #selector(cancelTapped)
        )

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        self.webView = webView

        webView.load(URLRequest(url: url))
    }

    @objc private func cancelTapped() {
        onCancel()
    }
}
#endif
