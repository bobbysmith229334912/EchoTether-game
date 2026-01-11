import Foundation
import FirebaseFirestore
import FirebaseFirestoreSwift
import FirebaseAuth   // ✅ Use auth.uid for the user doc

/// Server-backed whisper balance with live updates and atomic mutations.
/// - Live sync: uses a snapshot listener so UI stays current
/// - Atomic ops: Firestore transactions to prevent race conditions / underflow
/// - Optimistic UI: keeps `spend(_:) -> Bool` for existing callers (ContentView)
final class WhisperBalanceStore: ObservableObject {

    // MARK: - Public, observed properties

    @Published var balance: Int = 100        // UI renders this immediately
    @Published var isLoaded: Bool = false    // true once initial load/sync completes
    @Published var lastError: String? = nil  // optional debug surface

    // MARK: - Configuration

    /// Initial free balance for a brand new user (first document creation)
    private let initialFreeBalance: Int = 100

    // MARK: - Firestore plumbing

    private let db = Firestore.firestore()

    /// ✅ Always prefer Firebase Auth UID; fall back to persistent ID only if needed
    private var uid: String {
        if let authUid = Auth.auth().currentUser?.uid {
            return authUid
        } else {
            // Fallback so the app doesn't crash if called too early
            return EchoTetherApp.persistentUserID
        }
    }

    private var docRef: DocumentReference {
        db.collection("users").document(uid)
    }

    private var listener: ListenerRegistration?

    deinit {
        listener?.remove()
    }

    // MARK: - Public API

    /// Start live syncing this user's balance. Call once *after* sign-in.
    func load() {
        print("💰 [WhisperBalanceStore] load() for uid=\(uid)")

        // Remove any old listener if we re-call load()
        listener?.remove()

        // Attach a snapshot listener for live updates
        listener = docRef.addSnapshotListener { [weak self] snapshot, error in
            guard let self = self else { return }

            if let error = error {
                DispatchQueue.main.async {
                    self.lastError = error.localizedDescription
                    self.isLoaded = true
                }
                print("❌ [WhisperBalanceStore] snapshot error:", error.localizedDescription)
                return
            }

            guard let snap = snapshot else {
                print("⚠️ [WhisperBalanceStore] snapshot is nil")
                return
            }

            // Bootstrap first-time users by creating the document
            if !snap.exists {
                print("🆕 [WhisperBalanceStore] user doc missing; bootstrapping with \(self.initialFreeBalance)")
                self.bootstrapIfNeeded()
                return
            }

            if let data = snap.data(),
               let serverBalance = data["whisperBalance"] as? Int {
                DispatchQueue.main.async {
                    if self.balance != serverBalance {
                        self.balance = serverBalance
                        print("🔄 [WhisperBalanceStore] synced whisperBalance from server:", serverBalance)
                    }
                    self.isLoaded = true
                }
            } else {
                // Doc exists but field missing: set sane default
                print("⚠️ [WhisperBalanceStore] whisperBalance field missing; repairing.")
                self.ensureFieldExists()
            }
        }
    }

    /// Spend a number of whispers (client-optimistic) and commit atomically on server.
    @discardableResult
    func spend(_ amount: Int) -> Bool {
        guard amount > 0 else { return false }
        guard isLoaded else {
            lastError = "Balance not loaded"
            print("⚠️ [WhisperBalanceStore] spend(\(amount)) called before isLoaded")
            return false
        }

        // Optimistic local decrement to keep the UI snappy.
        if balance < amount {
            print("⚠️ [WhisperBalanceStore] spend(\(amount)) rejected – insufficient local balance (\(balance))")
            return false
        }

        print("💸 [WhisperBalanceStore] spend(\(amount)) – local balance before =", balance)
        balance -= amount

        applyDeltaAtomically(-amount, ensureNonNegative: true) { [weak self] ok, err in
            guard let self = self else { return }
            if !ok {
                // Rollback local optimistic decrement if server txn failed
                DispatchQueue.main.async {
                    self.balance += amount
                    self.lastError = err ?? "Spend failed"
                    print("⚠️ [WhisperBalanceStore] spend rollback:", err ?? "unknown error")
                }
            } else {
                print("✅ [WhisperBalanceStore] spend(\(amount)) committed on server")
            }
        }
        return true
    }

    /// Grant (add) whispers. Commits atomically on server; never underflows.
    func grant(_ amount: Int) {
        guard amount > 0 else { return }
        print("🎁 [WhisperBalanceStore] grant(\(amount)) – local balance before =", balance)

        // Optimistic local increment
        balance += amount
        applyDeltaAtomically(+amount, ensureNonNegative: false) { [weak self] ok, err in
            guard let self = self else { return }
            if !ok {
                // Rollback if server failed for any reason
                DispatchQueue.main.async {
                    self.balance -= amount
                    self.lastError = err ?? "Grant failed"
                    print("⚠️ [WhisperBalanceStore] grant rollback:", err ?? "unknown error")
                }
            } else {
                print("✅ [WhisperBalanceStore] grant(\(amount)) committed on server")
            }
        }
    }

