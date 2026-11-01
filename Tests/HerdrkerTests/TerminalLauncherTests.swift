import XCTest
@testable import Herdrker

final class TerminalLauncherTests: XCTestCase {
    func testLiveTaskUsesAttachMode() {
        let live = HerdrTask(
            address: "t3",
            name: "shell",
            title: nil,
            machine: nil,
            state: "live",
            status: nil,
            createdAt: nil
        )

        XCTAssertEqual(
            TerminalLauncher.liveAttachArguments(for: live),
            ["attach", "t3"]
        )
    }

    func testFinishedTaskReadsFinalScreenWithoutAttaching() {
        let command = TerminalLauncher.readOnlyCommand(
            executableURL: URL(fileURLWithPath: "/usr/local/bin/herdr-core"),
            address: "mini/t9"
        )

        XCTAssertTrue(command.contains("'read' 'mini/t9'"))
        XCTAssertTrue(command.contains("/bin/sleep 2147483647"))
        XCTAssertFalse(command.contains("attach"))
    }

    func testShellCommandQuotesSingleQuotes() {
        XCTAssertEqual(
            TerminalLauncher.shellQuote("it's ready"),
            "'it'\\''s ready'"
        )
    }
}
