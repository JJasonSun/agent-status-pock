import Foundation
import AgentBridgeModels
import AgentBridgeCore

// MARK: - Activity hub

/// Owns mutable per-agent bookkeeping (ordering, dwell, preferences) and
/// folds events through the pure `AgentReducer`. Not itself a state machine.
final class AgentHub: @unchecked Sendable {

    private let lock = NSLock()
    private var statuses: [AgentID: AgentSnapshot] = [:]
    /// Supplies the Codex quota chip; refreshes itself in the background.
    let usageMonitor = UsageMonitor()
    /// Invoked after the hub lock is released whenever an event mutated state.
    /// Used to push a fresh snapshot to the state file; must not re-enter Hub.
    var onStateChange: (() -> Void)?
    // Per-agent ordering + display-dwell bookkeeping.
    private var lastEventAt: [AgentID: Double] = [:]
    private var labelSetAt: [AgentID: Double] = [:]
    private var heldEvent: [AgentID: HeldEvent] = [:]
    /// Open tool calls per agent. PostToolUse only settles the bar when this
    /// hits zero, so parallel tools stay on the working label.
    private var toolsInFlight: [AgentID: Int] = [:]
    /// When each agent last saw a tool_start — used to resync the counter.
    private var lastToolStartAt: [AgentID: Double] = [:]

    /// Starts within this window count as a parallel burst and increment
    /// the in-flight counter. A later start is treated as sequential and
    /// resets the counter to 1, so a missing PostToolUse cannot pin it
    /// positive forever (Codex fires far fewer PostToolUse than PreToolUse).
    static let parallelStartWindow: TimeInterval = 0.25

    private struct HeldEvent {
        let event: String
        let tool: String?
        let detail: String?
        let ts: Double
    }

    init() {
        for agent in AgentID.allCases {
            statuses[agent] = .idleTemplate(for: agent)
        }
    }

    // MARK: Preferences

    private var enabledAgents: [AgentID: Bool] {
        let defaults = UserDefaults(suiteName: "com.touchbar.agentstatus")
        guard let dict = defaults?.dictionary(forKey: "enabledAgents") else {
            return [.claude: true, .codex: true, .opencode: true]
        }
        var result: [AgentID: Bool] = [.claude: true, .codex: true, .opencode: true]
        for (key, value) in dict {
            if let agent = AgentID(rawValue: key), let enabled = value as? Bool {
                result[agent] = enabled
            }
        }
        return result
    }

    private func isEnabled(_ agent: AgentID) -> Bool {
        let defaults = UserDefaults(suiteName: "com.touchbar.agentstatus")
        if defaults?.object(forKey: "widgetEnabled") != nil,
           defaults?.bool(forKey: "widgetEnabled") == false {
            return false
        }
        return enabledAgents[agent] ?? true
    }

