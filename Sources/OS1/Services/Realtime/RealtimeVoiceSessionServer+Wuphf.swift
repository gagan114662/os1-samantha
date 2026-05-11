import Foundation

/// Endpoints that bridge from the WebView (or external clients like the
/// Telegram bot) into the WUPHF AI office running at localhost:7891.
/// The voice server is the only thing exposed via the random-port file,
/// so everything that wants to talk to WUPHF flows through here.
extension RealtimeVoiceSessionServer {

    func proxyToWUPHF(method: String, path: String, body: [String: Any]? = nil) async -> HTTPResponse {
        guard let url = URL(string: "http://127.0.0.1:7891\(path)") else {
            return .plain(status: 500, body: "Bad WUPHF URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        request.timeoutInterval = 25
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 502
            return HTTPResponse(status: status, contentType: "application/json; charset=utf-8", body: data)
        } catch {
            return HTTPResponse.jsonDict(
                ["ok": false, "error": "WUPHF unreachable: \(error.localizedDescription). Is `wuphf` running? (run `wuphf --no-open --no-nex --pack starter` in a terminal)"],
                status: 502
            )
        }
    }
}
