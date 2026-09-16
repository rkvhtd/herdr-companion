// Modified from Herdrup https://github.com/jerryfane/herdrup commit 93c6578666e656c3206661389e81853bcc0b88da by Elysium Technologies.
import Foundation

// NO ActivityKit IMPORT. These wording tables are compiled only into the
// SwiftPM test product so they can run on Linux. The iOS companion app does
// not link this target.

struct AgentActivityState: Codable, Hashable {
    /// The agent shown in the headline — the session's highest-priority one.
    var headline: String
    /// That agent's bucket: drives the colour and the status word.
    var status: AgentActivityStatus
    /// How many agents are waiting on the user right now.
    var needsYouCount: Int
    /// How many of `needsYouCount` rest on a state the home could NOT confirm on its
    /// last poll: a federated agent on a degraded peer, whose blocked state is a
    /// last-known value rather than a live one. The lock screen and Dynamic Island have
    /// no room for a per-row marker, so the count is qualified in the summary line
    /// instead.
    ///
    /// A STORED-PROPERTY DEFAULT DOES NOT MAKE THIS DECODABLE FROM AN OLD PAYLOAD.
    /// An earlier version of this comment claimed it did; that was measured false.
    /// Synthesized `Decodable` calls `decode(Int.self, forKey:)` and throws
    /// `keyNotFound` when the key is absent, because stored-property defaults are
    /// invisible to Codable synthesis. Two directions actually break without help:
    /// this build reading an activity persisted by an older one (ActivityKit drops an
    /// undecodable activity, so it can never be reclaimed or ended), and a
    /// daemon-pushed payload minted before this field existed. The explicit
    /// `init(from:)` below uses `decodeIfPresent` for this ONE key to cover both.
    var unconfirmedCount: Int = 0
    /// How many agents are actively working right now.
    var workingCount: Int
    /// Total agents in the session.
    var totalCount: Int
    /// When the headline agent's CURRENT turn started (Unix SECONDS), set only
    /// while `status == .working`. Drives a live `Text(timerInterval:)` in the
    /// widget — the one thing iOS actually frame-interpolates in a Live Activity,
    /// so the working state shows real motion on the lock screen / Dynamic Island.
    /// A plain Double (not Date) so the daemon-pushed JSON decodes identically,
    /// dodging Swift's Date reference-date Codable strategy. `nil` when not working.
    var workingSince: Double?

    /// Hand-written for TWO additive directions, both of which otherwise make the whole
    /// activity undecodable, which ActivityKit answers by DROPPING the activity so it
    /// can never be reclaimed or ended.
    ///
    /// 1. An absent `unconfirmedCount`, from an activity persisted by, or a payload
    ///    minted by, a build predating the field. A stored-property default does not
    ///    help: Codable synthesis never consults it.
    /// 2. An UNRECOGNISED `status` word, from a newer app or daemon pushing a bucket
    ///    this widget binary lacks. Raw-value decoding throws `dataCorrupted` there,
    ///    which is the same drop-the-activity outcome as case 1. HerdrKit already
    ///    treats this hazard as first-class with `AgentStatus.unrecognised(String)`;
    ///    this file cannot carry that arm without a new case, so it falls back to
    ///    `.needsYou`, matching HerdrKit's rule that something uninterpretable
    ///    SURFACES rather than sinking. A wrongly-attention-grabbing lock screen is
    ///    recoverable; a silently dropped activity is not.
    ///
    /// Every OTHER field stays required exactly as synthesis would have it, so a
    /// genuinely malformed payload still fails loudly instead of decoding into a
    /// plausible zero.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        headline = try c.decode(String.self, forKey: .headline)
        let rawStatus = try c.decode(String.self, forKey: .status)
        status = AgentActivityStatus(rawValue: rawStatus) ?? .needsYou
        needsYouCount = try c.decode(Int.self, forKey: .needsYouCount)
        unconfirmedCount = try c.decodeIfPresent(Int.self, forKey: .unconfirmedCount) ?? 0
        workingCount = try c.decode(Int.self, forKey: .workingCount)
        totalCount = try c.decode(Int.self, forKey: .totalCount)
        workingSince = try c.decodeIfPresent(Double.self, forKey: .workingSince)
    }

    /// Restored because writing `init(from:)` suppresses the synthesized memberwise
    /// initialiser this type is constructed with everywhere else.
    init(headline: String, status: AgentActivityStatus, needsYouCount: Int, unconfirmedCount: Int = 0,
         workingCount: Int, totalCount: Int, workingSince: Double?) {
        self.headline = headline
        self.status = status
        self.needsYouCount = needsYouCount
        self.unconfirmedCount = unconfirmedCount
        self.workingCount = workingCount
        self.totalCount = totalCount
        self.workingSince = workingSince
    }
}

/// The display bucket. Mirrors HerdrKit's `AgentGroup` (needs-you / stopped /
/// working / idle) but is redeclared here so this shared file needs no HerdrKit
/// dependency. `.unrecognised` folds into `.needsYou` at the mapping site — an
/// uninterpretable agent surfaces, it does not sink.
enum AgentActivityStatus: String, Codable, Hashable {
    case needsYou
    case working
    case idle
    case stopped

    /// Short human word for the headline's status line.
    var label: String {
        switch self {
        case .needsYou: return "Needs you"
        case .working:  return "Working"
        case .idle:     return "Idle"
        case .stopped:  return "Stopped"
        }
    }
}

/// The summary wording for a Live Activity, in ONE place and in the ActivityKit-free file
/// so it is testable on Linux. Both widget layouts read it.
///
/// Kept in step with HerdrKit's `AgentList.needsYouSummary`, which serves the in-app roster
/// header. The two cannot be a single function: the widget target links only WidgetKit,
/// SwiftUI and ActivityKit and cannot see HerdrKit, and making HerdrKit depend on this
/// target would put these symbols in the app binary twice. So the wording is duplicated on
/// purpose, and BOTH copies are now pinned by tests against the same table.
enum AgentActivitySummary {
    static func line(_ s: AgentActivityState) -> String {
        if s.needsYouCount > 0 {
            // Every waiting agent rests on an unconfirmed state, so the whole claim is a
            // maybe: say so rather than appending a qualifier to an assertion.
            if s.unconfirmedCount >= s.needsYouCount { return "\(s.needsYouCount) may need you" }
            // Some confirmed and some not. Lead with the fact, name the doubt.
            if s.unconfirmedCount > 0 {
                return "\(s.needsYouCount) need you · \(s.unconfirmedCount) stale"
            }
            return "\(s.needsYouCount) need you"
        }
        if s.workingCount > 0 { return "\(s.workingCount) working" }
        return s.status.label
    }
}

