import SwiftUI

@main
struct YapmeterApp: App {
    @State private var engine = SignalEngine()

    var body: some Scene {
        MenuBarExtra {
            PopoverView(engine: engine)
        } label: {
            Image(nsImage: SignalHeadRenderer.menuBarImage(
                for: engine.aspect,
                speakingSeconds: engine.speakingSeconds
            ))
            .onAppear { engine.start() }
        }
        .menuBarExtraStyle(.window)
    }
}
