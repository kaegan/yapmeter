import SwiftUI

@main
struct SemaphoreApp: App {
    @State private var engine = SignalEngine()
    @State private var style = MenuBarStyle()

    var body: some Scene {
        MenuBarExtra {
            SemaphoreMenu(engine: engine, style: style)
        } label: {
            Image(nsImage: SignalHeadRenderer.menuBarImage(
                for: engine.aspect,
                speakingSeconds: engine.speakingSeconds,
                glyph: style.glyph,
                palette: style.palette
            ))
            .onAppear { engine.start() }
        }
    }
}
