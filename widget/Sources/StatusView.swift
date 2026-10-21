import AppKit

private func chipSlotWidth(_ text: String) -> CGFloat {
    let font = NSFont.systemFont(ofSize: 12, weight: .semibold)
    return (text as NSString).size(withAttributes: [.font: font]).width + 6
}

/// Main widget view. Shows the live agent status with a shimmering label.
/// Bounded width while active, can collapse when all enabled agents are idle.
///
/// Attention tiers (from agent-status UX patterns):
/// - active (thinking/answering/working) → white text + shimmer sweep
/// - response ready                       → green breathing text
/// - ready / connected                    → brand-colored text, gentle pulse
/// - needs input                          → amber pulsing text
final class StatusView: NSView {

    /// Bounded width: wide enough for useful status text and the two
    /// right-side chips, but leaves room for Pock widgets and the system
    /// control strip on either side.
    static let preferredWidth: CGFloat = 440

    // MARK: Callbacks

    var onTap: (() -> Void)?

    // MARK: Subviews

    private let iconView = NSImageView(frame: .zero)
    private let label = ShimmerLabel(frame: .zero)
    /// CPU icon for the combined system chip.
    private let cpuIcon = NSImageView(frame: .zero)
    /// CPU + RAM chip, immediately left of the quota chip.
    private let memoryLabel = ShimmerLabel(frame: .zero)
    /// Calendar icon for the quota chip.
    private let usageIcon = NSImageView(frame: .zero)
    /// Always-on Codex quota chip, right-aligned beside the agent status.
    private let usageLabel = ShimmerLabel(frame: .zero)

    // MARK: State

    private var activeAgents: [AgentSnapshot] = []
    private var usage: UsageInfo?
    private var memory: MemoryInfo?
    private var cpuPercent: Int?
    private let memorySlotWidth = chipSlotWidth("100%·99.9G") + 16
    private let usageSlotWidth = chipSlotWidth("100%·168h") + 16
    private let chipGap: CGFloat = 20
    private let rightPadding: CGFloat = 20
    private let agentGroupX: CGFloat = 18
    private var selectedIndex = 0
    private var pinned = false
    private var pinnedSince: Date?
    private var presentationWidth = StatusView.preferredWidth
    private var compactWhenIdle = false

