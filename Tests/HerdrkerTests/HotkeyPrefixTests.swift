import AppKit
import XCTest
@testable import Herdrker

final class HotkeyPrefixTests: XCTestCase {
    func testModifierDisplayAndMenuConversion() {
        let prefix = HotkeyPrefix.from(eventFlags: [.command, .control, .option])

        XCTAssertEqual(prefix.display, "⌘⌃⌥")
        XCTAssertTrue(prefix.menuModifierMask.contains(.command))
        XCTAssertTrue(prefix.menuModifierMask.contains(.control))
        XCTAssertTrue(prefix.menuModifierMask.contains(.option))
        XCTAssertTrue(prefix.isValid)
    }

    func testPrefixStoreRoundTripsAndRejectsEmptyPrefix() {
        let suiteName = "HerdrkerHotkeyTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let store = HotkeyPrefixStore(defaults: defaults)
        let commandControl = HotkeyPrefix.from(eventFlags: [.command, .control])

        store.save(commandControl)
        XCTAssertEqual(store.load(), commandControl)

        store.save(HotkeyPrefix(carbonModifiers: 0))
        XCTAssertEqual(store.load(), .defaultPrefix)
    }

    func testTaskShortcutKeysCoverNumbersAndLetters() {
        XCTAssertEqual(TaskShortcutKey.all.count, 33)
        XCTAssertEqual(
            TaskShortcutKey.all.map(\.character),
            Array("1234567890abcdefghijklmopstuvwxyz")
                .map(String.init)
        )
        XCTAssertEqual(
            Set(TaskShortcutKey.all.map(\.keyCode)).count,
            TaskShortcutKey.all.count
        )
    }

    func testBackendSelectionUsesLastAvailableBackend() {
        let suiteName = "HerdrkerBackendTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let store = BackendSelectionStore(defaults: defaults)

        store.save(.rex)

        XCTAssertEqual(
            store.load(available: [.herdr, .rex]),
            .rex
        )
        XCTAssertEqual(
            store.load(available: [.herdr]),
            .herdr
        )
    }

    func testOnlyInstalledBackendsAreAvailable() {
        XCTAssertEqual(
            TaskBackendAvailability.installed(herdr: true, rex: false),
            [.herdr]
        )
        XCTAssertEqual(
            TaskBackendAvailability.installed(herdr: false, rex: true),
            [.rex]
        )
        XCTAssertEqual(
            TaskBackendAvailability.installed(herdr: true, rex: true),
            [.herdr, .rex]
        )
        XCTAssertEqual(
            TaskBackendAvailability.visible(
                installed: [.herdr, .rex],
                hasHerdrTasks: false,
                hasRexTasks: true
            ),
            [.rex]
        )
        XCTAssertEqual(
            TaskBackendAvailability.visible(
                installed: [.herdr, .rex],
                hasHerdrTasks: false,
                hasRexTasks: false
            ),
            []
        )
    }
}
