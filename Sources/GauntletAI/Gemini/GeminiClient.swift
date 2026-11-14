import Foundation

/// Gemini over plain REST. The key goes in a header, never in the URL or the log.
public final class GeminiClient: @unchecked Sendable {
    /// One place for the default model. Overridden by Settings or the GEMINI_MODEL environment variable.
    public static let defaultModel = "gemini-3.8-flash"

    public static func model(override: String?) -> String {
        if let override, !override.isEmpty { return override }
        if let env = ProcessInfo.processInfo.environment["GEMINI_MODEL"], !env.isEmpty { return env }
        return defaultModel
    }

    private let session: URLSession

    public init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 40
        session = URLSession(configuration: config)
    }

    public func stream(body: Data, apiKey: String, model: String) -> AsyncThrowingStream<GeminiEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):streamGenerateContent?alt=sse") else {
                        throw JuneError.http(400, "Bad model name")
                    }
                    var request = URLRequest(url: url)
                    request.httpMethod = "POST"
                    request.httpBody = body
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")

                    let (bytes, response) = try await session.bytes(for: request)
                    guard let http = response as? HTTPURLResponse else { throw JuneError.noNetwork }
                    if http.statusCode != 200 {
                        var data = Data()
                        for try await byte in bytes {
                            data.append(byte)
                            if data.count > 4000 { break }
                        }
                        throw Self.httpError(http.statusCode, data)
                    }
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload.isEmpty || payload == "[DONE]" { continue }
                        for event in try GeminiSSE.parse(payload) { continuation.yield(event) }
                    }
                    continuation.yield(.done)
                    continuation.finish()
                } catch let error as URLError {
                    continuation.finish(throwing: Self.map(error))
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func httpError(_ status: Int, _ data: Data) -> JuneError {
        var detail = ""
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = object["error"] as? [String: Any], let message = error["message"] as? String {
            detail = String(message.prefix(160))
        }
        return .http(status, detail)
    }

    static func map(_ error: URLError) -> JuneError {
        switch error.code {
        case .timedOut: return .timeout
        case .cancelled: return .timeout
        default: return .noNetwork
        }
    }
}
