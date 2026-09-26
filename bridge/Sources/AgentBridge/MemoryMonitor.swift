import Foundation
import AgentBridgeModels
import Darwin

/// Samples system RAM the way Activity Monitor's "Memory Used" does:
/// active + wired + compressed pages, over physical memory.
///
/// Sampling is cheap (`host_statistics64`), so the hub can refresh on its
/// existing 1s publish tick. The reading is rounded before encoding so a
/// few pages of drift does not rewrite `state.json` every second.
enum MemoryMonitor {

    /// Snapshots current RAM usage, or nil if the kernel call fails.
    static func snapshot() -> MemoryInfo? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride
        )
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }

        var pageSize: vm_size_t = 0
        guard host_page_size(mach_host_self(), &pageSize) == KERN_SUCCESS, pageSize > 0 else {
            return nil
        }

        let usedPages = UInt64(stats.active_count)
            + UInt64(stats.wire_count)
            + UInt64(stats.compressor_page_count)
        // Round to 32 MiB so idle drift does not thrash the state file.
        let usedBytes = (usedPages * UInt64(pageSize) / (32 * 1024 * 1024)) * (32 * 1024 * 1024)
        let totalBytes = ProcessInfo.processInfo.physicalMemory
        guard totalBytes > 0 else { return nil }

        let usedPercent = min(100, max(0, Int((Double(usedBytes) / Double(totalBytes) * 100).rounded())))
        return MemoryInfo(
            usedBytes: usedBytes,
            totalBytes: totalBytes,
            usedPercent: usedPercent,
            fetchedAt: Date().timeIntervalSince1970
        )
    }
}