    /// Force set to a specific value (admin/dev tool). Uses a transaction to avoid stomping.
    func setBalance(_ newValue: Int) {
        let clamped = max(0, newValue)
        print("✏️ [WhisperBalanceStore] setBalance(\(clamped))")

        db.runTransaction({ txn, errPtr -> Any? in
            txn.updateData([
                "whisperBalance": clamped,
                "updatedAt": FieldValue.serverTimestamp()
            ], forDocument: self.docRef)
            return clamped
        }, completion: { [weak self] _, error in
            if let error = error {
                DispatchQueue.main.async {
                    self?.lastError = error.localizedDescription
                }
                print("❌ [WhisperBalanceStore] setBalance error:", error.localizedDescription)
            } else {
                print("✅ [WhisperBalanceStore] setBalance committed")
            }
        })
    }

    // MARK: - Private helpers

    /// Ensure the user doc exists with an initial balance.
    private func bootstrapIfNeeded() {
        docRef.setData([
            "whisperBalance": initialFreeBalance,
            "updatedAt": FieldValue.serverTimestamp()
        ], merge: true) { [weak self] error in
            if let error = error {
                DispatchQueue.main.async {
                    self?.lastError = error.localizedDescription
                    self?.isLoaded = true
                }
                print("❌ [WhisperBalanceStore] bootstrap error:", error.localizedDescription)
                return
            }
            DispatchQueue.main.async {
                self?.balance = self?.initialFreeBalance ?? 100
                self?.isLoaded = true
                print("🆕 [WhisperBalanceStore] bootstrapped whisperBalance:", self?.balance ?? -1)
            }
        }
    }

    /// If the doc exists but the field is missing, initialize it.
    private func ensureFieldExists() {
        docRef.setData([
            "whisperBalance": initialFreeBalance,
            "updatedAt": FieldValue.serverTimestamp()
        ], merge: true) { [weak self] error in
            if let error = error {
                DispatchQueue.main.async {
                    self?.lastError = error.localizedDescription
                }
                print("❌ [WhisperBalanceStore] ensureFieldExists error:", error.localizedDescription)
                return
            }
            DispatchQueue.main.async {
                if let s = self {
                    if s.balance != s.initialFreeBalance {
                        s.balance = s.initialFreeBalance
                    }
                    s.isLoaded = true
                    print("🛠️ [WhisperBalanceStore] ensured whisperBalance field =", s.balance)
                }
            }
        }
    }

    /// Apply a delta using a Firestore **transaction**.
    /// - Parameter ensureNonNegative: if true, the txn aborts when result would go < 0.
    private func applyDeltaAtomically(_ delta: Int,
                                      ensureNonNegative: Bool,
                                      completion: @escaping (Bool, String?) -> Void) {

        db.runTransaction({ txn, errPtr -> Any? in
            let snap: DocumentSnapshot
            do {
                snap = try txn.getDocument(self.docRef)
            } catch {
                let msg = "Failed to read balance"
                errPtr?.pointee = NSError(
                    domain: "WhisperBalanceStore",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: msg]
                )
                print("❌ [WhisperBalanceStore] transaction read error:", error.localizedDescription)
                return nil
            }

            let current = snap.data()?["whisperBalance"] as? Int ?? self.initialFreeBalance
            let proposed = current + delta

            print("🔁 [WhisperBalanceStore] txn current=\(current) delta=\(delta) proposed=\(proposed)")

            if ensureNonNegative && proposed < 0 {
                let msg = "Insufficient balance"
                errPtr?.pointee = NSError(
                    domain: "WhisperBalanceStore",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: msg]
                )
                print("⚠️ [WhisperBalanceStore] txn aborted – would go negative")
                return nil
            }

            txn.updateData([
                "whisperBalance": proposed,
                "updatedAt": FieldValue.serverTimestamp()
            ], forDocument: self.docRef)

            return proposed
        }, completion: { result, error in
            if let error = error {
                print("❌ [WhisperBalanceStore] txn error:", error.localizedDescription)
                completion(false, error.localizedDescription)
            } else {
                if let proposed = result as? Int {
                    print("✅ [WhisperBalanceStore] txn committed, new server balance =", proposed)
                } else {
                    print("✅ [WhisperBalanceStore] txn committed (no result cast)")
                }
                completion(true, nil)
            }
        })
    }
}
