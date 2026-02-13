import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOWebSocket

final class BridgeServer {
    private let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    private let core: BridgeCore
    private let host: String
    private let port: Int
    private let federationServer: FederationServer?
    private let configStore: ConfigStore
    private let logger: AppLogger

    private var channel: Channel?

    init(core: BridgeCore, host: String = "127.0.0.1", port: Int = 8765,
         federationServer: FederationServer? = nil, configStore: ConfigStore, logger: AppLogger) {
        self.core = core
        self.host = host
        self.port = port
        self.federationServer = federationServer
        self.configStore = configStore
        self.logger = logger
    }

    func start() throws {
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { [self] channel in
                if let federationServer = self.federationServer {
                    return self.configureWithFederation(channel: channel, federationServer: federationServer)
                } else {
                    return channel.pipeline.configureHTTPServerPipeline().flatMap {
                        channel.pipeline.addHandler(BridgeRequestHandler(core: self.core))
                    }
                }
            }
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)

        channel = try bootstrap.bind(host: host, port: port).wait()
    }

    func stop() {
        try? channel?.close().wait()
        try? group.syncShutdownGracefully()
    }

    private func configureWithFederation(channel: Channel, federationServer: FederationServer) -> EventLoopFuture<Void> {
        let cfg = self.configStore.load()
        let expectedToken = cfg.federationToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let logger = self.logger
        let core = self.core

        let upgrader = NIOWebSocketServerUpgrader(
            shouldUpgrade: { channel, head in
                // Only upgrade /federation paths
                guard head.uri.hasPrefix("/federation") else {
                    return channel.eventLoop.makeFailedFuture(WebSocketUpgradeError.unsupportedPath)
                }
                // Check bearer token if configured
                if !expectedToken.isEmpty {
                    let auth = head.headers.first(name: "Authorization") ?? ""
                    guard auth == "Bearer \(expectedToken)" else {
                        return channel.eventLoop.makeFailedFuture(WebSocketUpgradeError.unauthorized)
                    }
                }
                return channel.eventLoop.makeSucceededFuture(HTTPHeaders())
            },
            upgradePipelineHandler: { channel, _ in
                // Remove BridgeRequestHandler before adding WebSocket handler —
                // otherwise it receives WebSocket frames and crashes trying to decode as HTTP.
                channel.pipeline.handler(type: BridgeRequestHandler.self).flatMap { handler in
                    channel.pipeline.removeHandler(handler)
                }.flatMap {
                    channel.pipeline.addHandler(
                        FederationServerHandler(federationServer: federationServer, logger: logger)
                    )
                }
            }
        )

        return channel.pipeline.configureHTTPServerPipeline(
            withServerUpgrade: (
                upgraders: [upgrader] as [HTTPServerProtocolUpgrader],
                completionHandler: { context in
                    // Belt-and-suspenders: also remove BridgeRequestHandler here in case
                    // the upgradePipelineHandler removal didn't take effect in time.
                    context.pipeline.removeHandler(name: "bridge-request-handler", promise: nil)
                }
            )
        ).flatMap {
            channel.pipeline.addHandler(BridgeRequestHandler(core: core), name: "bridge-request-handler")
        }
    }
}

enum WebSocketUpgradeError: Error {
    case unsupportedPath
    case unauthorized
}
