//  PersonPickerView.swift
//  EchoTether
//
//  Shows a searchable list of @usernames from Firestore.
//  Reads from `usernames/{lower}` → { uid: String, updatedAt: Timestamp }
//
//  Firestore rules: your block has `allow read: if true;` for /usernames — perfect.

import SwiftUI
import FirebaseFirestore

struct PersonPickerView: View {
    var onPick: (UserLite) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var searchText: String = ""
    @State private var results: [UsernameDoc] = []
    @State private var loading = false
    @State private var errorText: String?

    private let db = Firestore.firestore()

    var body: some View {
        NavigationStack {
            List {
                if let err = errorText {
                    Text("⚠️ \(err)").foregroundStyle(.secondary)
                }

                if loading {
                    ProgressView("Searching…")
                }

                ForEach(results) { r in
                    Button {
                        // Build your existing lightweight model
                        let user = UserLite(
                            id: r.uid,
                            handle: "@\(r.username)",   // what you show in UI
                            displayName: nil            // optional: could fetch via callable if you want
                        )
                        onPick(user)
                        dismiss()
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "person.crop.circle")
                                .imageScale(.large)

                            VStack(alignment: .leading, spacing: 2) {
                                Text("@\(r.username)")
                                    .font(.headline)
                                Text(r.uid)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Select Person")
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search @handle")
            .onChange(of: searchText) { _, newValue in
                queryUsernames(prefix: newValue)
            }
            .onAppear {
                queryUsernames(prefix: "")
            }
        }
    }

    // MARK: - Firestore query (prefix search by docId = usernameLower)
    private func queryUsernames(prefix: String) {
        let trimmed = prefix
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        loading = true
        errorText = nil

        let handlesRef = db.collection("usernames")
        let fieldPath = FieldPath.documentID()

        let q: Query
        if trimmed.isEmpty {
            // no search: show recent/any (order by updatedAt desc)
            q = handlesRef
                .order(by: "updatedAt", descending: true)
                .limit(to: 25)
        } else {
            // prefix search: docId >= prefix AND docId < prefix+\uf8ff
            let end = trimmed + "\u{f8ff}"
            q = handlesRef
                .order(by: fieldPath)
                .start(at: [trimmed])
                .end(at: [end])
                .limit(to: 25)
        }

        q.getDocuments { snap, err in
            loading = false
            if let err = err {
                errorText = err.localizedDescription
                results = []
                return
            }
            let docs = snap?.documents ?? []
            results = docs.compactMap { d in
                let data = d.data()
                guard let uid = data["uid"] as? String else { return nil }
                return UsernameDoc(id: d.documentID, uid: uid)
            }
        }
    }
}

// MARK: - Small model for the picker
private struct UsernameDoc: Identifiable {
    let id: String      // lowercased username (docId)
    let uid: String

    var username: String { id } // already lower
}
