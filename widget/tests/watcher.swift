import Foundation

@main
struct WatcherTest {
    static func main() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentbridge-watcher-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("state.json").path

        func writeState(_ index: Int) {
            let agent = AgentSnapshot(
                agent: .claude,
                name: "Claude",
                symbol: "sparkles",
                color: "D97757",
                status: .thinking,
                label: "Thinking",
                lastActive: Double(index)
            )
            let data = try! JSONEncoder().encode(BridgeState(agents: [agent]))
            try! data.write(to: URL(fileURLWithPath: path), options: .atomic)
        }

        writeState(0)
        let watcher = StateFileWatcher(path: path)
        var received = 0
        watcher.onState = { _ in received += 1 }
        watcher.start()

        for index in 1...4 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3 * Double(index)) {
                writeState(index)
            }
        }

        RunLoop.current.run(until: Date().addingTimeInterval(2.0))
        watcher.stop()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))

        let expected = 5  // initial reload + four writes
        print("watcher updates: \(received) (expected at least \(expected))")
        try? FileManager.default.removeItem(at: directory)
        exit(received >= expected ? 0 : 1)
    }
}
