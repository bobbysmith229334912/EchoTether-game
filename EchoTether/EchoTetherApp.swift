//
//  EchoTetherApp.swift
//  EchoTether
//

import SwiftUI
import Firebase
import FirebaseAuth
import FirebaseFirestore
import FirebaseFirestoreSwift
import RevenueCat

private let kUserIdKey = "et_persistent_user_id"

@main
struct EchoTetherApp: App {
    // Global environment objects
    @StateObject private var subscriptionManager = SubscriptionManager()
    @StateObject private var whisperStore = WhisperBalanceStore()

    // Referrer / creator code
    @AppStorage("referrerCode") private var referrerCode: String = ""
    @State private var showCreatorCodeSheet = false

    // ✅ NEW: In-app animated splash (Chaotic Bubble Burst style)
    @State private var showSplash: Bool = true
    @State private var didBootstrapAfterSplash: Bool = false

    // Generate/read a persistent ID that survives reinstall
    static var persistentUserID: String = {
        if let data = Keychain.load(kUserIdKey),
           let id = String(data: data, encoding: .utf8) {
            return id
        }
        let newID = UUID().uuidString
        Keychain.save(kUserIdKey, data: Data(newID.utf8))
        return newID
    }()

    init() {
        // Firebase
        FirebaseApp.configure()

        // RevenueCat
        Purchases.logLevel = .debug
        Purchases.configure(
            withAPIKey: "appl_OvTAAYopStkWPyVKsFwCYrwFZuO",
            appUserID: EchoTetherApp.persistentUserID
        )
        print("🆔 RC appUserID:", EchoTetherApp.persistentUserID)
    }

    var body: some Scene {
        WindowGroup {
            ZStack {
                // Your main app
                ContentView()
                    .environmentObject(subscriptionManager)
                    .environmentObject(whisperStore)

                    // 🔑 Bootstrap everything on launch (after splash ends)
                    .task {
                        // ✅ NEW: prevent bootstrap from running behind the splash
                        guard !showSplash else { return }
                        guard !didBootstrapAfterSplash else { return }
                        didBootstrapAfterSplash = true
                        await bootstrapUserAndBalances()
                    }

                    // 🔗 Deep link handling for ?ref=CREATORCODE
                    .onOpenURL { url in
                        guard
                            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
                            let ref = items.first(where: { $0.name == "ref" })?.value?.trimmingCharacters(in: .whitespacesAndNewlines),
                            !ref.isEmpty
                        else { return }

                        let code = ref.uppercased()
                        referrerCode = code
                        Purchases.shared.attribution.setAttributes(["referrer": code])
                        print("🔗 Set referrer from URL: \(code)")
                    }

                    // 🧩 Creator code sheet
                    .sheet(isPresented: $showCreatorCodeSheet) {
                        CreatorCodeView(
                            onApply: { code in
                                let codeUpper = code.uppercased()
                                referrerCode = codeUpper
                                Purchases.shared.attribution.setAttributes(["referrer": codeUpper])
                                print("✅ Referrer saved via sheet: \(codeUpper)")
                                showCreatorCodeSheet = false
                            },
                            onSkip: {
                                showCreatorCodeSheet = false
                            }
                        )
                    }

                // ✅ NEW: Animated splash overlay (Chaotic Bubble Burst style)
                if showSplash {
                    SplashView {
                        withAnimation(.easeOut(duration: 0.25)) {
                            showSplash = false
                        }
                    }
                    .transition(.opacity)
                    .zIndex(999)
                }
            }
        }
    }
}

// MARK: - Bootstrap Helpers

extension EchoTetherApp {

    /// Main startup pipeline:
    /// 1) Ensure anonymous auth
    /// 2) Start live whisper balance sync
    /// 3) Check Firestore for creator/partner info
    /// 4) Decide whether to show the creator code sheet
    @MainActor
    private func bootstrapUserAndBalances() async {
        // 1) Anonymous auth (no visible login)
        if Auth.auth().currentUser == nil {
            do {
                let result = try await Auth.auth().signInAnonymously()
                print("✅ Signed in anonymously UID:", result.user.uid)
            } catch {
                print("❌ Anonymous sign-in failed:", error.localizedDescription)
            }
        } else {
            print("✅ Already signed in UID:", Auth.auth().currentUser?.uid ?? "nil")
        }

        // 2) Start live balance sync
        whisperStore.load()

        // 3) Creator code logic (only if we have a UID)
        guard let uid = Auth.auth().currentUser?.uid else {
            // If something weird happens and we *still* don’t have a UID,
            // fall back to local-only creator sheet logic.
            handleCreatorSheetWithoutUID()
            return
        }

        let userRef = Firestore.firestore().collection("users").document(uid)

        do {
            // ✅ async/await version – avoids getDocument overload warnings
            let snap = try await userRef.getDocument()
            let data = snap.data() ?? [:]

            let creatorInfo = data["creator"] as? [String: Any]
            let hasServerCreator =
                (data["hasCreatorCode"] as? Bool) == true ||
                (creatorInfo?["code"] as? String) != nil

            if hasServerCreator {
                // Firestore says this user already has a creator code.
                print("✅ Server shows creator code exists — skipping prompt")

                // Still restore local referrer into RevenueCat if we have one.
                if !referrerCode.isEmpty {
                    Purchases.shared.attribution.setAttributes(["referrer": referrerCode])
                    print("♻️ Restored referrer to RC: \(referrerCode)")
                }
                return
            }

            // No creator code in Firestore yet.
            if !referrerCode.isEmpty {
                // We already have a stored referrer; just push it to RevenueCat.
                Purchases.shared.attribution.setAttributes(["referrer": referrerCode])
                print("♻️ Restored referrer to RC: \(referrerCode)")
            } else {
                // Completely fresh user: show creator code sheet shortly after launch.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    print("🧩 Showing creator code sheet (no server code)")
                    self.showCreatorCodeSheet = true
                }
            }
        } catch {
            print("⚠️ Creator code lookup failed:", error.localizedDescription)
            handleCreatorSheetOnError()
        }
    }

    /// Fallback when we don’t have a Firebase UID yet.
    @MainActor
    private func handleCreatorSheetWithoutUID() {
        if !referrerCode.isEmpty {
            Purchases.shared.attribution.setAttributes(["referrer": referrerCode])
            print("♻️ Restored referrer to RC (no UID yet): \(referrerCode)")
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                print("🧩 Showing creator code sheet (no UID)")
                self.showCreatorCodeSheet = true
            }
        }
    }

    /// Fallback for Firestore errors when checking creator info.
    @MainActor
    private func handleCreatorSheetOnError() {
        if !referrerCode.isEmpty {
            Purchases.shared.attribution.setAttributes(["referrer": referrerCode])
            print("♻️ Restored referrer to RC after error: \(referrerCode)")
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                print("🧩 Showing creator code sheet (error fallback)")
                self.showCreatorCodeSheet = true
            }
        }
    }
}
