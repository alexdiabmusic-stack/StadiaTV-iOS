import AppKit
import SwiftUI

/// The BannerTV wordmark (mark and lettering), from the phone app's artwork.
struct Wordmark: View {
    var height: CGFloat = 64
    var body: some View {
        if let url = Bundle.main.url(forResource: "wordmark", withExtension: "png"), let image = NSImage(contentsOf: url) {
            Image(nsImage: image).resizable().aspectRatio(contentMode: .fit).frame(height: height)
        } else {
            Text("BannerTV").font(.jb(height * 0.5, .bold)).foregroundStyle(.white)
        }
    }
}

/// What the person sees before the app proper: sign-in, then "Who's watching?".
struct GateView: View {
    @EnvironmentObject private var account: AccountModel

    var body: some View {
        ZStack {
            Theme.background
            RadialGradient(colors: [Color(red: 0.0, green: 0.16, blue: 0.40).opacity(0.9), .clear], center: .topLeading, startRadius: 20, endRadius: 760)
            switch account.stage {
            case .launching: ProgressView().controlSize(.large)
            case .signedOut: WelcomeView()
            case .choosingProfile: ProfilePickerView()
            case .ready: EmptyView()
            }
        }
        .ignoresSafeArea()
    }
}

struct WelcomeView: View {
    @EnvironmentObject private var account: AccountModel
    @State private var email = ""
    @State private var password = ""

    var body: some View {
        VStack(spacing: 26) {
            Wordmark(height: 74)
            Text("Welcome back").font(.jb(40, .bold))
            Text("Sign in to bring your profiles, add-ons and watch history.").font(.jb(16)).foregroundStyle(Theme.textSecondary)
            VStack(spacing: 12) {
                field { TextField("Email", text: $email).textContentType(.username) }
                field { SecureField("Password", text: $password).textContentType(.password).onSubmit(submit) }
                Button(action: submit) { Text("Sign In").frame(maxWidth: .infinity) }
                    .buttonStyle(PillButtonStyle(kind: .primary, height: 50))
                    .disabled(email.isEmpty || password.isEmpty || account.busy)
                    .opacity(email.isEmpty || password.isEmpty ? 0.5 : 1)
                if let message = account.message { Text(message).font(.jb(14)).foregroundStyle(Color(red: 1, green: 0.45, blue: 0.45)) }
            }
            .frame(width: 340)
            Button("Use without an account") { account.continueWithoutAccount() }
                .buttonStyle(.plain).font(.jb(15, .semibold)).foregroundStyle(Theme.textSecondary)
        }
    }

    private func field<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content().textFieldStyle(.plain).font(.jb(16)).padding(.horizontal, 18).frame(height: 50)
            .background(Color.white.opacity(0.08), in: Capsule())
            .overlay(Capsule().stroke(Color.white.opacity(0.10), lineWidth: 1))
    }

    private func submit() {
        guard !email.isEmpty, !password.isEmpty else { return }
        account.signIn(email: email, password: password)
    }
}

struct ProfilePickerView: View {
    @EnvironmentObject private var account: AccountModel
    @State private var pinFor: ProfileInfo?

    var body: some View {
        VStack(spacing: 44) {
            Wordmark(height: 64)
            Text("Who's watching?").font(.jb(46, .bold))
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(190), spacing: 36), count: min(max(account.profiles.count, 1), 4)), spacing: 36) {
                ForEach(account.profiles) { profile in
                    Button { select(profile) } label: { ProfileTile(profile: profile) }.buttonStyle(.plain)
                }
            }
            .fixedSize()
            if let message = account.message { Text(message).foregroundStyle(Color(red: 1, green: 0.45, blue: 0.45)) }
        }
        .sheet(item: $pinFor) { profile in PinSheet(profile: profile) { Task { await account.choose(profile) } } }
    }

    private func select(_ profile: ProfileInfo) {
        if profile.pinEnabled { pinFor = profile } else { Task { await account.choose(profile) } }
    }
}

private struct ProfileTile: View {
    let profile: ProfileInfo
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle().fill(Color(hex: profile.colorHex))
                if let url = profile.avatar {
                    AsyncImage(url: url) { phase in
                        if let image = phase.image { image.resizable().aspectRatio(contentMode: .fill) }
                        else { initial }
                    }
                } else { initial }
                if profile.pinEnabled {
                    Image(systemName: "lock.fill").font(.system(size: 14)).padding(9).background(.black.opacity(0.55), in: Circle())
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                }
            }
            .frame(width: 150, height: 150).clipShape(Circle())
            .padding(6)
            .overlay(Circle().stroke(hovering ? Color.white : Color(hex: profile.colorHex).opacity(0.38), lineWidth: hovering ? 3 : 6))
            Text(profile.name).font(.jb(20, .semibold)).foregroundStyle(hovering ? Theme.textPrimary : Theme.textSecondary).lineLimit(1)
        }
        .scaleEffect(hovering ? 1.04 : 1)
        .animation(.easeOut(duration: 0.15), value: hovering)
        .onHover { hovering = $0 }
    }

    private var initial: some View {
        Text(String(profile.name.prefix(1)).uppercased()).font(.jb(56, .bold))
    }
}

private struct PinSheet: View {
    let profile: ProfileInfo
    let onUnlocked: () -> Void
    @EnvironmentObject private var account: AccountModel
    @Environment(\.dismiss) private var dismiss
    @State private var pin = ""
    @State private var error: String?
    @State private var checking = false

    var body: some View {
        VStack(spacing: 14) {
            Text("Enter PIN for \(profile.name)").font(.headline)
            SecureField("PIN", text: $pin).textFieldStyle(.roundedBorder).frame(width: 160).onSubmit(check)
            if let error { Text(error).foregroundStyle(.red).font(.callout) }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Unlock", action: check).keyboardShortcut(.defaultAction).disabled(pin.count < 4 || checking)
            }
        }
        .padding(28).frame(minWidth: 320).background(Theme.background)
    }

    private func check() {
        checking = true
        Task {
            let result = await account.verifyPin(profile, pin: pin)
            checking = false
            if let result { error = result; pin = "" } else { dismiss(); onUnlocked() }
        }
    }
}

extension Color {
    /// `#RRGGBB` (or `#AARRGGBB`) as a colour; falls back to the brand blue.
    init(hex: String) {
        let h = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        var value: UInt64 = 0
        guard Scanner(string: h).scanHexInt64(&value), h.count == 6 || h.count == 8 else { self = Color(red: 0.12, green: 0.53, blue: 0.9); return }
        let hasAlpha = h.count == 8
        self.init(.sRGB,
                  red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255, blue: Double(value & 0xFF) / 255,
                  opacity: hasAlpha ? Double((value >> 24) & 0xFF) / 255 : 1)
    }
}
