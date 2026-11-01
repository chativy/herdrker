import AppKit
import Foundation

@MainActor
final class TerminalLauncher {
    nonisolated static let allStoredHistoryLines = String(Int.max)

    private enum WindowTarget {
        case ghostty(windowID: String)
        case terminal(windowID: Int)
    }

    private let ghosttyApplicationURL: URL
    private var windowTargets: [String: WindowTarget] = [:]

    init(
        ghosttyApplicationURL: URL = URL(fileURLWithPath: "/Applications/Ghostty.app")
    ) {
        self.ghosttyApplicationURL = ghosttyApplicationURL
    }

    var taskEnvironment: [String: String] {
        Self.taskEnvironment(ghosttyInstalled: hasGhostty)
    }

    nonisolated static func taskEnvironment(ghosttyInstalled: Bool) -> [String: String] {
        [
            "TERM": "xterm-256color",
            "TERM_PROGRAM": ghosttyInstalled ? "ghostty" : "Apple_Terminal",
            "COLORTERM": "truecolor"
        ]
    }

    nonisolated static func liveAttachArguments(for task: HerdrTask) -> [String] {
        ["attach", "--history", allStoredHistoryLines, task.address]
    }

    nonisolated static func readOnlyCommand(
        executableURL: URL,
        address: String
    ) -> String {
        let readCommand = shellCommand(
            executableURL: executableURL,
            arguments: ["read", address]
        )
        let notice = "\\n[Read-only final screen. Close this terminal window to exit.]\\n"
        return """
        \(HerdrEnvironment.shellReset)\
        \(waitForStableTerminalSize) \
        \(readCommand) | /usr/bin/less -R -S; \
        printf '\(notice)'; exec /bin/sleep 2147483647
        """
    }

    nonisolated static func liveAttachCommand(
        executableURL: URL,
        address: String
    ) -> String {
        let attachCommand = shellCommand(
            executableURL: executableURL,
            arguments: ["attach", "--history", allStoredHistoryLines, address]
        )
        return "\(HerdrEnvironment.shellReset)\(waitForStableTerminalSize) exec \(attachCommand)"
    }

    nonisolated static func shellCommand(
        executableURL: URL,
        arguments: [String]
    ) -> String {
        ([executableURL.path] + arguments)
            .map(shellQuote)
            .joined(separator: " ")
    }

    nonisolated static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    @discardableResult
    func focus(taskAddress: String) -> Bool {
        guard let target = windowTargets[taskAddress] else {
            return false
        }

        let focused: Bool
        switch target {
        case let .ghostty(windowID):
            focused = focusGhostty(windowID: windowID)
        case let .terminal(windowID):
            focused = focusTerminal(windowID: windowID)
        }

        if !focused {
            windowTargets.removeValue(forKey: taskAddress)
        }
        return focused
    }

    func open(task: HerdrTask, coreExecutableURL: URL) async throws {
        if focus(taskAddress: task.address) {
            return
        }

        if task.isFinished {
            let command = Self.readOnlyCommand(
                executableURL: coreExecutableURL,
                address: task.address
            )
            try await openCommand(
                task: task,
                executableURL: URL(fileURLWithPath: "/bin/zsh"),
                arguments: ["-lc", command]
            )
        } else {
            let command = Self.liveAttachCommand(
                executableURL: coreExecutableURL,
                address: task.address
            )
            try await openCommand(
                task: task,
                executableURL: URL(fileURLWithPath: "/bin/zsh"),
                arguments: ["-lc", command]
            )
        }
    }

    func forget(taskAddress: String) {
        windowTargets.removeValue(forKey: taskAddress)
    }

    private var hasGhostty: Bool {
        FileManager.default.fileExists(atPath: ghosttyApplicationURL.path)
    }

    private func openCommand(
        task: HerdrTask,
        executableURL: URL,
        arguments: [String]
    ) async throws {
        if hasGhostty {
            try await openInGhostty(
                task: task,
                executableURL: executableURL,
                arguments: arguments
            )
        } else {
            try openInTerminal(
                task: task,
                command: Self.shellCommand(
                    executableURL: executableURL,
                    arguments: arguments
                )
            )
        }
    }

