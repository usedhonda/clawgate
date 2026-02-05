import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix

final class BridgeServer {
    private let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    private let core: BridgeCore
    private let host: String
    private let port: Int

    private var channel: Channel?

    init(core: BridgeCore, host: String = "127.0.0.1", port: Int = 8765) {
        self.core = core
        self.host = host
        self.port = port
    }

    func start() throws {
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline().flatMap {
                    channel.pipeline.addHandler(BridgeRequestHandler(core: self.core))
                }
            }
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)

        channel = try bootstrap.bind(host: host, port: port).wait()
    }

    func stop() {
        try? channel?.close().wait()
        try? group.syncShutdownGracefully()
    }
}
