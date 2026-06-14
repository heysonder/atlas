import SwiftUI

/// Circular channel avatar.
struct Avatar: View {
    let url: String?
    var size: CGFloat = 40
    var body: some View {
        AsyncImage(url: url.flatMap(URL.init(string:))) { phase in
            switch phase {
            case .success(let image): image.resizable().scaledToFill()
            default: Circle().fill(.quaternary).overlay(
                Image(systemName: "person.fill").foregroundStyle(.secondary)
            )
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }
}
