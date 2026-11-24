import AppKit
import Combine
import Network

/// A permission request from a coding agent, waiting for an answer.
struct AgentRequest: Identifiable {
    let id = UUID()
    let agent: String      // "Claude Code"
    let tool: String       // "Bash", "Edit", …
    let detail: String     // the command, file or URL
    let project: String    // folder name
    let risky: Bool
    let received = Date()
}

/// Something the agent did that isn't a question: it finished, or it needs your attention.
struct AgentEvent: Identifiable {
    let id = UUID()
    let agent: String
    let title: String
    let subtitle: String
    let date = Date()
}

enum AgentDecision { case allow, deny, ask }

/// Receives hook calls from coding agents on this Mac only (127.0.0.1, with a secret token), shows them in the
/// notch and sends the answer back. If the app isn't running, or nobody answers in time, the hook script
/// returns nothing and the agent shows its normal prompt, so nothing ever gets stuck or auto-approved.
final class AgentStore: ObservableObject {
    @Published private(set) var pending: [AgentRequest] = []
    @Published private(set) var events: [AgentEvent] = []
    @Published private(set) var connected: Bool
    @Published var message: String?

    /// How long a request waits for you before the agent's own prompt takes over.
    static let askAfter: TimeInterval = 90

    var onNewRequest: ((AgentRequest) -> Void)?
    var onEvent: ((AgentEvent) -> Void)?

    /// Whether the Agents tab should appear in the tab bar.
    var isVisible: Bool { connected || !pending.isEmpty }

    private var listener: NWListener?
    private var starting = false
    private var token = ""
    private var replies: [UUID: (Data) -> Void] = [:]

