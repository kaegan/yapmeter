import SwiftUI

@main
struct SemaphoreApp: App {
    @State private var engine = SignalEngine()
    @State private var style = MenuBarStyle()
    @State private var preview = AspectPreview()

    var body: some Scene {
        MenuBarExtra {
            SemaphoreMenu(engine: engine, style: style, preview: preview)
        } label: {
            Image(nsImage: SignalHeadRenderer.menuBarImage(
                for: preview.isRunning ? preview.aspect : engine.aspect,
                speakingSeconds: preview.isRunning ? preview.speakingSeconds : engine.speakingSeconds,
                glyph: style.glyph,
                palette: style.palette
            ))
            .onAppear { engine.start() }
            // A real meeting outranks the preview: the lamp must never show
            // a made-up state while someone is actually talking.
            .onChange(of: engine.aspect) { _, aspect in
                if aspect != .dark { preview.stop() }
            }
        }
    }
}
