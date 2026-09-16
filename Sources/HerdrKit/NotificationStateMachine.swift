import Foundation

public struct NotificationAgentObservation: Codable, Equatable, Sendable {
    public let session: String
    public let workspaceID: String
    public let paneID: String
    public let terminalID: String
    /// Helper-private keyed digest of the complete official agent-session
    /// identity. Raw path-kind values are deliberately not persisted.
    public let agentInstanceID: String
    public let status: String?
    public let stateChangeSequence: UInt64?
    /// Available only for the current in-memory snapshot so a destination can
    /// derive its per-registration APNs binding. Excluded from Codable storage.
    public let agentSession: AgentSessionInfo?

    public init(
        session: String,
        workspaceID: String,
        paneID: String,
        terminalID: String,
        agentInstanceID: String,
        status: String?,
        stateChangeSequence: UInt64?,
        agentSession: AgentSessionInfo? = nil
    ) {
        self.session = session
        self.workspaceID = workspaceID
        self.paneID = paneID
        self.terminalID = terminalID
        self.agentInstanceID = agentInstanceID
        self.status = status
        self.stateChangeSequence = stateChangeSequence
        self.agentSession = agentSession
    }

    public init?(session: String, agent: AgentInfo, installationID: String) {
        guard OfficialHerdrSession(name: session) != nil,
              !agent.paneID.isEmpty,
              let workspaceID = agent.workspaceID, !workspaceID.isEmpty,
              let terminalID = agent.terminalID, !terminalID.isEmpty,
              let agentSession = agent.agentSession,
              let agentInstanceID = NotificationAgentBinding.transitionIdentity(
                  for: agentSession, installationID: installationID) else { return nil }
        self.init(session: session, workspaceID: workspaceID, paneID: agent.paneID,
                  terminalID: terminalID, agentInstanceID: agentInstanceID,
                  status: agent.agentStatus, stateChangeSequence: agent.stateChangeSeq,
                  agentSession: agentSession)
    }

    public var identity: String {
        [session, terminalID, agentInstanceID].joined(separator: "\u{1f}")
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.session == rhs.session
            && lhs.workspaceID == rhs.workspaceID
            && lhs.paneID == rhs.paneID
            && lhs.terminalID == rhs.terminalID
            && lhs.agentInstanceID == rhs.agentInstanceID
            && lhs.status == rhs.status
            && lhs.stateChangeSequence == rhs.stateChangeSequence
    }

    enum CodingKeys: String, CodingKey {
        case session, status
        case workspaceID = "workspace_id"
        case paneID = "pane_id"
        case terminalID = "terminal_id"
        case agentInstanceID = "agent_instance_id"
        case stateChangeSequence = "state_change_seq"
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            session: try values.decode(String.self, forKey: .session),
            workspaceID: try values.decode(String.self, forKey: .workspaceID),
            paneID: try values.decode(String.self, forKey: .paneID),
            terminalID: try values.decode(String.self, forKey: .terminalID),
            agentInstanceID: try values.decode(String.self, forKey: .agentInstanceID),
            status: try values.decodeIfPresent(String.self, forKey: .status),
            stateChangeSequence: try values.decodeIfPresent(
                UInt64.self, forKey: .stateChangeSequence))
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(session, forKey: .session)
        try values.encode(workspaceID, forKey: .workspaceID)
        try values.encode(paneID, forKey: .paneID)
        try values.encode(terminalID, forKey: .terminalID)
        try values.encode(agentInstanceID, forKey: .agentInstanceID)
        try values.encodeIfPresent(status, forKey: .status)
        try values.encodeIfPresent(stateChangeSequence, forKey: .stateChangeSequence)
    }
}

public struct CompanionNotificationEvent: Codable, Equatable, Sendable {
    public let kind: CompanionNotificationKind
    public let observation: NotificationAgentObservation
    public let eventID: String

    public init(kind: CompanionNotificationKind, observation: NotificationAgentObservation) {
        self.kind = kind
        self.observation = observation
        self.eventID = [
            kind.rawValue, observation.session, observation.terminalID,
            observation.paneID, observation.workspaceID, observation.agentInstanceID,
            observation.stateChangeSequence.map(String.init) ?? observation.status ?? "unknown",
        ].joined(separator: "\u{1f}")
    }
}

public struct NotificationTransitionState: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var observation: NotificationAgentObservation
        public var lastSeenUnixSeconds: UInt64
        public var lastDeliveredEventID: String?

        public init(
            observation: NotificationAgentObservation,
            lastSeenUnixSeconds: UInt64,
            lastDeliveredEventID: String? = nil
        ) {
            self.observation = observation
            self.lastSeenUnixSeconds = lastSeenUnixSeconds
            self.lastDeliveredEventID = lastDeliveredEventID
        }
    }

    public var entries: [String: Entry]

    public init(entries: [String: Entry] = [:]) { self.entries = entries }
}

/// Pure transition interpreter. It never reads terminal output and never treats a
/// missing pane, unknown status, initial idle, reconnect, or changed terminal id as completion.
public struct NotificationTransitionEngine: Sendable {
    public enum SnapshotReason: Sendable {
        case initial
        case liveEvent
        case reconnect
    }