    private func log(_ message: String) {
        let logDir = (FileManager.default.homeDirectoryForCurrentUser.path as NSString)
            .appendingPathComponent(".agentbridge/logs")
        try? FileManager.default.createDirectory(atPath: logDir, withIntermediateDirectories: true)
        let path = (logDir as NSString).appendingPathComponent("events.log")
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(line.data(using: .utf8) ?? Data())
            try? handle.close()
        } else {
            try? line.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    // MARK: Events

    func record(event: String, agent: AgentID, tool: String?, detail: String?, ts: Double?) {
        lock.lock()

        guard isEnabled(agent) else {
            lock.unlock()
            log("[bridge] dropped event '\(event)' from disabled agent \(agent.rawValue)")
            return
        }

        // Out-of-order protection: detached hook processes race each other,
        // so a PostToolUse "thinking" can arrive before its PreToolUse
        // "tool_start". Drop anything older than what we already applied.
        let eventTime = ts ?? Date().timeIntervalSince1970
        if let last = lastEventAt[agent], eventTime < last - AgentReducer.staleTolerance {
            lock.unlock()
            log("[\(agent.rawValue)] dropped stale event '\(event)'")
            return
        }
        lastEventAt[agent] = eventTime

        // Track in-flight tools so a single PostToolUse from a parallel
        // batch cannot flip the bar to Thinking while siblings still run.
        // Sequential starts resync the counter: Codex often omits
        // PostToolUse, and an ever-growing count would discard every later
        // tool_done until Stop — leaving a stale "Running <old command>".
        if event == "tool_start" {
            toolsInFlight[agent] = AgentReducer.toolsInFlightAfterStart(
                current: toolsInFlight[agent] ?? 0,
                lastStartAt: lastToolStartAt[agent],
                now: eventTime,
                parallelWindow: Self.parallelStartWindow
            )
            lastToolStartAt[agent] = eventTime
        } else if event == "tool_done" {
            let remaining = max(0, (toolsInFlight[agent] ?? 0) - 1)
            toolsInFlight[agent] = remaining
            if remaining > 0 {
                lock.unlock()
                log("[\(agent.rawValue)] tool_done while \(remaining) still in flight")
                return
            }
        } else if event == "stop" || event == "session_end" {
            toolsInFlight[agent] = 0
        }

        // Display dwell: keep an active tool state visible for at least
        // `toolDisplayDwell` before a quieter state replaces it, so fast
        // tools (Read/Edit in <300ms) don't flick by unseen.
        let now = Date().timeIntervalSince1970
        if let current = statuses[agent],
           current.status == .working,
           AgentReducer.isQuietTransition(event),
           let setAt = labelSetAt[agent], now - setAt < AgentReducer.toolDisplayDwell {
            let shouldSchedule = heldEvent[agent] == nil
            heldEvent[agent] = HeldEvent(event: event, tool: tool, detail: detail, ts: eventTime)
            let wait = AgentReducer.toolDisplayDwell - (now - setAt)
            lock.unlock()
            log("[\(agent.rawValue)] holding '\(event)' for \(String(format: "%.2f", wait))s (tool dwell)")
            if shouldSchedule {
                DispatchQueue.global().asyncAfter(deadline: .now() + wait) { [weak self] in
                    self?.applyHeldEvent(for: agent)
                }
            }
            return
        }

        // Immediate/high-priority activity invalidates a held quiet state.
        if !AgentReducer.isQuietTransition(event) {
            heldEvent[agent] = nil
        }
        apply(event: event, agent: agent, tool: tool, detail: detail, eventTime: eventTime)
        lock.unlock()
        onStateChange?()
    }

    private func applyHeldEvent(for agent: AgentID) {
        lock.lock()
        guard let held = heldEvent[agent] else {
            lock.unlock()
            return
        }
        if let last = lastEventAt[agent], held.ts < last - AgentReducer.staleTolerance {
            lock.unlock()
            return
        }
        heldEvent[agent] = nil
        apply(event: held.event, agent: agent, tool: held.tool, detail: held.detail, eventTime: held.ts)
        lock.unlock()
        onStateChange?()
    }

    /// Caller holds the lock.
    private func apply(event: String, agent: AgentID, tool: String?, detail: String?, eventTime: Double) {
        let previous = statuses[agent] ?? .idleTemplate(for: agent)
        let now = Date().timeIntervalSince1970
        let status = AgentReducer.reduce(
            into: previous,
            event: event,
            tool: tool,
            detail: detail,
            at: now
        )

        // Track when this label started displaying (for the tool dwell).
        if previous.label != status.label || previous.status != status.status {
            labelSetAt[agent] = now
        } else if labelSetAt[agent] == nil {
            labelSetAt[agent] = now
        }
        statuses[agent] = status
        log("[\(agent.rawValue)] \(event) tool=\(tool ?? "-") detail=\((detail ?? "-").prefix(60))")
    }

    func snapshot() -> BridgeState {
        lock.lock()
        defer { lock.unlock() }
        let now = Date().timeIntervalSince1970
        let agents = AgentID.allCases
            .compactMap { statuses[$0] }
            .filter { isEnabled($0.agent) }
            .map { AgentReducer.project($0, now: now) }
            .sorted { $0.lastActive > $1.lastActive }
        return BridgeState(agents: agents, usage: usageMonitor.snapshot())
    }
}
