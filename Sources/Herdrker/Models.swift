import Foundation

struct NewTaskRequest: Equatable, Sendable {
    let host: String?
    let name: String?
    let command: String?
    let workingDirectory: String?
    let parent: String?
    let herdrSpaceID: String?
    let herdrTabID: String?
    let whereLabel: String?

    init(
        host: String?,
        name: String?,
        command: String?,
        workingDirectory: String?,
        parent: String? = nil,
        herdrSpaceID: String? = nil,
        herdrTabID: String? = nil,
        whereLabel: String? = nil
    ) {
        self.host = host
        self.name = name
        self.command = command
        self.workingDirectory = workingDirectory
        self.parent = parent
        self.herdrSpaceID = herdrSpaceID
        self.herdrTabID = herdrTabID
        self.whereLabel = whereLabel
    }
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
    let cols: Int?
    let rows: Int?
    let parent: String?

    init(
        address: String,
        name: String?,
        title: String?,
        machine: String?,
        state: String,
        status: String?,
        createdAt: Date?,
        cols: Int? = nil,
        rows: Int? = nil,
        parent: String? = nil
    ) {
        self.address = address
        self.name = name
        self.title = title
        self.machine = machine
        self.state = state
        self.status = status
        self.createdAt = createdAt
        self.cols = cols
        self.rows = rows
        self.parent = parent
    }

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

struct HerdrTaskNode: Identifiable, Hashable, Sendable {
    let task: HerdrTask
    let children: [HerdrTaskNode]

    var id: String { task.address }
}

struct HerdrLocationChoice: Identifiable, Hashable, Sendable {
    let spaceID: String
    let tabID: String
    let spaceName: String
    let tabName: String
    let machine: String?
    let terminalAddresses: [String]

    init(
        spaceID: String,
        tabID: String,
        spaceName: String,
        tabName: String,
        machine: String?,
        terminalAddresses: [String] = []
    ) {
        self.spaceID = spaceID
        self.tabID = tabID
        self.spaceName = spaceName
        self.tabName = tabName
        self.machine = machine
        self.terminalAddresses = terminalAddresses
    }

    var id: String { "\(spaceID)/\(tabID)" }
    var label: String { "\(spaceName) / \(tabName)" }
    var hostID: String { machine ?? HerdrModel.localHostID }
    var disambiguatedLabel: String {
        "\(label) [\(shortSpaceID)/\(shortTabID)]"
    }

    private var shortSpaceID: String {
        String((spaceID.split(separator: "/").last ?? "").prefix(8))
    }

    private var shortTabID: String {
        String((tabID.split(separator: "/").last ?? "").prefix(8))
    }
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

    static func defaultWorkingDirectory(
        hostID: String,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> String? {
        hostID == localHostID ? homeDirectory.path : nil
    }

    static func taskHierarchy(tasks: [HerdrTask]) -> [HerdrTaskNode] {
        let ordered = tasks.sorted(by: taskOrder)
        let addresses = Set(ordered.map(\.address))
        let childrenByParent = Dictionary(grouping: ordered.filter { task in
            guard let parent = task.parent else {
                return false
            }
            return parent != task.address && addresses.contains(parent)
        }, by: { $0.parent! })
        let roots = ordered.filter { task in
            guard let parent = task.parent else {
                return true
            }
            return !addresses.contains(parent) || parent == task.address
        }
        var emitted = Set<String>()

        func node(_ task: HerdrTask, ancestors: Set<String>) -> HerdrTaskNode {
            emitted.insert(task.address)
            let nextAncestors = ancestors.union([task.address])
            let children = (childrenByParent[task.address] ?? [])
                .filter { !nextAncestors.contains($0.address) }
                .map { node($0, ancestors: nextAncestors) }
            return HerdrTaskNode(task: task, children: children)
        }

        var result = roots.map { node($0, ancestors: []) }
        for task in ordered where !emitted.contains(task.address) {
            result.append(node(task, ancestors: [task.address]))
        }
        return result
    }

    static func flattened(_ nodes: [HerdrTaskNode]) -> [HerdrTask] {
        nodes.flatMap { [$0.task] + flattened($0.children) }
    }

    static func locationLabels(
        for locations: [HerdrLocationChoice]
    ) -> [String: String] {
        let counts = Dictionary(grouping: locations, by: \.label)
            .mapValues(\.count)
        return Dictionary(uniqueKeysWithValues: locations.map { location in
            let label = counts[location.label, default: 0] > 1
                ? location.disambiguatedLabel
                : location.label
            return (location.id, label)
        })
    }

    static func locations(from data: Data) throws -> [HerdrLocationChoice] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let spaces = object["spaces"] as? [[String: Any]] else {
            throw HerdrCoreError(
                kind: "invalid_response",
                message: "Herdr app returned an unexpected location list.",
                hint: nil
            )
        }
        return spaces.flatMap { space -> [HerdrLocationChoice] in
            guard let spaceID = space["id"] as? String,
                  let spaceName = space["name"] as? String else {
                return []
            }
            let machine = space["machine"] as? String
            let tabs = space["tabs"] as? [[String: Any]] ?? []
            return tabs.compactMap { tab in
                guard let tabID = tab["id"] as? String,
                      let tabName = tab["name"] as? String else {
                    return nil
                }
                let terminalAddresses = (tab["terminals"] as? [[String: Any]] ?? [])
                    .compactMap { $0["terminal"] as? String }
                    .filter { !$0.isEmpty }
                return HerdrLocationChoice(
                    spaceID: spaceID,
                    tabID: tabID,
                    spaceName: spaceName,
                    tabName: tabName,
                    machine: machine,
                    terminalAddresses: terminalAddresses
                )
            }
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

    static func task(from data: Data) throws -> HerdrTask {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let task = parseTask(object) else {
            throw HerdrCoreError(
                kind: "invalid_response",
                message: "herdr-core returned an unexpected task response.",
                hint: nil
            )
        }
        return task
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
            },
            cols: integer(object["cols"]),
            rows: integer(object["rows"]),
            parent: nonemptyString(object["parent"])
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

    private static func integer(_ value: Any?) -> Int? {
        if let number = value as? NSNumber {
            return number.intValue
        }
        return value as? Int
    }
}
