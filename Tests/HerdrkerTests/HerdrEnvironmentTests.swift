import XCTest
@testable import Herdrker

final class HerdrEnvironmentTests: XCTestCase {
    func testRemovesOnlyInheritedTaskContext() {
        let environment = [
            "HC_TERMINAL_ID": "t2",
            "HC_TERMINAL_SOCKET": "/tmp/core.sock",
            "HC_SCOPE": "scope",
            "HC_RUNTIME": "runtime",
            "HC_SESSION": "work",
            "HC_SOCKET": "/tmp/explicit.sock",
            "PATH": "/usr/bin"
        ]

        let sanitized = HerdrEnvironment.removingTaskContext(from: environment)

        XCTAssertNil(sanitized["HC_TERMINAL_ID"])
        XCTAssertNil(sanitized["HC_TERMINAL_SOCKET"])
        XCTAssertNil(sanitized["HC_SCOPE"])
        XCTAssertNil(sanitized["HC_RUNTIME"])
        XCTAssertEqual(sanitized["HC_SESSION"], "work")
        XCTAssertEqual(sanitized["HC_SOCKET"], "/tmp/explicit.sock")
        XCTAssertEqual(sanitized["PATH"], "/usr/bin")
    }

    func testShellResetUnsetsTaskContext() {
        for variable in HerdrEnvironment.inheritedTaskVariables {
            XCTAssertTrue(HerdrEnvironment.shellReset.contains(variable))
        }
    }
}
