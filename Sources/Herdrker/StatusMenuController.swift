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

private final class RexTaskPayload: NSObject {
    let task: RexTaskBlock

    init(task: RexTaskBlock) {
        self.task = task
    }
}

private enum TaskShortcutTarget: Hashable {
    case herdr(HerdrTask)
    case rex(RexTaskBlock)
}

private struct HotKeyRegistrationResult {
    let registered: Int
    let expected: Int
    let failures: [String]
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
    private let client: (any HerdrCoreProviding)?
    private let rexClient: RexClient
    private let terminalLauncher: TerminalLauncher
    private let herdrAppClient: HerdrAppLocationClient
    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private let herdrIcon: NSImage?
    private let hotkeyStore: HotkeyPrefixStore
    private let backendStore = BackendSelectionStore()
    private var hotkeyPrefix: HotkeyPrefix

    private var hosts: [HerdrHost] = []
    private var tasks: [HerdrTask] = []
    private var groups: [HerdrHostGroup] = []
    private var rexHostGroups: [RexHostGroup] = []
    private var appLocations: [HerdrLocationChoice] = []
    private var loadError: String?
    private var rexLoadError: String?
    private var isMenuOpen = false
    private var refreshLoop: Task<Void, Never>?
    private var activeDialog: DialogWindowController?
    private var hotKeyRefs: [EventHotKeyRef] = []
    private var hotKeyEventHandler: EventHandlerRef?
    private var registeredTaskShortcutKeys: [TaskShortcutKey] = []
    private var taskShortcutIndexByHotKeyID: [UInt32: Int] = [:]
    private var registeredActionHotKeyIDs: Set<UInt32> = []

    private var availableBackends: [TaskBackendKind] {
        TaskBackendAvailability.installed(
            herdr: client != nil,
            rex: rexClient.isAvailable
        )
    }

    init(
        client: (any HerdrCoreProviding)?,
        rexClient: RexClient = RexClient(),
        terminalLauncher: TerminalLauncher = TerminalLauncher(),
        herdrAppClient: HerdrAppLocationClient = HerdrAppLocationClient()
    ) {
        self.client = client
        self.rexClient = rexClient
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
        _ = registerGlobalHotKeys()
        rebuildMenu()
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
        var nextRexGroups = rexHostGroups
        var nextRexError: String?
        var errors: [String] = []

        if let client {
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
        } else {
            nextTasks = []
            nextHosts = []
        }

        if includeLocations {
            nextLocations = (try? await herdrAppClient.listLocations()) ?? []
        }

        if rexClient.isAvailable {
            do {
                nextRexGroups = try await rexClient.listHostGroups()
            } catch {
                nextRexError = error.localizedDescription
            }
        } else {
            nextRexError = "Rex CLI is not installed."
        }

        tasks = nextTasks
        hosts = nextHosts
        appLocations = nextLocations
        rexHostGroups = nextRexGroups
        rexLoadError = nextRexError
        groups = HerdrModel.groups(hosts: nextHosts, tasks: nextTasks)
        loadError = errors.first
        updateStatusIcon(
            hasTasks: !nextTasks.isEmpty
                || nextRexGroups.contains { !$0.tasks.isEmpty }
        )
        if !isMenuOpen {
            rebuildMenu()
        }
    }

