import Foundation

public enum GeminiEvent: Sendable, Equatable {
    case text(String)
    case functionCall(name: String, args: [String: String])
    case blocked(String)
    case done
}

/// Parses one `data:` payload of a streamGenerateContent SSE response.
public enum GeminiSSE {
    public static func parse(_ payload: String) throws -> [GeminiEvent] {
        guard let data = payload.data(using: .utf8),
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        var events: [GeminiEvent] = []
        if let feedback = root["promptFeedback"] as? [String: Any], let reason = feedback["blockReason"] as? String {
            events.append(.blocked(reason))
        }
        if let error = root["error"] as? [String: Any] {
            let code = error["code"] as? Int ?? 0
            throw JuneError.http(code, (error["message"] as? String) ?? "")
        }
        for candidate in (root["candidates"] as? [[String: Any]]) ?? [] {
            if let content = candidate["content"] as? [String: Any] {
                for part in (content["parts"] as? [[String: Any]]) ?? [] {
                    if let thought = part["thought"] as? Bool, thought { continue }
                    if let text = part["text"] as? String, !text.isEmpty {
                        events.append(.text(text))
                    } else if let call = part["functionCall"] as? [String: Any], let name = call["name"] as? String {
                        var args: [String: String] = [:]
                        for (key, value) in (call["args"] as? [String: Any]) ?? [:] {
                            if let s = value as? String { args[key] = s } else { args[key] = "\(value)" }
                        }
                        events.append(.functionCall(name: name, args: args))
                    }
                }
            }
            if let reason = candidate["finishReason"] as? String, reason == "SAFETY" || reason == "PROHIBITED_CONTENT" {
                events.append(.blocked(reason))
            }
        }
        return events
    }
}
