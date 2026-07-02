import Foundation
import NIOHTTP1
import XCTest
@testable import ClawGate

/// Characterization matrix for the ClawGate HTTP routing surface.
///
/// The set of (method, path) pairs is a public contract: the 405-vs-404
/// behavior and every endpoint's reachability must not shift. These tests
/// freeze that surface so the ES-02 single-sourcing refactor (and any future
/// route change) is provably behavior-preserving.
final class BridgeRouteMatrixTests: XCTestCase {

    /// Canonical expected route table (37 entries). Any add/remove/method
    /// change to `BridgeRequestHandler.routes` breaks this freeze.
    private static let expectedRoutes: [(HTTPMethod, String)] = [
        (.GET, "/v1/health"),
        (.GET, "/v1/config"),
        (.GET, "/v1/adapters"),
        (.GET, "/v1/tmux/session-mode"),
        (.PUT, "/v1/tmux/session-mode"),
        (.GET, "/v1/poll"),
        (.GET, "/v1/stats"),
        (.GET, "/v1/ops/logs"),
        (.GET, "/v1/autonomous/status"),
        (.POST, "/v1/send"),
        (.POST, "/v1/bubble-notify"),
        (.GET, "/v1/context"),
        (.GET, "/v1/messages"),
        (.GET, "/v1/conversations"),
        (.GET, "/v1/axdump"),
        (.GET, "/v1/doctor"),
        (.GET, "/v1/openclaw-info"),
        (.GET, "/v1/events"),
        (.POST, "/v1/debug/inject"),
        (.POST, "/v1/oauth/safari-open"),
        (.GET, "/v1/debug/line-dedup"),
        (.GET, "/v1/debug/line-health"),
        (.GET, "/v1/debug/tmux-direct"),
        (.GET, "/v1/tmux/prompt-state"),
        (.POST, "/v1/tproj-msg-deliver"),
        (.GET, "/v1/project-context-read"),
        (.POST, "/v1/line/ensure-conversation"),
        (.POST, "/v1/debug/reset-line-baseline"),
        (.GET, "/v1/ambient/status"),
        (.POST, "/v1/ambient/stream/start"),
        (.POST, "/v1/ambient/stream/stop"),
        (.POST, "/v1/ambient/capture/pause"),
        (.POST, "/v1/ambient/capture/resume"),
        (.POST, "/v1/ambient/capture/recover"),
        (.POST, "/v1/ambient/capture/_simulate_wedge"),
        (.GET, "/v1/ambient/sessions"),
        (.GET, "/v1/ambient/transcript"),
    ]

    /// Routes reachable via the in-process federation switch
    /// (`BridgeCore.handleFederationCommand`). This is a strict subset of the
    /// full route table — the remaining 23 routes fall to federation's default
    /// 404 branch. Freezing it turns the 3rd route enumeration into a
    /// drift-detectable guard (3 duplicated lists -> 2 + guard).
    private static let federationRoutes: [(HTTPMethod, String)] = [
        (.GET, "/v1/health"),
        (.GET, "/v1/config"),
        (.GET, "/v1/tmux/session-mode"),
        (.PUT, "/v1/tmux/session-mode"),
        (.GET, "/v1/autonomous/status"),
        (.GET, "/v1/poll"),
        (.POST, "/v1/send"),
        (.GET, "/v1/context"),
        (.GET, "/v1/messages"),
        (.GET, "/v1/conversations"),
        (.GET, "/v1/axdump"),
        (.GET, "/v1/doctor"),
        (.GET, "/v1/openclaw-info"),
        (.GET, "/v1/project-context-read"),
    ]

    /// Federation routes whose handlers spawn subprocesses (doctor -> codesign,
    /// project-context-read -> ~/.local/bin/project-context-read). Their
    /// membership is frozen structurally (federationRoutes + subset test) but
    /// they are excluded from live dispatch assertions to keep the suite
    /// hermetic and fast.
    private static let federationLiveExcluded: Set<String> = [
        "GET /v1/doctor",
        "GET /v1/project-context-read",
    ]

