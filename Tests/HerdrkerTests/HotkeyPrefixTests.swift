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
}