    private let supportDir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".notchisland")
    private var scriptURL: URL { supportDir.appendingPathComponent("hook.sh") }
    private var claudeSettings: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/settings.json")
    }

    init() {
        connected = UserDefaults.standard.bool(forKey: "agentsConnected")
    }

    func startIfConnected() {
        if connected { startServer() }
    }

    // MARK: Connect / disconnect

    func connect() {
        message = nil
        do {
            try writeSupportFiles()
        } catch {
            message = "Couldn't create ~/.notchisland: \(error.localizedDescription)"
            return
        }
        if let problem = installClaudeHooks() {
            message = problem
            return
        }
        UserDefaults.standard.set(true, forKey: "agentsConnected")
        connected = true
        startServer()
    }

    func disconnect() {
        removeClaudeHooks()
        UserDefaults.standard.set(false, forKey: "agentsConnected")
        connected = false
        message = nil
        for request in pending { decide(request.id, .ask) }
        listener?.cancel()
        listener = nil
    }

    // MARK: Answering

    func decide(_ id: UUID, _ decision: AgentDecision) {
        guard let reply = replies.removeValue(forKey: id) else { return }
        pending.removeAll { $0.id == id }
        let body: String
        switch decision {
        case .allow:
            body = #"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}"#
        case .deny:
            body = #"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny","message":"Denied from Notch Island"}}}"#
        case .ask:
            body = ""   // no answer: the agent shows its normal prompt
        }
        reply(Data(body.utf8))
    }

    // MARK: Support files (token, port, hook script)

    private func writeSupportFiles() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: supportDir, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        let tokenURL = supportDir.appendingPathComponent("token")
        if let existing = try? String(contentsOf: tokenURL, encoding: .utf8), existing.count >= 32 {
            token = existing.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            token = (UUID().uuidString + UUID().uuidString).replacingOccurrences(of: "-", with: "")
            try token.write(to: tokenURL, atomically: true, encoding: .utf8)
        }
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tokenURL.path)

        let script = """
        #!/bin/sh
        # Notch Island hook. Sends the agent's request to the app and prints the answer.
        # If the app isn't running, prints nothing, so the agent asks you the normal way.
        dir="$HOME/.notchisland"
        token=$(cat "$dir/token" 2>/dev/null) || exit 0
        port=$(cat "$dir/port" 2>/dev/null) || exit 0
        curl -s --connect-timeout 1 --max-time 115 -X POST \\
          -H "X-Notch-Token: $token" -H "X-Notch-Agent: ${2:-claude}" \\
          --data-binary @- "http://127.0.0.1:$port/$1" 2>/dev/null
        exit 0
        """
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
    }

    // MARK: Claude Code settings

    private func isOurs(_ group: [String: Any]) -> Bool {
        let hooks = group["hooks"] as? [[String: Any]] ?? []
        return hooks.contains { hook in
            (hook["command"] as? String)?.contains(".notchisland/hook.sh") == true
        }
    }

    private func installClaudeHooks() -> String? {
        let fm = FileManager.default
        let dir = claudeSettings.deletingLastPathComponent()
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)

        var root: [String: Any] = [:]
        if let data = try? Data(contentsOf: claudeSettings) {
            guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                return "Couldn't read ~/.claude/settings.json. Is it valid JSON?"
            }
            root = object
            let backup = dir.appendingPathComponent("settings.json.notchisland-backup")
            if !fm.fileExists(atPath: backup.path) { try? data.write(to: backup) }
        }

        var hooks = root["hooks"] as? [String: Any] ?? [:]
        let command = "\"\(scriptURL.path)\""
        let entries: [(String, String, Int)] = [
            ("PermissionRequest", "approve", 120),
            ("Stop", "event", 10),
            ("Notification", "event", 10),
        ]
        for (event, mode, timeout) in entries {
            var groups = hooks[event] as? [[String: Any]] ?? []
            if groups.contains(where: { isOurs($0) }) { continue }
            let hook: [String: Any] = ["type": "command", "command": "\(command) \(mode) claude", "timeout": timeout]
            groups.append(["hooks": [hook]])
            hooks[event] = groups
        }
        root["hooks"] = hooks

        do {
            let out = try JSONSerialization.data(withJSONObject: root,
                                                 options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            try out.write(to: claudeSettings, options: .atomic)
            return nil
        } catch {
            return "Couldn't update ~/.claude/settings.json: \(error.localizedDescription)"
        }
    }

    private func removeClaudeHooks() {
        guard let data = try? Data(contentsOf: claudeSettings),
              var root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              var hooks = root["hooks"] as? [String: Any] else { return }
        for event in ["PermissionRequest", "Stop", "Notification"] {
            guard let groups = hooks[event] as? [[String: Any]] else { continue }
            let kept = groups.filter { !isOurs($0) }
            if kept.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = kept }
        }
        if hooks.isEmpty { root.removeValue(forKey: "hooks") } else { root["hooks"] = hooks }
        if let out = try? JSONSerialization.data(withJSONObject: root,
                                                 options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) {
            try? out.write(to: claudeSettings, options: .atomic)
        }
    }

    // MARK: Local server

    private func startServer() {
        guard listener == nil, !starting else { return }
        if (try? writeSupportFiles()) == nil { message = "Couldn't prepare ~/.notchisland"; return }
        starting = true
        startListener(offset: 0)
    }

    private func startListener(offset: Int) {
        guard offset < 10, let port = NWEndpoint.Port(rawValue: UInt16(47653 + offset)) else {
            starting = false
            message = "Couldn't open a local port for agent approvals."
            return
        }
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        guard let newListener = try? NWListener(using: parameters, on: port) else {
            startListener(offset: offset + 1)
            return
        }
        newListener.stateUpdateHandler = { [weak self, weak newListener] state in
            DispatchQueue.main.async {
                guard let self, let newListener else { return }
                switch state {
                case .ready:
                    self.starting = false
                    self.listener = newListener
                    let portFile = self.supportDir.appendingPathComponent("port")
                    try? "\(port.rawValue)".write(to: portFile, atomically: true, encoding: .utf8)
                case .failed:
                    newListener.cancel()
                    if self.listener == nil { self.startListener(offset: offset + 1) }
                default:
                    break
                }
            }
        }
        newListener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        newListener.start(queue: .main)
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: .main)
        read(connection, buffer: Data())
    }

    private func read(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { connection.cancel(); return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if error != nil || buffer.count > 1_000_000 { connection.cancel(); return }
            if let request = HTTPRequest.parse(buffer) {
                self.handle(request, on: connection)
            } else if isComplete {
                connection.cancel()
            } else {
                self.read(connection, buffer: buffer)
            }
        }
    }

    private func respond(_ connection: NWConnection, status: String = "200 OK", body: Data = Data()) {
        let head = "HTTP/1.1 \(status)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        var out = Data(head.utf8)
        out.append(body)
        connection.send(content: out, completion: .contentProcessed { _ in connection.cancel() })
    }

    private func handle(_ request: HTTPRequest, on connection: NWConnection) {
        guard connected, request.method == "POST", !token.isEmpty,
              request.headers["x-notch-token"] == token else {
            respond(connection, status: "403 Forbidden")
            return
        }
        let agent = AgentStore.displayName(request.headers["x-notch-agent"] ?? "claude")
        let json = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any] ?? [:]
        let project = (json["cwd"] as? String).map { ($0 as NSString).lastPathComponent } ?? ""

        switch request.path {
        case "/approve":
            let tool = json["tool_name"] as? String ?? "Tool"
            let input = json["tool_input"] as? [String: Any] ?? [:]
            let detail = String(AgentStore.describe(tool: tool, input: input).prefix(400))
            let item = AgentRequest(agent: agent, tool: tool, detail: detail, project: project,
                                    risky: AgentStore.isRisky(tool: tool, detail: detail))
            pending.append(item)
            replies[item.id] = { [weak self] body in self?.respond(connection, body: body) }
            // If the agent gives up (you answered in the terminal instead), the connection closes: drop the card.
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { [weak self] _, _, isComplete, error in
                if isComplete || error != nil {
                    DispatchQueue.main.async {
                        self?.replies.removeValue(forKey: item.id)
                        self?.pending.removeAll { $0.id == item.id }
                    }
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + AgentStore.askAfter) { [weak self] in
                self?.decide(item.id, .ask)
            }
            onNewRequest?(item)
        case "/event":
            let name = json["hook_event_name"] as? String ?? ""
            let text = json["message"] as? String ?? ""
            if name == "Stop" {
                add(AgentEvent(agent: agent, title: "Finished", subtitle: project))
            } else if name == "Notification", !text.localizedCaseInsensitiveContains("permission") {
                add(AgentEvent(agent: agent, title: text.isEmpty ? "Needs your attention" : text, subtitle: project))
            }
            respond(connection)
        default:
            respond(connection, status: "404 Not Found")
        }
    }

    private func add(_ event: AgentEvent) {
        events.insert(event, at: 0)
        if events.count > 8 { events.removeLast(events.count - 8) }
        onEvent?(event)
    }

    // MARK: Helpers

    static func displayName(_ id: String) -> String {
        switch id.lowercased() {
        case "claude": return "Claude Code"
        case "codex": return "Codex"
        case "cursor": return "Cursor"
        case "gemini": return "Gemini CLI"
        default: return id
        }
    }

    static func describe(tool: String, input: [String: Any]) -> String {
        switch tool {
        case "Bash": return input["command"] as? String ?? ""
        case "Edit", "Write", "MultiEdit", "Read":
            return input["file_path"] as? String ?? ""
        case "NotebookEdit": return input["notebook_path"] as? String ?? ""
        case "WebFetch": return input["url"] as? String ?? ""
        case "WebSearch": return input["query"] as? String ?? ""
        default:
            if let data = try? JSONSerialization.data(withJSONObject: input),
               let text = String(data: data, encoding: .utf8) { return text }
            return ""
        }
    }

    /// Commands worth a second look. This only colours the card; it never decides anything.
    static func isRisky(tool: String, detail: String) -> Bool {
        guard tool == "Bash" else { return false }
        let text = detail.lowercased()
        let flags = ["rm -", "sudo ", "git push", "--force", "mkfs", "dd if=", "chmod -r", "| sh", "| bash", "drop table", "> /dev/"]
        return flags.contains { text.contains($0) }
    }
}

/// Just enough HTTP to read a hook's POST.
struct HTTPRequest {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data

    /// Returns nil until the whole request (headers and body) has arrived.
    static func parse(_ data: Data) -> HTTPRequest? {
        guard let separator = data.range(of: Data("\r\n\r\n".utf8)),
              let head = String(data: data.subdata(in: data.startIndex..<separator.lowerBound), encoding: .utf8) else {
            return nil
        }
        var lines = head.components(separatedBy: "\r\n")
        let first = lines.removeFirst().split(separator: " ")
        guard first.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = String(line[..<colon]).lowercased()
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }
        let length = Int(headers["content-length"] ?? "") ?? 0
        let bodyStart = separator.upperBound
        guard data.endIndex - bodyStart >= length else { return nil }
        return HTTPRequest(method: String(first[0]), path: String(first[1]), headers: headers,
                           body: data.subdata(in: bodyStart..<(bodyStart + length)))
    }
}
