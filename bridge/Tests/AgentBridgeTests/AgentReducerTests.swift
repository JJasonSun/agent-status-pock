import XCTest
import AgentBridgeModels
@testable import AgentBridgeCore

final class AgentReducerTests: XCTestCase {

    private func snapshot(
        status: AgentStatus = .idle,
        label: String = "No agent running",
        lastActive: TimeInterval = 0,
        transientUntil: TimeInterval? = nil
    ) -> AgentSnapshot {
        AgentSnapshot(
            agent: .claude,
            name: "Claude",
            symbol: "sparkles",
            color: "D97757",
            status: status,
            label: label,
            lastActive: lastActive,
            transientUntil: transientUntil
        )
    }

    // MARK: - reduce

    func testToolStartBecomesWorkingWithVerbAndBasename() {
        let next = AgentReducer.reduce(
            into: snapshot(),
            event: "tool_start",
            tool: "Edit",
            detail: "/Users/me/project/auth.swift | fix nil check",
            at: 100
        )
        XCTAssertEqual(next.status, .working)
        XCTAssertEqual(next.label, "Editing")
        XCTAssertEqual(next.detail, "auth.swift")
        XCTAssertEqual(next.lastActive, 100)
        XCTAssertNil(next.transientUntil)
    }

    func testStopBecomesResponseReadyWithTransientWindow() {
        let next = AgentReducer.reduce(
            into: snapshot(status: .working, label: "Editing"),
            event: "stop",
            tool: nil,
            detail: nil,
            at: 50
        )
        XCTAssertEqual(next.status, .responseReady)
        XCTAssertEqual(next.label, "Response ready")
        XCTAssertEqual(next.transientUntil, 50 + AgentReducer.responseReadyTransient)
    }

    func testNeedsInputIsStickyAgainstThinkingAndNotification() {
        let asking = snapshot(status: .needsInput, label: "Pick a file")
        for event in ["thinking", "tool_done", "notification", "connected"] {
            let next = AgentReducer.reduce(
                into: asking, event: event, tool: nil, detail: "ignored", at: 10
            )
            XCTAssertEqual(next.status, .needsInput, "event \(event) must not clear needsInput")
            XCTAssertEqual(next.label, "Pick a file")
            XCTAssertEqual(next.lastActive, 10)
        }
    }

    func testThinkingDoesNotWakeSettledAgent() {
        for status in [AgentStatus.ready, .idle, .responseReady] {
            let before = snapshot(status: status, label: "Codex is ready", lastActive: 100)
            for event in ["thinking", "tool_done"] {
                let next = AgentReducer.reduce(
                    into: before, event: event, tool: nil, detail: nil, at: 120
                )
                XCTAssertEqual(next.status, status, "settled \(status) must ignore \(event)")
                XCTAssertEqual(next.lastActive, 100, "ignored \(event) must not refresh lastActive")
            }
        }
    }

    func testPromptWakesReadyToThinking() {
        let next = AgentReducer.reduce(
            into: snapshot(status: .ready, label: "Codex is ready"),
            event: "prompt",
            tool: nil,
            detail: nil,
            at: 50
        )
        XCTAssertEqual(next.status, .thinking)
        XCTAssertEqual(next.label, "Thinking")
        XCTAssertEqual(next.lastActive, 50)
    }

    func testToolDoneAfterWorkingBecomesThinking() {
        let next = AgentReducer.reduce(
            into: snapshot(status: .working, label: "Running", lastActive: 10),
            event: "tool_done",
            tool: nil,
            detail: nil,
            at: 20
        )
        XCTAssertEqual(next.status, .thinking)
        XCTAssertEqual(next.label, "Thinking")
        XCTAssertEqual(next.lastActive, 20)
    }

    func testNeedsInputIsClearedByToolStart() {
        let next = AgentReducer.reduce(
            into: snapshot(status: .needsInput, label: "Pick a file"),
            event: "tool_start",
            tool: "Bash",
            detail: "ls",
            at: 10
        )
        XCTAssertEqual(next.status, .working)
        XCTAssertEqual(next.label, "Running")
    }

