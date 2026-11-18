import Foundation

enum TaskBackendKind: String, CaseIterable, Identifiable, Sendable {
    case herdr
    case rex

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .herdr:
            return "Herdr"
        case .rex:
            return "Rex"
        }
    }
}

enum TaskBackendAvailability {
    static func installed(
        herdr: Bool,
        rex: Bool
    ) -> [TaskBackendKind] {
        var backends: [TaskBackendKind] = []
        if herdr {
            backends.append(.herdr)
        }
        if rex {
            backends.append(.rex)
        }
        return backends
    }
}

struct BackendSelectionStore {
    private let defaults: UserDefaults
    private let key: String

    init(
        defaults: UserDefaults = .standard,
        key: String = "lastTaskBackend"
    ) {
        self.defaults = defaults
        self.key = key
    }

    func load(available: [TaskBackendKind]) -> TaskBackendKind {
        let stored = defaults.string(forKey: key)
            .flatMap(TaskBackendKind.init(rawValue:))
        if let stored, available.contains(stored) {
            return stored
        }
        return available.first ?? .herdr
    }

    func save(_ backend: TaskBackendKind) {
        defaults.set(backend.rawValue, forKey: key)
    }
}

struct RexHost: Identifiable, Hashable, Sendable {
    static let localID = "__rex_local__"

    let label: String
    let displayName: String
    let endpoints: [String]
    let isLocal: Bool

    var id: String { isLocal ? Self.localID : label }
    var serverArgument: String? { isLocal ? nil : label }
}

struct RexSessionInfo: Identifiable, Hashable, Sendable {
    let id: String
    let label: String
    let windows: [RexWindowInfo]

    var displayName: String { label.isEmpty ? id : label }
}

struct RexWindowInfo: Identifiable, Hashable, Sendable {
    let id: String
    let label: String
    let blocks: [RexTaskBlock]

    var displayName: String { label.isEmpty ? id : label }
}

struct RexTaskBlock: Identifiable, Hashable, Sendable {
    let hostID: String
    let hostLabel: String
    let hostIsLocal: Bool
    let sessionID: String
    let sessionLabel: String
    let windowID: String
    let windowLabel: String
    let blockID: String
    let label: String
    let title: String?
    let status: String?

    var id: String { "\(hostID)/\(sessionID)/\(blockID)" }
    var displayName: String {
        let value = label.isEmpty ? title ?? blockID : label
        return value.isEmpty ? blockID : value
    }
    var stateLabel: String { status?.capitalized ?? "Live" }
}

struct RexHostGroup: Identifiable, Hashable, Sendable {
    let host: RexHost
    let sessions: [RexSessionInfo]
    let connectionError: String?

    var id: String { host.id }
    var tasks: [RexTaskBlock] {
        sessions.flatMap { $0.windows.flatMap(\.blocks) }
    }
}

struct NewRexTaskRequest: Equatable, Sendable {
    let host: RexHost
    let session: RexSessionInfo?
    let name: String?
    let command: String?
    let workingDirectory: String?
}

struct NewRexHostRequest: Equatable, Sendable {
    let label: String
    let endpoints: [String]
    let icon: String?
    let checkAfterAdding: Bool
}

struct RexHostCheck: Equatable, Sendable {
    let label: String
    let reachable: Bool
    let detail: String?
}

enum NewTaskSubmission: Sendable {
    case herdr(NewTaskRequest)
    case rex(NewRexTaskRequest)
}

enum NewHostSubmission: Sendable {
    case herdr(NewHostRequest)
    case rex(NewRexHostRequest)
}

struct RexClient: Sendable {
    let executableURL: URL?

    init(executableURL: URL? = RexClient.locateExecutable()) {
        self.executableURL = executableURL
    }

    var isAvailable: Bool { executableURL != nil }

    func listHostGroups() async throws -> [RexHostGroup] {
        let hosts = try await listHosts()
        var groups: [RexHostGroup] = []
        for host in hosts {
            do {
                let sessions = try await listSessions(host: host)
                groups.append(
                    RexHostGroup(
                        host: host,
                        sessions: sessions,
                        connectionError: nil
                    )
                )
            } catch {
                groups.append(
                    RexHostGroup(
                        host: host,
                        sessions: [],
                        connectionError: error.localizedDescription
                    )
                )
            }
        }
        return groups
    }

