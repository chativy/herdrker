import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusMenuController: StatusMenuController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let client = try HerdrCoreClient()
            let controller = StatusMenuController(client: client)
            statusMenuController = controller
            controller.start()
        } catch {
            let alert = NSAlert(error: error)
            alert.messageText = "Herdrker could not start"
            alert.runModal()
            NSApplication.shared.terminate(nil)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        statusMenuController?.stop()
    }
}
