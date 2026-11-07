import NIOHTTP1
import XCTest
@testable import ClawGate

final class BridgeRequestSecurityTests: XCTestCase {
    func testHostAllowsIPAndExactMachineNames() {
        let names = ["bridge.example-tailnet.ts.net", "bridge", "bridge.local"]
        for host in ["127.0.0.1:8765", "[::1]:8765", "100.64.0.10:8765", "localhost:8765", "BRIDGE.LOCAL.:8765", "bridge.example-tailnet.ts.net", "bridge:8765"] {
            XCTAssertTrue(BridgeRequestSecurity.allowsHost(HTTPHeaders([("Host", host)]), localHostnames: names), host)
        }
    }

    func testHostRejectsDNSRebindingAndAuthorityConfusion() {
        let names = ["bridge.example-tailnet.ts.net", "bridge.local"]
        for host in ["attacker.example:8765", "bridge.local.attacker.example", "another.example-tailnet.ts.net", "localhost@attacker.example", "localhost:8765/", "localhost:8765?ignored", "localhost:8765,attacker.example", "localhost:", "[::1]:65536", "[localhost]", "::1", " localhost", "localhost:foo"] {
            XCTAssertFalse(BridgeRequestSecurity.allowsHost(HTTPHeaders([("Host", host)]), localHostnames: names), host)
        }
        XCTAssertFalse(BridgeRequestSecurity.allowsHost(HTTPHeaders(), localHostnames: names))
        XCTAssertFalse(BridgeRequestSecurity.allowsHost(HTTPHeaders([("Host", "localhost"), ("Host", "attacker.example")]), localHostnames: names))
    }

    func testBrowserGetWithoutOriginCannotBypassWithFetchMetadata() {
        for site in ["same-origin", "same-site", "cross-site"] {
            XCTAssertFalse(BridgeRequestSecurity.allowsBrowserHeaders(HTTPHeaders([("Sec-Fetch-Site", site), ("Sec-Fetch-Mode", "cors")])), site)
        }
        XCTAssertFalse(BridgeRequestSecurity.allowsBrowserHeaders(HTTPHeaders([("Sec-Fetch-Site", "none"), ("Sec-Fetch-Mode", "navigate"), ("Sec-Fetch-Dest", "document")])))
        XCTAssertTrue(BridgeRequestSecurity.allowsBrowserHeaders(HTTPHeaders()))
        XCTAssertTrue(BridgeRequestSecurity.allowsBrowserHeaders(HTTPHeaders([("Sec-Fetch-Site", "none"), ("Sec-Fetch-Mode", "cors"), ("Sec-Fetch-Dest", "empty")])))
    }

    func testOnlyCanonicalExtensionOriginsAreAccepted() {
        let valid = "chrome-extension://abcdefghijklmnopabcdefghijklmnop"
        XCTAssertTrue(BridgeRequestSecurity.allowsBrowserHeaders(HTTPHeaders([("Origin", valid), ("Sec-Fetch-Site", "cross-site")])))
        for origin in ["https://attacker.example", "null", "", "chrome-extension://", "chrome-extension://arbitrary", valid + ".attacker.example", valid + "@attacker.example", valid + "/path"] {
            XCTAssertFalse(BridgeRequestSecurity.allowsBrowserHeaders(HTTPHeaders([("Origin", origin)])), origin)
        }
        XCTAssertFalse(BridgeRequestSecurity.allowsBrowserHeaders(HTTPHeaders([("Origin", valid), ("Origin", "https://attacker.example")])))
    }
}
