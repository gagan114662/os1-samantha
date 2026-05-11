import Foundation
import Network

/// Tiny HTTP plumbing for the localhost voice server. Extracted from
/// `RealtimeVoiceSessionServer.swift` so per-feature endpoint extensions
/// (Codex, WUPHF, Orgo, ElevenLabs) can return / receive these types
/// without the parent file having to be one massive grab-bag.

struct HTTPRequest {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data

    init?(data: Data) {
        let marker = Data("\r\n\r\n".utf8)
        guard let headerRange = data.range(of: marker) else { return nil }

        let headerData = data[..<headerRange.lowerBound]
        guard let headerText = String(data: headerData, encoding: .utf8) else { return nil }

        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let requestParts = requestLine.split(separator: " ", maxSplits: 2).map(String.init)
        guard requestParts.count >= 2 else { return nil }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let separator = line.firstIndex(of: ":") else { continue }
            let name = line[..<separator].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines)
            headers[name] = value
        }

        let contentLength = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = headerRange.upperBound
        guard data.count >= bodyStart + contentLength else { return nil }

        method = requestParts[0].uppercased()
        path = String(requestParts[1].split(separator: "?", maxSplits: 1).first ?? "/")
        self.headers = headers
        body = Data(data[bodyStart..<(bodyStart + contentLength)])
    }
}

struct HTTPResponse {
    let status: Int
    let contentType: String
    let body: Data

    var reasonPhrase: String {
        switch status {
        case 200..<300: "OK"
        case 400:       "Bad Request"
        case 404:       "Not Found"
        case 413:       "Payload Too Large"
        case 500:       "Internal Server Error"
        case 502:       "Bad Gateway"
        default:        "HTTP"
        }
    }

    static func html(status: Int, body: String) -> HTTPResponse {
        HTTPResponse(status: status, contentType: "text/html; charset=utf-8", body: Data(body.utf8))
    }

    static func plain(status: Int, body: String) -> HTTPResponse {
        HTTPResponse(status: status, contentType: "text/plain; charset=utf-8", body: Data(body.utf8))
    }

    /// Encode an arbitrary `[String: Any]` (JSONSerialization-compatible) as
    /// a JSON HTTP response. Falls back to a generic error if encoding fails.
    static func jsonDict(_ dict: [String: Any], status: Int = 200) -> HTTPResponse {
        let safe = JSONSerialization.isValidJSONObject(dict)
            ? dict
            : ["ok": false, "error": "Non-encodable response"]
        guard let data = try? JSONSerialization.data(withJSONObject: safe) else {
            return .plain(status: 500, body: "Failed to encode JSON response")
        }
        return HTTPResponse(status: status, contentType: "application/json; charset=utf-8", body: data)
    }

    static func json<T: Encodable>(_ value: T, status: Int = 200) -> HTTPResponse {
        do {
            let data = try JSONEncoder().encode(value)
            return HTTPResponse(status: status, contentType: "application/json; charset=utf-8", body: data)
        } catch {
            return .plain(status: 500, body: "Failed to encode JSON response: \(error.localizedDescription)")
        }
    }
}

struct RealtimeToolsResponse: Encodable {
    let tools: [RealtimeOrgoMCPTool]
    let orgo: RealtimeOrgoStatus
}

struct RealtimeOrgoStatus: Encodable {
    let enabled: Bool
    let status: String
}

extension Data {
    mutating func appendString(_ string: String) {
        append(contentsOf: string.utf8)
    }
}
