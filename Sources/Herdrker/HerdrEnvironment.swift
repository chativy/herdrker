import Foundation

enum HerdrEnvironment {
    static let inheritedTaskVariables = [
        "HC_TERMINAL_ID",
        "HC_TERMINAL_SOCKET",
        "HC_SCOPE",
        "HC_RUNTIME"
    ]

    static func removingTaskContext(
        from environment: [String: String]
    ) -> [String: String] {
        environment.filter { !inheritedTaskVariables.contains($0.key) }
    }

    static func sanitizeCurrentProcess() {
        for variable in inheritedTaskVariables {
            unsetenv(variable)
        }
    }

    static var shellReset: String {
        "unset \(inheritedTaskVariables.joined(separator: " ")); "
    }
}
