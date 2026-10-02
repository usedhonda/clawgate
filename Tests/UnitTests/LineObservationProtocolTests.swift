import XCTest
@testable import ClawGate

final class LineObservationProtocolTests: XCTestCase {
    func testUpgradeRequiresExplicitCompatibleAdvertisement() throws {
        func version(_ value: [String: Any]) throws -> Int {
            LineObservationProtocol.supportedVersion(capabilityData: try JSONSerialization.data(withJSONObject: value))
        }
        XCTAssertEqual(try version(["ok": true, "supportedSchemaVersions": [1, 2],
                                    "bodyCandidateFormat": "line-body-candidate-v1"]), 2)
        XCTAssertEqual(try version(["ok": true, "supportedSchemaVersions": [1]]), 1)
        XCTAssertEqual(try version(["ok": true, "supportedSchemaVersions": [2],
                                    "bodyCandidateFormat": "other"]), 1)
        XCTAssertEqual(try version(["ok": false, "supportedSchemaVersions": [2],
                                    "bodyCandidateFormat": "line-body-candidate-v1"]), 1)
        XCTAssertEqual(LineObservationProtocol.supportedVersion(capabilityData: Data("not-json".utf8)), 1)
    }
}