    private func rebuildMenu() {
        menu.removeAllItems()
        let visibleBackends = TaskBackendAvailability.visible(
            installed: availableBackends,
            hasHerdrTasks: groups.contains { !$0.tasks.isEmpty },
            hasRexTasks: rexHostGroups.contains { !$0.tasks.isEmpty }
        )

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

        switch TaskBackendAvailability.menuLayout(for: visibleBackends) {
        case .none:
            break
        case let .flat(backend):
            switch backend {
            case .herdr:
                herdrHostItems().forEach(menu.addItem)
            case .rex:
                rexHostItems().forEach(menu.addItem)
            }
        case .sections:
            let herdrMenu = NSMenu(title: "Herdr")
            herdrMenu.autoenablesItems = false
            herdrHostItems().forEach(herdrMenu.addItem)
            let herdrItem = NSMenuItem(
                title: "Herdr",
                action: nil,
                keyEquivalent: ""
            )
            herdrItem.submenu = herdrMenu
            menu.addItem(herdrItem)

            let rexItem = NSMenuItem(
                title: "Rex",
                action: nil,
                keyEquivalent: ""
            )
            rexItem.submenu = rexRootMenu()
            menu.addItem(rexItem)
        }

        menu.addItem(.separator())

        let newTaskItem = NSMenuItem(
            title: "New Task…",
            action: #selector(showNewTask),
            keyEquivalent: registeredActionHotKeyIDs.contains(101) ? "n" : ""
        )
        newTaskItem.target = self
        if registeredActionHotKeyIDs.contains(101) {
            newTaskItem.keyEquivalentModifierMask = hotkeyPrefix.menuModifierMask
        }
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
            keyEquivalent: registeredActionHotKeyIDs.contains(102) ? "r" : ""
        )
        refreshItem.target = self
        if registeredActionHotKeyIDs.contains(102) {
            refreshItem.keyEquivalentModifierMask = hotkeyPrefix.menuModifierMask
        }
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
            keyEquivalent: registeredActionHotKeyIDs.contains(103) ? "q" : ""
        )
        quitItem.target = self
        if registeredActionHotKeyIDs.contains(103) {
            quitItem.keyEquivalentModifierMask = hotkeyPrefix.menuModifierMask
        }
        menu.addItem(quitItem)
    }

    private func taskMenu(for group: HerdrHostGroup) -> NSMenu {
        let submenu = NSMenu(title: group.host.displayName)
        submenu.autoenablesItems = false

        let locations = appLocations.filter { $0.hostID == group.host.id }
        let locationGroups = HerdrModel.taskLocationGroups(
            tasks: group.tasks,
            locations: locations
        )
        let unplacedTasks = HerdrModel.unplacedTasks(
            tasks: group.tasks,
            locations: locations
        )

        if locationGroups.isEmpty && unplacedTasks.isEmpty {
            submenu.addItem(disabledItem("No tasks"))
            return submenu
        }

        let spaces = HerdrModel.spaces(
            from: locationGroups.map(\.location)
        )
        let spaceLabels = HerdrModel.spaceLabels(for: spaces)
        for space in spaces {
            let tabGroups = locationGroups.filter {
                $0.location.spaceID == space.id
            }
            let tabLabels = HerdrModel.tabLabels(
                for: tabGroups.map(\.location)
            )
            let spaceItem = NSMenuItem(
                title: spaceLabels[space.id] ?? space.label,
                action: nil,
                keyEquivalent: ""
            )
            let tabsMenu = NSMenu(title: spaceItem.title)
            tabsMenu.autoenablesItems = false
            for tabGroup in tabGroups {
                let tabItem = NSMenuItem(
                    title: tabLabels[tabGroup.location.id]
                        ?? tabGroup.location.tabName,
                    action: nil,
                    keyEquivalent: ""
                )
                let tasksMenu = NSMenu(title: tabItem.title)
                tasksMenu.autoenablesItems = false
                appendTaskNodes(
                    HerdrModel.taskHierarchy(tasks: tabGroup.tasks),
                    to: tasksMenu,
                    includeLocation: false
                )
                tabItem.submenu = tasksMenu
                tabsMenu.addItem(tabItem)
            }
            spaceItem.submenu = tabsMenu
            submenu.addItem(spaceItem)
        }

        if !locationGroups.isEmpty && !unplacedTasks.isEmpty {
            submenu.addItem(.separator())
        }
        appendTaskNodes(
            HerdrModel.taskHierarchy(tasks: unplacedTasks),
            to: submenu,
            includeLocation: false
        )
        return submenu
    }

    private func herdrHostItems() -> [NSMenuItem] {
        let items = groups.map { group in
            let item = NSMenuItem(
                title: hostTitle(for: group),
                action: nil,
                keyEquivalent: ""
            )
            item.submenu = taskMenu(for: group)
            return item
        }
        return items.isEmpty ? [disabledItem("No hosts")] : items
    }

    private func appendTaskNodes(
        _ nodes: [HerdrTaskNode],
        to menu: NSMenu,
        includeLocation: Bool
    ) {
        let column = shortcutColumn(
            for: nodes,
            includeLocation: includeLocation
        )
        for node in nodes {
            menu.addItem(
                taskItem(
                    for: node,
                    shortcutColumn: column,
                    includeLocation: includeLocation
                )
            )
        }
    }

    private func taskItem(
        for node: HerdrTaskNode,
        shortcutColumn: CGFloat,
        includeLocation: Bool
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
        let title = taskTitle(
            for: task,
            includeLocation: includeLocation
        )
        let item = NSMenuItem(
            title: title,
            action: nil,
            keyEquivalent: ""
        )
        if let index = shortcutIndex(for: task),
           let shortcut = registeredTaskShortcut(at: index) {
            item.attributedTitle = menuTitle(
                title,
                shortcut: "\(hotkeyPrefix.display)\(shortcut.character)",
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
                action: #selector(removeTask(_:)),
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
            appendTaskNodes(
                node.children,
                to: actions,
                includeLocation: includeLocation
            )
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
            NSTextTab(textAlignment: .left, location: column)
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
        value.addAttribute(
            .kern,
            value: -8,
            range: NSRange(location: value.length - 1, length: 1)
        )
        return value
    }

    private func shortcutColumn(
        for nodes: [HerdrTaskNode],
        includeLocation: Bool
    ) -> CGFloat {
        let font = NSFont.menuFont(ofSize: 0)
        let widest = nodes.map { node in
            (taskTitle(
                for: node.task,
                includeLocation: includeLocation
            ) as NSString)
                .size(withAttributes: [.font: font])
                .width
        }.max() ?? 0
        return ceil(widest) + 16
    }

    private func taskTitle(
        for task: HerdrTask,
        includeLocation: Bool
    ) -> String {
        let locationSuffix: String
        if includeLocation, let currentLocation = location(for: task) {
            locationSuffix =
                " · \(appLocationLabels[currentLocation.id] ?? currentLocation.label)"
        } else {
            locationSuffix = ""
        }
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

    private func rexRootMenu() -> NSMenu {
        let menu = NSMenu(title: "Rex")
        menu.autoenablesItems = false
        if !rexClient.isAvailable {
            menu.addItem(disabledItem("Rex CLI unavailable"))
            return menu
        }
        if rexHostGroups.isEmpty {
            menu.addItem(
                disabledItem(rexLoadError ?? "No Rex hosts")
            )
            return menu
        }
        for item in rexHostItems() {
            menu.addItem(item)
        }
        return menu
    }

    private func rexHostItems() -> [NSMenuItem] {
        rexHostGroups.map { group in
            let suffix = group.tasks.isEmpty ? "" : " (\(group.tasks.count))"
            let warning = group.connectionError == nil ? "" : " — Unavailable"
            let item = NSMenuItem(
                title: group.host.displayName + suffix + warning,
                action: nil,
                keyEquivalent: ""
            )
            item.submenu = rexHostMenu(group)
            return item
        }
    }

    private func rexHostMenu(_ group: RexHostGroup) -> NSMenu {
        let menu = NSMenu(title: group.host.displayName)
        menu.autoenablesItems = false
        if let error = group.connectionError {
            menu.addItem(disabledItem("Connection failed"))
            let detail = disabledItem(error)
            detail.toolTip = error
            menu.addItem(detail)
            return menu
        }
        if group.sessions.isEmpty {
            menu.addItem(disabledItem("No sessions"))
            return menu
        }
        for session in group.sessions {
            let sessionItem = NSMenuItem(
                title: session.displayName,
                action: nil,
                keyEquivalent: ""
            )
            let sessionsMenu = NSMenu(title: session.displayName)
            sessionsMenu.autoenablesItems = false
            if session.windows.isEmpty {
                sessionsMenu.addItem(disabledItem("No windows"))
            }
            for window in session.windows {
                let windowItem = NSMenuItem(
                    title: window.displayName,
                    action: nil,
                    keyEquivalent: ""
                )
                let tasksMenu = NSMenu(title: window.displayName)
                tasksMenu.autoenablesItems = false
                let column = rexShortcutColumn(for: window.blocks)
                if window.blocks.isEmpty {
                    tasksMenu.addItem(disabledItem("No terminal blocks"))
                }
                for task in window.blocks {
                    tasksMenu.addItem(
                        rexTaskItem(task, shortcutColumn: column)
                    )
                }
                windowItem.submenu = tasksMenu
                sessionsMenu.addItem(windowItem)
            }
            sessionItem.submenu = sessionsMenu
            menu.addItem(sessionItem)
        }
        return menu
    }

    private func rexTaskItem(
        _ task: RexTaskBlock,
        shortcutColumn: CGFloat
    ) -> NSMenuItem {
        let title = "\(task.displayName) — \(task.stateLabel)"
        let item = NSMenuItem(
            title: title,
            action: nil,
            keyEquivalent: ""
        )
        if let index = shortcutIndex(for: task),
           let shortcut = registeredTaskShortcut(at: index) {
            item.attributedTitle = menuTitle(
                title,
                shortcut: "\(hotkeyPrefix.display)\(shortcut.character)",
                column: shortcutColumn
            )
        }
        let payload = RexTaskPayload(task: task)
        item.representedObject = payload
        item.image = NSImage(
            systemSymbolName: task.status == "blocked"
                ? "exclamationmark.circle.fill"
                : "circle.fill",
            accessibilityDescription: task.stateLabel
        )
        let actions = NSMenu(title: task.displayName)
        actions.autoenablesItems = false
        let open = NSMenuItem(
            title: "Open in Rex",
            action: #selector(openRexTask(_:)),
            keyEquivalent: ""
        )
        open.target = self
        open.representedObject = payload
        actions.addItem(open)
        let rename = NSMenuItem(
            title: "Rename…",
            action: #selector(renameRexTask(_:)),
            keyEquivalent: ""
        )
        rename.target = self
        rename.representedObject = payload
        actions.addItem(rename)
        let close = NSMenuItem(
            title: "Close Block",
            action: #selector(confirmCloseRexTask(_:)),
            keyEquivalent: ""
        )
        close.target = self
        close.representedObject = payload
        actions.addItem(close)
        item.submenu = actions
        return item
    }

    private func rexShortcutColumn(for tasks: [RexTaskBlock]) -> CGFloat {
        let font = NSFont.menuFont(ofSize: 0)
        let widest = tasks.map { task in
            ("\(task.displayName) — \(task.stateLabel)" as NSString)
                .size(withAttributes: [.font: font])
                .width
        }.max() ?? 0
        return ceil(widest) + 16
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
            guard let self, let client = self.client else {
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
            guard let self, let client = self.client else {
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

    private func rexTask(from sender: NSMenuItem) -> RexTaskBlock? {
        (sender.representedObject as? RexTaskPayload)?.task
    }

    @objc private func openRexTask(_ sender: NSMenuItem) {
        guard let task = rexTask(from: sender) else {
            return
        }
        activateRexTask(task)
    }

    private func activateRexTask(_ task: RexTaskBlock) {
        Task { [weak self] in
            guard let self else {
                return
            }
            do {
                try await rexClient.focus(task)
            } catch {
                showError(error)
            }
        }
    }

    @objc private func renameRexTask(_ sender: NSMenuItem) {
        guard let task = rexTask(from: sender) else {
            return
        }
        let field = NSTextField(string: task.displayName)
        field.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
        let alert = NSAlert()
        alert.messageText = "Rename Rex Block"
        alert.informativeText = "Enter a new label for this block."
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else {
            return
        }
        let name = field.stringValue.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !name.isEmpty else {
            return
        }
        Task { [weak self] in
            guard let self else {
                return
            }
            do {
                try await rexClient.rename(task, to: name)
                await refresh()
            } catch {
                showError(error)
            }
        }
    }

    @objc private func confirmCloseRexTask(_ sender: NSMenuItem) {
        guard let task = rexTask(from: sender) else {
            return
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Close “\(task.displayName)”?"
        alert.informativeText = "This closes the Rex block and ends its program."
        alert.addButton(withTitle: "Close Block")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else {
            return
        }
        Task { [weak self] in
            guard let self else {
                return
            }
            do {
                try await rexClient.close(task)
                await refresh()
            } catch {
                showError(error)
            }
        }
    }

    @objc private func removeTask(_ sender: NSMenuItem) {
        guard let task = task(from: sender) else {
            return
        }

        Task { [weak self] in
            guard let self, let client = self.client else {
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
            guard !availableBackends.isEmpty else {
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
            tasks: orderedHerdrTasks,
            locations: locations,
            rexHostGroups: rexHostGroups,
            availableBackends: availableBackends,
            backendStore: backendStore,
            onCancel: { [weak self] in
                self?.activeDialog?.close()
            },
            onSubmit: { [weak self] submission in
                self?.activeDialog?.close()
                self?.createTask(submission)
            }
        )
        presentDialog(
            title: "Herdrker — New Task",
            size: NSSize(width: 520, height: 580),
            rootView: AnyView(rootView)
        )
    }

    @objc private func showAddHost() {
        guard !availableBackends.isEmpty else {
            return
        }
        let rootView = AddHostDialog(
            availableBackends: availableBackends,
            backendStore: backendStore,
            onCancel: { [weak self] in
                self?.activeDialog?.close()
            },
            onSubmit: { [weak self] submission in
                self?.activeDialog?.close()
                self?.addHost(submission)
            }
        )
        presentDialog(
            title: "Herdrker — Add Host",
            size: NSSize(width: 520, height: 520),
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

    private func createTask(_ submission: NewTaskSubmission) {
        Task { [weak self] in
            guard let self else {
                return
            }
            do {
                switch submission {
                case let .herdr(request):
                    guard let client = self.client else {
                        throw HerdrCoreError(
                            kind: "hc_missing",
                            message: "Herdr Core is not installed.",
                            hint: nil
                        )
                    }
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
                    let detailedTask = try await client.task(
                        address: createdTask.address
                    )
                    try await terminalLauncher.open(
                        task: detailedTask,
                        coreExecutableURL: client.executableURL
                    )
                case let .rex(request):
                    let createdTask = try await rexClient.createTask(request)
                    await refresh(includeLocations: true)
                    try await rexClient.focus(createdTask)
                }
            } catch {
                showError(error)
            }
        }
    }

    private func addHost(_ submission: NewHostSubmission) {
        Task { [weak self] in
            guard let self else {
                return
            }
            do {
                switch submission {
                case let .herdr(request):
                    guard let client = self.client else {
                        throw HerdrCoreError(
                            kind: "hc_missing",
                            message: "Herdr Core is not installed.",
                            hint: nil
                        )
                    }
                    try await client.addHost(request)
                case let .rex(request):
                    let check = try await rexClient.addHost(request)
                    if let check, !check.reachable {
                        let alert = NSAlert()
                        alert.alertStyle = .warning
                        alert.messageText = "Rex host added, but not reachable"
                        alert.informativeText =
                            check.detail
                            ?? "Install Rex Server on the remote machine, then run `rex hosts check \(check.label)`."
                        alert.runModal()
                    }
                }
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

    private var shortcutTasks: [TaskShortcutTarget] {
        let herdr = orderedHerdrTasks.map(TaskShortcutTarget.herdr)
        let rex = orderedRexTasks.map(TaskShortcutTarget.rex)
        return Array((herdr + rex).prefix(TaskShortcutKey.all.count))
    }

    private var orderedHerdrTasks: [HerdrTask] {
        groups.flatMap { group in
            let locations = appLocations.filter {
                $0.hostID == group.host.id
            }
            let placed = HerdrModel.taskLocationGroups(
                tasks: group.tasks,
                locations: locations
            ).flatMap { locationGroup in
                HerdrModel.flattened(
                    HerdrModel.taskHierarchy(tasks: locationGroup.tasks)
                )
            }
            let unplaced = HerdrModel.flattened(
                HerdrModel.taskHierarchy(
                    tasks: HerdrModel.unplacedTasks(
                        tasks: group.tasks,
                        locations: locations
                    )
                )
            )
            return placed + unplaced
        }
    }

    private var orderedRexTasks: [RexTaskBlock] {
        rexHostGroups.flatMap(\.tasks)
    }

    private func shortcutIndex(for task: HerdrTask) -> Int? {
        shortcutTasks.firstIndex {
            if case let .herdr(candidate) = $0 {
                return candidate.address == task.address
            }
            return false
        }
    }

    private func shortcutIndex(for task: RexTaskBlock) -> Int? {
        shortcutTasks.firstIndex {
            if case let .rex(candidate) = $0 {
                return candidate.id == task.id
            }
            return false
        }
    }

    private func registeredTaskShortcut(at index: Int) -> TaskShortcutKey? {
        guard registeredTaskShortcutKeys.indices.contains(index) else {
            return nil
        }
        return registeredTaskShortcutKeys[index]
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

        guard let taskIndex = taskShortcutIndexByHotKeyID[id],
              shortcutTasks.indices.contains(taskIndex) else {
            return
        }
        switch shortcutTasks[taskIndex] {
        case let .herdr(task):
            activateTask(task)
        case let .rex(task):
            activateRexTask(task)
        }
    }

    private func registerGlobalHotKeys() -> HotKeyRegistrationResult {
        registeredTaskShortcutKeys.removeAll()
        taskShortcutIndexByHotKeyID.removeAll()
        registeredActionHotKeyIDs.removeAll()
        let expected = TaskShortcutKey.all.count + 3
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
            return HotKeyRegistrationResult(
                registered: 0,
                expected: expected,
                failures: ["all shortcuts"]
            )
        }

        let modifiers = hotkeyPrefix.carbonModifiers
        var failures: [String] = []
        for (index, key) in TaskShortcutKey.all.enumerated() {
            let hotKeyID = EventHotKeyID(
                signature: herdrkerHotKeySignature,
                id: UInt32(index + 1)
            )
            var hotKeyRef: EventHotKeyRef?
            let status = RegisterEventHotKey(
                key.keyCode,
                modifiers,
                hotKeyID,
                GetApplicationEventTarget(),
                0,
                &hotKeyRef
            )
            if status == noErr, let hotKeyRef {
                hotKeyRefs.append(hotKeyRef)
                taskShortcutIndexByHotKeyID[hotKeyID.id] =
                    registeredTaskShortcutKeys.count
                registeredTaskShortcutKeys.append(key)
            } else {
                failures.append("\(hotkeyPrefix.display)\(key.character)")
            }
        }

        let appBindings: [(id: UInt32, keyCode: UInt32, name: String)] = [
            (101, UInt32(45), "n"),
            (102, UInt32(15), "r"),
            (103, UInt32(12), "q")
        ]
        for binding in appBindings {
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
                registeredActionHotKeyIDs.insert(binding.id)
            } else {
                failures.append("\(hotkeyPrefix.display)\(binding.name)")
            }
        }
        return HotKeyRegistrationResult(
            registered: hotKeyRefs.count,
            expected: expected,
            failures: failures
        )
    }

    private func unregisterGlobalHotKeys() {
        for hotKeyRef in hotKeyRefs {
            UnregisterEventHotKey(hotKeyRef)
        }
        hotKeyRefs.removeAll()
        registeredTaskShortcutKeys.removeAll()
        taskShortcutIndexByHotKeyID.removeAll()
        registeredActionHotKeyIDs.removeAll()
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
        let result = registerGlobalHotKeys()
        rebuildMenu()

        if !result.failures.isEmpty {
            let warning = NSAlert()
            warning.messageText = "Some hotkeys are unavailable"
            warning.informativeText =
                "These shortcuts were not assigned because another application or macOS is using them:\n\n"
                + result.failures.joined(separator: ", ")
            warning.runModal()
        }
    }
}