    func listHosts() async throws -> [RexHost] {
        let data = try await run(arguments: ["hosts", "--json"])
        return try Self.hosts(from: data)
    }

    func listSessions(host: RexHost) async throws -> [RexSessionInfo] {
        let data = try await run(
            arguments: serverArguments(for: host) + ["ls", "--json"]
        )
        let sessions = try Self.sessions(from: data)
        var result: [RexSessionInfo] = []
        for session in sessions {
            let inspectData = try await run(
                arguments: serverArguments(for: host)
                    + ["session", "inspect", session.id, "--json"]
            )
            result.append(
                try Self.sessionInfo(
                    from: inspectData,
                    host: host,
                    fallbackSession: session
                )
            )
        }
        return result
    }

    func createTask(_ request: NewRexTaskRequest) async throws -> RexTaskBlock {
        var options: [String: Any] = [:]
        if let name = request.name, !name.isEmpty {
            options["label"] = name
        }
        if let cwd = request.workingDirectory, !cwd.isEmpty {
            options["cwd"] = cwd
        }
        if let command = request.command, !command.isEmpty {
            options["initial_input"] = command.hasSuffix("\n") ? command : command + "\n"
        }

        var block: [String: Any] = [
            "flavor": "com.superlogical.terminal.shell"
        ]
        if let name = request.name, !name.isEmpty {
            block["label"] = name
        }
        if !options.isEmpty {
            block["options"] = options
        }
        let layout: [String: Any] = ["block": block]

        let response: [String: Any]
        let sessionID: String
        let windowID: String
        let blockID: String
        if let session = request.session {
            let arguments: [String: Any] = [
                "layout": layout,
                "focus": true
            ]
            response = try await apiCall(
                host: request.host,
                sessionID: session.id,
                method: "session.new_window",
                arguments: arguments
            )
            sessionID = session.id
            windowID = response["window_id"] as? String ?? ""
            blockID = (response["block_ids"] as? [String])?.first ?? ""
        } else {
            var arguments: [String: Any] = [
                "initial_windows": [["layout": layout]]
            ]
            if let name = request.name, !name.isEmpty {
                arguments["label"] = name
                arguments["initial_windows"] = [
                    ["window_label": name, "layout": layout]
                ]
            }
            response = try await apiCall(
                host: request.host,
                sessionID: nil,
                method: "session.create",
                arguments: arguments
            )
            sessionID = response["session_id"] as? String ?? ""
            let window = (response["initial_windows"] as? [[String: Any]])?.first
            windowID = window?["window_id"] as? String ?? ""
            blockID = (window?["block_ids"] as? [String])?.first ?? ""
        }

        guard !sessionID.isEmpty, !blockID.isEmpty else {
            throw HerdrCoreError(
                kind: "invalid_response",
                message: "Rex did not return the created session or block.",
                hint: nil
            )
        }
        return RexTaskBlock(
            hostID: request.host.id,
            hostLabel: request.host.displayName,
            hostIsLocal: request.host.isLocal,
            sessionID: sessionID,
            sessionLabel: request.session?.label ?? request.name ?? "",
            windowID: windowID,
            windowLabel: request.name ?? "",
            blockID: blockID,
            label: request.name ?? "",
            title: nil,
            status: nil
        )
    }

    func addHost(_ request: NewRexHostRequest) async throws -> RexHostCheck? {
        var arguments = ["hosts", "add", request.label]
        arguments.append(contentsOf: request.endpoints)
        if let icon = request.icon, !icon.isEmpty {
            arguments.append(contentsOf: ["--icon", icon])
        }
        _ = try await run(arguments: arguments)
        guard request.checkAfterAdding else {
            return nil
        }
        do {
            return try await checkHost(label: request.label)
        } catch {
            return RexHostCheck(
                label: request.label,
                reachable: false,
                detail: error.localizedDescription
            )
        }
    }

    func checkHost(label: String) async throws -> RexHostCheck {
        let data = try await run(
            arguments: ["hosts", "check", label, "--json"]
        )
        return try Self.hostCheck(label: label, from: data)
    }

    func focus(_ task: RexTaskBlock) async throws {
        let host = RexHost(
            label: task.hostLabel,
            displayName: task.hostLabel,
            endpoints: [],
            isLocal: task.hostIsLocal
        )
        _ = try await run(
            arguments: serverArguments(for: host) + [
                "block", "focus", task.blockID,
                "--session", task.sessionID
            ]
        )
        try activateRexApp()
    }

