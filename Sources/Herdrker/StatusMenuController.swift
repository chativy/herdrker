import AppKit
import SwiftUI

private final class TaskMenuPayload: NSObject {
    let task: HerdrTask

    init(task: HerdrTask) {
        self.task = task
    }
}

@MainActor
final class StatusMenuController: NSObject, NSMenuDelegate {
    private let client: any HerdrCoreProviding
    private let terminalLauncher: TerminalLauncher
    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private let herdrIcon: NSImage?

    private var hosts: [HerdrHost] = []
    private var tasks: [HerdrTask] = []
    private var groups: [HerdrHostGroup] = []
    private var loadError: String?
    private var isMenuOpen = false
    private var refreshLoop: Task<Void, Never>?
    private var activeDialog: DialogWindowController?

    init(
        client: any HerdrCoreProviding,
        terminalLauncher: TerminalLauncher = TerminalLauncher()
    ) {
        self.client = client
        self.terminalLauncher = terminalLauncher
        self.statusItem = NSStatusBar.system.statusItem(
            withLength: NSStatusItem.variableLength
        )
        self.herdrIcon = Self.loadHerdrIcon()
        super.init()

        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        statusItem.button?.imagePosition = .imageOnly
        statusItem.button?.toolTip = "Herdrker"
        statusItem.button?.setAccessibilityLabel("Herdrker")
        updateStatusIcon(hasTasks: false)
        rebuildMenu()
    }