    private func openInGhostty(
        task: HerdrTask,
        executableURL: URL,
        arguments: [String]
    ) async throws {
        let command = Self.shellCommand(
            executableURL: executableURL,
            arguments: arguments
        )
        let script = """
        on run argv
            tell application "Ghostty"
                set cfg to new surface configuration
                set command of cfg to (item 1 of argv)
                set newWindow to new window with configuration cfg
                activate window newWindow
                return id of newWindow
            end tell
        end run
        """
        let output = try runProcess(
            executableURL: URL(fileURLWithPath: "/usr/bin/osascript"),
            arguments: ["-e", script, "--", command],
            failureMessage: "Ghostty could not open the task."
        )
        let windowID = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !windowID.isEmpty else {
            throw HerdrCoreError(
                kind: "terminal_launch_failed",
                message: "Ghostty did not return a window identifier.",
                hint: nil
            )
        }
        windowTargets[task.address] = .ghostty(windowID: windowID)
    }

    private func focusGhostty(windowID: String) -> Bool {
        let script = """
        on run argv
            tell application "Ghostty"
                try
                    set targetWindow to first window whose id is (item 1 of argv)
                    activate window targetWindow
                    return "focused"
                on error
                    return "missing"
                end try
            end tell
        end run
        """
        do {
            let output = try runProcess(
                executableURL: URL(fileURLWithPath: "/usr/bin/osascript"),
                arguments: ["-e", script, "--", windowID],
                failureMessage: "Ghostty could not focus the task."
            )
            return output.trimmingCharacters(in: .whitespacesAndNewlines) == "focused"
        } catch {
            return false
        }
    }

    private func openInTerminal(task: HerdrTask, command: String) throws {
        let script = """
        on run argv
            tell application "Terminal"
                activate
                set newTab to do script (item 1 of argv)
                set custom title of newTab to (item 2 of argv)
                return (id of front window) as text
            end tell
        end run
        """
        let output = try runProcess(
            executableURL: URL(fileURLWithPath: "/usr/bin/osascript"),
            arguments: [
                "-e", script, "--",
                command,
                "Herdrker: \(task.address)"
            ],
            failureMessage: "Terminal could not open the task."
        )
        if let windowID = Int(output.trimmingCharacters(in: .whitespacesAndNewlines)) {
            windowTargets[task.address] = .terminal(windowID: windowID)
        }
    }

    private func focusTerminal(windowID: Int) -> Bool {
        let script = """
        on run argv
            set wanted to (item 1 of argv) as integer
            tell application "Terminal"
                repeat with candidate in windows
                    if (id of candidate) is wanted then
                        set index of candidate to 1
                        activate
                        return "focused"
                    end if
                end repeat
            end tell
            return "missing"
        end run
        """
        do {
            let output = try runProcess(
                executableURL: URL(fileURLWithPath: "/usr/bin/osascript"),
                arguments: ["-e", script, "--", String(windowID)],
                failureMessage: "Terminal could not focus the task."
            )
            return output.trimmingCharacters(in: .whitespacesAndNewlines) == "focused"
        } catch {
            return false
        }
    }

    private func runProcess(
        executableURL: URL,
        arguments: [String],
        failureMessage: String
    ) throws -> String {
        let fileManager = FileManager.default
        let temporaryDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("Herdrker-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        defer {
            try? fileManager.removeItem(at: temporaryDirectory)
        }

        let stdoutURL = temporaryDirectory.appendingPathComponent("stdout")
        let stderrURL = temporaryDirectory.appendingPathComponent("stderr")
        fileManager.createFile(atPath: stdoutURL.path, contents: nil)
        fileManager.createFile(atPath: stderrURL.path, contents: nil)

        let stdoutHandle = try FileHandle(forWritingTo: stdoutURL)
        let stderrHandle = try FileHandle(forWritingTo: stderrURL)
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardOutput = stdoutHandle
        process.standardError = stderrHandle

        try process.run()
        process.waitUntilExit()
        try stdoutHandle.close()
        try stderrHandle.close()

        guard process.terminationStatus == 0 else {
            let data = try Data(contentsOf: stderrURL)
            let detail = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw HerdrCoreError(
                kind: "terminal_launch_failed",
                message: failureMessage,
                hint: detail.flatMap { $0.isEmpty ? nil : $0 }
            )
        }

        return String(data: try Data(contentsOf: stdoutURL), encoding: .utf8) ?? ""
    }

    private nonisolated static let waitForStableTerminalSize = """
    previous=""; \
    for attempt in 1 2 3 4 5 6 7 8; do \
        current="$(stty size 2>/dev/null)"; \
        if [[ -n "$previous" && "$current" == "$previous" ]]; then break; fi; \
        previous="$current"; sleep 0.1; \
    done;
    """
}
