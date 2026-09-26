import Foundation

// Single source of truth for the bridge ↔ widget JSON contract.
// Both AgentBridge (SPM) and the Pock widget (swiftc) compile this file.

// MARK: - Agents

public enum AgentID: String, Codable, CaseIterable, Sendable {
    case claude
    case codex
    case opencode

    public var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .opencode: return "OpenCode"
        }
    }

    public var symbol: String {
        switch self {
        case .claude: return "sparkles"
        case .codex: return "bolt.fill"
        case .opencode: return "terminal.fill"
        }
    }

    /// Brand color (hex RRGGBB).
    public var color: String {
        switch self {
        case .claude: return "D97757"   // Claude clay
        case .codex: return "10A37F"    // OpenAI teal
        case .opencode: return "8B5CF6" // opencode violet
        }
    }
}

public enum AgentStatus: String, Codable, Sendable {
    case idle              // no session ever seen
    case ready             // session open, nothing happening
    case connected         // transient: session just started
    case thinking
    case answering
    case working
    case needsInput
    case responseReady     // transient: answer just finished

    /// Statuses that mean the agent is doing something worth watching.
    public var isAttention: Bool {
        switch self {
        case .connected, .thinking, .answering, .working, .needsInput, .responseReady:
            return true
        case .idle, .ready:
            return false
        }
    }

    /// Active work that should shimmer / stay white on the bar.
    public var isActiveWork: Bool {
        switch self {
        case .thinking, .answering, .working:
            return true
        case .idle, .ready, .connected, .needsInput, .responseReady:
            return false
        }
    }
}

public struct AgentSnapshot: Codable, Sendable {
    public let agent: AgentID
    public let name: String
    public let symbol: String
    public let color: String
    public var status: AgentStatus
    public var label: String
    public var tool: String?
    public var detail: String?
    public var lastActive: TimeInterval
    public var transientUntil: TimeInterval?

    public init(
        agent: AgentID,
        name: String,
        symbol: String,
        color: String,
        status: AgentStatus,
        label: String,
        tool: String? = nil,
        detail: String? = nil,
        lastActive: TimeInterval = 0,
        transientUntil: TimeInterval? = nil
    ) {
        self.agent = agent
        self.name = name
        self.symbol = symbol
        self.color = color
        self.status = status
        self.label = label
        self.tool = tool
        self.detail = detail
        self.lastActive = lastActive
        self.transientUntil = transientUntil
    }

    public static func idleTemplate(for agent: AgentID) -> AgentSnapshot {
        AgentSnapshot(
            agent: agent,
            name: agent.displayName,
            symbol: agent.symbol,
            color: agent.color,
            status: .idle,
            label: "No agent running"
        )
    }
}

// MARK: - Codex quota

public struct UsageInfo: Codable, Sendable {
    public let remainingPercent: Int
    public let usedPercent: Int
    public let windowLabel: String
    public let windowMinutes: Double
    public let resetsAt: TimeInterval?
    public let planType: String?
    public let unlimited: Bool
    /// Whether the reading has aged past the monitor's stale threshold.
    /// Recomputed on every bridge read, so a snapshot taken seconds ago is not stale.
    public var stale: Bool
    /// "live" (app-server query) or "session" (recorded snapshot).
    public let source: String
    /// When the underlying number was observed; keeps the freshest reading
    /// when both sources are available.
    public let fetchedAt: TimeInterval

    public init(
        remainingPercent: Int,
        usedPercent: Int,
        windowLabel: String,
        windowMinutes: Double,
        resetsAt: TimeInterval?,
        planType: String?,
        unlimited: Bool,
        stale: Bool,
        source: String,
        fetchedAt: TimeInterval
    ) {
        self.remainingPercent = remainingPercent
        self.usedPercent = usedPercent
        self.windowLabel = windowLabel
        self.windowMinutes = windowMinutes
        self.resetsAt = resetsAt
        self.planType = planType
        self.unlimited = unlimited
        self.stale = stale
        self.source = source
        self.fetchedAt = fetchedAt
    }
}

// MARK: - System memory

public struct MemoryInfo: Codable, Sendable {
    public let usedBytes: UInt64
    public let totalBytes: UInt64
    public let usedPercent: Int
    public let fetchedAt: TimeInterval

    public init(usedBytes: UInt64, totalBytes: UInt64, usedPercent: Int, fetchedAt: TimeInterval) {
        self.usedBytes = usedBytes
        self.totalBytes = totalBytes
        self.usedPercent = usedPercent
        self.fetchedAt = fetchedAt
    }
}

// MARK: - Bridge payload

public struct BridgeState: Codable, Sendable {
    public let agents: [AgentSnapshot]
    /// Codex quota reading, when one is available. Optional so older
    /// widgets that only decode `agents` keep working.
    public let usage: UsageInfo?
    /// System RAM reading for the Touch Bar chip.
    public let memory: MemoryInfo?

    public init(agents: [AgentSnapshot], usage: UsageInfo? = nil, memory: MemoryInfo? = nil) {
        self.agents = agents
        self.usage = usage
        self.memory = memory
    }
}
