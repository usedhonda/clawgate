import Foundation

// Runtime role resolution for the Ambient Context Stream feature.
//
// Design decision (docs/recording-transcription-design.md): the feature is
// client-only. The honest, already-persisted client signal is the Gateway
// relationship — the *server* hosts the OpenClaw Gateway locally (openclawHost
// resolves to localhost), while the *client* points openclawHost at a remote
// Gateway. We resolve role from that, NOT from a persisted `nodeRole` (whose
// persistence was deliberately removed) and NOT from `lineEnabled` (a LINE
// concern, not an identity one).
//
// Fail-closed: the default openclawHost is 127.0.0.1, so an unconfigured host
// resolves to `.server` and ambient capture stays OFF. Only a host explicitly
// pointed at a remote Gateway is treated as the client.
extension AppConfig {
    /// The runtime role derived from the Gateway relationship.
    var runtimeRole: NodeRole {
        let host = openclawHost
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if host.isEmpty { return .server }
        if Self.loopbackHosts.contains(host) { return .server }
        return .client
    }

    /// True when this host is the client (points at a remote Gateway).
    /// Ambient Context Stream is available iff this is true.
    var isClientRole: Bool { runtimeRole == .client }
}
