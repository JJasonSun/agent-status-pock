import Foundation
import Darwin

/// Samples aggregate CPU usage from cumulative Mach tick counters.
/// Rounded to 5% steps so the state file does not rewrite every second.
final class CPUMonitor: @unchecked Sendable {

    private let lock = NSLock()
    private var previous: [UInt32]?

    func snapshot() -> Int? {
        var info = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride
        )
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }

        let ticks = withUnsafeBytes(of: info.cpu_ticks) {
            Array($0.bindMemory(to: UInt32.self))
        }

        lock.lock()
        defer { lock.unlock() }
        defer { previous = ticks }
        guard let previous, previous.count == 4 else { return nil }

        let user = Double(ticks[0] &- previous[0])
        let system = Double(ticks[1] &- previous[1])
        let idle = Double(ticks[2] &- previous[2])
        let nice = Double(ticks[3] &- previous[3])
        let active = user + system + nice
        let total = active + idle
        guard total > 0 else { return nil }

        let percent = Int((active / total * 100).rounded())
        return min(100, max(0, (percent / 5) * 5))
    }
}