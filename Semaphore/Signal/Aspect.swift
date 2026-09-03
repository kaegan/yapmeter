import Foundation

/// The five states of the signal, borrowed from UK railway block signalling.
///
/// A "block" is the section of track (here: the conversational floor) that can
/// only be occupied by one train (speaker) at a time.
enum Aspect: String, CaseIterable, Sendable {
    /// No meeting audio detected. The signal is dark — not in service.
    case dark

    /// The other person is speaking. The block is occupied; hold your train.
    case occupied

    /// They just stopped. Early in the pause — could resume any moment.
    case caution

    /// The pause has lengthened past half the learned dwell time.
    /// The block is almost clear.
    case preliminary

    /// The pause has lengthened past the learned dwell time. Go.
    case clear

    /// Display name for the departure-board popover.
    var displayName: String {
        switch self {
        case .dark: return "OUT OF SERVICE"
        case .occupied: return "OCCUPIED"
        case .caution: return "CAUTION"
        case .preliminary: return "PRELIMINARY"
        case .clear: return "CLEAR"
        }
    }
}
