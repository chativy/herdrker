import AppKit
import Carbon

struct HotkeyPrefix: Equatable, Sendable {
    static let defaultPrefix = HotkeyPrefix(
        carbonModifiers: UInt32(cmdKey | optionKey)
    )

    let carbonModifiers: UInt32

    init(carbonModifiers: UInt32) {
        let allowed = UInt32(cmdKey | controlKey | optionKey | shiftKey)
        self.carbonModifiers = carbonModifiers & allowed
    }

    var isValid: Bool {
        let required = UInt32(cmdKey | controlKey | optionKey)
        return carbonModifiers & required != 0
    }

    var display: String {
        var value = ""
        if carbonModifiers & UInt32(cmdKey) != 0 {
            value += "⌘"
        }
        if carbonModifiers & UInt32(controlKey) != 0 {
            value += "⌃"
        }
        if carbonModifiers & UInt32(optionKey) != 0 {
            value += "⌥"
        }
        if carbonModifiers & UInt32(shiftKey) != 0 {
            value += "⇧"
        }
        return value
    }

    var menuModifierMask: NSEvent.ModifierFlags {
        var value: NSEvent.ModifierFlags = []
        if carbonModifiers & UInt32(cmdKey) != 0 {
            value.insert(.command)
        }
        if carbonModifiers & UInt32(controlKey) != 0 {
            value.insert(.control)
        }
        if carbonModifiers & UInt32(optionKey) != 0 {
            value.insert(.option)
        }
        if carbonModifiers & UInt32(shiftKey) != 0 {
            value.insert(.shift)
        }
        return value
    }

    static func from(eventFlags: NSEvent.ModifierFlags) -> HotkeyPrefix {
        var value: UInt32 = 0
        if eventFlags.contains(.command) {
            value |= UInt32(cmdKey)
        }
        if eventFlags.contains(.control) {
            value |= UInt32(controlKey)
        }
        if eventFlags.contains(.option) {
            value |= UInt32(optionKey)
        }
        if eventFlags.contains(.shift) {
            value |= UInt32(shiftKey)
        }
        return HotkeyPrefix(carbonModifiers: value)
    }

    var modifierCount: Int {
        [cmdKey, controlKey, optionKey, shiftKey].reduce(0) { count, key in
            count + (carbonModifiers & UInt32(key) != 0 ? 1 : 0)
        }
    }
}

final class HotkeyPrefixStore {
    private let defaults: UserDefaults
    private let storageKey: String

    init(
        defaults: UserDefaults = .standard,
        storageKey: String = "taskHotkeyPrefix"
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
    }

    func load() -> HotkeyPrefix {
        let stored = defaults.object(forKey: storageKey) as? NSNumber
        let prefix = HotkeyPrefix(
            carbonModifiers: UInt32(truncatingIfNeeded: stored?.uint64Value ?? 0)
        )
        return prefix.isValid ? prefix : .defaultPrefix
    }

    func save(_ prefix: HotkeyPrefix) {
        defaults.set(NSNumber(value: prefix.carbonModifiers), forKey: storageKey)
    }
}
