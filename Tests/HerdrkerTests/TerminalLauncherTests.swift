import XCTest
@testable import Herdrker

final class TerminalLauncherTests: XCTestCase {
    func testFinishedTaskUsesObserveMode() {
        let finished = HerdrTask(
            address: "mini/t9",
            name: "deploy",
            title: nil,
            machine: "mini",
            state: "finished",
            status: "done",
            createdAt: nil
        )
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
            TerminalLauncher.attachArguments(for: finished),
            ["attach", "--observe", "mini/t9"]
        )
        XCTAssertEqual(
            TerminalLauncher.attachArguments(for: live),
            ["attach", "t3"]
        )
    }

    func testShellCommandQuotesSingleQuotes() {
        XCTAssertEqual(
            TerminalLauncher.shellQuote("it's ready"),
            "'it'\\''s ready'"
        )
    }
}
