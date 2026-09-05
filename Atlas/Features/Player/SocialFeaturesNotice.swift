import SwiftUI

/// Shown in place of comments / live chat when the age check hasn't allowed
/// social features. Offers a re-check when the user declined to share.
struct SocialFeaturesNotice: View {
    let gate: SocialFeaturesGate
    var onCheckAgain: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if gate.isChecking {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Checking age…").foregroundStyle(.secondary)
                }
            } else {
                Label(title, systemImage: "person.crop.circle.badge.exclamationmark")
                    .font(.subheadline.weight(.semibold))
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if gate.status == .declined || gate.status == .unknown {
                    Button("Check Age", action: onCheckAgain)
                        .buttonStyle(.bordered)
                        .font(.footnote.weight(.semibold))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(.secondarySystemFill)))
        .accessibilityElement(children: .combine)
    }

    private var title: String {
        switch gate.status {
        case .underage: "Comments and chat are off"
        case .declined, .unknown: "Comments and chat need an age check"
        case .allowed: ""
        }
    }

    private var message: String {
        switch gate.status {
        case .underage:
            "Comments, live chat, and chat replay aren’t available for users under 13."
        case .declined, .unknown:
            "Atlas uses your Apple Account’s declared age range to turn on comments and chat. Nothing about your age is stored beyond the result."
        case .allowed: ""
        }
    }
}
