import Foundation

struct TerminalLauncher: Sendable {
    private let ghosttyApplicationURL: URL

    init(
        ghosttyApplicationURL: URL = URL(fileURLWithPath: "/Applications/Ghostty.app")
    ) {
        self.ghosttyApplicationURL = ghosttyApplicationURL
    }

    func open(task: HerdrTask, coreExecutableURL: URL) throws {
        let arguments = Self.attachArguments(for: task)
        if FileManager.default.fileExists(atPath: ghosttyApplicationURL.path) {
            try openInGhostty(
                executableURL: coreExecutableURL,
                coreArguments: arguments
            )
        } else {
            try openInTerminal(
                command: Self.shellCommand(
                    executableURL: coreExecutableURL,
                    arguments: arguments
                )
            )
        }
    }

    static func attachArguments(for task: HerdrTask) -> [String] {
        if task.isFinished {
            return ["attach", "--observe", task.address]
        }
        return ["attach", task.address]
    }

    static func shellCommand(executableURL: URL, arguments: [String]) -> String {
        ([executableURL.path] + arguments)
            .map(shellQuote)
            .joined(separator: " ")
    }

    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func openInGhostty(
        executableURL: URL,
        coreArguments: [String]
    ) throws {
        try runProcess(
            executableURL: URL(fileURLWithPath: "/usr/bin/open"),
            arguments: [
                "-na", ghosttyApplicationURL.path,
                "--args", "-e",
                executableURL.path
            ] + coreArguments,
            failureMessage: "Ghostty could not open the task."
        )
    }

    private func openInTerminal(command: String) throws {
        let script = """
        on run argv
            tell application "Terminal"
                activate
                do script (item 1 of argv)
            end tell
        end run
        """
        try runProcess(
            executableURL: URL(fileURLWithPath: "/usr/bin/osascript"),
            arguments: ["-e", script, "--", command],
            failureMessage: "Terminal could not open the task."
        )
    }

    private func runProcess(
        executableURL: URL,
        arguments: [String],
        failureMessage: String
    ) throws {
        let standardError = Pipe()
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardError = standardError

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let data = standardError.fileHandleForReading.readDataToEndOfFile()
            let detail = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw HerdrCoreError(
                kind: "terminal_launch_failed",
                message: failureMessage,
                hint: detail.flatMap { $0.isEmpty ? nil : $0 }
            )
        }
    }
}
