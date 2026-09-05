import SwiftUI

@main
struct YapmeterApp: App {
    @State private var engine = SignalEngine()
    @State private var preview = AspectPreview()
    @State private var updater = Updater()

    var body: some Scene {
        MenuBarExtra {
            YapmeterMenu(engine: engine, preview: preview, updater: updater)
        } label: {
            Image(nsImage: SignalHeadRenderer.menuBarImage(
                for: preview.isRunning ? preview.aspect : engine.aspect,
                speakingSeconds: preview.isRunning ? preview.speakingSeconds : engine.speakingSeconds
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
