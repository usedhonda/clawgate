import Foundation

/// Typed reader for the `gateway` section of `~/.openclaw/openclaw.json`.
///
/// Holds only the fields shared by the two call sites (token / port / host).
/// `host` is returned raw so each caller keeps its own fallback: BridgeCore
/// resolves an empty/absent host via `OwnHostnameResolver`, while the WS client
/// falls back to `127.0.0.1`.
struct OpenClawGatewayInfo {
    let token: String
    let port: Int
    let host: String?

    static func load(
        path: String = NSString("~/.openclaw/openclaw.json").expandingTildeInPath
    ) -> OpenClawGatewayInfo? {
        guard let data = FileManager.default.contents(atPath: path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let gateway = json["gateway"] as? [String: Any],
              let auth = gateway["auth"] as? [String: Any],
              let token = auth["token"] as? String, !token.isEmpty else {
            return nil
        }
        let port = gateway["port"] as? Int ?? AppConfig.defaultOpenClawPort
        let host = gateway["host"] as? String
        return OpenClawGatewayInfo(token: token, port: port, host: host)
    }
}