    func rename(_ task: RexTaskBlock, to label: String) async throws {
        let host = RexHost(
            label: task.hostLabel,
            displayName: task.hostLabel,
            endpoints: [],
            isLocal: task.hostIsLocal
        )
        _ = try await run(
            arguments: serverArguments(for: host) + [
                "block", "rename", task.blockID, label,
                "--session", task.sessionID
            ]
        )
    }

    func close(_ task: RexTaskBlock) async throws {
        let host = RexHost(
            label: task.hostLabel,
            displayName: task.hostLabel,
            endpoints: [],
            isLocal: task.hostIsLocal
        )
        _ = try await run(
            arguments: serverArguments(for: host) + [
                "block", "close", task.blockID,
                "--session", task.sessionID
            ]
        )
    }

    static func locateExecutable(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL? {
        var candidates: [URL] = []
        if let path = environment["PATH"] {
            candidates.append(contentsOf: path.split(separator: ":").map {
                URL(fileURLWithPath: String($0)).appendingPathComponent("rex")
            })
        }
        for app in ["Rex.app", "Rex Beta.app"] {
            candidates.append(
                URL(fileURLWithPath: "/Applications")
                    .appendingPathComponent(app)
                    .appendingPathComponent("Contents/Helpers/Rex Server.rex/Contents/MacOS/rex")
            )
            candidates.append(
                homeDirectory
                    .appendingPathComponent("Applications")
                    .appendingPathComponent(app)
                    .appendingPathComponent("Contents/Helpers/Rex Server.rex/Contents/MacOS/rex")
            )
        }
        candidates.append(
            homeDirectory.appendingPathComponent(
                "Library/Application Support/com.superlogical.rex/RexServer/Versions/Current/Rex Server.app/Contents/MacOS/rex"
            )
        )
        return candidates.first {
            FileManager.default.isExecutableFile(atPath: $0.path)
        }
    }

    static func hosts(from data: Data) throws -> [RexHost] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw invalidRexResponse("Rex returned an unexpected host list.")
        }
        var result: [RexHost] = []
        if let home = object["home"] as? [String: Any],
           home["this_machine"] as? Bool == true {
            result.append(
                RexHost(
                    label: "",
                    displayName: "This Mac",
                    endpoints: [home["endpoint"] as? String ?? ""].filter { !$0.isEmpty },
                    isLocal: true
                )
            )
        }
        for raw in object["hosts"] as? [[String: Any]] ?? [] {
            guard let label = raw["label"] as? String, !label.isEmpty else {
                continue
            }
            result.append(
                RexHost(
                    label: label,
                    displayName: label,
                    endpoints: raw["endpoints"] as? [String] ?? [],
                    isLocal: false
                )
            )
        }
        return result
    }

    static func sessions(from data: Data) throws -> [RexSessionInfo] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawSessions = object["sessions"] as? [[String: Any]] else {
            throw invalidRexResponse("Rex returned an unexpected session list.")
        }
        return rawSessions.compactMap { raw in
            guard let id = raw["session_id"] as? String else { return nil }
            return RexSessionInfo(
                id: id,
                label: raw["label"] as? String ?? "",
                windows: []
            )
        }
    }

    static func sessionInfo(
        from data: Data,
        host: RexHost,
        fallbackSession: RexSessionInfo
    ) throws -> RexSessionInfo {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw invalidRexResponse("Rex returned an unexpected session view.")
        }
        let sessionLabel = object["label"] as? String ?? fallbackSession.label
        let windows = (object["windows"] as? [[String: Any]] ?? []).map { window -> RexWindowInfo in
            let windowID = window["window_id"] as? String ?? ""
            let windowLabel = window["label"] as? String ?? ""
            let blocks = (window["layers"] as? [[String: Any]] ?? [])
                .flatMap { $0["blocks"] as? [[String: Any]] ?? [] }
                .compactMap { block -> RexTaskBlock? in
                    let creator = block["creator_name"] as? String ?? ""
                    guard creator == "com.superlogical.terminal" else {
                        return nil
                    }
                    guard let blockID = block["block_id"] as? String else {
                        return nil
                    }
                    return RexTaskBlock(
                        hostID: host.id,
                        hostLabel: host.displayName,
                        hostIsLocal: host.isLocal,
                        sessionID: fallbackSession.id,
                        sessionLabel: sessionLabel,
                        windowID: windowID,
                        windowLabel: windowLabel,
                        blockID: blockID,
                        label: block["label"] as? String ?? "",
                        title: block["title"] as? String,
                        status: block["status"] as? String
                    )
                }
            return RexWindowInfo(
                id: windowID,
                label: windowLabel,
                blocks: blocks
            )
        }
        return RexSessionInfo(
            id: fallbackSession.id,
            label: sessionLabel,
            windows: windows
        )
    }

    static func hostCheck(label: String, from data: Data) throws -> RexHostCheck {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hosts = object["hosts"] as? [[String: Any]],
              let host = hosts.first(where: { $0["label"] as? String == label })
                ?? hosts.first else {
            return RexHostCheck(label: label, reachable: false, detail: nil)
        }
        let status = host["status"] as? String ?? ""
        return RexHostCheck(
            label: label,
            reachable: status == "reachable",
            detail: host["detail"] as? String
        )
    }

    private func apiCall(
        host: RexHost,
        sessionID: String?,
        method: String,
        arguments: [String: Any]
    ) async throws -> [String: Any] {
        let json = String(
            data: try JSONSerialization.data(withJSONObject: arguments),
            encoding: .utf8
        ) ?? "{}"
        var command = serverArguments(for: host) + ["api", "call"]
        if let sessionID {
            command.append(contentsOf: ["--session", sessionID])
        }
        command.append(contentsOf: [method, json])
        let data = try await run(arguments: command)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Self.invalidRexResponse("Rex returned an unexpected API response.")
        }
        return object
    }

    private func serverArguments(for host: RexHost) -> [String] {
        host.serverArgument.map { ["-S", $0] } ?? []
    }

    private func run(arguments: [String]) async throws -> Data {
        guard let executableURL else {
            throw HerdrCoreError(
                kind: "rex_missing",
                message: "The Rex CLI is not available.",
                hint: "Install Rex or make its CLI available on PATH."
            )
        }
        return try await Task.detached(priority: .userInitiated) {
            try Self.runProcess(executableURL: executableURL, arguments: arguments)
        }.value
    }

    private func activateRexApp() throws {
        let candidates = [
            URL(fileURLWithPath: "/Applications/Rex.app"),
            URL(fileURLWithPath: "/Applications/Rex Beta.app"),
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Applications/Rex.app"),
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Applications/Rex Beta.app")
        ]
        guard let app = candidates.first(where: {
            FileManager.default.fileExists(atPath: $0.path)
        }) else {
            throw HerdrCoreError(
                kind: "rex_app_missing",
                message: "The Rex app is not installed.",
                hint: "Install Rex to open its terminal blocks."
            )
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", app.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw HerdrCoreError(
                kind: "open_failed",
                message: "Rex could not be activated.",
                hint: nil
            )
        }
    }

    private static func runProcess(
        executableURL: URL,
        arguments: [String]
    ) throws -> Data {
        let fileManager = FileManager.default
        let temporaryDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("Herdrker-rex-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        defer { try? fileManager.removeItem(at: temporaryDirectory) }

        let stdoutURL = temporaryDirectory.appendingPathComponent("stdout")
        let stderrURL = temporaryDirectory.appendingPathComponent("stderr")
        fileManager.createFile(atPath: stdoutURL.path, contents: nil)
        fileManager.createFile(atPath: stderrURL.path, contents: nil)
        let stdoutHandle = try FileHandle(forWritingTo: stdoutURL)
        let stderrHandle = try FileHandle(forWritingTo: stderrURL)

        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdoutHandle
        process.standardError = stderrHandle
        try process.run()
        process.waitUntilExit()
        try stdoutHandle.close()
        try stderrHandle.close()

        guard process.terminationStatus == 0 else {
            let stderr = try Data(contentsOf: stderrURL)
            let stdout = try Data(contentsOf: stdoutURL)
            let message = String(data: stderr.isEmpty ? stdout : stderr, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw HerdrCoreError(
                kind: "rex_command_failed",
                message: message?.isEmpty == false
                    ? (message ?? "Rex command failed.")
                    : "Rex command failed.",
                hint: nil
            )
        }
        return try Data(contentsOf: stdoutURL)
    }

    private static func invalidRexResponse(_ message: String) -> HerdrCoreError {
        HerdrCoreError(kind: "invalid_response", message: message, hint: nil)
    }
}
