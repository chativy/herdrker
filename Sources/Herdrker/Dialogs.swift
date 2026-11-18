import AppKit
import SwiftUI

@MainActor
struct NewTaskDialog: View {
    let hosts: [HerdrHost]
    let tasks: [HerdrTask]
    let locations: [HerdrLocationChoice]
    let rexHostGroups: [RexHostGroup]
    let availableBackends: [TaskBackendKind]
    let backendStore: BackendSelectionStore
    let onCancel: () -> Void
    let onSubmit: (NewTaskSubmission) -> Void

    @State private var backend: TaskBackendKind
    @State private var selectedHostID: String
    @State private var selectedRexHostID: String
    @State private var selectedRexSessionID = ""
    @State private var selectedParentAddress = ""
    @State private var taskName = ""
    @State private var selectedLocationID = ""
    @State private var command = ""
    @State private var workingDirectory = ""
    @State private var validationError: String?
    @FocusState private var taskNameFocused: Bool

    init(
        hosts: [HerdrHost],
        tasks: [HerdrTask],
        locations: [HerdrLocationChoice],
        rexHostGroups: [RexHostGroup],
        availableBackends: [TaskBackendKind],
        backendStore: BackendSelectionStore = BackendSelectionStore(),
        onCancel: @escaping () -> Void,
        onSubmit: @escaping (NewTaskSubmission) -> Void
    ) {
        self.hosts = hosts
        self.tasks = tasks
        self.locations = locations
        self.rexHostGroups = rexHostGroups
        self.availableBackends = availableBackends
        self.backendStore = backendStore
        self.onCancel = onCancel
        self.onSubmit = onSubmit
        _backend = State(
            initialValue: backendStore.load(available: availableBackends)
        )
        _selectedHostID = State(
            initialValue: hosts.first?.id ?? HerdrModel.localHostID
        )
        _selectedRexHostID = State(
            initialValue: rexHostGroups.first?.host.id ?? ""
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Create Task")
                .font(.title2.weight(.semibold))
            Text("Start a persistent task in Herdr Core or Rex.")
                .foregroundStyle(.secondary)

            Picker("Backend", selection: $backend) {
                ForEach(availableBackends) { backend in
                    Text(backend.displayName).tag(backend)
                }
            }
            .pickerStyle(.segmented)

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 12) {
                if backend == .herdr {
                    herdrRows
                } else {
                    rexRows
                }
                GridRow {
                    Text(backend == .herdr ? "Task name" : "Label")
                        .frame(width: 120, alignment: .trailing)
                    TextField("Optional", text: $taskName)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 300)
                        .focused($taskNameFocused)
                }
                GridRow {
                    Text("Working directory")
                        .frame(width: 120, alignment: .trailing)
                    TextField("Optional", text: $workingDirectory)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 300)
                }
                GridRow {
                    Text("Command")
                        .frame(width: 120, alignment: .trailing)
                    TextField("Optional", text: $command)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 300)
                }
            }

            Text(helpText)
                .font(.caption)
                .foregroundStyle(.secondary)

            if let validationError {
                Text(validationError)
                    .foregroundStyle(.red)
                    .font(.callout)
            }

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Create Task", action: submit)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 460)
        .onAppear {
            taskNameFocused = true
        }
        .onChange(of: selectedHostID) { _, _ in
            if !parentCandidates.contains(where: {
                $0.address == selectedParentAddress
            }) {
                selectedParentAddress = ""
            }
            if !locationCandidates.contains(where: {
                $0.id == selectedLocationID
            }) {
                selectedLocationID = ""
            }
        }
        .onChange(of: selectedRexHostID) { _, _ in
            if !rexSessions.contains(where: {
                $0.id == selectedRexSessionID
            }) {
                selectedRexSessionID = ""
            }
        }
        .onChange(of: backend) { _, newValue in
            backendStore.save(newValue)
        }
        .onExitCommand(perform: onCancel)
    }

    @ViewBuilder
    private var herdrRows: some View {
        GridRow {
            Text("Host")
                .frame(width: 120, alignment: .trailing)
            Picker("Host", selection: $selectedHostID) {
                ForEach(hosts) { host in
                    Text(host.displayName).tag(host.id)
                }
            }
            .labelsHidden()
            .frame(width: 300)
        }
        GridRow {
            Text("Parent")
                .frame(width: 120, alignment: .trailing)
            Picker("Parent", selection: $selectedParentAddress) {
                Text("None (independent task)").tag("")
                ForEach(parentCandidates) { task in
                    Text("\(task.displayName) (\(task.address))")
                        .tag(task.address)
                }
            }
            .labelsHidden()
            .frame(width: 300)
        }
        GridRow {
            Text("Space / tab")
                .frame(width: 120, alignment: .trailing)
            Picker("Space / tab", selection: $selectedLocationID) {
                Text("None").tag("")
                ForEach(locationCandidates) { location in
                    Text(locationLabels[location.id] ?? location.label)
                        .tag(location.id)
                }
            }
            .labelsHidden()
            .frame(width: 300)
        }
    }

    @ViewBuilder
    private var rexRows: some View {
        GridRow {
            Text("Host")
                .frame(width: 120, alignment: .trailing)
            Picker("Host", selection: $selectedRexHostID) {
                ForEach(rexHostGroups) { group in
                    Text(group.host.displayName).tag(group.host.id)
                }
            }
            .labelsHidden()
            .frame(width: 300)
        }
        GridRow {
            Text("Session")
                .frame(width: 120, alignment: .trailing)
            Picker("Session", selection: $selectedRexSessionID) {
                Text("New session").tag("")
                ForEach(rexSessions) { session in
                    Text(session.displayName).tag(session.id)
                }
            }
            .labelsHidden()
            .frame(width: 300)
        }
    }

    private var helpText: String {
        if backend == .herdr {
            return "Leave Command blank to start the login shell. A blank local Working directory starts in your home folder."
        }
        return "Leave Command blank to start Rex's default shell. Select New session to create a separate Rex session."
    }

    private var parentCandidates: [HerdrTask] {
        tasks.filter {
            !$0.isFinished
                && ($0.machine ?? HerdrModel.localHostID) == selectedHostID
        }
    }

    private var locationCandidates: [HerdrLocationChoice] {
        locations.filter { $0.hostID == selectedHostID }
    }

    private var locationLabels: [String: String] {
        HerdrModel.locationLabels(for: locationCandidates)
    }

    private var selectedRexGroup: RexHostGroup? {
        rexHostGroups.first { $0.host.id == selectedRexHostID }
    }

    private var rexSessions: [RexSessionInfo] {
        selectedRexGroup?.sessions ?? []
    }

    private func submit() {
        validationError = nil
        let trimmedCommand = command.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let trimmedName = taskName.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let trimmedDirectory = workingDirectory.trimmingCharacters(
            in: .whitespacesAndNewlines
        )

        if backend == .herdr {
            submitHerdr(
                name: trimmedName,
                command: trimmedCommand,
                directory: trimmedDirectory
            )
        } else {
            submitRex(
                name: trimmedName,
                command: trimmedCommand,
                directory: trimmedDirectory
            )
        }
    }

    private func submitHerdr(
        name: String,
        command: String,
        directory: String
    ) {
        let resolvedDirectory = directory.isEmpty
            ? HerdrModel.defaultWorkingDirectory(hostID: selectedHostID)
            : directory
        let selectedLocation = locationCandidates.first {
            $0.id == selectedLocationID
        }
        onSubmit(
            .herdr(
                NewTaskRequest(
                    host: selectedHostID == HerdrModel.localHostID
                        ? nil
                        : selectedHostID,
                    name: name.isEmpty ? nil : name,
                    command: command.isEmpty ? nil : command,
                    workingDirectory: resolvedDirectory,
                    parent: selectedParentAddress.isEmpty
                        ? nil
                        : selectedParentAddress,
                    herdrSpaceID: selectedLocation?.coreSpaceID,
                    herdrTabID: selectedLocation?.coreTabID,
                    whereLabel: selectedLocation?.label
                )
            )
        )
    }

    private func submitRex(
        name: String,
        command: String,
        directory: String
    ) {
        guard let group = selectedRexGroup else {
            validationError = "Select a Rex host."
            return
        }
        onSubmit(
            .rex(
                NewRexTaskRequest(
                    host: group.host,
                    session: group.sessions.first {
                        $0.id == selectedRexSessionID
                    },
                    name: name.isEmpty ? nil : name,
                    command: command.isEmpty ? nil : command,
                    workingDirectory: directory.isEmpty ? nil : directory
                )
            )
        )
    }
}

