import Foundation

struct NewTaskRequest: Equatable, Sendable {
    let host: String?
    let name: String?
    let command: String?
    let workingDirectory: String?
}

struct NewHostRequest: Equatable, Sendable {
    let name: String?
    let target: String
    let installCore: Bool
}

struct HerdrTask: Identifiable, Hashable, Sendable {
    let address: String
    let name: String?
    let title: String?
    let machine: String?
    let state: String
    let status: String?
    let createdAt: Date?

    var id: String { address }
    var isFinished: Bool { state == "finished" }
    var displayName: String {
        name ?? title.flatMap { $0.isEmpty ? nil : $0 } ?? address
    }

    var stateLabel: String {
        if isFinished {
            return "Stopped"
        }
        guard let status, !status.isEmpty else {
            return "Live"
        }
        return status.capitalized
    }
}

struct HerdrHost: Identifiable, Hashable, Sendable {
    let name: String
    let target: String?
    let isTemporary: Bool
    let hasConnectionError: Bool

    var id: String { name }
    var displayName: String {
        name == HerdrModel.localHostID ? "This Mac" : name
    }
}

struct HerdrHostGroup: Identifiable, Hashable, Sendable {
    let host: HerdrHost
    let tasks: [HerdrTask]

    var id: String { host.id }
}

enum HerdrModel {
    static let localHostID = "__local__"
    static let localHost = HerdrHost(
        name: localHostID,
        target: nil,
        isTemporary: false,
        hasConnectionError: false
    )

    static func groups(hosts: [HerdrHost], tasks: [HerdrTask]) -> [HerdrHostGroup] {
        let knownHosts = Dictionary(
            hosts
                .filter { !$0.isTemporary && $0.name != localHostID }
                .map { ($0.name, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        var tasksByHost: [String: [HerdrTask]] = [localHostID: []]
        for task in tasks {
            tasksByHost[task.machine ?? localHostID, default: []].append(task)
        }

        let allHosts = [localHost]
            + knownHosts.values.sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        let knownIDs = Set(allHosts.map(\.id))
        let unknownHosts = tasksByHost.keys
            .filter { !knownIDs.contains($0) }
            .sorted {
                $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
            }
            .map {
                HerdrHost(
                    name: $0,
                    target: nil,
                    isTemporary: false,
                    hasConnectionError: false
                )
            }

        return (allHosts + unknownHosts).map { host in
            HerdrHostGroup(
                host: host,
                tasks: (tasksByHost[host.id] ?? []).sorted(by: taskOrder)
            )
        }
    }

    private static func taskOrder(_ lhs: HerdrTask, _ rhs: HerdrTask) -> Bool {
        if lhs.isFinished != rhs.isFinished {
            return !lhs.isFinished
        }
        let comparison = lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName)
        if comparison != .orderedSame {
            return comparison == .orderedAscending
        }
        return lhs.address.localizedStandardCompare(rhs.address) == .orderedAscending
    }
}

enum HerdrJSON {
    static func taskList(from data: Data) throws -> [HerdrTask] {
        try records(from: data, preferredKey: "terminals").compactMap(parseTask)
    }

    static func hostList(from data: Data) throws -> [HerdrHost] {
        try records(from: data, preferredKey: "machines").compactMap(parseHost)
    }

    private static func records(from data: Data, preferredKey: String) throws -> [[String: Any]] {
        if data.isEmpty {
            return []
        }
        let value = try JSONSerialization.jsonObject(with: data)
        if let records = value as? [[String: Any]] {
            return records
        }
        if let object = value as? [String: Any],
           let records = object[preferredKey] as? [[String: Any]] {
            return records
        }
        throw HerdrCoreError(
            kind: "invalid_response",
            message: "herdr-core returned an unexpected JSON response.",
            hint: nil
        )
    }

    private static func parseTask(_ object: [String: Any]) -> HerdrTask? {
        guard let address = nonemptyString(object["address"]) else {
            return nil
        }

        let addressParts = address.split(separator: "/", maxSplits: 1)
        let addressMachine = addressParts.count == 2 ? String(addressParts[0]) : nil
        let explicitMachine = nonemptyString(object["machine"])
        let labels = object["labels"] as? [String: Any]
        let labelMachine = nonemptyString(labels?["herdr.machine"])
        let createdMilliseconds = number(object["created_ms"])

        return HerdrTask(
            address: address,
            name: nonemptyString(object["name"]),
            title: nonemptyString(object["title"]),
            machine: explicitMachine ?? addressMachine ?? labelMachine,
            state: nonemptyString(object["state"]) ?? "live",
            status: nonemptyString(object["status"]),
            createdAt: createdMilliseconds.map {
                Date(timeIntervalSince1970: $0 / 1_000)
            }
        )
    }

    private static func parseHost(_ object: [String: Any]) -> HerdrHost? {
        guard let name = nonemptyString(object["name"]) else {
            return nil
        }
        return HerdrHost(
            name: name,
            target: nonemptyString(object["target"]),
            isTemporary: object["temporary"] as? Bool ?? false,
            hasConnectionError: object["error"] != nil
        )
    }

    private static func nonemptyString(_ value: Any?) -> String? {
        guard let string = value as? String else {
            return nil
        }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber {
            return number.doubleValue
        }
        return value as? Double
    }
}
