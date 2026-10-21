import XCTest
import AgentBridgeModels

final class UsageInfoTests: XCTestCase {

    private func usage(resetsAt: TimeInterval?) -> UsageInfo {
        UsageInfo(
            remainingPercent: 20,
            usedPercent: 80,
            windowLabel: "周",
            windowMinutes: 10080,
            resetsAt: resetsAt,
            planType: "pro",
            unlimited: false,
            stale: false,
            source: "session",
            fetchedAt: 100
        )
    }

    func testRollsOverAfterReset() {
        let rolled = usage(resetsAt: 200).rolledOver(now: 300)
        XCTAssertEqual(rolled.remainingPercent, 100)
        XCTAssertEqual(rolled.usedPercent, 0)
        XCTAssertNil(rolled.resetsAt)
        XCTAssertEqual(rolled.fetchedAt, 100)
    }

    func testKeepsReadingBeforeReset() {
        let current = usage(resetsAt: 300)
        XCTAssertEqual(current.rolledOver(now: 200).remainingPercent, 20)
    }

    func testKeepsReadingWithoutReset() {
        let current = usage(resetsAt: nil)
        XCTAssertEqual(current.rolledOver(now: 300).remainingPercent, 20)
    }
}
