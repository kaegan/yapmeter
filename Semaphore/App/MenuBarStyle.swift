import AppKit
import Observation

/// Which drawing the status item shows. All of the candidates from the brand
/// exploration are here so each can be lived with for a day before one wins;
/// the losers get deleted once that happens.
enum GlyphStyle: String, CaseIterable, Sendable {
    /// The original single lamp: a disc in the aspect's colour.
    case lamp
    /// Round one's pet: a speech-bubble blob with eyes, a tail and a face
    /// for each state.
    case petClassic
    /// The bubble with no eyes. The mouth is the whole message: zipped,
    /// a small o, a grin, wide open.
    case petMouth
    /// Hollow while it isn't your turn, solid when it is. The face rides on
    /// top; it puffs up on a long turn.
    case petHollowSolid
    /// Two pets: them on the left, you on the right. Whoever's mouth is
    /// open is talking.
    case petPair
    /// A semaphore arm. Horizontal is stop, dropped is clear.
    case semaphoreArm
    /// A signal head on its side, with the live lamp drawn big.
    case wideHead
    /// A striped level-crossing barrier. Down is stop, up is clear.
    case crossingBarrier

    var displayName: String {
        switch self {
        case .lamp: return "Lamp"
        case .petClassic: return "Pet"
        case .petMouth: return "Pet, mouth only"
        case .petHollowSolid: return "Pet, hollow or solid"
        case .petPair: return "Two pets"
        case .semaphoreArm: return "Semaphore arm"
        case .wideHead: return "Wide signal head"
        case .crossingBarrier: return "Crossing barrier"
        }
    }
}

/// The four live colours the glyph can wear. The dark aspect is always the
/// secondary label colour so an out-of-service signal looks like part of the
/// menu bar rather than a fifth colour.
enum LampPalette: String, CaseIterable, Sendable {
    /// macOS system red, yellow, green and blue: what the app shipped with.
    case system
    /// Round one's pet board: bubblegum, butter, mint and sky.
    case pet
    /// Round one's railway board: the aspect colours of a colour-light signal.
    case railway

    var displayName: String {
        switch self {
        case .system: return "System"
        case .pet: return "Pet pastels"
        case .railway: return "Railway"
        }
    }

    func color(for aspect: Aspect) -> NSColor {
        switch aspect {
        case .dark: return .secondaryLabelColor
        case .occupied: return red
        case .caution, .preliminary: return amber
        case .clear: return green
        // Blue, not another lamp colour: "you" needs to be unmistakable
        // against the red/yellow/green of the block itself.
        case .speaking: return blue
        }
    }

    private var red: NSColor {
        switch self {
        case .system: return .systemRed
        case .pet: return NSColor(hex: 0xFF8FB1)
        case .railway: return NSColor(hex: 0xE8352B)
        }
    }

    private var amber: NSColor {
        switch self {
        case .system: return .systemYellow
        case .pet: return NSColor(hex: 0xFFE27A)
        case .railway: return NSColor(hex: 0xF6A800)
        }
    }

    private var green: NSColor {
        switch self {
        case .system: return .systemGreen
        case .pet: return NSColor(hex: 0x7FE0A8)
        case .railway: return NSColor(hex: 0x23A055)
        }
    }

    private var blue: NSColor {
        switch self {
        case .system: return .systemBlue
        case .pet: return NSColor(hex: 0x8ED0FF)
        case .railway: return NSColor(hex: 0x2F6BFF)
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

/// The user's choice of glyph and palette, persisted like sensitivity is.
/// Separate from `SignalEngine` because the engine is about audio and this
/// is about paint.
@MainActor
@Observable
final class MenuBarStyle {
    var glyph: GlyphStyle {
        didSet {
            guard glyph != oldValue else { return }
            UserDefaults.standard.set(glyph.rawValue, forKey: Self.glyphKey)
        }
    }

    var palette: LampPalette {
        didSet {
            guard palette != oldValue else { return }
            UserDefaults.standard.set(palette.rawValue, forKey: Self.paletteKey)
        }
    }

    private static let glyphKey = "menuBarGlyph"
    private static let paletteKey = "menuBarPalette"

    init() {
        let defaults = UserDefaults.standard
        glyph = defaults.string(forKey: Self.glyphKey).flatMap(GlyphStyle.init(rawValue:)) ?? .lamp
        palette = defaults.string(forKey: Self.paletteKey).flatMap(LampPalette.init(rawValue:)) ?? .system
    }
}