    func testSessionStartIsConnectedWithThreeSecondTransient() {
        let next = AgentReducer.reduce(
            into: snapshot(), event: "session_start", tool: nil, detail: nil, at: 5
        )
        XCTAssertEqual(next.status, .connected)
        XCTAssertEqual(next.label, "Claude connected")
        XCTAssertEqual(next.transientUntil, 8)
    }

    func testNotificationOnlyRewritesIdleOrReady() {
        let fromIdle = AgentReducer.reduce(
            into: snapshot(), event: "notification", tool: nil, detail: "Ping", at: 1
        )
        XCTAssertEqual(fromIdle.status, .ready)
        XCTAssertEqual(fromIdle.label, "Ping")

        let fromWorking = AgentReducer.reduce(
            into: snapshot(status: .working, label: "Editing"),
            event: "notification", tool: nil, detail: "Ping", at: 1
        )
        XCTAssertEqual(fromWorking.status, .working)
        XCTAssertEqual(fromWorking.label, "Editing")
    }

    func testUnknownEventLeavesStatusUnchanged() {
        let before = snapshot(status: .working, label: "Editing", lastActive: 1)
        let next = AgentReducer.reduce(
            into: before, event: "something_new", tool: nil, detail: nil, at: 9
        )
        XCTAssertEqual(next.status, .working)
        XCTAssertEqual(next.label, "Editing")
        XCTAssertEqual(next.lastActive, 9)
    }

    // MARK: - project

    func testProjectExpiresResponseReadyTransient() {
        let s = snapshot(
            status: .responseReady,
            label: "Response ready",
            lastActive: 100,
            transientUntil: 106
        )
        let projected = AgentReducer.project(s, now: 107)
        XCTAssertEqual(projected.status, .ready)
        XCTAssertEqual(projected.label, "Claude is ready")
        XCTAssertNil(projected.transientUntil)
    }

    func testProjectKeepsLiveTransient() {
        let s = snapshot(
            status: .responseReady,
            label: "Response ready",
            lastActive: 100,
            transientUntil: 106
        )
        let projected = AgentReducer.project(s, now: 103)
        XCTAssertEqual(projected.status, .responseReady)
        XCTAssertEqual(projected.transientUntil, 106)
    }

    func testProjectFallsBackToReadyAfterInactivity() {
        let s = snapshot(
            status: .thinking,
            label: "Thinking",
            lastActive: 100
        )
        let projected = AgentReducer.project(s, now: 100 + AgentReducer.inactivityTimeout + 1)
        XCTAssertEqual(projected.status, .ready)
        XCTAssertEqual(projected.label, "Claude is ready")
    }

    func testProjectKeepsActiveWorkInsideTimeout() {
        let s = snapshot(status: .working, label: "Editing", lastActive: 100)
        let projected = AgentReducer.project(s, now: 120)
        XCTAssertEqual(projected.status, .working)
    }

    // MARK: - labels

    func testVerbMapping() {
        XCTAssertEqual(AgentReducer.verb(for: "Edit"), "Editing")
        XCTAssertEqual(AgentReducer.verb(for: "Write"), "Editing")
        XCTAssertEqual(AgentReducer.verb(for: "MultiEdit"), "Editing")
        XCTAssertEqual(AgentReducer.verb(for: "Read"), "Reading")
        XCTAssertEqual(AgentReducer.verb(for: "Grep"), "Searching")
        XCTAssertEqual(AgentReducer.verb(for: "Glob"), "Searching")
        XCTAssertEqual(AgentReducer.verb(for: "Bash"), "Running")
        XCTAssertEqual(AgentReducer.verb(for: "WebFetch"), "Browsing")
        XCTAssertEqual(AgentReducer.verb(for: "Task"), "Delegating")
        XCTAssertEqual(AgentReducer.verb(for: "AskUserQuestion"), "Asking")
        // TodoWrite contains "write" — planning must win.
        XCTAssertEqual(AgentReducer.verb(for: "TodoWrite"), "Planning")
        XCTAssertEqual(AgentReducer.verb(for: "ExitPlanMode"), "Planning")
        XCTAssertEqual(AgentReducer.verb(for: "swift_test_runner"), "Testing")
        XCTAssertEqual(AgentReducer.verb(for: "my_tool"), "My Tool")
    }