    public static let maximumEntries = 4_096
    public static let retentionSeconds: UInt64 = 7 * 24 * 60 * 60

    public private(set) var state: NotificationTransitionState

    public init(state: NotificationTransitionState = NotificationTransitionState()) {
        self.state = state
    }

    /// Convenience for one-session callers/tests. The helper uses the explicit
    /// `snapshotSession` overload so an empty roster cannot affect another
    /// registered session.
    @discardableResult
    public mutating func ingest(
        _ observations: [NotificationAgentObservation],
        reason: SnapshotReason,
        nowUnixSeconds: UInt64
    ) -> [CompanionNotificationEvent] {
        let session = observations.first?.session
            ?? state.entries.values.first?.observation.session
            ?? OfficialHerdrSession.defaultName
        return ingest(
            observations, snapshotSession: session,
            reason: reason, nowUnixSeconds: nowUnixSeconds)
    }

    @discardableResult
    public mutating func ingest(
        _ observations: [NotificationAgentObservation],
        snapshotSession: String,
        reason: SnapshotReason,
        nowUnixSeconds: UInt64
    ) -> [CompanionNotificationEvent] {
        var events: [CompanionNotificationEvent] = []
        let valid = observations.filter(Self.isValid)

        // `agent.list` is an atomic roster for one official session. Removing
        // identities absent from the new roster prevents a later process in the
        // same pane/terminal from inheriting state or sequence numbers, even if
        // it happens to report the same raw session identity again.
        let currentIdentities = Set(valid.map(\.identity))
        state.entries = state.entries.filter {
            $0.value.observation.session != snapshotSession
                || currentIdentities.contains($0.key)
        }

        for current in valid {
            let prior = state.entries[current.identity]
            if let priorSequence = prior?.observation.stateChangeSequence,
               let currentSequence = current.stateChangeSequence,
               currentSequence <= priorSequence {
                var retained = prior!
                retained.lastSeenUnixSeconds = nowUnixSeconds
                state.entries[current.identity] = retained
                continue
            }
            let event = Self.transition(from: prior?.observation, to: current, reason: reason)
            var entry = NotificationTransitionState.Entry(
                observation: current,
                lastSeenUnixSeconds: nowUnixSeconds,
                lastDeliveredEventID: prior?.lastDeliveredEventID)

            if let event, event.eventID != prior?.lastDeliveredEventID {
                events.append(event)
                entry.lastDeliveredEventID = event.eventID
            } else if prior?.observation.status != current.status {
                // Leaving an alerting state arms the next cycle even when an
                // older server does not provide a state-change sequence.
                entry.lastDeliveredEventID = nil
            }
            state.entries[current.identity] = entry
        }

        prune(nowUnixSeconds: nowUnixSeconds)
        return events
    }

    private static func transition(
        from prior: NotificationAgentObservation?,
        to current: NotificationAgentObservation,
        reason: SnapshotReason
    ) -> CompanionNotificationEvent? {
        guard let prior,
            prior.terminalID == current.terminalID,
              prior.agentInstanceID == current.agentInstanceID,
              prior.paneID == current.paneID,
              prior.workspaceID == current.workspaceID else { return nil }
        let old = normalized(prior.status)
        let new = normalized(current.status)
        guard old != new else { return nil }

        // A positively observed blocked state is actionable even when discovered
        // after a reconnect. Persisted state + event id prevents a restart storm.
        if new == "blocked" {
            return CompanionNotificationEvent(kind: .needsAttention, observation: current)
        }

        // Completion requires an uninterrupted live observation of the same agent
        // leaving working. Reconnect is deliberately excluded: network loss is not
        // evidence that a response ended.
        if reason == .liveEvent, old == "working", new == "idle" || new == "done" {
            return CompanionNotificationEvent(kind: .finishedResponding, observation: current)
        }
        return nil
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        switch value {
        case "working", "blocked", "idle", "done", "unknown": return value
        default: return nil
        }
    }

    private static func isValid(_ observation: NotificationAgentObservation) -> Bool {
        OfficialHerdrSession(name: observation.session) != nil
            && NotificationHelperRequest.isSafeOpaqueID(observation.workspaceID)
            && NotificationHelperRequest.isSafeOpaqueID(observation.paneID)
            && NotificationHelperRequest.isSafeOpaqueID(observation.terminalID)
            && NotificationAgentBinding.isValidDigest(observation.agentInstanceID)
    }

    private mutating func prune(nowUnixSeconds: UInt64) {
        state.entries = state.entries.filter {
            nowUnixSeconds < $0.value.lastSeenUnixSeconds
                || nowUnixSeconds - $0.value.lastSeenUnixSeconds <= Self.retentionSeconds
        }
        guard state.entries.count > Self.maximumEntries else { return }
        let keep = state.entries.values
            .sorted { $0.lastSeenUnixSeconds > $1.lastSeenUnixSeconds }
            .prefix(Self.maximumEntries)
        state.entries = Dictionary(uniqueKeysWithValues: keep.map { ($0.observation.identity, $0) })
    }
}
