import Foundation

struct TerminalLauncher: Sendable {
    static let allStoredHistoryLines = String(Int.max)
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

        let command = Self.liveAttachCommand(
            executableURL: coreExecutableURL,
            address: task.address
        )
        if hasGhostty {
            try openInGhostty(
                task: task,
                executableURL: URL(fileURLWithPath: "/bin/zsh"),
                arguments: ["-lc", command]
            )
        } else {
            try openInTerminal(command: command)
        }
    }

    var taskEnvironment: [String: String] {
        Self.taskEnvironment(ghosttyInstalled: hasGhostty)
    }

    static func taskEnvironment(ghosttyInstalled: Bool) -> [String: String] {
        [
            "TERM": "xterm-256color",
            "TERM_PROGRAM": ghosttyInstalled ? "ghostty" : "Apple_Terminal",
            "COLORTERM": "truecolor"
        ]
    }

    static func liveAttachArguments(for task: HerdrTask) -> [String] {
        return ["attach", "--history", allStoredHistoryLines, task.address]
    }

    static func readOnlyCommand(executableURL: URL, address: String) -> String {
        let readCommand = shellCommand(
            executableURL: executableURL,
            arguments: ["read", address]
        )
        let notice = "\\n[Read-only final screen. Close this terminal window to exit.]\\n"
        return """
        \(waitForStableTerminalSize) \
        \(readCommand) | /usr/bin/less -R -S; \
        printf '\(notice)'; exec /bin/sleep 2147483647
        """
    }

    static func liveAttachCommand(executableURL: URL, address: String) -> String {
        let attachCommand = shellCommand(
            executableURL: executableURL,
            arguments: ["attach", "--history", allStoredHistoryLines, address]
        )
        return "\(waitForStableTerminalSize) exec \(attachCommand)"
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

    private static let waitForStableTerminalSize = """
    previous=""; \
    for attempt in 1 2 3 4 5 6 7 8; do \
        current="$(stty size 2>/dev/null)"; \
        if [[ -n "$previous" && "$current" == "$previous" ]]; then break; fi; \
        previous="$current"; sleep 0.1; \
    done;
    """

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
                task: task,
                executableURL: URL(fileURLWithPath: "/bin/zsh"),
                arguments: ["-lc", command]
            )
        } else {
            try openInTerminal(command: command)
        }
    }

    private func openInGhostty(
        task: HerdrTask,
        executableURL: URL,
        arguments: [String]
    ) throws {
        var ghosttyArguments = ["-na", ghosttyApplicationURL.path, "--args"]
        if let cols = task.cols, let rows = task.rows {
            ghosttyArguments.append(contentsOf: [
                "--window-width=\(cols)",
                "--window-height=\(rows)"
            ])
        }
        ghosttyArguments.append(contentsOf: ["-e", executableURL.path])
        ghosttyArguments.append(contentsOf: arguments)

        try runProcess(
            executableURL: URL(fileURLWithPath: "/usr/bin/open"),
            arguments: ghosttyArguments,
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