    func start() {
        refreshLoop?.cancel()
        refreshLoop = Task { [weak self] in
            await self?.refresh()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard !Task.isCancelled else {
                    return
                }
                await self?.refresh()
            }
        }
    }

    func stop() {
        refreshLoop?.cancel()
        refreshLoop = nil
    }

    func menuWillOpen(_ menu: NSMenu) {
        isMenuOpen = true
        Task { [weak self] in
            await self?.refresh()
        }
    }

    func menuDidClose(_ menu: NSMenu) {
        isMenuOpen = false
        rebuildMenu()
    }

    private func refresh() async {
        var nextTasks = tasks
        var nextHosts = hosts
        var errors: [String] = []

        do {
            nextTasks = try await client.listTasks()
        } catch {
            errors.append(error.localizedDescription)
        }

        do {
            nextHosts = try await client.listHosts()
        } catch {
            errors.append(error.localizedDescription)
        }

        tasks = nextTasks
        hosts = nextHosts
        groups = HerdrModel.groups(hosts: nextHosts, tasks: nextTasks)
        loadError = errors.first
        updateStatusIcon(hasTasks: !nextTasks.isEmpty)
        if !isMenuOpen {
            rebuildMenu()
        }
    }

    private func rebuildMenu() {
        menu.removeAllItems()

        if loadError != nil {
            let errorItem = NSMenuItem(
                title: "Herdr Core unavailable",
                action: nil,
                keyEquivalent: ""
            )
            errorItem.image = NSImage(
                systemSymbolName: "exclamationmark.triangle.fill",
                accessibilityDescription: "Error"
            )
            menu.addItem(errorItem)
            menu.addItem(.separator())
        }

        for group in groups {
            let hostItem = NSMenuItem(
                title: hostTitle(for: group),
                action: nil,
                keyEquivalent: ""
            )
            hostItem.submenu = taskMenu(for: group)
            menu.addItem(hostItem)
        }

        if groups.isEmpty {
            menu.addItem(disabledItem("Loading tasks…"))
        }

        menu.addItem(.separator())

        let newTaskItem = NSMenuItem(
            title: "New Task…",
            action: #selector(showNewTask),
            keyEquivalent: "n"
        )
        newTaskItem.target = self
        newTaskItem.image = NSImage(
            systemSymbolName: "plus.square",
            accessibilityDescription: "New task"
        )
        menu.addItem(newTaskItem)

        let addHostItem = NSMenuItem(
            title: "Add Host…",
            action: #selector(showAddHost),
            keyEquivalent: ""
        )
        addHostItem.target = self
        addHostItem.image = NSImage(
            systemSymbolName: "network",
            accessibilityDescription: "Add host"
        )
        menu.addItem(addHostItem)

        let refreshItem = NSMenuItem(
            title: "Refresh",
            action: #selector(refreshNow),
            keyEquivalent: "r"
        )
        refreshItem.target = self
        menu.addItem(refreshItem)

        menu.addItem(.separator())
        let quitItem = NSMenuItem(
            title: "Quit Herdrker",
            action: #selector(quitApplication),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)
    }

    private func taskMenu(for group: HerdrHostGroup) -> NSMenu {
        let submenu = NSMenu(title: group.host.displayName)
        submenu.autoenablesItems = false

        if group.tasks.isEmpty {
            submenu.addItem(disabledItem("No tasks"))
            return submenu
        }

        for task in group.tasks {
            let item = NSMenuItem(
                title: "\(task.displayName) — \(task.stateLabel)",
                action: nil,
                keyEquivalent: ""
            )
            let payload = TaskMenuPayload(task: task)
            item.representedObject = payload

            if task.isFinished {
                item.image = NSImage(
                    systemSymbolName: "stop.circle.fill",
                    accessibilityDescription: "Stopped"
                )
                let actions = NSMenu(title: task.displayName)
                let viewItem = NSMenuItem(
                    title: "View Final Screen",
                    action: #selector(openTask(_:)),
                    keyEquivalent: ""
                )
                viewItem.target = self
                viewItem.representedObject = payload
                actions.addItem(viewItem)

                let removeItem = NSMenuItem(
                    title: "Remove Task",
                    action: #selector(confirmRemoveTask(_:)),
                    keyEquivalent: ""
                )
                removeItem.target = self
                removeItem.representedObject = payload
                actions.addItem(removeItem)
                item.submenu = actions
            } else {
                item.action = #selector(openTask(_:))
                item.target = self
                item.image = NSImage(
                    systemSymbolName: task.status == "blocked"
                        ? "exclamationmark.circle.fill"
                        : "circle.fill",
                    accessibilityDescription: task.stateLabel
                )
            }
            submenu.addItem(item)
        }
        return submenu
    }

    private func hostTitle(for group: HerdrHostGroup) -> String {
        let count = group.tasks.count
        let suffix = count == 0 ? "" : " (\(count))"
        let warning = group.host.hasConnectionError ? " — Disconnected" : ""
        return group.host.displayName + suffix + warning
    }

    private func disabledItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func updateStatusIcon(hasTasks: Bool) {
        statusItem.length = hasTasks ? 24 : 20
        statusItem.button?.image = Self.makeStatusImage(
            herdrIcon: herdrIcon,
            hasTasks: hasTasks
        )
    }

    private static func makeStatusImage(
        herdrIcon: NSImage?,
        hasTasks: Bool
    ) -> NSImage {
        let size = NSSize(width: 22, height: 18)
        let image = NSImage(size: size, flipped: false) { _ in
            let iconRect = NSRect(x: 1, y: 0, width: 18, height: 18)
            if let herdrIcon {
                herdrIcon.draw(
                    in: iconRect,
                    from: .zero,
                    operation: .sourceOver,
                    fraction: 1
                )
            } else {
                let fallback = NSImage(
                    systemSymbolName: "terminal.fill",
                    accessibilityDescription: "Herdrker"
                )
                fallback?.draw(
                    in: iconRect,
                    from: .zero,
                    operation: .sourceOver,
                    fraction: 1
                )
            }

            if hasTasks {
                let badgeRect = NSRect(x: 15, y: 11, width: 6, height: 6)
                NSColor.white.setFill()
                NSBezierPath(ovalIn: badgeRect.insetBy(dx: -1, dy: -1)).fill()
                NSColor.systemRed.setFill()
                NSBezierPath(ovalIn: badgeRect).fill()
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    private static func loadHerdrIcon() -> NSImage? {
        var candidates: [URL] = []
        if let bundled = Bundle.main.url(forResource: "Herdr", withExtension: "icns") {
            candidates.append(bundled)
        }
        candidates.append(
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("Resources/Herdr.icns")
        )
        return candidates.compactMap(NSImage.init(contentsOf:)).first
    }

    private func task(from sender: NSMenuItem) -> HerdrTask? {
        (sender.representedObject as? TaskMenuPayload)?.task
    }

    @objc private func openTask(_ sender: NSMenuItem) {
        guard let task = task(from: sender) else {
            return
        }
        Task { [weak self] in
            guard let self else {
                return
            }
            do {
                let detailedTask = try await client.task(address: task.address)
                try terminalLauncher.open(
                    task: detailedTask,
                    coreExecutableURL: client.executableURL
                )
            } catch {
                showError(error)
            }
        }
    }

    @objc private func confirmRemoveTask(_ sender: NSMenuItem) {
        guard let task = task(from: sender) else {
            return
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Remove “\(task.displayName)”?"
        alert.informativeText = "This permanently removes the stopped task from Herdr Core."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else {
            return
        }

        Task { [weak self] in
            guard let self else {
                return
            }
            do {
                try await client.removeTask(address: task.address)
                await refresh()
            } catch {
                showError(error)
            }
        }
    }

    @objc private func showNewTask() {
        let rootView = NewTaskDialog(
            hosts: groups.map(\.host),
            onCancel: { [weak self] in
                self?.activeDialog?.close()
            },
            onSubmit: { [weak self] request in
                self?.activeDialog?.close()
                self?.createTask(request)
            }
        )
        presentDialog(
            title: "Herdrker — New Task",
            size: NSSize(width: 520, height: 420),
            rootView: AnyView(rootView)
        )
    }

    @objc private func showAddHost() {
        let rootView = AddHostDialog(
            onCancel: { [weak self] in
                self?.activeDialog?.close()
            },
            onSubmit: { [weak self] request in
                self?.activeDialog?.close()
                self?.addHost(request)
            }
        )
        presentDialog(
            title: "Herdrker — Add Host",
            size: NSSize(width: 520, height: 370),
            rootView: AnyView(rootView)
        )
    }

    private func presentDialog(
        title: String,
        size: NSSize,
        rootView: AnyView
    ) {
        let controller = DialogWindowController(
            title: title,
            size: size,
            rootView: rootView
        )
        controller.onClose = { [weak self] in
            self?.activeDialog = nil
        }
        activeDialog = controller
        controller.present()
    }

    private func createTask(_ request: NewTaskRequest) {
        Task { [weak self] in
            guard let self else {
                return
            }
            do {
                let createdTask = try await client.createTask(request)
                await refresh()
                let detailedTask = try await client.task(address: createdTask.address)
                try terminalLauncher.open(
                    task: detailedTask,
                    coreExecutableURL: client.executableURL
                )
            } catch {
                showError(error)
            }
        }
    }

    private func addHost(_ request: NewHostRequest) {
        Task { [weak self] in
            guard let self else {
                return
            }
            do {
                try await client.addHost(request)
                await refresh()
            } catch {
                showError(error)
            }
        }
    }

    private func showError(_ error: Error) {
        let alert = NSAlert(error: error)
        alert.alertStyle = .warning
        alert.runModal()
    }

    @objc private func refreshNow() {
        Task { [weak self] in
            await self?.refresh()
        }
    }

    @objc private func quitApplication() {
        NSApplication.shared.terminate(nil)
    }
}
