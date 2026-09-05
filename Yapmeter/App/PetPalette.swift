import AppKit

/// Yap's four live colours, from the pet brand board: strawberry, butter,
/// mint and sky. The dark aspect is always the label colour, so an asleep
/// pet is white on a dark menu bar and black on a light one, exactly like
/// the icons around it.
enum PetPalette {
    static func color(for aspect: Aspect) -> NSColor {
        switch aspect {
        case .dark: return .labelColor
        case .occupied: return NSColor(hex: 0xFF5C7A)
        case .caution, .preliminary: return NSColor(hex: 0xFFE27A)
        case .clear: return NSColor(hex: 0x7FE0A8)
        // Blue, not another signal colour: "you" needs to be unmistakable
        // against the red/yellow/green of the block itself.
        case .speaking: return NSColor(hex: 0x8ED0FF)
        }
    }
}

private extension NSColor {
    convenience init(hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}