    private static func key(_ method: HTTPMethod, _ path: String) -> String {
        "\(method) \(path)"
    }

    // MARK: - Route table freeze

    func testRouteTableMatchesExpectedExactly() {
        let actual = Set(BridgeRequestHandler.routes.map { Self.key($0.0, $0.1) })
        let expected = Set(Self.expectedRoutes.map { Self.key($0.0, $0.1) })
        XCTAssertEqual(
            BridgeRequestHandler.routes.count, Self.expectedRoutes.count,
            "route count drift (expected 37)"
        )
        XCTAssertEqual(
            actual, expected,
            "route table drift: \(actual.symmetricDifference(expected))"
        )
    }

    func testRouteTableHasNoDuplicates() {
        let keys = BridgeRequestHandler.routes.map { Self.key($0.0, $0.1) }
        XCTAssertEqual(keys.count, Set(keys).count, "duplicate (method, path) in route table")
    }

    // MARK: - 405 / 404 semantics matrix

    /// Replicates the predicate used by `BridgeRequestHandler.handleRequest`:
    /// a known path invoked with an unsupported method returns 405; an unknown
    /// path returns 404. Driving it off the frozen table locks the observable
    /// contract for all 37 routes without needing a live NIO channel.
    func testMethodMismatchAnd404Matrix() {
        let routes = BridgeRequestHandler.routes
        let knownPaths = Set(routes.map(\.1))

        func wouldReturn405(_ method: HTTPMethod, _ path: String) -> Bool {
            knownPaths.contains(path)
                && !routes.contains(where: { $0.0 == method && $0.1 == path })
        }

        // Every declared route: known path (not 404) and correct method (not 405).
        for (method, path) in routes {
            XCTAssertTrue(knownPaths.contains(path), "\(path) should be a known path")
            XCTAssertFalse(wouldReturn405(method, path), "\(method) \(path) should be valid")
        }

        // Known path + wrong method -> 405.
        XCTAssertTrue(wouldReturn405(.DELETE, "/v1/health"))
        XCTAssertTrue(wouldReturn405(.GET, "/v1/send"), "/v1/send is POST-only")
        XCTAssertTrue(wouldReturn405(.POST, "/v1/config"), "/v1/config is GET-only")
        // session-mode accepts GET + PUT; POST is a mismatch.
        XCTAssertTrue(wouldReturn405(.POST, "/v1/tmux/session-mode"))
        XCTAssertFalse(wouldReturn405(.GET, "/v1/tmux/session-mode"))
        XCTAssertFalse(wouldReturn405(.PUT, "/v1/tmux/session-mode"))

        // Unknown path -> 404 (never 405).
        XCTAssertFalse(knownPaths.contains("/v1/nonexistent"))
        XCTAssertFalse(wouldReturn405(.GET, "/v1/nonexistent"))
    }

    // MARK: - Federation switch drift guards

    func testFederationRoutesAreSubsetOfRouteTable() {
        let routeSet = Set(BridgeRequestHandler.routes.map { Self.key($0.0, $0.1) })
        for (method, path) in Self.federationRoutes {
            XCTAssertTrue(
                routeSet.contains(Self.key(method, path)),
                "federation route \(method) \(path) missing from route table"
            )
        }
    }

