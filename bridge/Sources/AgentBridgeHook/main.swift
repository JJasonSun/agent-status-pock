import Foundation
import Darwin

// agentbridge-hook <claude|codex>
//
// Reads a Claude Code / Codex hook payload on stdin and forwards one
// compact event to AgentBridge. Fire-and-forget: always exits 0 so a
// missing bridge never fails the agent's hook, and the request is
// bounded to a quarter second.

signal(SIGPIPE, SIG_IGN)

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

// MARK: - Mapping

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
          url.scheme == "http",
          let host = url.host,
          let port = url.port,
          let body = try? JSONSerialization.data(withJSONObject: payload) else { return }
    let path = url.path.isEmpty ? "/" : url.path

    // Raw socket keeps the process tiny: no URLSession session spin-up
    // on every hook invocation. getaddrinfo also accepts "localhost" and
    // IPv6, unlike inet_addr.
    var hints = addrinfo()
    hints.ai_family = AF_UNSPEC
    hints.ai_socktype = SOCK_STREAM
    var results: UnsafeMutablePointer<addrinfo>?
    guard getaddrinfo(host, String(port), &hints, &results) == 0, let first = results else {
        return
    }
    defer {
        if let results { freeaddrinfo(results) }
    }

    let hostHeader = host.contains(":") ? "[\(host)]" : host
    var request = "POST \(path) HTTP/1.1\r\n"
    request += "Host: \(hostHeader):\(port)\r\n"
    request += "Content-Type: application/json\r\n"
    request += "Content-Length: \(body.count)\r\n"
    request += "Connection: close\r\n\r\n"

    var out = Data(request.utf8)
    out.append(body)

    var current: UnsafeMutablePointer<addrinfo>? = first
    while let info = current {
        let fd = socket(info.pointee.ai_family, info.pointee.ai_socktype, info.pointee.ai_protocol)
        if fd >= 0 {
            var timeout = timeval(tv_sec: 0, tv_usec: 250_000)
            setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            var noSigPipe: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

            if let addr = info.pointee.ai_addr,
               connect(fd, addr, info.pointee.ai_addrlen) == 0 {
                var sent = 0
                out.withUnsafeBytes { raw in
                    guard let base = raw.baseAddress else { return }
                    while sent < out.count {
                        let count = send(fd, base.advanced(by: sent), out.count - sent, 0)
                        if count <= 0 { break }
                        sent += count
                    }
                }
                // Best-effort drain so the peer can finish the response.
                var sink = [UInt8](repeating: 0, count: 256)
                _ = sink.withUnsafeMutableBytes { recv(fd, $0.baseAddress, $0.count, 0) }
                close(fd)
                return
            }
            close(fd)
        }
        current = info.pointee.ai_next
    }
}
