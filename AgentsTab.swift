import AppKit
import Combine

/// One waiting permission request: what the agent wants to do, and the buttons to answer.
final class AgentRequestRow: NSView {
    override var isFlipped: Bool { true }

    init(request: AgentRequest, width: CGFloat, answer: @escaping (AgentDecision) -> Void) {
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: AgentRequestRow.height))
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.backgroundColor = UI.dim(0.07).cgColor
        if request.risky {
            layer?.borderWidth = 1
            layer?.borderColor = NSColor.systemOrange.withAlphaComponent(0.7).cgColor
        }

        let who = request.project.isEmpty ? request.agent : "\(request.agent) · \(request.project)"
        let title = UI.label("\(who) wants to use \(request.tool)", size: 11, weight: .semibold,
                             color: request.risky ? .systemOrange : UI.dim(0.65))
        title.frame = NSRect(x: 12, y: 8, width: width - 24, height: 14)
        addSubview(title)

        let detail = UI.label(request.detail.isEmpty ? "(no details)" : request.detail, size: 11, lines: 2)
        detail.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        detail.lineBreakMode = .byCharWrapping
        detail.cell?.truncatesLastVisibleLine = true
        detail.frame = NSRect(x: 12, y: 25, width: width - 24, height: 30)
        addSubview(detail)

        let allow = ClosureButton.pill("Allow", fill: NSColor.systemGreen.withAlphaComponent(0.85), height: 24) { answer(.allow) }
        let deny = ClosureButton.pill("Deny", fill: NSColor.systemRed.withAlphaComponent(0.85), height: 24) { answer(.deny) }
        let ask = ClosureButton.pill("Ask in terminal", size: 11, fill: UI.dim(0.12), textColor: UI.dim(0.8), height: 24) { answer(.ask) }
        var x: CGFloat = 12
        for button in [allow, deny, ask] {
            button.frame.origin = NSPoint(x: x, y: 58)
            addSubview(button)
            x += button.frame.width + 8
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    static let height: CGFloat = 92
}

/// Approvals from coding agents (Claude Code first), without switching windows.
final class AgentsTabView: TabContentView {
    private let store: AgentStore
    private let scroll = UI.scrollView(horizontal: false)
    private let doc = FlippedView()
    private let icon = NSImageView()
    private let title = UI.label("", size: 14, weight: .semibold, alignment: .center)
    private let detail = UI.label("", size: 12, color: UI.dim(0.6), alignment: .center, lines: 3)
    private let status = UI.label("", size: 11, color: .systemOrange, alignment: .center, lines: 2)
    private let connectButton = ClosureButton.pill("Connect Claude Code", fill: NSColor.systemBlue) {}
    private let footer = ClosureButton(frame: .zero)
    private var cancellable: AnyCancellable?

    init(store: AgentStore) {
        self.store = store
        super.init(frame: .zero)
        icon.image = UI.symbol("terminal.fill", size: 22, weight: .regular)
        icon.contentTintColor = UI.dim(0.6)
        detail.cell?.wraps = true
        connectButton.handler = { [weak store] in store?.connect() }
        footer.handler = { [weak store] in store?.disconnect() }
        scroll.documentView = doc
        for view in [scroll, icon, title, detail, status, connectButton, footer] as [NSView] { addSubview(view) }
        cancellable = store.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in DispatchQueue.main.async { self?.rebuild() } }
        rebuild()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func layoutContents() { rebuild() }

    private func rebuild() {
        let w = bounds.width
        let h = bounds.height
        guard w > 0 else { return }

        let showList = store.connected
        scroll.isHidden = !showList
        footer.isHidden = !showList
        for view in [icon, title, detail, connectButton] as [NSView] { view.isHidden = showList && !store.pending.isEmpty }

        status.stringValue = store.message ?? ""
        status.isHidden = (store.message ?? "").isEmpty

        if !showList {
            title.stringValue = "Approve your coding agent from the notch"
            detail.stringValue = "Permission requests from Claude Code show up here, so you don't have to switch back to your editor. If the notch isn't running, your agent asks you as usual."
            connectButton.isHidden = false
            layoutCentered(width: w, height: h, hasButton: true)
            return
        }

        footer.setText("Connected to Claude Code · Disconnect", size: 10, weight: .medium, color: UI.dim(0.4))
        footer.frame = NSRect(x: 0, y: h - 16, width: w, height: 16)
        scroll.frame = NSRect(x: 0, y: 0, width: w, height: h - 20)

        doc.subviews.forEach { $0.removeFromSuperview() }
        let docWidth = max(scroll.bounds.width, 1)
        var y: CGFloat = 0

        if store.pending.isEmpty {
            title.stringValue = "All quiet"
            detail.stringValue = "When an agent asks to run something, it appears here."
            connectButton.isHidden = true
            title.isHidden = false; detail.isHidden = false; icon.isHidden = false
            if store.events.isEmpty {
                layoutCentered(width: w, height: h - 20, hasButton: false)
            } else {
                // Keep it short when there is recent activity to show.
                icon.isHidden = true
                title.frame = NSRect(x: 0, y: 0, width: w, height: 18)
                detail.isHidden = true
                scroll.frame = NSRect(x: 0, y: 24, width: w, height: h - 24 - 20)
                let width = max(scroll.bounds.width, 1)
                for event in store.events.prefix(6) {
                    let row = UI.label("\(event.agent) · \(event.title)\(event.subtitle.isEmpty ? "" : "  —  \(event.subtitle)")",
                                       size: 11, color: UI.dim(0.7))
                    row.frame = NSRect(x: 4, y: y, width: width - 8, height: 22)
                    doc.addSubview(row)
                    y += 22
                }
            }
        } else {
            for request in store.pending {
                let id = request.id
                let row = AgentRequestRow(request: request, width: docWidth) { [weak self] decision in
                    self?.store.decide(id, decision)
                }
                row.frame.origin = NSPoint(x: 0, y: y)
                doc.addSubview(row)
                y += AgentRequestRow.height + 8
            }
        }
        doc.frame = NSRect(x: 0, y: 0, width: docWidth, height: max(y, scroll.bounds.height))
    }

    private func layoutCentered(width w: CGFloat, height h: CGFloat, hasButton: Bool) {
        let contentHeight: CGFloat = hasButton ? 140 : 80
        var y = max((h - contentHeight) / 2, 0)
        icon.frame = NSRect(x: w / 2 - 14, y: y, width: 28, height: 28); y += 34
        title.frame = NSRect(x: 0, y: y, width: w, height: 18); y += 22
        detail.frame = NSRect(x: 30, y: y, width: w - 60, height: hasButton ? 48 : 18); y += hasButton ? 54 : 20
        if hasButton {
            connectButton.frame.origin = NSPoint(x: (w - connectButton.frame.width) / 2, y: y)
            status.frame = NSRect(x: 20, y: y + 32, width: w - 40, height: 28)
        }
    }
}
