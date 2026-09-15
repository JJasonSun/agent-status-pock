import Foundation

// MARK: - Model

/// Codex quota state, shaped for a compact Touch Bar chip.
struct UsageInfo: Codable {
    let remainingPercent: Int
    let usedPercent: Int
    let windowLabel: String
    let windowMinutes: Double
    let resetsAt: TimeInterval?
    let planType: String?
    let unlimited: Bool
    /// Whether the reading has aged past `staleAfter`. Recomputed on every
    /// read, so a snapshot taken seconds ago is not reported as stale.
    var stale: Bool
    /// "live" (app-server query) or "session" (recorded snapshot).
    let source: String
    /// When the underlying number was observed, used to keep the freshest
    /// reading when both sources are available.
    let fetchedAt: TimeInterval
}

// MARK: - Monitor

/// Locked container so a background query can hand its result back safely.
private final class ValueBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: UsageInfo?

    func set(_ value: UsageInfo?) {
        lock.lock()
        stored = value
        lock.unlock()
    }

    func get() -> UsageInfo? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

/// Keeps a Codex quota reading available for the Touch Bar.
///
/// Two independent sources, cheapest first:
///
/// 1. **Session snapshots** — every Codex run records the official
///    `rate_limits` payload into `~/.codex/sessions/<Y>/<M>/<D>/*.jsonl`.
///    Reading the newest one costs a tail-read of a local file and reflects
///    the quota as of the last Codex activity.
/// 2. **Live account query** — `codex app-server --stdio` plus the
///    `account/rateLimits/read` JSON-RPC method. Authoritative and current,
///    but needs network access to the account backend, so it is attempted
///    at a slower cadence and always falls back to (1) on failure.
final class UsageMonitor: @unchecked Sendable {

    private let lock = NSLock()
    private var cached: UsageInfo?

    private let stateQueue = DispatchQueue(label: "com.touchbar.agentbridge.usage")
    private var timer: DispatchSourceTimer?
    private var lastLiveAttempt: TimeInterval = 0

    /// How often the local snapshot is re-read.
    private let scanInterval: TimeInterval = 120
    /// Minimum spacing between authoritative live queries.
    private let liveInterval: TimeInterval = 600
    /// Hard ceiling for one live query.
    private let liveTimeout: TimeInterval = 12
    /// A reading older than this is reported as stale (the widget dims it).
    private let staleAfter: TimeInterval = 180

    private var codexBinaryPath: String?
    private var didResolveBinary = false

    // MARK: Lifecycle

    func start() {
        stateQueue.async { [weak self] in
            guard let self else { return }
            self.refresh(forceLive: true)
            let timer = DispatchSource.makeTimerSource(queue: self.stateQueue)
            timer.schedule(
                deadline: .now() + self.scanInterval,
                repeating: self.scanInterval,
                leeway: .seconds(5)
            )
            timer.setEventHandler { [weak self] in self?.refresh(forceLive: false) }
            timer.resume()
            self.timer = timer
        }
    }

    func snapshot() -> UsageInfo? {
        lock.lock()
        defer { lock.unlock() }
        guard var info = cached else { return nil }
        info.stale = Date().timeIntervalSince1970 - info.fetchedAt > staleAfter
        return info
    }

    // MARK: Refresh

    private func refresh(forceLive: Bool) {
        let now = Date().timeIntervalSince1970

        if forceLive || now - lastLiveAttempt >= liveInterval {
            lastLiveAttempt = now
            if let live = queryLive() {
                store(live)
                return
            }
        }
        if let recorded = readSessionSnapshot() {
            store(recorded)
        }
    }

    /// Keeps the reading that describes the most recent observation. The
    /// latest local snapshot is usually fresher than the last live query
    /// while Codex is in use, and vice versa while it is idle, so the two
    /// sources are ordered by when their number was observed rather than by
    /// which one produced it.
    private func store(_ info: UsageInfo) {
        lock.lock()
        defer { lock.unlock() }
        if let existing = cached, existing.fetchedAt >= info.fetchedAt { return }
        cached = info
    }

    // MARK: Live query

