import XCTest
@testable import ClawGate

final class TmuxShellTests: XCTestCase {
    func testProcessEnvironmentPreservesBaseAndSetsLCAll() {
        let base = ["PATH": "/usr/bin", "HOME": "/Users/test"]
        let result = TmuxShell.processEnvironment(base: base)

        XCTAssertEqual(result["PATH"], "/usr/bin")
        XCTAssertEqual(result["HOME"], "/Users/test")
        XCTAssertEqual(result["LC_ALL"], "en_US.UTF-8")
    }

    func testProcessEnvironmentOverridesExistingLocale() {
        let base = ["LC_ALL": "C", "LANG": "C"]
        let result = TmuxShell.processEnvironment(base: base)

        XCTAssertEqual(result["LC_ALL"], "en_US.UTF-8")
        XCTAssertEqual(result["LANG"], "C")
    }
}
