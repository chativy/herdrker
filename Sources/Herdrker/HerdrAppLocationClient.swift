import Foundation

struct HerdrAppLocationClient: Sendable {
    let executableURL: URL?

    init(executableURL: URL? = HerdrAppLocationClient.locateExecutable()) {
        self.executableURL = executableURL
    }

    func listLocations() async throws -> [HerdrLocationChoice] {
        guard let executableURL else {
            return []
        }
        let data = try await Task.detached(priority: .userInitiated) {
            try Self.runProcess(executableURL: executableURL)
        }.value
        return try HerdrModel.locations(from: data)
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

    private static func runProcess(executableURL: URL) throws -> Data {
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
        process.arguments = ["ls"]
        process.standardOutput = stdoutHandle
        process.standardError = stderrHandle
        try process.run()
        process.waitUntilExit()
        try stdoutHandle.close()
        try stderrHandle.close()

        guard process.terminationStatus == 0 else {
            let data = try Data(contentsOf: stderrURL)
            throw HerdrCoreError.decode(
                from: data,
                fallback: "Could not read spaces and tabs from Herdr."
            )
        }
        return try Data(contentsOf: stdoutURL)
    }
}
