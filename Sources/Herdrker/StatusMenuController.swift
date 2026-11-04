import AppKit
import Carbon
import SwiftUI

private let herdrkerHotKeySignature: OSType = 0x4852444B

private func herdrkerHotKeyHandler(
    _ nextHandler: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event, let userData else {
        return OSStatus(eventNotHandledErr)
    }

    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )
    guard status == noErr, hotKeyID.signature == herdrkerHotKeySignature else {
        return OSStatus(eventNotHandledErr)
    }

    let controller = Unmanaged<StatusMenuController>
        .fromOpaque(userData)
        .takeUnretainedValue()
    Task { @MainActor in
        controller.handleGlobalHotKey(id: hotKeyID.id)
    }
    return noErr
}

private final class TaskMenuPayload: NSObject {
    let task: HerdrTask

    init(task: HerdrTask) {
        self.task = task
    }
}

private final class MoveTaskPayload: NSObject {
    let task: HerdrTask
    let location: HerdrLocationChoice

    init(task: HerdrTask, location: HerdrLocationChoice) {
        self.task = task
        self.location = location
    }
}

@MainActor
private final class HotkeyRecorder: NSObject {
    let label: NSTextField
    private(set) var prefix: HotkeyPrefix
    private var timer: Timer?
    private var pendingPeak: HotkeyPrefix?

    init(initialPrefix: HotkeyPrefix) {
        self.prefix = initialPrefix
        self.label = NSTextField(labelWithString: initialPrefix.display)
        super.init()
        label.font = .monospacedSystemFont(ofSize: 28, weight: .semibold)
        label.alignment = .center
        label.frame = NSRect(x: 0, y: 0, width: 340, height: 42)
    }

