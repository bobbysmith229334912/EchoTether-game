//
//  EchoTetherMimojiSyncService.swift
//  EchoTether-game
//
//  Universal Mimoji sync layer for EchoTether-game.
//  Safe design: no hardcoded user, no email-only identity lookup.
//

import Foundation
import FirebaseAuth
import FirebaseFirestore

@MainActor
final class EchoTetherMimojiSyncService: ObservableObject {
    static let shared = EchoTetherMimojiSyncService()

    @Published private(set) var activeMimoji: EchoTetherMimojiModel?
    @Published private(set) var publicMimojis: [EchoTetherMimojiModel] = []
    @Published private(set) var diagnostics = EchoTetherMimojiDiagnostics()
    @Published private(set) var isLoading = false

    private let db = Firestore.firestore()

    private init() {}

    func refresh() async {
        let uid = Auth.auth().currentUser?.uid
        var checked: [String] = []

        guard let uid else {
            activeMimoji = nil
            publicMimojis = []
            diagnostics = EchoTetherMimojiDiagnostics(
                isSignedIn: false,
                currentUid: nil,
                activeMimojiFound: false,
                resolvedModelURLFound: false,
                checkedSources: checked,
                message: "Signed out. EchoTether can still load, but no personal Mimoji can be resolved."
            )
            return
        }

        isLoading = true

        do {
            let active = try await loadActiveMimoji(uid: uid, checkedSources: &checked)
            let publicItems = try await loadPublicMimojis(currentUid: uid, checkedSources: &checked)

            activeMimoji = active
            publicMimojis = publicItems
            diagnostics = EchoTetherMimojiDiagnostics(
                isSignedIn: true,
                currentUid: uid,
                activeMimojiFound: active != nil,
                resolvedModelURLFound: active?.resolvedModelURL != nil,
                checkedSources: checked,
                message: active == nil ? "No active Mimoji found yet. App should show a safe connect/create prompt." : "Active Mimoji connection resolved."
            )
        } catch {
            diagnostics = EchoTetherMimojiDiagnostics(
                isSignedIn: true,
                currentUid: uid,
                activeMimojiFound: activeMimoji != nil,
                resolvedModelURLFound: activeMimoji?.resolvedModelURL != nil,
                checkedSources: checked,
                message: "Mimoji sync error: \(error.localizedDescription)"
            )
        }

        isLoading = false
    }

    private func loadActiveMimoji(
        uid: String,
        checkedSources: inout [String]
    ) async throws -> EchoTetherMimojiModel? {
        let directPaths = [
            "users/\(uid)/echoMimojis/active",
            "users/\(uid)/activeMimoji/current"
        ]

        for path in directPaths {
            checkedSources.append(path)
            let doc = try await db.document(path).getDocument()
            if doc.exists, let model = decode(doc: doc, fallbackOwnerUid: uid) {
                return model
            }
        }

        checkedSources.append("users/\(uid)/mimojis newest")
        let userMimojis = try await db
            .collection("users")
            .document(uid)
            .collection("mimojis")
            .order(by: "updatedAt", descending: true)
            .limit(to: 1)
            .getDocuments()

        if let doc = userMimojis.documents.first,
           let model = decode(doc: doc, fallbackOwnerUid: uid) {
            return model
        }

        checkedSources.append("echoTetherMimojis ownerUid == current uid")
        let owned = try await db
            .collection("echoTetherMimojis")
            .whereField("ownerUid", isEqualTo: uid)
            .limit(to: 1)
            .getDocuments()

        if let doc = owned.documents.first,
           let model = decode(doc: doc, fallbackOwnerUid: uid) {
            return model
        }

        return nil
    }

    private func loadPublicMimojis(
        currentUid: String,
        checkedSources: inout [String]
    ) async throws -> [EchoTetherMimojiModel] {
        checkedSources.append("echoTetherMimojis isPublicForEchoTether == true")

        let snap = try await db
            .collection("echoTetherMimojis")
            .whereField("isPublicForEchoTether", isEqualTo: true)
            .limit(to: 25)
            .getDocuments()

        return snap.documents.compactMap { decode(doc: $0, fallbackOwnerUid: currentUid) }
    }

    private func decode(
        doc: DocumentSnapshot,
        fallbackOwnerUid: String
    ) -> EchoTetherMimojiModel? {
        let data = doc.data() ?? [:]

        let ownerUid = data["ownerUid"] as? String ?? data["uid"] as? String ?? data["userId"] as? String ?? fallbackOwnerUid
        let displayName = data["displayName"] as? String ?? data["name"] as? String ?? data["title"] as? String ?? "My Mimoji"
        let usdzURL = data["usdzURL"] as? String ?? data["modelURL"] as? String ?? data["modelUrl"] as? String
        let avatarUSDZURL = data["avatarUSDZURL"] as? String ?? data["avatarUsdzUrl"] as? String
        let previewImageURL = data["previewImageURL"] as? String ?? data["imageURL"] as? String ?? data["thumbnailURL"] as? String
        let isPublic = data["isPublicForEchoTether"] as? Bool ?? data["isPublic"] as? Bool ?? false
        let createdAt = (data["createdAt"] as? Timestamp)?.dateValue()
        let updatedAt = (data["updatedAt"] as? Timestamp)?.dateValue()

        return EchoTetherMimojiModel(
            id: doc.documentID,
            ownerUid: ownerUid,
            displayName: displayName,
            usdzURL: usdzURL,
            avatarUSDZURL: avatarUSDZURL,
            previewImageURL: previewImageURL,
            isPublicForEchoTether: isPublic,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }
}
