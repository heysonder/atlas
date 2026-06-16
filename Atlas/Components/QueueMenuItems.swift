import SwiftUI

struct QueueMenuItems: View {
    let request: PlayRequest

    @Environment(AppModel.self) private var app

    var body: some View {
        Button("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") {
            app.playNext(request)
        }
        Button("Add to Queue", systemImage: "text.line.last.and.arrowtriangle.forward") {
            app.addToQueue(request)
        }
    }
}