    func start() {
        timer = Timer(
            timeInterval: 0.05,
            target: self,
            selector: #selector(pollModifiers),
            userInfo: nil,
            repeats: true
        )
        if let timer {
            RunLoop.main.add(timer, forMode: .modalPanel)
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    @objc private func pollModifiers() {
        let pressed = HotkeyPrefix.from(eventFlags: NSEvent.modifierFlags)
        if pressed.isValid {
            if pendingPeak == nil
                || pressed.modifierCount >= pendingPeak!.modifierCount {
                pendingPeak = pressed
                label.stringValue = pressed.display
            }
        } else if let pendingPeak {
            prefix = pendingPeak
            self.pendingPeak = nil
        }
    }
}

@MainActor
final class StatusMenuController: NSObject, NSMenuDelegate {
    private let client: any HerdrCoreProviding
    private let terminalLauncher: TerminalLauncher
    private let herdrAppClient: HerdrAppLocationClient
    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private let herdrIcon: NSImage?
    private let hotkeyStore: HotkeyPrefixStore
    private var hotkeyPrefix: HotkeyPrefix

    private var hosts: [HerdrHost] = []
    private var tasks: [HerdrTask] = []
    private var groups: [HerdrHostGroup] = []
    private var appLocations: [HerdrLocationChoice] = []
    private var loadError: String?
    private var isMenuOpen = false
    private var refreshLoop: Task<Void, Never>?
    private var activeDialog: DialogWindowController?
    private var hotKeyRefs: [EventHotKeyRef] = []
    private var hotKeyEventHandler: EventHandlerRef?

    init(
        client: any HerdrCoreProviding,
        terminalLauncher: TerminalLauncher = TerminalLauncher(),
        herdrAppClient: HerdrAppLocationClient = HerdrAppLocationClient()
    ) {
        self.client = client
        self.terminalLauncher = terminalLauncher
        self.herdrAppClient = herdrAppClient
        self.statusItem = NSStatusBar.system.statusItem(
            withLength: NSStatusItem.variableLength
        )
        self.herdrIcon = Self.loadHerdrIcon()
        self.hotkeyStore = HotkeyPrefixStore()
        self.hotkeyPrefix = HotkeyPrefixStore().load()
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
        registerGlobalHotKeys()
        refreshLoop?.cancel()
        refreshLoop = Task { [weak self] in
            await self?.refresh(includeLocations: true)
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard !Task.isCancelled else {
                    return
                }
                await self?.refresh(includeLocations: true)
            }
        }
    }

    func stop() {
        refreshLoop?.cancel()
        refreshLoop = nil
        unregisterGlobalHotKeys()
    }

    func menuWillOpen(_ menu: NSMenu) {
        isMenuOpen = true
        Task { [weak self] in
            await self?.refresh(includeLocations: true)
        }
    }

    func menuDidClose(_ menu: NSMenu) {
        isMenuOpen = false
        rebuildMenu()
    }

    private func refresh(includeLocations: Bool = false) async {
        var nextTasks = tasks
        var nextHosts = hosts
        var nextLocations = appLocations
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

        if includeLocations {
            nextLocations = (try? await herdrAppClient.listLocations()) ?? []
        }

        tasks = nextTasks
        hosts = nextHosts
        appLocations = nextLocations
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
        newTaskItem.keyEquivalentModifierMask = hotkeyPrefix.menuModifierMask
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
        refreshItem.keyEquivalentModifierMask = hotkeyPrefix.menuModifierMask
        menu.addItem(refreshItem)

        menu.addItem(.separator())
        let assignItem = NSMenuItem(
            title: "Assign Hotkey… (\(hotkeyPrefix.display))",
            action: #selector(assignHotKey),
            keyEquivalent: ""
        )
        assignItem.target = self
        assignItem.image = NSImage(
            systemSymbolName: "keyboard",
            accessibilityDescription: "Assign hotkey"
        )
        menu.addItem(assignItem)

        let quitItem = NSMenuItem(
            title: "Quit Herdrker",
            action: #selector(quitApplication),
            keyEquivalent: "q"
        )
        quitItem.target = self
        quitItem.keyEquivalentModifierMask = hotkeyPrefix.menuModifierMask
        menu.addItem(quitItem)
    }

    private func taskMenu(for group: HerdrHostGroup) -> NSMenu {
        let submenu = NSMenu(title: group.host.displayName)
        submenu.autoenablesItems = false

        if group.tasks.isEmpty {
            submenu.addItem(disabledItem("No tasks"))
            return submenu
        }

        appendTaskNodes(
            HerdrModel.taskHierarchy(tasks: group.tasks),
            to: submenu
        )
        return submenu
    }

    private func appendTaskNodes(_ nodes: [HerdrTaskNode], to menu: NSMenu) {
        let column = shortcutColumn(for: nodes)
        for node in nodes {
            menu.addItem(
                taskItem(
                    for: node,
                    shortcutColumn: column
                )
            )
        }
    }

    private func taskItem(
        for node: HerdrTaskNode,
        shortcutColumn: CGFloat
    ) -> NSMenuItem {
        let task = node.task
        let currentLocation = location(for: task)
        let availableMoveTargets = moveTargets(
            for: task,
            currentLocation: currentLocation
        )
        let hasSubmenu = task.isFinished
            || !node.children.isEmpty
            || !availableMoveTargets.isEmpty
        let title = taskTitle(for: task)
        let item = NSMenuItem(
            title: title,
            action: nil,
            keyEquivalent: ""
        )
        if let index = shortcutIndex(for: task) {
            let key = index == 9 ? "0" : String(index + 1)
            item.attributedTitle = menuTitle(
                title,
                shortcut: "\(hotkeyPrefix.display)\(key)",
                column: shortcutColumn
            )
        }

        let payload = TaskMenuPayload(task: task)
        item.representedObject = payload
        item.image = NSImage(
            systemSymbolName: task.isFinished
                ? "stop.circle.fill"
                : task.status == "blocked"
                    ? "exclamationmark.circle.fill"
                    : "circle.fill",
            accessibilityDescription: task.stateLabel
        )

        if !hasSubmenu {
            item.action = #selector(openTask(_:))
            item.target = self
            return item
        }

        let actions = NSMenu(title: task.displayName)
        actions.autoenablesItems = false
        let openTitle = task.isFinished ? "View Final Screen" : "Attach"
        let openItem = NSMenuItem(
            title: openTitle,
            action: #selector(openTask(_:)),
            keyEquivalent: ""
        )
        openItem.target = self
        openItem.representedObject = payload
        actions.addItem(openItem)

        if task.isFinished {
            let removeItem = NSMenuItem(
                title: "Remove Task",
                action: #selector(confirmRemoveTask(_:)),
                keyEquivalent: ""
            )
            removeItem.target = self
            removeItem.representedObject = payload
            actions.addItem(removeItem)
        } else if !availableMoveTargets.isEmpty {
            actions.addItem(
                moveToItem(
                    for: task,
                    locations: availableMoveTargets
                )
            )
        }

        if !node.children.isEmpty {
            actions.addItem(.separator())
            appendTaskNodes(node.children, to: actions)
        }
        item.submenu = actions
        return item
    }

    private func menuTitle(
        _ title: String,
        shortcut: String,
        column: CGFloat
    ) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.tabStops = [
            NSTextTab(textAlignment: .right, location: column)
        ]
        let value = NSMutableAttributedString(
            string: "\(title)\t\(shortcut)"
        )
        value.addAttributes(
            [
                .font: NSFont.menuFont(ofSize: 0),
                .paragraphStyle: paragraph
            ],
            range: NSRange(location: 0, length: value.length)
        )
        return value
    }

