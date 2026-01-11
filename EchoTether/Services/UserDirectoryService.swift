//
//  UserDirectoryService.swift
//  EchoTether
//
//  Created by Bobby Smith on 10/18/25.
//

//
//  UserDirectoryService.swift
//  EchoTether
//
//  Created by Bobby Smith on 10/18/25.
//

import Foundation
import FirebaseAuth
import FirebaseFirestore

/// Minimal directory for resolving @handles → uid and type-ahead user search.
/// Reads from `users/{uid}` and `usernames/{usernameLower}`.
final class UserDirectoryService {
    static let shared = UserDirectoryService()
    private init() {}

    private let db = Firestore.firestore()

    // MARK: Models

    struct Profile: Identifiable, Codable, Equatable {
        let id: String               // uid
        let handle: String?          // e.g., "Bobby_Smith"
        let handleLower: String?     // e.g., "bobby_smith"
        let displayName: String?
        let photoURL: String?
    }

    // MARK: Cache (tiny in-memory)

    private var byUid: [String: Profile] = [:]
    private var byHandleLower: [String: Profile] = [:]

    // MARK: Reads

    /// Resolve a handle like "@bobby" or "bobby" to a UID via `usernames/{lower}`.
    func resolveHandleToUid(_ handleOrAt: String) async throws -> String? {
        let trimmed = handleOrAt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let noAt = trimmed.hasPrefix("@") ? String(trimmed.dropFirst()) : trimmed
        let lower = noAt.lowercased()

        if let cached = byHandleLower[lower] { return cached.id }

        let snap = try await db.collection("usernames").document(lower).getDocument()
        return (snap.data()?["uid"] as? String)
    }

    /// Fetch a profile by UID from `users/{uid}`.
    @discardableResult
    func fetchProfile(uid: String) async throws -> Profile? {
        if let cached = byUid[uid] { return cached }
        let doc = try await db.collection("users").document(uid).getDocument()
        guard let data = doc.data() else { return nil }
        let p = Profile(
            id: doc.documentID,
            handle: data["username"] as? String,
            handleLower: data["usernameLower"] as? String,
            displayName: data["displayName"] as? String,
            photoURL: data["photoURL"] as? String
        )
        byUid[p.id] = p
        if let hl = p.handleLower { byHandleLower[hl] = p }
        return p
    }

    /// Convenience: resolve @handle → Profile.
    func fetchProfile(handle: String) async throws -> Profile? {
        let noAt = handle.hasPrefix("@") ? String(handle.dropFirst()) : handle
        let lower = noAt.lowercased()
        if let cached = byHandleLower[lower] { return cached }
        guard let uid = try await resolveHandleToUid(handle) else { return nil }
        return try await fetchProfile(uid: uid)
    }

    // MARK: Type-ahead search

    /// Prefix search for users by handle or display name.
    /// Firestore can do prefix with startAt/endAt on a single field.
    /// We’ll try handle first, then displayNameLower as fallback.
    func searchUsers(prefix: String, limit: Int = 10) async throws -> [Profile] {
        let q = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        let lower = q.lowercased()
        let end = lower + "\u{f8ff}"

        // 1) Try handle prefix on usernameLower
        var results: [Profile] = []
        do {
            let snap = try await db.collection("users")
                .order(by: "usernameLower")
                .start(at: [lower])
                .end(at: [end])
                .limit(to: limit)
                .getDocuments()

            for d in snap.documents {
                let data = d.data()
                let p = Profile(
                    id: d.documentID,
                    handle: data["username"] as? String,
                    handleLower: data["usernameLower"] as? String,
                    displayName: data["displayName"] as? String,
                    photoURL: data["photoURL"] as? String
                )
                results.append(p)
            }
        } catch {
            // swallow; we’ll try display name query below
        }

        if results.count < limit {
            // 2) Top up with displayNameLower prefix if needed (and avoid dupes)
            let snap2 = try await db.collection("users")
                .order(by: "displayNameLower")
                .start(at: [lower])
                .end(at: [end])
                .limit(to: max(0, limit - results.count))
                .getDocuments()

            let existing = Set(results.map { $0.id })
            for d in snap2.documents {
                if existing.contains(d.documentID) { continue }
                let data = d.data()
                let p = Profile(
                    id: d.documentID,
                    handle: data["username"] as? String,
                    handleLower: data["usernameLower"] as? String,
                    displayName: data["displayName"] as? String,
                    photoURL: data["photoURL"] as? String
                )
                results.append(p)
            }
        }

        // update caches
        for p in results {
            byUid[p.id] = p
            if let hl = p.handleLower { byHandleLower[hl] = p }
        }
        return results
    }
}
