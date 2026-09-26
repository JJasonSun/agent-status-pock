import Foundation

// agentbridge-hook <claude|codex>
//
// Reads a Claude Code / Codex hook payload on stdin and forwards one
// compact event to AgentBridge. Fire-and-forget: always exits 0 so a
// missing bridge never fails the agent's hook, and the request is
// bounded to a quarter second.

let agent = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "claude"
let bridgeURL = ProcessInfo.processInfo.environment["AGENTBRIDGE_URL"]
    ?? "http://127.0.0.1:3939"

guard let stdin = try? FileHandle.standardInput.readToEnd(),
      let root = try? JSONSerialization.jsonObject(with: stdin) as? [String: Any]
else {
    exit(0)
}

let hookEvent = root["hook_event_name"] as? String ?? ""
let toolName = root["tool_name"] as? String ?? ""
let toolInput = root["tool_input"] as? [String: Any] ?? [:]
let notificationType = (root["notification_type"] as? String) ?? ""
let message = (root["message"] as? String) ?? ""

guard let outbound = mapEvent(
    hookEvent: hookEvent,
    toolName: toolName,
    detail: summarize(toolInput),
    notificationType: notificationType,
    message: message
) else {
    exit(0)
}

var payload: [String: Any] = [
    "agent": agent,
    "event": outbound.event,
    "ts": Date().timeIntervalSince1970,
]
if let tool = outbound.tool { payload["tool"] = tool }
if let detail = outbound.detail { payload["detail"] = detail }

postJSON(urlString: bridgeURL + "/v1/event", payload: payload)
exit(0)

// MARK: - Mapping (mirrors hooks/agentbridge-hook.py)

func mapEvent(
    hookEvent: String,
    toolName: String,
    detail: String?,
    notificationType: String,
    message: String
) -> (event: String, tool: String?, detail: String?)? {
    switch hookEvent {
    case "PreToolUse":
        if toolName == "AskUserQuestion" {
            return ("needs_input", nil, "Agent is asking a question")
        }
        return ("tool_start", toolName.isEmpty ? nil : toolName, detail)

    case "MessageDisplay":
        return ("answering", nil, nil)

    // A finished tool is not the same as "thinking": the hub uses `tool_done`
    // to drop its in-flight count and only then settle on Thinking. Mapping
    // PostToolUse straight to thinking made parallel tools look idle while
    // siblings were still running.
    case "PostToolUse", "PostToolUseFailure":
        return ("tool_done", nil, nil)

    // User prompt starts a new turn — must be able to wake the bar after Stop.
    case "UserPromptSubmit":
        return ("prompt", nil, nil)

    case "SubagentStart", "PreCompact", "PostCompact":
        return ("thinking", nil, nil)

    // Late SubagentStop after Stop must not re-light a settled bar; the
    // reducer ignores thinking once the agent is ready/idle/responseReady.
    case "SubagentStop":
        return ("thinking", nil, nil)

    case "SessionStart":
        return ("session_start", nil, nil)

    case "Stop", "StopFailure":
        return ("stop", nil, nil)

    case "SessionEnd":
        return ("session_end", nil, nil)

    case "Notification":
        let text = (notificationType.isEmpty ? message : notificationType).lowercased()
        if text.contains("input") || text.contains("question") {
            return ("needs_input", nil, "Agent is asking a question")
        }
        if text.contains("idle") || text.contains("completed") {
            return ("ready", nil, nil)
        }
        let shown = message.isEmpty ? notificationType : message
        return ("notification", nil, String(shown.prefix(120)))

    default:
        return nil
    }
}

/// Short human-readable target for tool_start, matching the Python hook.
func summarize(_ toolInput: [String: Any]) -> String? {
    guard !toolInput.isEmpty else { return nil }
    let keys = [
        "command", "file_path", "pattern", "query", "description",
        "prompt", "path", "url", "subagent_type", "agent_type",
    ]
    var parts: [String] = []
    for key in keys {
        if let value = toolInput[key] as? String {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { parts.append(trimmed) }
        }
    }
    if parts.isEmpty {
        guard let data = try? JSONSerialization.data(withJSONObject: toolInput),
              let text = String(data: data, encoding: .utf8) else { return nil }
        return String(text.prefix(140))
    }
    return String(parts.joined(separator: " | ").prefix(140))
}

// MARK: - Fire-and-forget POST

func postJSON(urlString: String, payload: [String: Any]) {
    guard let url = URL(string: urlString),
          let body = try? JSONSerialization.data(withJSONObject: payload) else { return }

    // Raw socket keeps the process tiny: no URLSession session spin-up
    // on every hook invocation.
    guard let host = url.host, let port = url.port else { return }
    let path = url.path.isEmpty ? "/" : url.path

    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { return }
    defer { close(fd) }

    var timeout = timeval(tv_sec: 0, tv_usec: 250_000)
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = in_port_t(port).bigEndian
    addr.sin_addr.s_addr = inet_addr(host)

    let connected = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard connected == 0 else { return }

    var request = "POST \(path) HTTP/1.1\r\n"
    request += "Host: \(host):\(port)\r\n"
    request += "Content-Type: application/json\r\n"
    request += "Content-Length: \(body.count)\r\n"
    request += "Connection: close\r\n\r\n"

    var out = Data(request.utf8)
    out.append(body)
    _ = out.withUnsafeBytes { raw -> Int in
        guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return -1 }
        return send(fd, base, raw.count, 0)
    }
    // Best-effort drain so the peer can finish the response and we don't
    // RST mid-reply; ignore failures.
    var sink = [UInt8](repeating: 0, count: 256)
    _ = recv(fd, &sink, sink.count, 0)
}
