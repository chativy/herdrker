import Foundation

final class TaskAliasStore {
    private let defaults: UserDefaults
    private let storageKey: String

    init(
        defaults: UserDefaults = .standard,
        storageKey: String = "taskAliases"
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
    }

    func alias(for address: String) -> String? {
        aliases[address]
    }

    func setAlias(_ name: String?, for address: String) {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        var updated = aliases
        if let trimmed, !trimmed.isEmpty {
            updated[address] = trimmed
        } else {
            updated.removeValue(forKey: address)
        }
        defaults.set(updated, forKey: storageKey)
    }

    func removeAlias(for address: String) {
        setAlias(nil, for: address)
    }

    private var aliases: [String: String] {
        defaults.dictionary(forKey: storageKey) as? [String: String] ?? [:]
    }
}
