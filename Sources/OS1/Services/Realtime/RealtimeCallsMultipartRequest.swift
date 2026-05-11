import Foundation

struct RealtimeCallsMultipartRequest {
    let body: Data
    let contentType: String

    static func make(sdp: String, session: String, boundary: String = "OS1RealtimeBoundary-\(UUID().uuidString)") -> RealtimeCallsMultipartRequest {
        var body = Data()
        body.appendFormField(name: "sdp", value: sdp, boundary: boundary, contentType: "application/sdp")
        body.appendFormField(name: "session", value: session, boundary: boundary, contentType: "application/json")
        body.appendString("--\(boundary)--\r\n")

        return RealtimeCallsMultipartRequest(
            body: body,
            contentType: "multipart/form-data; boundary=\(boundary)"
        )
    }
}

private extension Data {
    mutating func appendFormField(name: String, value: String, boundary: String, contentType: String) {
        appendString("--\(boundary)\r\n")
        appendString("Content-Disposition: form-data; name=\"\(name)\"\r\n")
        appendString("Content-Type: \(contentType)\r\n")
        appendString("\r\n")
        appendString(value)
        appendString("\r\n")
    }

    // appendString lives in RealtimeVoiceHTTP.swift (shared utility for the
    // realtime voice server). Removed from here to avoid duplicate-symbol.
}
