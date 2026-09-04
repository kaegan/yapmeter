import Foundation

/// The states of the signal, borrowed from UK railway block signalling.
///
/// A "block" is the section of track (here: the conversational floor) that can
/// only be occupied by one train (speaker) at a time. The railway vocabulary
/// stays in the code; what the user reads is plain English.
enum Aspect: String, CaseIterable, Sendable {
    /// No meeting detected. The signal is dark — not in service.
    case dark

    /// You are the train in the block. Shown with your turn's elapsed time.
    case speaking

    /// The other person is speaking. The block is occupied; hold your train.
    case occupied

    /// They just stopped. Early in the pause — could resume any moment.
    case caution

    /// The pause has lengthened past half the dwell time.
    /// The block is almost clear.
    case preliminary

    /// The pause has lengthened past the dwell time. Go.
    case clear

    /// What the menu bar lamp means, in plain words. The lamp carries the
    /// state visually; this is its accessibility description.
    var displayName: String {
        switch self {
        case .dark: return "No meeting"
        case .speaking: return "Your turn"
        case .occupied: return "Someone's speaking"
        case .caution: return "They paused"
        case .preliminary: return "Almost clear"
        case .clear: return "Clear to speak"
        }
    }
}
