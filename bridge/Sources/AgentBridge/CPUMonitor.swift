import Foundation
import Darwin

/// Samples aggregate CPU usage on its own 1s cadence and caches the rounded
/// percentage. Multiple callers (HTTP, state publisher) must not each advance
/// the tick baseline, or their deltas interfere and the value goes stale.
final class CPUMonitor: @unchecked Sendable {

    private let lock = NSLock()
    private var cached: Int?
    private let queue = DispatchQueue(label: "com.touchbar.agentbridge.cpu")
    private var timer: DispatchSourceTimer?
    private var previous: [UInt32]?

    func start() {
        queue.async { [weak self] in
            guard let self else { return }
            self.sample()
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(200))
            timer.setEventHandler { [weak self] in self?.sample() }
            timer.resume()
            self.timer = timer
        }
    }

    func snapshot() -> Int? {
        lock.lock()
        defer { lock.unlock() }
        return cached
    }

    private func sample() {
        var info = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride
        )
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return }

        let ticks = withUnsafeBytes(of: info.cpu_ticks) {
            Array($0.bindMemory(to: UInt32.self))
        }

        lock.lock()
        defer { lock.unlock() }
        defer { previous = ticks }
        guard let previous, previous.count == 4 else { return }

        let user = Double(ticks[0] &- previous[0])
        let system = Double(ticks[1] &- previous[1])
        let idle = Double(ticks[2] &- previous[2])
        let nice = Double(ticks[3] &- previous[3])
        let active = user + system + nice
        let total = active + idle
        guard total > 0 else { return }

        let percent = Int((active / total * 100).rounded())
        cached = min(100, max(0, (percent / 5) * 5))
    }
}