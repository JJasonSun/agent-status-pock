import Foundation
import AgentBridgeModels

/// Atomically writes the current BridgeState to a JSON file the Pock widget
/// can watch with DispatchSource, so the bar updates on change instead of
/// polling HTTP every few hundred milliseconds.
///
/// The write goes through a temporary file + rename (via `.atomic`), so a
/// reader either sees the previous complete document or the new one — never
/// a torn file. The widget re-opens its watch descriptor after each event
/// because the inode is replaced.
final class StatePublisher: @unchecked Sendable {

    private let path: URL
    private let encoder: JSONEncoder
    private let lock = NSLock()
    private var lastWritten: Data?

    init(path: URL) {
        self.path = path
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        self.encoder = encoder
    }

    /// Convenience: honour `AGENTBRIDGE_STATE`, else `~/.agentbridge/state.json`.
    static func defaultPath() -> URL {
        if let override = ProcessInfo.processInfo.environment["AGENTBRIDGE_STATE"],
           !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".agentbridge/state.json")
    }

    func publish(_ state: BridgeState) {
        guard let data = try? encoder.encode(state) else { return }
        lock.lock()
        defer { lock.unlock() }
        if data == lastWritten { return }
        do {
            try FileManager.default.createDirectory(
                at: path.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: path, options: .atomic)
            lastWritten = data
        } catch {
            fputs("[AgentBridge] failed to write \(path.path): \(error)\n", stderr)
        }
    }
}
