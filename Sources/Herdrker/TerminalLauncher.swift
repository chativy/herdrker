import Foundation

struct TerminalLauncher: Sendable {
    private let ghosttyApplicationURL: URL

    init(
        ghosttyApplicationURL: URL = URL(fileURLWithPath: "/Applications/Ghostty.app")
    ) {
        self.ghosttyApplicationURL = ghosttyApplicationURL
    }

    func open(task: HerdrTask, coreExecutableURL: URL) throws {
        if task.isFinished {
            try openReadOnlyFinalScreen(
                task: task,
                coreExecutableURL: coreExecutableURL
            )
            return
        }

        let arguments = Self.liveAttachArguments(for: task)
        if hasGhostty {
            try openInGhostty(executableURL: coreExecutableURL, arguments: arguments)
        } else {
            try openInTerminal(
                command: Self.shellCommand(
                    executableURL: coreExecutableURL,
                    arguments: arguments
                )
            )
        }
    }

    static func liveAttachArguments(for task: HerdrTask) -> [String] {
        return ["attach", task.address]
    }

    static func readOnlyCommand(executableURL: URL, address: String) -> String {
        let readCommand = shellCommand(
            executableURL: executableURL,
            arguments: ["read", address]
        )
        let notice = "\\n[Read-only final screen. Close this terminal window to exit.]\\n"
        return "\(readCommand); printf '\(notice)'; exec /bin/sleep 2147483647"
    }

    static func shellCommand(executableURL: URL, arguments: [String]) -> String {
        ([executableURL.path] + arguments)
            .map(shellQuote)
            .joined(separator: " ")
    }

    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private var hasGhostty: Bool {
        FileManager.default.fileExists(atPath: ghosttyApplicationURL.path)
    }

    private func openReadOnlyFinalScreen(
        task: HerdrTask,
        coreExecutableURL: URL
    ) throws {
        let command = Self.readOnlyCommand(
            executableURL: coreExecutableURL,
            address: task.address
        )
        if hasGhostty {
            try openInGhostty(
                executableURL: URL(fileURLWithPath: "/bin/zsh"),
                arguments: ["-lc", command]
            )
        } else {
            try openInTerminal(command: command)
        }
    }

    private func openInGhostty(
        executableURL: URL,
        arguments: [String]
    ) throws {
        try runProcess(
            executableURL: URL(fileURLWithPath: "/usr/bin/open"),
            arguments: [
                "-na", ghosttyApplicationURL.path,
                "--args", "-e",
                executableURL.path
            ] + arguments,
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
