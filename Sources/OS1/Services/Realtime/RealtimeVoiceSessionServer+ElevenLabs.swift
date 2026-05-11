import Foundation

/// Endpoints that broker access to ElevenLabs Conversational AI.
/// Currently just the signed-URL exchange — the WebView calls
/// `GET /signed-url`, we hit ElevenLabs' get-signed-url endpoint with the
/// agent's API key, return the resulting `wss://` URL the WebView opens.
extension RealtimeVoiceSessionServer {

    func fetchSignedURL(apiKey: String, agentID: String) async -> HTTPResponse {
        var components = URLComponents(string: "https://api.elevenlabs.io/v1/convai/conversation/get-signed-url")!
        components.queryItems = [URLQueryItem(name: "agent_id", value: agentID)]
        guard let url = components.url else {
            return .plain(status: 500, body: "Failed to build signed-url request")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                return .plain(status: 502, body: "ElevenLabs returned a non-HTTP response")
            }
            if (200..<300).contains(httpResponse.statusCode) {
                return HTTPResponse(status: httpResponse.statusCode, contentType: "application/json; charset=utf-8", body: data)
            }
            let body = String(data: data, encoding: .utf8) ?? "ElevenLabs signed URL request failed"
            return .plain(status: httpResponse.statusCode, body: body)
        } catch {
            return .plain(status: 502, body: error.localizedDescription)
        }
    }
}