    /// Exercises `handleFederationCommand` for the whole route table and freezes
    /// which routes federation actually serves. Additions to the switch flip a
    /// route out of the routing-default 404 set; removals flip a served route
    /// into it — both break this test (except the two subprocess handlers, which
    /// are frozen structurally above).
    func testFederationDispatchRoutingMatrix() {
        let core = makeCore()
        let fedSet = Set(Self.federationRoutes.map { Self.key($0.0, $0.1) })

        // Non-federation routes -> federation's routing-default 404.
        for (method, path) in BridgeRequestHandler.routes where !fedSet.contains(Self.key(method, path)) {
            let resp = fedCommand(core, method: methodString(method), path: path)
            XCTAssertTrue(
                isRoutingDefault404(resp),
                "\(method) \(path) should hit federation routing-default 404 (status=\(resp.status))"
            )
        }

        // Unknown path -> routing-default 404.
        XCTAssertTrue(isRoutingDefault404(fedCommand(core, method: "GET", path: "/v1/nonexistent")))

        // Federation-served routes (minus subprocess handlers) -> reach a real
        // handler, i.e. not the routing-default 404.
        for (method, path) in Self.federationRoutes where !Self.federationLiveExcluded.contains(Self.key(method, path)) {
            let resp = fedCommand(core, method: methodString(method), path: path, body: bodyFor(path))
            XCTAssertFalse(
                isRoutingDefault404(resp),
                "\(method) \(path) should be handled by federation, not routed to default (status=\(resp.status))"
            )
        }
    }

    // MARK: - Helpers

    private func fedCommand(
        _ core: BridgeCore, method: String, path: String, body: String? = nil
    ) -> FederationResponsePayload {
        let cmd = FederationCommandPayload(
            id: UUID().uuidString, method: method, path: path, headers: [:], body: body
        )
        return core.handleFederationCommand(cmd)
    }

    private func isRoutingDefault404(_ resp: FederationResponsePayload) -> Bool {
        guard resp.status == 404 else { return false }
        struct Probe: Decodable { let code: String?; let failed_step: String? }
        struct Wrap: Decodable { let error: Probe? }
        guard let data = resp.body.data(using: .utf8),
              let wrap = try? JSONDecoder().decode(Wrap.self, from: data) else { return false }
        return wrap.error?.code == "not_found" && wrap.error?.failed_step == "routing"
    }

    private func methodString(_ method: HTTPMethod) -> String {
        switch method {
        case .GET: return "GET"
        case .POST: return "POST"
        case .PUT: return "PUT"
        default: return "\(method)"
        }
    }

    /// send and PUT session-mode need a (deliberately invalid) body so the
    /// handler reaches JSON validation and returns a non-404 error instead of
    /// crashing on nil — the exact error is irrelevant, only that it is routed.
    private func bodyFor(_ path: String) -> String? {
        switch path {
        case "/v1/send", "/v1/tmux/session-mode": return "{}"
        default: return nil
        }
    }

    private func makeCore() -> BridgeCore {
        let suite = "clawgate.tests.routematrix"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let cfg = ConfigStore(defaults: defaults)
        var appCfg = cfg.load()
        appCfg.lineEnabled = true
        cfg.save(appCfg)

        let statsFile = NSTemporaryDirectory() + "clawgate-stats-test-\(UUID().uuidString).json"
        return BridgeCore(
            eventBus: EventBus(),
            registry: AdapterRegistry(adapters: [FakeRouteAdapter()]),
            logger: AppLogger(configStore: cfg),
            opsLogStore: OpsLogStore(),
            configStore: cfg,
            statsCollector: StatsCollector(filePath: statsFile)
        )
    }
}

/// Minimal line adapter so context/messages/conversations reach a real handler
/// (returns 200) instead of adapter_not_found during the federation matrix.
private final class FakeRouteAdapter: AdapterProtocol {
    let name = "line"
    let bundleIdentifier = "jp.naver.line.mac"

    func sendMessage(payload: SendPayload) throws -> (SendResult, [StepLog]) {
        (SendResult(adapter: "line", action: "send_message", messageID: "route-test", timestamp: "2026-07-02T00:00:00Z"), [])
    }

    func getContext() throws -> ConversationContext {
        ConversationContext(adapter: "line", conversationName: "T", hasInputField: true, windowTitle: "T", timestamp: "2026-07-02T00:00:00Z")
    }

    func getMessages(limit: Int) throws -> MessageList {
        MessageList(adapter: "line", conversationName: "T", messages: [], messageCount: 0, timestamp: "2026-07-02T00:00:00Z")
    }

    func getConversations(limit: Int) throws -> ConversationList {
        ConversationList(adapter: "line", conversations: [], count: 0, timestamp: "2026-07-02T00:00:00Z")
    }
}
