import AppKit
import PockKit

/// Agent Status widget for Pock.
///
/// Shows live activity (thinking / editing / searching ...) of coding agents
/// (Claude Code, Codex, OpenCode) with a shimmering status label. Data comes
/// from the local AgentBridge daemon.
public final class AgentTouchBarWidget: NSObject, PKWidget {

    // MARK: Protocol compatibility

    @available(*, deprecated, message: "Identifier is read from the bundle's Info.plist")
    public static var identifier: String = "com.touchbar.agentstatus"

    @objc public var identifier: NSTouchBarItem.Identifier = NSTouchBarItem.Identifier("com.touchbar.agentstatus")

    public var customizationLabel = "Agent Status"
    public var view: NSView!

    private static weak var shared: AgentTouchBarWidget?

    @objc public static func viewWillAppear() { shared?.viewWillAppear() }
    @objc public static func viewDidAppear() { shared?.viewDidAppear() }
    @objc public static func viewWillDisappear() { shared?.viewWillDisappear() }
    @objc public static func viewDidDisappear() { shared?.viewDidDisappear() }
    @objc public static func prepareForCustomization() { shared?.prepareForCustomization() }
    @objc public static var imageForCustomization: NSImage { makeCustomizationImage() }

    @objc public func viewDidAppear() {}
    @objc public func viewWillDisappear() {}
    @objc public func prepareForCustomization() {}
    @objc public var imageForCustomization: NSImage { Self.makeCustomizationImage() }

    private static func makeCustomizationImage() -> NSImage {
        let size = NSSize(width: 118, height: 30)
        return NSImage(size: size, flipped: false) { rect in
            if let icon = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [.white])) {
                icon.draw(in: NSRect(x: 10, y: (rect.height - 15) / 2, width: 15, height: 15))
            }
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
                .foregroundColor: NSColor.white,
            ]
            let text = "Agent Status" as NSString
            let textSize = text.size(withAttributes: attrs)
            text.draw(at: NSPoint(x: 33, y: (rect.height - textSize.height) / 2), withAttributes: attrs)
            return true
        }
    }

    // MARK: State

    private let statusView: StatusView
    private let client = BridgeClient()
    private let stateWatcher = StateFileWatcher()
    /// Slow HTTP fallback while the state file is unavailable (bridge not
    /// started yet, or an older bridge that does not publish one).
    private var fallbackTimer: Timer?
    private var isFetching = false
    private var receivedFromFile = false

    override public required init() {
        statusView = StatusView(frame: NSRect(x: 0, y: 0, width: StatusView.preferredWidth, height: 30))
        super.init()
        view = statusView
        statusView.onTap = { [weak self] in
            self?.statusView.cycleSelection()
        }
        stateWatcher.onState = { [weak self] state in
            guard let self else { return }
            self.receivedFromFile = true
            self.stopFallback()
            self.statusView.apply(agents: state.agents, usage: state.usage)
        }
        AgentTouchBarWidget.shared = self
    }

    // MARK: Lifecycle

    @objc public func viewWillAppear() {
        startUpdates()
    }

    @objc public func viewDidDisappear() {
        stopUpdates()
    }

    private func startUpdates() {
        stateWatcher.start()
        startFallback()
        // One immediate HTTP fetch so the bar is not blank before the first
        // file write or if the bridge predates state-file publishing.
        fetchOverHTTP()
    }

    private func stopUpdates() {
        stateWatcher.stop()
        stopFallback()
    }

    private func startFallback() {
        guard fallbackTimer == nil else { return }
        let timer = Timer(timeInterval: 10.0, repeats: true) { [weak self] _ in
            self?.fetchOverHTTP()
        }
        RunLoop.main.add(timer, forMode: .common)
        fallbackTimer = timer
    }

    private func stopFallback() {
        fallbackTimer?.invalidate()
        fallbackTimer = nil
    }

    private func fetchOverHTTP() {
        // Once the file path is delivering, HTTP is only a health net; skip
        // while a request is already in flight.
        guard !isFetching else { return }
        isFetching = true
        client.fetchState { [weak self] state in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isFetching = false
                if let state, !self.receivedFromFile {
                    self.statusView.apply(agents: state.agents, usage: state.usage)
                }
            }
        }
    }
}

// MARK: - Cursor-mode clicks

extension AgentTouchBarWidget: PKScreenEdgeMouseDelegate {

    public func screenEdgeController(_ controller: PKScreenEdgeController, mouseClickAtLocation location: NSPoint, in view: NSView) {
        guard let statusView = self.view as? StatusView else { return }
        let local = statusView.convert(location, from: view)
        if statusView.bounds.contains(local) {
            statusView.cycleSelection()
        }
    }

    public func screenEdgeController(_ controller: PKScreenEdgeController, mouseEnteredAtLocation location: NSPoint, in view: NSView) {}

    public func screenEdgeController(_ controller: PKScreenEdgeController, mouseMovedAtLocation location: NSPoint, in view: NSView) {}

    public func screenEdgeController(_ controller: PKScreenEdgeController, mouseExitedAtLocation location: NSPoint, in view: NSView) {}
}