    private func queryLive() -> UsageInfo? {
        guard let binary = resolvedCodexBinary() else { return nil }
        let box = ValueBox()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            box.set(self?.performRateLimitQuery(binary: binary))
            done.signal()
        }
        // The worker enforces its own timeout by killing the child, which
        // closes the pipe and lets the read loop finish, so this wait is
        // only a second safety net.
        if done.wait(timeout: .now() + liveTimeout + 5) == .timedOut { return nil }
        return box.get()
    }

    private func performRateLimitQuery(binary: String) -> UsageInfo? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["app-server", "--stdio"]

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        // Discard stderr: leaving an unread pipe here would fill its buffer
        // and stall the child mid-handshake.
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }

        // Watchdog: terminating the child closes stdout, ending the read loop.
        DispatchQueue.global().asyncAfter(deadline: .now() + liveTimeout) {
            if process.isRunning { process.terminate() }
        }

        let output = stdoutPipe.fileHandleForReading
        let input = stdinPipe.fileHandleForWriting

        func send(_ payload: [String: Any]) {
            guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
            var line = data
            line.append(0x0A)
            try? input.write(contentsOf: line)
        }

        send([
            "method": "initialize",
            "id": 0,
            "params": [
                "clientInfo": [
                    "name": "agentbridge",
                    "title": "AgentBridge",
                    "version": "1.0.0",
                ],
            ],
        ])

        var buffer = Data()
        var result: UsageInfo?
        var finished = false

        while !finished {
            let chunk = output.availableData
            if chunk.isEmpty { break }  // EOF
            buffer.append(chunk)

            while let newline = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer.subdata(in: buffer.startIndex..<newline)
                buffer.removeSubrange(buffer.startIndex...newline)

                guard let object = try? JSONSerialization.jsonObject(with: lineData),
                      let message = object as? [String: Any],
                      let id = message["id"] as? Int
                else { continue }

                if id == 0 {
                    guard message["error"] == nil else {
                        finished = true
                        break
                    }
                    send(["method": "initialized", "params": [:]])
                    send(["method": "account/rateLimits/read", "id": 1])
                } else if id == 1 {
                    if let payload = message["result"] as? [String: Any] {
                        result = usage(fromLive: payload)
                    }
                    finished = true
                    break
                }
            }
        }

        if process.isRunning { process.terminate() }
        return result
    }

    private func usage(fromLive payload: [String: Any]) -> UsageInfo? {
        let byID = payload["rateLimitsByLimitId"] as? [String: Any]
        let limit = (byID?["codex"] as? [String: Any]) ?? (payload["rateLimits"] as? [String: Any])
        guard let limit, let primary = limit["primary"] as? [String: Any] else { return nil }
        let credits = limit["credits"] as? [String: Any]
        return makeInfo(
            usedPercent: number(primary["usedPercent"]),
            windowMinutes: number(primary["windowDurationMins"]),
            resetsAt: number(primary["resetsAt"]),
            planType: limit["planType"] as? String,
            unlimited: (credits?["unlimited"] as? Bool) ?? false,
            source: "live",
            fetchedAt: Date().timeIntervalSince1970
        )
    }

    // MARK: Session snapshot

    private func readSessionSnapshot() -> UsageInfo? {
        let calendar = Calendar.current
        let root = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex/sessions")
        let manager = FileManager.default

        // Session filenames embed their start timestamp, so a descending
        // name sort lists the most recent run first.
        for offset in 0..<4 {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: Date()) else { continue }
            let parts = calendar.dateComponents([.year, .month, .day], from: day)
            guard let year = parts.year, let month = parts.month, let dayOfMonth = parts.day else { continue }
            let directory = root
                .appendingPathComponent(String(format: "%04d", year))
                .appendingPathComponent(String(format: "%02d", month))
                .appendingPathComponent(String(format: "%02d", dayOfMonth))

            guard let names = try? manager.contentsOfDirectory(atPath: directory.path) else { continue }
            let sessions = names.filter { $0.hasSuffix(".jsonl") }.sorted(by: >)

            for name in sessions.prefix(3) {
                let url = directory.appendingPathComponent(name)
                if let info = usageFromSessionFile(url) { return info }
            }
        }
        return nil
    }

    private func usageFromSessionFile(_ url: URL) -> UsageInfo? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        // Used when the record itself carries no usable timestamp.
        let fallbackObservedAt = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate?.timeIntervalSince1970 ?? Date().timeIntervalSince1970

        // The quota payload is appended as sessions progress, so the tail is
        // where the freshest reading lives.
        let maxBytes: UInt64 = 512 * 1024
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > maxBytes ? size - maxBytes : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd(), !data.isEmpty else { return nil }

        let lines = data.split(separator: 0x0A, omittingEmptySubsequences: true)
        for line in lines.reversed() {
            guard let text = String(data: line, encoding: .utf8),
                  text.contains("\"rate_limits\"") else { continue }
            guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)),
                  let limits = findRateLimits(in: object) else { continue }
            let observedAt = Self.observedAt(from: object, fallback: fallbackObservedAt)
            if let info = usage(fromRecorded: limits, observedAt: observedAt) { return info }
        }
        return nil
    }

    /// Reads the recording's own timestamp so readings from the two sources
    /// can be compared by age. Formatters are built per call: they are not
    /// Sendable, and this runs a handful of times per refresh at most.
    private static func observedAt(from object: Any, fallback: TimeInterval) -> TimeInterval {
        guard let text = (object as? [String: Any])?["timestamp"] as? String else { return fallback }

        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: text) {
            return date.timeIntervalSince1970
        }

        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: text)?.timeIntervalSince1970 ?? fallback
    }

    private func findRateLimits(in object: Any) -> [String: Any]? {
        if let dictionary = object as? [String: Any] {
            if let limits = dictionary["rate_limits"] as? [String: Any] { return limits }
            for value in dictionary.values {
                if let found = findRateLimits(in: value) { return found }
            }
        } else if let array = object as? [Any] {
            for value in array {
                if let found = findRateLimits(in: value) { return found }
            }
        }
        return nil
    }

    private func usage(fromRecorded limits: [String: Any], observedAt: TimeInterval) -> UsageInfo? {
        guard let primary = limits["primary"] as? [String: Any] else { return nil }
        let credits = limits["credits"] as? [String: Any]
        return makeInfo(
            usedPercent: number(primary["used_percent"]),
            windowMinutes: number(primary["window_minutes"]),
            resetsAt: number(primary["resets_at"]),
            planType: limits["plan_type"] as? String,
            unlimited: (credits?["unlimited"] as? Bool) ?? false,
            source: "session",
            fetchedAt: observedAt
        )
    }

    // MARK: Helpers

    private func makeInfo(
        usedPercent: Double?,
        windowMinutes: Double?,
        resetsAt: Double?,
        planType: String?,
        unlimited: Bool,
        source: String,
        fetchedAt: TimeInterval
    ) -> UsageInfo? {
        guard let windowMinutes, windowMinutes > 0 else { return nil }

        var used = min(max(usedPercent ?? 0, 0), 100)
        var effectiveResetsAt = resetsAt

        // A window whose reset time has already passed rolled over, so the
        // recorded percentage no longer describes the current period.
        if let resets = resetsAt, resets > 0, resets < Date().timeIntervalSince1970 {
            used = 0
            effectiveResetsAt = nil
        }

        let remaining = unlimited ? 100 : Int((100 - used).rounded())
        return UsageInfo(
            remainingPercent: remaining,
            usedPercent: Int(used.rounded()),
            windowLabel: windowLabel(minutes: windowMinutes),
            windowMinutes: windowMinutes,
            resetsAt: effectiveResetsAt,
            planType: planType,
            unlimited: unlimited,
            stale: false,
            source: source,
            fetchedAt: fetchedAt
        )
    }

    private func windowLabel(minutes: Double) -> String {
        if minutes >= 10_000 { return "周" }
        if minutes >= 1_400 { return "日" }
        if minutes >= 60, minutes.truncatingRemainder(dividingBy: 60) == 0 {
            return "\(Int(minutes / 60))h"
        }
        return "\(Int(minutes))m"
    }

    private func number(_ value: Any?) -> Double? {
        if let double = value as? Double { return double }
        if let int = value as? Int { return Double(int) }
        if let number = value as? NSNumber { return number.doubleValue }
        return nil
    }

    private func resolvedCodexBinary() -> String? {
        if didResolveBinary { return codexBinaryPath }
        didResolveBinary = true

        let candidates = [
            "/Applications/ChatGPT.app/Contents/Resources/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            NSHomeDirectory() + "/.local/bin/codex",
        ]
        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate) {
            codexBinaryPath = candidate
            break
        }
        return codexBinaryPath
    }
}
