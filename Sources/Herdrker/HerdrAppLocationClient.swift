import Foundation

struct HerdrAppLocationClient: Sendable {
    let executableURL: URL?

    init(executableURL: URL? = HerdrAppLocationClient.locateExecutable()) {
        self.executableURL = executableURL
    }

    func listLocations() async throws -> [HerdrLocationChoice] {
        guard executableURL != nil else {
            return []
        }
        let data = try await run(
            arguments: ["ls"],
            fallback: "Could not read spaces and tabs from Herdr."
        )
        return try HerdrModel.locations(from: data)
    }

    func parkTerminal(address: String) async throws {
        _ = try await run(
            arguments: ["do", "terminal.park", "--terminal", address],
            fallback: "Could not detach the task from its current Herdr tab."
        )
        guard await waitUntil({ locations in
            !locations.contains {
                $0.terminalAddresses.contains(address)
            }
        }) else {
            throw HerdrCoreError(
                kind: "herdr_move_timeout",
                message: "Herdr did not detach the task from its current tab.",
                hint: nil
            )
        }
    }

    func waitForPlacement(
        address: String,
        at location: HerdrLocationChoice
    ) async throws {
        guard await waitUntil({ locations in
            locations.contains {
                $0.spaceID == location.spaceID
                    && $0.tabID == location.tabID
                    && $0.terminalAddresses.contains(address)
            }
        }) else {
            throw HerdrCoreError(
                kind: "herdr_move_timeout",
                message: "The task did not appear in the destination Herdr tab.",
                hint: nil
            )
        }
    }

    static func locateExecutable(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL? {
        var candidates: [URL] = []
        if let path = environment["PATH"] {
            candidates.append(contentsOf: path.split(separator: ":").map {
                URL(fileURLWithPath: String($0)).appendingPathComponent("herdr-app")
            })
        }
        candidates.append(contentsOf: [
            homeDirectory.appendingPathComponent(".local/bin/herdr-app"),
            URL(fileURLWithPath: "/Applications/Herdr.app/Contents/MacOS/Herdr")
        ])
        return candidates.first {
            FileManager.default.isExecutableFile(atPath: $0.path)
        }
    }

    private func run(arguments: [String], fallback: String) async throws -> Data {
        guard let executableURL else {
            throw HerdrCoreError(
                kind: "herdr_app_missing",
                message: "The Herdr app is not installed.",
                hint: "Install Herdr to manage spaces and tabs."
            )
        }
        return try await Task.detached(priority: .userInitiated) {
            try Self.runProcess(
                executableURL: executableURL,
                arguments: arguments,
                fallback: fallback
            )
        }.value
    }

    private func waitUntil(
        _ predicate: ([HerdrLocationChoice]) -> Bool
    ) async -> Bool {
        for _ in 0..<40 {
            if let locations = try? await listLocations(), predicate(locations) {
                return true
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return false
    }

    private static func runProcess(
        executableURL: URL,
        arguments: [String],
        fallback: String
    ) throws -> Data {
        let fileManager = FileManager.default
        let temporaryDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("Herdrker-app-list-\(UUID().uuidString)", isDirectory: true)
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
            let errorData = try Data(contentsOf: stderrURL)
            let data = errorData.isEmpty
                ? try Data(contentsOf: stdoutURL)
                : errorData
            throw HerdrCoreError.decode(
                from: data,
                fallback: fallback
            )
        }
        return try Data(contentsOf: stdoutURL)
    }
}
