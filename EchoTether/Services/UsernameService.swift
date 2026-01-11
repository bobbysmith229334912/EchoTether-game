//
//  UsernameService.swift
//  EchoTether
//
//  Created by Bobby Smith on 10/17/25.
//

import Foundation
import FirebaseAuth
import FirebaseFunctions
import FirebaseFirestore
import Combine

/// Centralized username utilities + backend calls.
/// Single responsibility: username CRUD/reads. No UI.
final class UsernameService {

    static let shared = UsernameService()

    private let db = Firestore.firestore()
    private lazy var functions = Functions.functions(region: "us-central1")

    private init() {}

    // MARK: Local validation (mirror of Cloud Function)

    struct ValidationResult {
        let ok: Bool
        let message: String?
        let username: String?
        let usernameLower: String?
    }

    /// Enforces: 3-20 chars, start with letter, [A-Za-z0-9_], basic reserved
    func validateLocally(_ raw: String) -> ValidationResult {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let minLen = 3, maxLen = 20
        guard (minLen...maxLen).contains(s.count) else {
            return .init(ok: false, message: "Username must be \(minLen)-\(maxLen) characters.", username: nil, usernameLower: nil)
        }
        let regex = try! NSRegularExpression(pattern: "^[A-Za-z][A-Za-z0-9_]*$")
        let range = NSRange(location: 0, length: s.utf16.count)
        guard regex.firstMatch(in: s, options: [], range: range) != nil else {
            return .init(ok: false, message: "Use letters, numbers, and underscores only; must start with a letter.", username: nil, usernameLower: nil)
        }

        let reserved: Set<String> = [
            "admin","support","help","echo","echotether","system","apple","google","firebase",
            "moderator","root","null","undefined","about","terms","privacy","api","v1","v2",
            "me","you","owner","user","username","profile","settings"
        ]
        let lower = s.lowercased()
        if reserved.contains(lower) {
            return .init(ok: false, message: "That username is reserved.", username: nil, usernameLower: nil)
        }
        return .init(ok: true, message: nil, username: s, usernameLower: lower)
    }

    // MARK: Public API

    /// Checks if a username looks free by reading `usernames/{lower}`.
    /// NOTE: Final authority is the Cloud Function; this is just fast feedback.
    func checkAvailability(_ candidate: String) async throws -> Bool {
        let v = validateLocally(candidate)
        guard v.ok, let lower = v.usernameLower else { return false }
        let snap = try await db.collection("usernames").document(lower).getDocument()
        if !snap.exists { return true }
        // If reserved by me, also consider it "available" (no-op changes)
        if let myUid = Auth.auth().currentUser?.uid,
           let data = snap.data(),
           let uid = data["uid"] as? String,
           uid == myUid {
            return true
        }
        return false
    }

    /// Calls the deployed callable `setUsername` (authoritative, transactional).
    /// Returns the final username on success.
    func setUsername(_ desired: String) async throws -> String {
        let v = validateLocally(desired)
        if !v.ok { throw UsernameError.invalid(v.message ?? "Invalid username.") }

        let res = try await functions.httpsCallable("setUsername").call(["username": v.username!])
        guard let dict = res.data as? [String: Any],
              let success = dict["success"] as? Bool, success == true,
              let finalName = dict["username"] as? String
        else {
            let msg = (res.data as? [String: Any])?["message"] as? String ?? "Unknown error."
            throw UsernameError.server(msg)
        }
        return finalName
    }

    /// Returns the current user’s username (live updates).
    func usernamePublisher() -> AnyPublisher<String?, Never> {
        guard let uid = Auth.auth().currentUser?.uid else {
            return Just(nil).eraseToAnyPublisher()
        }
        let ref = db.collection("users").document(uid)
        return DocumentPublisher(ref: ref)
            .map { snap in
                guard let data = snap.data() else { return nil }
                return (data["username"] as? String) ?? nil
            }
            .replaceError(with: nil)
            .eraseToAnyPublisher()
    }

    /// Resolve `@handle` -> uid (for mentions, search, etc.)
    func lookupUid(forHandle handle: String) async throws -> String? {
        let trimmed = handle.trimmingCharacters(in: .whitespacesAndNewlines)
        let withoutAt = trimmed.hasPrefix("@") ? String(trimmed.dropFirst()) : trimmed
        let v = validateLocally(withoutAt)
        guard v.ok, let lower = v.usernameLower else { return nil }
        let snap = try await db.collection("usernames").document(lower).getDocument()
        return (snap.data()?["uid"] as? String)
    }

    // MARK: Errors

    enum UsernameError: LocalizedError {
        case invalid(String)
        case server(String)

        var errorDescription: String? {
            switch self {
            case .invalid(let m): return m
            case .server(let m): return m
            }
        }
    }
}

// MARK: - Lightweight Firestore doc publisher (Combine)

private struct DocumentPublisher: Publisher {
    typealias Output = DocumentSnapshot
    typealias Failure = Error

    let ref: DocumentReference

    func receive<S>(subscriber: S) where S : Subscriber, Error == S.Failure, DocumentSnapshot == S.Input {
        let subscription = DocumentSubscription(ref: ref, subscriber: subscriber)
        subscriber.receive(subscription: subscription)
    }

    private final class DocumentSubscription<S: Subscriber>: Subscription where S.Input == DocumentSnapshot, S.Failure == Error {
        private var listener: ListenerRegistration?
        private var subscriber: S?

        init(ref: DocumentReference, subscriber: S) {
            self.subscriber = subscriber
            self.listener = ref.addSnapshotListener { [weak self] snap, err in
                guard let self = self else { return }
                if let err = err {
                    _ = self.subscriber?.receive(completion: .failure(err))
                    return
                }
                if let snap = snap {
                    _ = self.subscriber?.receive(snap)
                }
            }
        }

        func request(_ demand: Subscribers.Demand) {}

        func cancel() {
            listener?.remove()
            listener = nil
            subscriber = nil
        }
    }
}
