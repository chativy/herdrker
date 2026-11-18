import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusMenuController: StatusMenuController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let herdrClient = try? HerdrCoreClient()
        let rexClient = RexClient()
        guard herdrClient != nil || rexClient.isAvailable else {
            let alert = NSAlert()
            alert.messageText = "Herdrker could not start"
            alert.informativeText =
                "Install herdr-core or Rex, then launch Herdrker again."
            alert.alertStyle = .critical
            alert.runModal()
            NSApplication.shared.terminate(nil)
            return
        }
        let controller = StatusMenuController(
            client: herdrClient,
            rexClient: rexClient
        )
        statusMenuController = controller
        controller.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        statusMenuController?.stop()
    }
}
