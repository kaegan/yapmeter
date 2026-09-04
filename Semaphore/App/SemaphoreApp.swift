import SwiftUI

@main
struct SemaphoreApp: App {
    @State private var engine = SignalEngine()

    var body: some Scene {
        MenuBarExtra {
            SemaphoreMenu(engine: engine)
        } label: {
            Image(nsImage: SignalHeadRenderer.menuBarImage(
                for: engine.aspect,
                speakingSeconds: engine.speakingSeconds
            ))
            .onAppear { engine.start() }
        }
    }
}