    private func shortcutColumn(for nodes: [HerdrTaskNode]) -> CGFloat {
        let font = NSFont.menuFont(ofSize: 0)
        let widest = nodes.map { node in
            (taskTitle(for: node.task) as NSString).size(
                withAttributes: [.font: font]
            ).width
        }.max() ?? 0
        return ceil(widest) + 24
    }

    private func taskTitle(for task: HerdrTask) -> String {
        let locationSuffix = location(for: task).map {
            " · \(appLocationLabels[$0.id] ?? $0.label)"
        } ?? ""
        return "\(task.displayName) — \(task.stateLabel)\(locationSuffix)"
    }

    private func moveToItem(
        for task: HerdrTask,
        locations: [HerdrLocationChoice]
    ) -> NSMenuItem {
        let item = NSMenuItem(
            title: "Move to",
            action: nil,
            keyEquivalent: ""
        )
        let submenu = NSMenu(title: "Move to")
        submenu.autoenablesItems = false

        let spaces = HerdrModel.spaces(from: locations)
        let spaceLabels = HerdrModel.spaceLabels(for: spaces)
        for space in spaces {
            let spaceLocations = locations.filter { $0.spaceID == space.id }
            let tabLabels = HerdrModel.tabLabels(for: spaceLocations)
            let spaceItem = NSMenuItem(
                title: spaceLabels[space.id] ?? space.label,
                action: nil,
                keyEquivalent: ""
            )
            let tabsMenu = NSMenu(title: spaceItem.title)
            tabsMenu.autoenablesItems = false
            for location in spaceLocations {
                let tabItem = NSMenuItem(
                    title: tabLabels[location.id] ?? location.tabName,
                    action: #selector(moveTask(_:)),
                    keyEquivalent: ""
                )
                tabItem.target = self
                tabItem.representedObject = MoveTaskPayload(
                    task: task,
                    location: location
                )
                tabsMenu.addItem(tabItem)
            }
            spaceItem.submenu = tabsMenu
            submenu.addItem(spaceItem)
        }
        item.submenu = submenu
        return item
    }

    private func moveTargets(
        for task: HerdrTask,
        currentLocation: HerdrLocationChoice?
    ) -> [HerdrLocationChoice] {
        guard !task.isFinished else {
            return []
        }
        let hostID = task.machine ?? HerdrModel.localHostID
        return appLocations.filter {
            $0.hostID == hostID && $0.id != currentLocation?.id
        }
    }

    private func hostTitle(for group: HerdrHostGroup) -> String {
        let count = group.tasks.count
        let suffix = count == 0 ? "" : " (\(count))"
        let warning = group.host.hasConnectionError ? " — Disconnected" : ""
        return group.host.displayName + suffix + warning
    }

    private var appLocationLabels: [String: String] {
        HerdrModel.locationLabels(for: appLocations)
    }

    private func location(for task: HerdrTask) -> HerdrLocationChoice? {
        appLocations.first { $0.terminalAddresses.contains(task.address) }
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
        activateTask(task)
    }

    @objc private func moveTask(_ sender: NSMenuItem) {
        guard let payload = sender.representedObject as? MoveTaskPayload else {
            return
        }
        let task = payload.task
        let destination = payload.location
        let previous = location(for: task)

        Task { [weak self] in
            guard let self else {
                return
            }
            do {
                if previous != nil {
                    try await herdrAppClient.parkTerminal(address: task.address)
                }
                try await client.moveTask(
                    address: task.address,
                    spaceID: destination.coreSpaceID,
                    tabID: destination.coreTabID
                )
                try await herdrAppClient.waitForPlacement(
                    address: task.address,
                    at: destination
                )
                await refresh(includeLocations: true)
            } catch {
                if let previous {
                    let currentLocations =
                        (try? await herdrAppClient.listLocations()) ?? []
                    if currentLocations.contains(where: {
                        $0.terminalAddresses.contains(task.address)
                    }) {
                        try? await herdrAppClient.parkTerminal(
                            address: task.address
                        )
                    }
                    try? await client.moveTask(
                        address: task.address,
                        spaceID: previous.coreSpaceID,
                        tabID: previous.coreTabID
                    )
                    try? await herdrAppClient.waitForPlacement(
                        address: task.address,
                        at: previous
                    )
                }
                await refresh(includeLocations: true)
                showError(error)
            }
        }
    }

