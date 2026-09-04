import SwiftUI

/// The full four-lamp signal head, for the popover. This is where the railway
/// metaphor earns its keep: the menu bar shows one lamp because that's all
/// 18 points can carry, but here there's room to show the double yellow.
///
/// Lamp order matches a UK four-aspect head reading bottom-to-top, laid out
/// left-to-right: red, then the two yellows, then green.
struct SignalHeadView: View {
    let aspect: Aspect

    private static let lampColors: [Color] = [.red, .yellow, .yellow, .green]

    var body: some View {
        HStack(spacing: 8) {
            ForEach(0..<4, id: \.self) { index in
                lamp(at: index)
            }
            if aspect == .speaking {
                // You're not in the block ahead, you're in this one. The head
                // stays dark and a separate marker says so.
                Text("YOU")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.blue)
                    .padding(.leading, 2)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(.black.opacity(0.35))
        )
        .animation(.easeOut(duration: 0.12), value: aspect)
    }

    @ViewBuilder
    private func lamp(at index: Int) -> some View {
        let isLit = litLampIndices.contains(index)
        let color = Self.lampColors[index]
        Circle()
            .fill(isLit ? color : Color.white.opacity(0.12))
            .frame(width: 14, height: 14)
            .shadow(color: isLit ? color.opacity(0.8) : .clear, radius: 5)
    }

    /// Which lamp positions are lit. `dark` and `speaking` light nothing:
    /// neither is a statement about the block ahead.
    private var litLampIndices: Set<Int> {
        switch aspect {
        case .dark, .speaking: return []
        case .occupied: return [0]
        case .caution: return [1]
        case .preliminary: return [1, 2]
        case .clear: return [3]
        }
    }
}
