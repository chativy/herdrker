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
            ["attach", "--history", TerminalLauncher.allStoredHistoryLines, "t3"]
        )
    }

    func testFinishedTaskReadsFinalScreenWithoutAttaching() {
        let command = TerminalLauncher.readOnlyCommand(
            executableURL: URL(fileURLWithPath: "/usr/local/bin/herdr-core"),
            address: "mini/t9"
        )

        XCTAssertTrue(command.contains("'read' 'mini/t9'"))
        XCTAssertTrue(command.contains("/usr/bin/less -R -S"))
        XCTAssertTrue(command.contains("/bin/sleep 2147483647"))
        XCTAssertFalse(command.contains("attach"))
    }

    func testLiveAttachWaitsForStableTerminalSize() {
        let command = TerminalLauncher.liveAttachCommand(
            executableURL: URL(fileURLWithPath: "/usr/local/bin/herdr-core"),
            address: "t2"
        )

        XCTAssertTrue(command.contains("stty size"))
        XCTAssertTrue(
            command.contains(
                "'attach' '--history' '\(TerminalLauncher.allStoredHistoryLines)' 't2'"
            )
        )
    }

    func testShellCommandQuotesSingleQuotes() {
        XCTAssertEqual(
            TerminalLauncher.shellQuote("it's ready"),
            "'it'\\''s ready'"
        )
    }
}