    func testSummarizedTarget() {
        XCTAssertEqual(
            AgentReducer.summarizedTarget(toolName: "Edit", detail: "/a/b/c.swift | notes"),
            "c.swift"
        )
        XCTAssertEqual(
            AgentReducer.summarizedTarget(toolName: "Bash", detail: "ls -la | grep foo"),
            "ls -la"
        )
        XCTAssertEqual(
            AgentReducer.summarizedTarget(toolName: "Read", detail: #"{"file_path":"/x"}"#),
            ""
        )
        XCTAssertEqual(AgentReducer.summarizedTarget(toolName: "Edit", detail: nil), "")
        XCTAssertEqual(AgentReducer.summarizedTarget(toolName: "Edit", detail: ""), "")
    }

    // MARK: - classification

    func testQuietTransitions() {
        XCTAssertTrue(AgentReducer.isQuietTransition("thinking"))
        XCTAssertTrue(AgentReducer.isQuietTransition("tool_done"))
        XCTAssertTrue(AgentReducer.isQuietTransition("stop"))
        XCTAssertTrue(AgentReducer.isQuietTransition("ready"))
        XCTAssertFalse(AgentReducer.isQuietTransition("tool_start"))
        XCTAssertFalse(AgentReducer.isQuietTransition("prompt"))
        XCTAssertFalse(AgentReducer.isQuietTransition("needs_input"))
        XCTAssertFalse(AgentReducer.isQuietTransition("session_start"))
    }

    func testActiveWorkClassification() {
        XCTAssertTrue(AgentStatus.thinking.isActiveWork)
        XCTAssertTrue(AgentStatus.answering.isActiveWork)
        XCTAssertTrue(AgentStatus.working.isActiveWork)
        XCTAssertFalse(AgentStatus.ready.isActiveWork)
        XCTAssertFalse(AgentStatus.needsInput.isActiveWork)
        XCTAssertFalse(AgentStatus.responseReady.isActiveWork)

        XCTAssertTrue(AgentStatus.needsInput.isAttention)
        XCTAssertTrue(AgentStatus.responseReady.isAttention)
        XCTAssertFalse(AgentStatus.ready.isAttention)
        XCTAssertFalse(AgentStatus.idle.isAttention)
    }

    // MARK: - tools in flight

    func testFirstToolStartResetsToOne() {
        XCTAssertEqual(AgentReducer.toolsInFlightAfterStart(current: 0, lastStartAt: nil, now: 100), 1)
        // Stale positive count from a missed PostToolUse must not grow forever.
        XCTAssertEqual(AgentReducer.toolsInFlightAfterStart(current: 40, lastStartAt: 50, now: 100), 1)
    }

    func testParallelBurstWithinWindowIncrements() {
        XCTAssertEqual(
            AgentReducer.toolsInFlightAfterStart(current: 1, lastStartAt: 100, now: 100.1),
            2
        )
        XCTAssertEqual(
            AgentReducer.toolsInFlightAfterStart(current: 2, lastStartAt: 100.1, now: 100.2),
            3
        )
    }

    func testSequentialStartAfterWindowResyncsToOne() {
        XCTAssertEqual(
            AgentReducer.toolsInFlightAfterStart(current: 5, lastStartAt: 100, now: 102),
            1
        )
        XCTAssertEqual(
            AgentReducer.toolsInFlightAfterStart(current: 1, lastStartAt: 100, now: 100.25),
            1
        )
    }
}