private enum RexEndpointKind: String, CaseIterable, Identifiable {
    case ssh
    case https
    case unix

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .ssh: return "SSH"
        case .https: return "HTTPS / Tailscale"
        case .unix: return "Unix socket"
        }
    }
}

@MainActor
struct AddHostDialog: View {
    let availableBackends: [TaskBackendKind]
    let backendStore: BackendSelectionStore
    let onCancel: () -> Void
    let onSubmit: (NewHostSubmission) -> Void

    @State private var backend: TaskBackendKind
    @State private var hostName = ""
    @State private var sshTarget = ""
    @State private var installCore = true
    @State private var rexLabel = ""
    @State private var rexEndpointKind: RexEndpointKind = .ssh
    @State private var rexEndpoint = ""
    @State private var rexIcon = ""
    @State private var checkRexHost = true
    @State private var validationError: String?

    init(
        availableBackends: [TaskBackendKind],
        backendStore: BackendSelectionStore = BackendSelectionStore(),
        onCancel: @escaping () -> Void,
        onSubmit: @escaping (NewHostSubmission) -> Void
    ) {
        self.availableBackends = availableBackends
        self.backendStore = backendStore
        self.onCancel = onCancel
        self.onSubmit = onSubmit
        _backend = State(
            initialValue: backendStore.load(available: availableBackends)
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add Host")
                .font(.title2.weight(.semibold))
            Text("Register another machine with Herdr Core or Rex.")
                .foregroundStyle(.secondary)

            Picker("Backend", selection: $backend) {
                ForEach(availableBackends) { backend in
                    Text(backend.displayName).tag(backend)
                }
            }
            .pickerStyle(.segmented)

            Form {
                if backend == .herdr {
                    TextField("Display name (optional)", text: $hostName)
                    TextField("SSH target", text: $sshTarget)
                    Toggle("Install herdr-core if missing", isOn: $installCore)
                } else {
                    TextField("Host label", text: $rexLabel)
                    Picker("Transport", selection: $rexEndpointKind) {
                        ForEach(RexEndpointKind.allCases) { kind in
                            Text(kind.displayName).tag(kind)
                        }
                    }
                    TextField(endpointPlaceholder, text: $rexEndpoint)
                    TextField("Icon name (optional)", text: $rexIcon)
                    Toggle(
                        "Check reachability after adding",
                        isOn: $checkRexHost
                    )
                    if rexEndpointKind == .ssh {
                        Text(
                            "Rex Server must already be installed on the remote machine."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)

            if let validationError {
                Text(validationError)
                    .foregroundStyle(.red)
                    .font(.callout)
            }

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Add Host", action: submit)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 460)
        .onChange(of: backend) { _, newValue in
            backendStore.save(newValue)
        }
        .onExitCommand(perform: onCancel)
    }

    private var endpointPlaceholder: String {
        switch rexEndpointKind {
        case .ssh:
            return "user@host or ssh://user@host"
        case .https:
            return "https://host.tailnet.ts.net"
        case .unix:
            return "/path/to/rex.sock or unix:///path"
        }
    }

    private func submit() {
        validationError = nil
        if backend == .herdr {
            submitHerdr()
        } else {
            submitRex()
        }
    }

    private func submitHerdr() {
        let trimmedTarget = sshTarget.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !trimmedTarget.isEmpty else {
            validationError = "SSH target is required."
            return
        }
        let trimmedName = hostName.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        onSubmit(
            .herdr(
                NewHostRequest(
                    name: trimmedName.isEmpty ? nil : trimmedName,
                    target: trimmedTarget,
                    installCore: installCore
                )
            )
        )
    }

    private func submitRex() {
        let label = rexLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawEndpoint = rexEndpoint.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !label.isEmpty else {
            validationError = "Host label is required."
            return
        }
        guard !rawEndpoint.isEmpty else {
            validationError = "Host endpoint is required."
            return
        }
        let endpoint: String
        switch rexEndpointKind {
        case .ssh:
            endpoint = rawEndpoint.contains("://")
                ? rawEndpoint
                : "ssh://\(rawEndpoint)"
        case .https:
            endpoint = rawEndpoint
        case .unix:
            endpoint = rawEndpoint.hasPrefix("unix://")
                ? rawEndpoint
                : "unix://\(rawEndpoint)"
        }
        let icon = rexIcon.trimmingCharacters(in: .whitespacesAndNewlines)
        onSubmit(
            .rex(
                NewRexHostRequest(
                    label: label,
                    endpoints: [endpoint],
                    icon: icon.isEmpty ? nil : icon,
                    checkAfterAdding: checkRexHost
                )
            )
        )
    }
}

@MainActor
final class DialogWindowController: NSWindowController, NSWindowDelegate {
    var onClose: (() -> Void)?

    init(title: String, size: NSSize, rootView: AnyView) {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        let hostingController = NSHostingController(rootView: rootView)
        let fittingSize = hostingController.view.fittingSize
        window.contentViewController = hostingController
        window.setContentSize(
            NSSize(
                width: max(size.width, fittingSize.width),
                height: max(size.height, fittingSize.height)
            )
        )
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func present() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }
}
