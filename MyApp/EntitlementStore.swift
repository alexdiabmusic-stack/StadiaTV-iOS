import StoreKit
import Foundation
import Combine
#if os(iOS)
import UIKit
#endif

// MARK: - StoreKit 2 entitlements manager

@MainActor
final class EntitlementStore: ObservableObject {

    // MARK: Product IDs

    static let annualID   = "stadiatv.premium.annual"
    static let lifetimeID = "stadiatv.premium.lifetime"

    // MARK: Published state

    @Published private(set) var isPremium: Bool
    @Published private(set) var products: [Product] = []
    @Published private(set) var isPurchasing = false
    @Published var purchaseError: String?

    // MARK: Private

    private static let cacheKey = "stadiatv.entitlement.premium.v1"
    private var updateListenerTask: Task<Void, Never>?

    // MARK: Init

    init() {
        // Seed from cache so premium users never see a paywall flash on launch.
        isPremium = UserDefaults.standard.bool(forKey: Self.cacheKey)
        updateListenerTask = Task { await listenForTransactions() }
        Task { await loadAll() }
    }

    deinit { updateListenerTask?.cancel() }

    // MARK: Convenience

    var annualProduct: Product? { products.first { $0.id == Self.annualID } }
    var lifetimeProduct: Product? { products.first { $0.id == Self.lifetimeID } }

    // MARK: Public API

    /// Loads products and verifies current entitlements from the App Store.
    func loadAll() async {
        do {
            products = try await Product.products(for: [Self.annualID, Self.lifetimeID])
                .sorted { $0.id == Self.annualID && $1.id == Self.lifetimeID }
        } catch {
            // Products are unavailable in builds without a StoreKit configuration.
        }
        await refreshEntitlements()
    }

    /// Initiates a purchase for the given product.
    func purchase(_ product: Product) async {
        isPurchasing = true
        purchaseError = nil
        defer { isPurchasing = false }

        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                let transaction = try verification.payloadValue
                await refreshEntitlements()
                await transaction.finish()
            case .userCancelled, .pending:
                break
            @unknown default:
                break
            }
        } catch StoreKitError.userCancelled {
            // No error UI for user-initiated cancellations.
        } catch {
            purchaseError = error.localizedDescription
        }
    }

    /// Syncs with the App Store and refreshes entitlements.
    func restore() async {
        isPurchasing = true
        purchaseError = nil
        defer { isPurchasing = false }
        do {
            try await AppStore.sync()
            await refreshEntitlements()
        } catch {
            purchaseError = error.localizedDescription
        }
    }

    /// Presents the system offer code redemption sheet.
    func redeemOfferCode() {
        #if os(iOS)
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first else { return }
        Task { try? await AppStore.presentOfferCodeRedeemSheet(in: scene) }
        #endif
    }

    // MARK: Private

    // ⚠️ TESTFLIGHT ONLY — Remove this before App Store submission.
    private static var isTestFlight: Bool {
        get async {
            guard case .verified(let tx) = try? await AppTransaction.shared else { return false }
            return tx.environment == .sandbox
        }
    }

    private func refreshEntitlements() async {
        // ⚠️ TESTFLIGHT ONLY — Remove this block before App Store submission.
        if await Self.isTestFlight {
            isPremium = true
            UserDefaults.standard.set(true, forKey: Self.cacheKey)
            return
        }

        var hasPremium = false
        for await result in Transaction.currentEntitlements {
            guard let transaction = try? result.payloadValue,
                  transaction.revocationDate == nil,
                  [Self.annualID, Self.lifetimeID].contains(transaction.productID) else { continue }
            hasPremium = true
            break
        }
        isPremium = hasPremium
        UserDefaults.standard.set(hasPremium, forKey: Self.cacheKey)
    }

    private func listenForTransactions() async {
        for await result in Transaction.updates {
            if let transaction = try? result.payloadValue {
                await refreshEntitlements()
                await transaction.finish()
            }
        }
    }
}
