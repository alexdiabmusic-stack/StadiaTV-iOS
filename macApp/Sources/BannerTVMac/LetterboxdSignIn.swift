import BannerCore
import SwiftUI
import WebKit

/// Letterboxd has no sign-in API, so the member signs in on Letterboxd's own page, here in a web view. BannerTV never sees the password:
/// once the site has signed the member in, only the session cookies and the web view's user agent are handed to the shared core, which
/// checks them before keeping anything (in the Keychain, for this profile). The web view keeps nothing of its own.
struct LetterboxdSignInView: NSViewRepresentable {
    let onSignedIn: ([String: String], String, String?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onSignedIn: onSignedIn) }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: .zero, configuration: configuration)
        context.coordinator.start(web)
        return web
    }

    func updateNSView(_ view: WKWebView, context: Context) {}

    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        coordinator.stop()
        view.stopLoading()
    }

    @MainActor
    final class Coordinator {
        private let onSignedIn: ([String: String], String, String?) -> Void
        private var task: Task<Void, Never>?
        private let settingsURL = URL(string: "https://letterboxd.com/settings/")!
        private let readUsername = "(function(){try{var i=document.querySelector('input[name=username]');return i&&i.value?i.value:'';}catch(e){return '';}})()"

        init(onSignedIn: @escaping ([String: String], String, String?) -> Void) { self.onSignedIn = onSignedIn }

        func stop() { task?.cancel() }

        func start(_ web: WKWebView) {
            let core = MacLetterboxd.shared
            if let url = URL(string: core.signInUrl) { web.load(URLRequest(url: url)) }
            let host = core.signInHost
            task = Task { [weak self, weak web] in
                var sentToSettings = false
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    guard let self, let web else { return }
                    if DebugHarness.openLetterboxdSignIn { FileHandle.standardError.write(Data("[letterboxd-signin] page \(web.url?.host ?? "-")\(web.url?.path ?? "") title=\(web.title ?? "-") loading=\(web.isLoading)\n".utf8)) }
                    guard (web.url?.host ?? "").hasSuffix(host) else { continue }
                    let all = await web.configuration.websiteDataStore.httpCookieStore.allCookies()
                    var cookies: [String: String] = [:]
                    for c in all where c.domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")).hasSuffix(host) { cookies[c.name] = c.value }
                    guard core.isSignedIn(cookieNames: Array(cookies.keys)) else { continue }
                    if !sentToSettings {
                        // Signed in: the account page names the member, and is read inside the browser, which the site trusts.
                        sentToSettings = true
                        web.load(URLRequest(url: self.settingsURL))
                        continue
                    }
                    guard web.url?.path.hasPrefix("/settings") == true, !web.isLoading else { continue }
                    let name = (try? await web.evaluateJavaScript(self.readUsername) as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                    let agent = (try? await web.evaluateJavaScript("navigator.userAgent") as? String) ?? ""
                    web.isHidden = true
                    self.onSignedIn(cookies, agent.isEmpty ? "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15" : agent, (name?.isEmpty ?? true) ? nil : name)
                    return
                }
            }
        }
    }
}

/// The sign-in sheet: Letterboxd's own page, with a Close button.
struct LetterboxdSignInSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onSignedIn: ([String: String], String, String?) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Sign in to Letterboxd").font(.jb(18, .semibold))
                Spacer()
                Button("Close") { dismiss() }.buttonStyle(PillButtonStyle(kind: .secondary, height: 34)).keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
            Divider().overlay(Theme.hairline)
            LetterboxdSignInView { cookies, agent, name in
                dismiss()
                onSignedIn(cookies, agent, name)
            }
        }
        .frame(width: 560, height: 720).background(Theme.background)
    }
}
