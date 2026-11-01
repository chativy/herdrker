import Foundation
import XCTest
@testable import Herdrker

final class TaskAliasStoreTests: XCTestCase {
    func testAliasCanBeSetAndReset() {
        let suiteName = "HerdrkerTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let store = TaskAliasStore(defaults: defaults)

        store.setAlias("  Review changes  ", for: "t2")
        XCTAssertEqual(store.alias(for: "t2"), "Review changes")

        store.setAlias("", for: "t2")
        XCTAssertNil(store.alias(for: "t2"))
    }
}
