import Foundation

let port = UInt16(ProcessInfo.processInfo.environment["AGENTBRIDGE_PORT"] ?? "3939") ?? 3939

let hub = AgentHub()
let server = HTTPServer(hub: hub, port: port)

// Push state to a watchable file so the Pock widget updates on change
// instead of polling HTTP. Event mutations publish immediately; a 1s tick
// covers time-based transitions (transient expiry, inactivity, staleness).
let publisher = StatePublisher(path: StatePublisher.defaultPath())
hub.onStateChange = { publisher.publish(hub.snapshot()) }
hub.usageMonitor.onStateChange = { publisher.publish(hub.snapshot()) }

// Begin collecting Codex quota readings for the Touch Bar chip.
hub.usageMonitor.start()

signal(SIGPIPE, SIG_IGN)

publisher.publish(hub.snapshot())
let publishTimer = Timer(timeInterval: 1.0, repeats: true) { [weak hub] _ in
    guard let hub else { return }
    publisher.publish(hub.snapshot())
}
RunLoop.main.add(publishTimer, forMode: .common)

// The accept loop must not run on the main thread — it would block the
// run loop and the publish timer would never fire.
DispatchQueue.global(qos: .userInitiated).async {
    do {
        try server.start()
    } catch {
        fputs("[AgentBridge] failed to start: \(error)\n", stderr)
        exit(1)
    }
}

RunLoop.main.run()