    private func activateTask(_ task: HerdrTask) {
        if terminalLauncher.focus(taskAddress: task.address) {
            return
        }
        Task { [weak self] in
            guard let self else {
                return
            }
            do {
                let detailedTask = try await client.task(address: task.address)
                try await terminalLauncher.open(
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
        Task { [weak self] in
            guard let self else {
                return
            }
            let locations = (try? await herdrAppClient.listLocations()) ?? []
            appLocations = locations
            presentNewTask(locations: locations)
        }
    }

    private func presentNewTask(locations: [HerdrLocationChoice]) {
        let rootView = NewTaskDialog(
            hosts: groups.map(\.host),
            tasks: orderedTasks,
            locations: locations,
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
            size: NSSize(width: 520, height: 520),
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
                let createdTask = try await client.createTask(
                    request,
                    environment: terminalLauncher.taskEnvironment
                )
                if let spaceID = request.herdrSpaceID,
                   let tabID = request.herdrTabID,
                   let location = appLocations.first(where: {
                       $0.coreSpaceID == spaceID && $0.coreTabID == tabID
                   }) {
                    try? await herdrAppClient.waitForPlacement(
                        address: createdTask.address,
                        at: location
                    )
                }
                await refresh(includeLocations: true)
                let detailedTask = try await client.task(address: createdTask.address)
                try await terminalLauncher.open(
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
            await self?.refresh(includeLocations: true)
        }
    }

    @objc private func quitApplication() {
        NSApplication.shared.terminate(nil)
    }

    private var shortcutTasks: [HerdrTask] {
        Array(orderedTasks.prefix(10))
    }

    private var orderedTasks: [HerdrTask] {
        groups.flatMap { group in
            HerdrModel.flattened(
                HerdrModel.taskHierarchy(tasks: group.tasks)
            )
        }
    }

    private func shortcutIndex(for task: HerdrTask) -> Int? {
        shortcutTasks.firstIndex(where: { $0.address == task.address })
    }

    fileprivate func handleGlobalHotKey(id: UInt32) {
        switch id {
        case 101:
            showNewTask()
            return
        case 102:
            refreshNow()
            return
        case 103:
            quitApplication()
            return
        default:
            break
        }

        let index = Int(id) - 1
        guard shortcutTasks.indices.contains(index) else {
            return
        }
        activateTask(shortcutTasks[index])
    }

    @discardableResult
    private func registerGlobalHotKeys() -> Int {
        guard hotKeyRefs.isEmpty else {
            return hotKeyRefs.count
        }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            herdrkerHotKeyHandler,
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &hotKeyEventHandler
        )
        guard handlerStatus == noErr else {
            return 0
        }

        let bindings: [(id: UInt32, keyCode: UInt32)] = [
            (1, 18), (2, 19), (3, 20), (4, 21), (5, 23),
            (6, 22), (7, 26), (8, 28), (9, 25), (10, 29),
            (101, 45), (102, 15), (103, 12)
        ]
        let modifiers = hotkeyPrefix.carbonModifiers
        for binding in bindings {
            var hotKeyRef: EventHotKeyRef?
            let hotKeyID = EventHotKeyID(
                signature: herdrkerHotKeySignature,
                id: binding.id
            )
            let status = RegisterEventHotKey(
                binding.keyCode,
                modifiers,
                hotKeyID,
                GetApplicationEventTarget(),
                0,
                &hotKeyRef
            )
            if status == noErr, let hotKeyRef {
                hotKeyRefs.append(hotKeyRef)
            }
        }
        return hotKeyRefs.count
    }

    private func unregisterGlobalHotKeys() {
        for hotKeyRef in hotKeyRefs {
            UnregisterEventHotKey(hotKeyRef)
        }
        hotKeyRefs.removeAll()
        if let hotKeyEventHandler {
            RemoveEventHandler(hotKeyEventHandler)
            self.hotKeyEventHandler = nil
        }
    }

    @objc private func assignHotKey() {
        let recorder = HotkeyRecorder(initialPrefix: hotkeyPrefix)

        let alert = NSAlert()
        alert.messageText = "Assign Hotkey Prefix"
        alert.informativeText =
            "Press a modifier combination such as Command+Option, Command+Control, or Command+Control+Option."
        alert.addButton(withTitle: "Assign")
        alert.addButton(withTitle: "Cancel")
        alert.accessoryView = recorder.label
        recorder.start()
        defer { recorder.stop() }

        guard alert.runModal() == .alertFirstButtonReturn else {
            return
        }

        hotkeyPrefix = recorder.prefix
        hotkeyStore.save(recorder.prefix)
        unregisterGlobalHotKeys()
        let registered = registerGlobalHotKeys()
        rebuildMenu()

        if registered < 13 {
            let warning = NSAlert()
            warning.messageText = "Some hotkeys are unavailable"
            warning.informativeText =
                "Only \(registered) of 13 global shortcuts could be registered. Another application or macOS may be using this combination."
            warning.runModal()
        }
    }
}
