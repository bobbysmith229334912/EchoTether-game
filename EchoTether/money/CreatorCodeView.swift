import SwiftUI

struct CreatorCodeView: View {
    var onApply: (String) -> Void
    var onSkip: () -> Void

    @State private var code: String = ""
    @State private var showError = false

    var body: some View {
        VStack(spacing: 16) {
            Text("Got a creator code?")
                .font(.title3).bold()

            Text("Support your favorite creator by entering their code.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            TextField("Enter code (e.g., JORDAN)", text: $code)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled(true)
                .padding(12)
                .background(Color.secondary.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 12))

            Button {
                let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty {
                    showError = true
                } else {
                    onApply(trimmed)
                }
            } label: {
                Text("Apply Code")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)

            Button("Skip for now") { onSkip() }
                .foregroundStyle(.secondary)

            if showError {
                Text("Please enter a code or tap Skip.")
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
        .padding(24)
        .presentationDetents([.fraction(0.35), .medium])
    }
}
