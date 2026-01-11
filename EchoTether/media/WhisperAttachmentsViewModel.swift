import Foundation
import FirebaseFirestore
import FirebaseFirestoreSwift

@MainActor
final class WhisperAttachmentsViewModel: ObservableObject {
    @Published var attachments: [Attachment] = []
    @Published var isLoading = false
    @Published var errorMessage: String?

    private let whisperId: String
    private let db = Firestore.firestore()

    init(whisperId: String) {
        self.whisperId = whisperId
    }

    func load() async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let snap = try await db.collection("whispers")
                .document(whisperId)
                .collection("attachments")
                .order(by: "createdAt", descending: false)
                .getDocuments()

            let decoded: [Attachment] = snap.documents.compactMap { doc in
                try? doc.data(as: Attachment.self)
            }
            self.attachments = decoded
        } catch {
            self.errorMessage = error.localizedDescription
            print("❌ attachments load error:", error.localizedDescription)
        }
    }
}