    // Anti-flicker: a displayed agent stays displayed until it has been
    // quiet for this long while another agent is active.
    private let switchHysteresis: TimeInterval = 4

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)

        iconView.imageScaling = .scaleProportionallyDown
        iconView.contentTintColor = .white
        iconView.wantsLayer = true
        addSubview(iconView)
        addSubview(label)

        cpuIcon.image = NSImage(systemSymbolName: "cpu", accessibilityDescription: nil)
        cpuIcon.imageScaling = .scaleProportionallyDown
        cpuIcon.isHidden = true
        addSubview(cpuIcon)

        memoryLabel.setFont(size: 12, weight: .semibold)
        memoryLabel.setShimmering(false)
        memoryLabel.isHidden = true
        addSubview(memoryLabel)

        usageIcon.image = NSImage(systemSymbolName: "calendar", accessibilityDescription: nil)
        usageIcon.imageScaling = .scaleProportionallyDown
        usageIcon.isHidden = true
        addSubview(usageIcon)

        usageLabel.setFont(size: 12, weight: .semibold)
        usageLabel.setShimmering(false)
        usageLabel.isHidden = true
        addSubview(usageLabel)

        let tap = NSClickGestureRecognizer(target: self, action: #selector(handleTap))
        tap.allowedTouchTypes = .direct
        addGestureRecognizer(tap)
    }

    override var intrinsicContentSize: NSSize {
        return NSSize(width: presentationWidth, height: 30)
    }

    override func layout() {
        super.layout()
        if presentationWidth <= 1 {
            iconView.isHidden = true
            label.isHidden = true
            cpuIcon.isHidden = true
            memoryLabel.isHidden = true
            usageIcon.isHidden = true
            usageLabel.isHidden = true
            return
        }
        if compactWhenIdle {
            // Compact idle presentation is a bare logo; the right-side chips
            // are part of the full-width layout only.
            label.isHidden = true
            cpuIcon.isHidden = true
            memoryLabel.isHidden = true
            usageIcon.isHidden = true
            usageLabel.isHidden = true
            iconView.isHidden = false
            iconView.frame = NSRect(
                x: max((bounds.width - 18) / 2, 0),
                y: (bounds.height - 18) / 2,
                width: 18,
                height: 18
            )
            return
        }
        label.isHidden = false
        iconView.isHidden = false

        // Right-side info group: [memory] [usage]. Fixed-width slots keep the
        // agent group and both chips from shifting as their text changes.
        let usageWidth = usageLabel.isHidden ? 0 : usageSlotWidth
        let memoryWidth = memoryLabel.isHidden ? 0 : memorySlotWidth
        let gap = (usageWidth > 0 && memoryWidth > 0) ? chipGap : 0
        let rightGroupWidth = memoryWidth + gap + usageWidth
        let contentWidth = max(bounds.width - rightGroupWidth - rightPadding, 80)

        let maxTextWidth = max(contentWidth - agentGroupX - 18, 60)
        let textWidth = min(label.measuredWidth, maxTextWidth)
        iconView.frame = NSRect(x: agentGroupX, y: (bounds.height - 16) / 2, width: 16, height: 16)
        label.frame = NSRect(x: agentGroupX + 24, y: 0, width: textWidth, height: bounds.height)

        if memoryWidth > 0 {
            let slotX = bounds.width - usageWidth - gap - memoryWidth
            cpuIcon.frame = NSRect(x: slotX, y: (bounds.height - 12) / 2, width: 12, height: 12)
            memoryLabel.frame = NSRect(
                x: slotX + 16,
                y: 0,
                width: memoryWidth - 16,
                height: bounds.height
            )
        }
        if usageWidth > 0 {
            let slotX = bounds.width - usageWidth
            usageIcon.frame = NSRect(x: slotX, y: (bounds.height - 12) / 2, width: 12, height: 12)
            usageLabel.frame = NSRect(
                x: slotX + 16,
                y: 0,
                width: usageWidth - 16,
                height: bounds.height
            )
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: Tap

    @objc private func handleTap() {
        onTap?()
    }

    func cycleSelection() {
        guard activeAgents.count > 1 else { return }
        pinned = true
        pinnedSince = Date()
        selectedIndex = (selectedIndex + 1) % activeAgents.count
        refresh()
    }

    // MARK: State

    func apply(
        agents: [AgentSnapshot],
        usage: UsageInfo? = nil,
        memory: MemoryInfo? = nil,
        cpuPercent: Int? = nil
    ) {
        self.usage = usage
        self.memory = memory
        self.cpuPercent = cpuPercent
        activeAgents = agents.filter { $0.lastActive > 0 }

        refreshUsage()
        refreshMemory()

        if let pinnedSince = pinnedSince, Date().timeIntervalSince(pinnedSince) > 300 {
            pinned = false
            self.pinnedSince = nil
        }
        if !pinned || activeAgents.isEmpty {
            selectedIndex = displayedAgentIndex()
        }
        selectedIndex = min(selectedIndex, max(activeAgents.count - 1, 0))

        updateIdlePresentation()
        refresh()
        needsLayout = true
    }

    private func updateIdlePresentation() {
        let hasAttention = activeAgents.contains { $0.status.isAttention }
        let mode = AgentPrefs.visibilityMode
        let widgetEnabled = AgentPrefs.widgetEnabled && AgentPrefs.hasEnabledAgents
        let shouldCollapse = !hasAttention && mode != "always"

        compactWhenIdle = shouldCollapse
        let nextWidth: CGFloat
        if !widgetEnabled {
            nextWidth = 18
        } else if shouldCollapse {
            nextWidth = mode == "active" ? 18 : 36
        } else {
            nextWidth = Self.preferredWidth
        }
        guard nextWidth != presentationWidth else { return }
        presentationWidth = nextWidth
        alphaValue = (!widgetEnabled || (shouldCollapse && mode == "active")) ? 0.12 : 1
        invalidateIntrinsicContentSize()
        superview?.needsLayout = true
        needsLayout = true
    }

    // MARK: Quota chip

    /// Renders the Codex quota chip. Green while there is comfortable
    /// headroom, amber under 50%, red under 20%; a snapshot-sourced reading
    /// (recorded rather than queried) is dimmed instead of re-labelled.
    private func refreshUsage() {
        guard AgentPrefs.usageEnabled, let usage = usage, usage.remainingPercent >= 0 else {
            usageIcon.isHidden = true
            usageLabel.isHidden = true
            needsLayout = true
            return
        }

        usageLabel.text = usage.unlimited
            ? "∞"
            : "\(usage.remainingPercent)%\(Self.resetSuffix(for: usage, now: Date()))"
        let color = Self.usageColor(usage)
        usageLabel.textColor = color
        let alpha: CGFloat = usage.stale ? 0.85 : 1
        usageLabel.alphaValue = alpha
        usageIcon.contentTintColor = color
        usageIcon.alphaValue = alpha
        usageIcon.isHidden = false
        usageLabel.isHidden = false
        needsLayout = true
    }

    func refreshCountdown() {
        guard usage?.resetsAt != nil else { return }
        refreshUsage()
        needsLayout = true
    }

    private static func resetSuffix(for usage: UsageInfo, now: Date) -> String {
        guard !usage.unlimited, let resetsAt = usage.resetsAt else { return "" }
        let seconds = resetsAt - now.timeIntervalSince1970
        guard seconds > 0 else { return "" }
        if seconds >= 3_600 {
            return "·\(Int(seconds / 3_600))h"
        }
        return "·\(max(1, Int(seconds / 60)))m"
    }

    private static func usageColor(_ usage: UsageInfo) -> NSColor {
        if usage.unlimited { return NSColor(calibratedRed: 0.30, green: 0.85, blue: 0.55, alpha: 1) }
        switch usage.remainingPercent {
        case 50...:
            return NSColor(calibratedRed: 0.30, green: 0.85, blue: 0.55, alpha: 1)
        case 20..<50:
            return NSColor.systemYellow
        default:
            return NSColor.systemRed
        }
    }

    // MARK: Memory chip

    /// Renders the combined CPU + RAM chip just left of the quota chip:
    /// " 38%·12.4G". Color follows memory pressure.
    private func refreshMemory() {
        guard AgentPrefs.memoryEnabled, let memory = memory, memory.totalBytes > 0 else {
            cpuIcon.isHidden = true
            memoryLabel.isHidden = true
            needsLayout = true
            return
        }

        let cpuText = cpuPercent.map { String(format: "%3d%%", $0) } ?? " --%"
        memoryLabel.text = "\(cpuText)·\(Self.formatMemory(memory))"
        let color = Self.memoryColor(memory)
        memoryLabel.textColor = color
        cpuIcon.contentTintColor = color
        cpuIcon.isHidden = false
        memoryLabel.isHidden = false
        needsLayout = true
    }

    static func formatMemory(_ memory: MemoryInfo) -> String {
        let gb = Double(memory.usedBytes) / 1_073_741_824.0
        return gb < 100 ? String(format: "%.1fG", gb) : String(format: "%.0fG", gb)
    }

    private static func memoryColor(_ memory: MemoryInfo) -> NSColor {
        if let pressure = memory.pressure {
            switch pressure {
            case .normal:
                return NSColor(calibratedRed: 0.30, green: 0.85, blue: 0.55, alpha: 1)
            case .warning:
                return NSColor.systemYellow
            case .critical:
                return NSColor.systemRed
            }
        }
        switch memory.usedPercent {
        case ..<70:
            return NSColor(calibratedRed: 0.30, green: 0.85, blue: 0.55, alpha: 1)
        case 70..<90:
            return NSColor.systemYellow
        default:
            return NSColor.systemRed
        }
    }

    private func displayedAgentIndex() -> Int {
        guard !activeAgents.isEmpty else { return 0 }
        let currentID = activeAgents[selectedIndex].agent
        let now = Date().timeIntervalSince1970
        let currentQuietFor = now - activeAgents[selectedIndex].lastActive
        let busiest = activeAgents.first!
        if currentID == busiest.agent { return selectedIndex }
        if currentQuietFor < switchHysteresis { return selectedIndex }
        return 0
    }

    private func refresh() {
        guard !activeAgents.isEmpty else {
            iconView.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)
            iconView.contentTintColor = NSColor(calibratedWhite: 0.45, alpha: 1)
            setDisplayText("No agent running", textColor: .white, shimmer: false)
            setAmbient(.none)
            return
        }
        let agent = activeAgents[selectedIndex]
        let brand = NSColor(hex: agent.color) ?? .white
        iconView.image = logo(for: agent.agent)
            ?? NSImage(systemSymbolName: agent.symbol, accessibilityDescription: nil)

        var text = agent.label
        if let detail = agent.detail, !detail.isEmpty {
            text = "\(agent.label) · \(detail)"
        }

        let shimmerAllowed = AgentPrefs.shimmerEnabled
        switch agent.status {
        case .thinking, .answering, .working:
            iconView.contentTintColor = brand
            setDisplayText(text, textColor: .white, shimmer: shimmerAllowed)
            setAmbient(.none)
        case .responseReady:
            iconView.contentTintColor = NSColor.systemGreen
            setDisplayText(text, textColor: NSColor(calibratedRed: 0.30, green: 0.85, blue: 0.55, alpha: 1), shimmer: false)
            setAmbient(.breathe)
        case .connected:
            iconView.contentTintColor = brand
            setDisplayText(text, textColor: brand, shimmer: false)
            setAmbient(.breathe)
        case .needsInput:
            iconView.contentTintColor = NSColor.systemYellow
            setDisplayText(text, textColor: NSColor.systemYellow, shimmer: false)
            setAmbient(.breathe)
        case .idle, .ready:
            iconView.contentTintColor = brand
            setDisplayText(text, textColor: .white, shimmer: false)
            setAmbient(.pulse)
        }
    }

    private func setDisplayText(_ text: String, textColor: NSColor, shimmer: Bool) {
        label.textColor = textColor
        label.text = text
        label.setShimmering(shimmer && AgentPrefs.shimmerEnabled)
        needsLayout = true
        layout()
    }

    private func logo(for agent: AgentID) -> NSImage? {
        let resource: String
        switch agent {
        case .claude: resource = "Claude"
        case .codex: resource = "ChatGPT"
        case .opencode: resource = "OpenCode"
        }
        guard let image = Bundle(for: type(of: self)).image(forResource: resource) else {
            return nil
        }
        image.isTemplate = false
        return image
    }

    // MARK: Ambient animation

    private enum Ambient {
        case none
        case pulse      // ready: gentle
        case breathe    // response ready / needs input: stronger
    }

    private var ambient: Ambient = .none

    private func setAmbient(_ mode: Ambient) {
        guard mode != ambient else { return }
        ambient = mode
        iconView.layer?.removeAnimation(forKey: "ambientPulse")
        switch mode {
        case .none:
            iconView.layer?.opacity = 1
        case .pulse:
            addAmbientAnimation(from: 0.80, to: 1.0, duration: 2.2)
        case .breathe:
            addAmbientAnimation(from: 0.65, to: 1.0, duration: 1.4)
        }
    }

    private func addAmbientAnimation(from: CGFloat, to: CGFloat, duration: CFTimeInterval) {
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = from
        animation.toValue = to
        animation.duration = duration
        animation.autoreverses = true
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        iconView.layer?.add(animation, forKey: "ambientPulse")
    }
}