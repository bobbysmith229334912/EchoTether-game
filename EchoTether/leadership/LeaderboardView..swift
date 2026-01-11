import SwiftUI
import FirebaseFunctions

struct LeaderboardEntry: Identifiable {
    let id: String          // uid
    let username: String
    let totalEarnedCents: Int

    var totalEarnedDollars: String {
        String(format: "$%.2f", Double(totalEarnedCents) / 100.0)
    }
}

@MainActor
final class LeaderboardViewModel: ObservableObject {
    @Published var entries: [LeaderboardEntry] = []
    @Published var isLoading: Bool = false
    @Published var errorMessage: String?

    private let functions = Functions.functions()

    func loadTopEarners(limit: Int = 10) {
        isLoading = true
        errorMessage = nil
        entries = []

        let data: [String: Any] = [
            "limit": limit
        ]

        functions.httpsCallable("leaderboardTopEarners").call(data) { [weak self] result, error in
            Task { @MainActor in
                guard let self = self else { return }
                self.isLoading = false

                if let error = error {
                    self.errorMessage = error.localizedDescription
                    return
                }

                guard
                    let root = result?.data as? [String: Any],
                    let success = root["success"] as? Bool,
                    success,
                    let rawEntries = root["entries"] as? [[String: Any]]
                else {
                    self.errorMessage = "Unable to load leaderboard."
                    return
                }

                self.entries = rawEntries.compactMap { item in
                    let uid =
                        (item["uid"] as? String) ??
                        (item["id"] as? String) ??
                        ""

                    let cents = item["totalEarnedCents"] as? Int ?? 0
                    guard !uid.isEmpty, cents > 0 else { return nil }

                    let nameRaw =
                        (item["username"] as? String) ??
                        (item["usernameLower"] as? String) ??
                        String(uid.prefix(6))

                    let username = nameRaw
                        .trimmingCharacters(in: .whitespacesAndNewlines)

                    return LeaderboardEntry(
                        id: uid,
                        username: username.isEmpty ? "User" : username,
                        totalEarnedCents: cents
                    )
                }
            }
        }
    }
}

struct LeaderboardView: View {
    @StateObject private var vm = LeaderboardViewModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Top EchoTether Earners")
                .font(.title.bold())

            if let error = vm.errorMessage {
                Text(error)
                    .font(.footnote)
                    .foregroundColor(.red)
            }

            if vm.isLoading {
                ProgressView()
                    .progressViewStyle(.circular)
            }

            if vm.entries.isEmpty && !vm.isLoading {
                Text("No earnings yet. Be the first to earn from Whispers and referrals.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            } else {
                List {
                    ForEach(Array(vm.entries.enumerated()), id: \.1.id) { index, entry in
                        HStack(spacing: 12) {
                            Text("#\(index + 1)")
                                .font(.headline)
                                .frame(width: 32, alignment: .leading)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.username)
                                    .font(.headline)
                                Text(entry.totalEarnedDollars)
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                            }

                            Spacer()
                        }
                        .padding(.vertical, 4)
                    }
                }
                .listStyle(.plain)
            }

            Spacer()
        }
        .padding()
        .onAppear {
            vm.loadTopEarners()
        }
    }
}
