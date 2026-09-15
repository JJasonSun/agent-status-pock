import Foundation
import AgentBridgeModels

/// Pure event → snapshot transition rules for one agent.
///
/// Everything here is a function of its inputs: no locks, no clocks, no I/O.
/// `AgentHub` owns the mutable bookkeeping (ordering, dwell, preferences)
/// and calls into this.
public enum AgentReducer {

    /// A tool state stays on the bar at least this long before a quieter
    /// state (thinking/answering/stop) may replace it.
    public static let toolDisplayDwell: TimeInterval = 1.2
    /// Events older than the newest applied one (minus this) are stale.
    public static let staleTolerance: TimeInterval = 0.05
    /// Active states with no events for this long fall back to ready.
    public static let inactivityTimeout: TimeInterval = 45
    /// How long `connected` is shown before it becomes ready.
    public static let connectedTransient: TimeInterval = 3
    /// How long `responseReady` is shown before it becomes ready.
    public static let responseReadyTransient: TimeInterval = 6

    /// Quiet events may be deferred while a tool label is still dwelling.
    public static func isQuietTransition(_ event: String) -> Bool {
        ["thinking", "answering", "stop", "session_end", "answer_done", "ready", "idle", "notification"]
            .contains(event)
    }

    /// Events that must not clear a sticky needs-input prompt.
    public static func isIgnoredWhileNeedsInput(_ event: String) -> Bool {
        ["thinking", "notification", "connected"].contains(event)
    }

    /// Fold one hook event into a snapshot. `at` is the wall-clock moment
    /// the event is applied (used for lastActive / transient windows) —
    /// not the event's own timestamp, which Hub uses only for ordering.
    public static func reduce(
        into current: AgentSnapshot,
        event: String,
        tool: String?,
        detail: String?,
        at now: TimeInterval
    ) -> AgentSnapshot {
        var status = current
        status.lastActive = now

        // Keep needsInput sticky: while a question is on the Touch Bar,
        // thinking/notification events must not overwrite it. Only a real
        // state change (tool_start, answering, stop, ready, session_start,
        // or a new needs_input) clears it.
        if status.status == .needsInput, isIgnoredWhileNeedsInput(event) {
            return status
        }

        switch event {
        case "session_start":
            status.status = .connected
            status.label = "\(status.agent.displayName) connected"
            status.tool = nil
            status.detail = nil
            status.transientUntil = now + connectedTransient

        case "thinking":
            status.status = .thinking
            status.label = "Thinking"
            status.tool = nil
            status.detail = detail
            status.transientUntil = nil

        case "answering":
            status.status = .answering
            status.label = "Writing the answer"
            status.tool = nil
            status.detail = nil
            status.transientUntil = nil

        case "tool_start":
            status.status = .working
            let toolName = tool ?? "tool"
            status.tool = toolName
            status.label = verb(for: toolName)
            status.detail = summarizedTarget(toolName: toolName, detail: detail)
            status.transientUntil = nil

        case "needs_input":
            status.status = .needsInput
            status.label = detail ?? "Needs your answer"
            status.tool = nil
            status.detail = nil
            status.transientUntil = nil

        case "ready", "idle":
            status.status = .ready
            status.label = "\(status.agent.displayName) is ready"
            status.tool = nil
            status.detail = nil
            status.transientUntil = nil

        case "stop", "session_end", "answer_done":
            status.status = .responseReady
            status.label = "Response ready"
            status.tool = nil
            status.detail = nil
            status.transientUntil = now + responseReadyTransient

        case "notification":
            if status.status == .idle || status.status == .ready {
                status.status = .ready
                status.label = detail ?? "\(status.agent.displayName) is ready"
            }
            status.transientUntil = nil

        default:
            break
        }

        return status
    }

    /// Time-based projection of a stored snapshot: expire transients and
    /// fall back to ready when an active state has gone quiet too long.
    /// Applied on every read/publish; does not mutate stored state.
    public static func project(_ snapshot: AgentSnapshot, now: TimeInterval) -> AgentSnapshot {
        var s = snapshot
        if let until = s.transientUntil, until < now {
            s.transientUntil = nil
            switch s.status {
            case .connected, .responseReady, .ready:
                s.status = .ready
                s.label = "\(s.name) is ready"
            default:
                break
            }
        }
        if s.status.isActiveWork, now - s.lastActive > inactivityTimeout {
            s.status = .ready
            s.label = "\(s.name) is ready"
            s.tool = nil
            s.detail = nil
            s.transientUntil = nil
        }
        return s
    }

    // MARK: Label composition

    public static func verb(for tool: String) -> String {
        let lower = tool.lowercased()
        // Order matters: TodoWrite contains "write", and "task" contains
        // "ask" — more specific names must be tested first.
        if lower.contains("todo") || lower.contains("plan") { return "Planning" }
        if lower.contains("task") || lower.contains("delegate") || lower.contains("subagent") {
            return "Delegating"
        }
        if lower.contains("ask") || lower.contains("question") { return "Asking" }
        if lower.contains("grep") || lower.contains("search") || lower.contains("find") || lower.contains("glob") {
            return "Searching"
        }
        if lower.contains("edit") || lower.contains("write") || lower.contains("patch") {
            return "Editing"
        }
        if lower.contains("read") || lower.contains("view") || lower.contains("cat ") {
            return "Reading"
        }
        if lower.contains("fetch") || lower.contains("web") || lower.contains("browse") || lower.contains("curl") {
            return "Browsing"
        }
        if lower.contains("test") || lower.contains("lint") || lower.contains("build") || lower.contains("install") {
            return "Testing"
        }
        if lower.contains("bash") || lower.contains("shell") || lower.contains("exec") || lower.contains("run") {
            return "Running"
        }
        return tool.replacingOccurrences(of: "_", with: " ").capitalized
    }

    /// Short, human target for the current action: file basename, command
    /// head, or search pattern.
    public static func summarizedTarget(toolName: String, detail: String?) -> String {
        guard var detail = detail, !detail.isEmpty else { return "" }
        detail = detail.split(separator: "|").first.map(String.init) ?? detail
        detail = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        if detail.hasPrefix("/") { // file path → basename
            detail = (detail as NSString).lastPathComponent
        }
        if detail.hasPrefix("{") { return "" }
        return String(detail.prefix(48))
    }
}
