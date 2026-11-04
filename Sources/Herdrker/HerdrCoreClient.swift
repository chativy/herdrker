import Foundation

protocol HerdrCoreProviding: Sendable {
    var executableURL: URL { get }

    func listTasks() async throws -> [HerdrTask]
    func listHosts() async throws -> [HerdrHost]
    func task(address: String) async throws -> HerdrTask
    func createTask(
        _ request: NewTaskRequest,
        environment: [String: String]
    ) async throws -> HerdrTask
    func addHost(_ request: NewHostRequest) async throws
    func removeTask(address: String) async throws
}

struct HerdrCoreError: LocalizedError, Sendable {
    let kind: String
    let message: String
    let hint: String?

    var errorDescription: String? {
        guard let hint, !hint.isEmpty else {
            return message
        }
        return "\(message)\n\n\(hint)"
    }

    static func decode(from data: Data, fallback: String) -> HerdrCoreError {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = object["error"] as? [String: Any] {
            return HerdrCoreError(
                kind: error["kind"] as? String ?? "herdr_core_error",
                message: error["message"] as? String ?? fallback,
                hint: error["hint"] as? String
            )
        }

        let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return HerdrCoreError(
            kind: "process_error",
            message: text.flatMap { $0.isEmpty ? nil : $0 } ?? fallback,
            hint: nil
        )
    }
}

enum HerdrCoreCommand: Equatable {
    case listTasks
    case listHosts
    case task(String)
    case createTask(NewTaskRequest)
    case addHost(NewHostRequest)
    case removeTask(String)

    var arguments: [String] {
        switch self {
        case .listTasks:
            return ["ls", "--all", "--json"]
        case .listHosts:
            return ["machine", "ls", "--json"]
        case let .task(address):
            return ["get", address, "--json"]
        case let .createTask(request):
            var arguments = ["run", "--bg", "--json"]
            if let parent = request.parent {
                arguments.append(contentsOf: ["--parent", parent])
            } else {
                arguments.append("--no-parent")
            }
            if let host = request.host {
                arguments.append(contentsOf: ["--on", host])
            }
            if let name = request.name {
                arguments.append(contentsOf: ["--name", name])
            }
            if let workingDirectory = request.workingDirectory {
                arguments.append(contentsOf: ["--cwd", workingDirectory])
            }
            if let whereLabel = request.whereLabel {
                arguments.append(contentsOf: ["--label", "where=\(whereLabel)"])
            }
            if let command = request.command {
                arguments.append(contentsOf: ["--", command])
            }
            return arguments
        case let .addHost(request):
            var arguments = ["machine", "add", "--json"]
            if let name = request.name {
                arguments.append(contentsOf: ["--name", name])
            }
            if request.installCore {
                arguments.append("--install")
            }
            arguments.append(contentsOf: ["--", request.target])
            return arguments
        case let .removeTask(address):
            return ["rm", "--json", "--", address]
        }
    }
}

final class HerdrCoreClient: HerdrCoreProviding, Sendable {
    let executableURL: URL

    init(executableURL: URL? = nil) throws {
        if let executableURL {
            self.executableURL = executableURL
        } else {
            self.executableURL = try Self.locateExecutable()
        }
    }

    func listTasks() async throws -> [HerdrTask] {
        try HerdrJSON.taskList(from: await output(for: .listTasks))
    }

    func listHosts() async throws -> [HerdrHost] {
        try HerdrJSON.hostList(from: await output(for: .listHosts))
    }

    func task(address: String) async throws -> HerdrTask {
        try HerdrJSON.task(from: await output(for: .task(address)))
    }

    func createTask(
        _ request: NewTaskRequest,
        environment: [String: String]
    ) async throws -> HerdrTask {
        try HerdrJSON.task(
            from: await output(
                for: .createTask(request),
                extraEnvironment: environment
            )
        )
    }

    func addHost(_ request: NewHostRequest) async throws {
        _ = try await output(for: .addHost(request))
    }

    func removeTask(address: String) async throws {
        _ = try await output(for: .removeTask(address))
    }

    static func locateExecutable(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) throws -> URL {
        var candidates: [URL] = []
        if let path = environment["PATH"] {
            candidates.append(contentsOf: path.split(separator: ":").map {
                URL(fileURLWithPath: String($0)).appendingPathComponent("herdr-core")
            })
        }
        candidates.append(contentsOf: [
            homeDirectory.appendingPathComponent(".local/bin/herdr-core"),
            URL(fileURLWithPath: "/opt/homebrew/bin/herdr-core"),
            URL(fileURLWithPath: "/usr/local/bin/herdr-core")
        ])

        if let executable = candidates.first(where: {
            FileManager.default.isExecutableFile(atPath: $0.path)
        }) {
            return executable
        }

        throw HerdrCoreError(
            kind: "hc_missing",
            message: "Herdr Core is not installed.",
            hint: "Install herdr-core or make the herdr-core executable available on PATH."
        )
    }

    private func output(
        for command: HerdrCoreCommand,
        extraEnvironment: [String: String] = [:]
    ) async throws -> Data {
        let executable = executableURL
        let arguments = command.arguments
        let result = try await Task.detached(priority: .userInitiated) {
            try Self.runProcess(
                executable: executable,
                arguments: arguments,
                extraEnvironment: extraEnvironment
            )
        }.value

        guard result.exitCode == 0 else {
            let errorData = result.stderr.isEmpty ? result.stdout : result.stderr
            throw HerdrCoreError.decode(
                from: errorData,
                fallback: "herdr-core exited with status \(result.exitCode)."
            )
        }
        return result.stdout
    }

    private static func runProcess(
        executable: URL,
        arguments: [String],
        extraEnvironment: [String: String]
    ) throws -> (stdout: Data, stderr: Data, exitCode: Int32) {
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
        process.executableURL = executable
        process.arguments = arguments
        let inheritedEnvironment = HerdrEnvironment.removingTaskContext(
            from: ProcessInfo.processInfo.environment
        )
        process.environment = inheritedEnvironment.merging(
            extraEnvironment,
            uniquingKeysWith: { _, new in new }
        )
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdoutHandle
        process.standardError = stderrHandle

        try process.run()
        process.waitUntilExit()
        try stdoutHandle.close()
        try stderrHandle.close()

        return (
            stdout: try Data(contentsOf: stdoutURL),
            stderr: try Data(contentsOf: stderrURL),
            exitCode: process.terminationStatus
        )
    }
}
