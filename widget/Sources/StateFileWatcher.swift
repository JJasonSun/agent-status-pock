import Foundation

/// Watches the bridge's state file and delivers decoded snapshots on change.
///
/// AgentBridge rewrites `~/.agentbridge/state.json` atomically (temp + rename),
/// which replaces the inode. A DispatchSource on the old descriptor therefore
/// sees a delete/rename; we re-open after every event so the next write is
/// observed too. The path is overridable via `AGENTBRIDGE_STATE` for tests.
final class StateFileWatcher {

    private let path: String
    private let queue = DispatchQueue(label: "com.touchbar.agentstatus.statewatch")
    private var source: DispatchSourceFileSystemObject?
    private var fd: Int32 = -1
    private var isRunning = false

    /// Called on the main queue with each successfully decoded snapshot.
    var onState: ((BridgeState) -> Void)?

    init(path: String? = nil) {
        if let path, !path.isEmpty {
            self.path = path
        } else if let override = ProcessInfo.processInfo.environment["AGENTBRIDGE_STATE"],
                  !override.isEmpty {
            self.path = override
        } else {
            self.path = NSHomeDirectory() + "/.agentbridge/state.json"
        }
    }

    func start() {
        queue.async { [weak self] in
            guard let self else { return }
            self.isRunning = true
            self.reload()
            self.arm()
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.isRunning = false
            self.cancelSource()
        }
    }

    // MARK: - Private (queue-confined)

    /// The cancel handler owns the descriptor. Closing it here as well would
    /// close the descriptor opened below after the OS reuses the same number.
    private func cancelSource() {
        if let source {
            self.source = nil
            fd = -1
            source.cancel()
        } else if fd >= 0 {
            close(fd)
            fd = -1
        }
    }

    private func arm() {
        guard isRunning else { return }
        cancelSource()

        let newFD = open(path, O_EVTONLY)
        guard newFD >= 0 else {
            // Mid-rename or bridge not up yet — retry so the watch cannot
            // die permanently after a single failed open.
            queue.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.arm()
            }
            return
        }

        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: newFD,
            eventMask: [.write, .delete, .rename, .extend, .attrib, .link],
            queue: queue
        )
        src.setEventHandler { [weak self] in
            guard let self else { return }
            self.reload()
            self.arm()
        }
        src.setCancelHandler {
            close(newFD)
        }
        src.resume()
        source = src
        fd = newFD
    }

    private func reload() {
        guard let data = FileManager.default.contents(atPath: path), !data.isEmpty else { return }
        guard let state = try? JSONDecoder().decode(BridgeState.self, from: data) else { return }
        DispatchQueue.main.async { [weak self] in
            self?.onState?(state)
        }
    }
}
