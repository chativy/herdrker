import AppKit
import SwiftUI

@MainActor
struct NewTaskDialog: View {
    let hosts: [HerdrHost]
    let tasks: [HerdrTask]
    let locations: [HerdrLocationChoice]
    let onCancel: () -> Void
    let onSubmit: (NewTaskRequest) -> Void

    @State private var selectedHostID: String
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
        onCancel: @escaping () -> Void,
        onSubmit: @escaping (NewTaskRequest) -> Void
    ) {
        self.hosts = hosts
        self.tasks = tasks
        self.locations = locations
        self.onCancel = onCancel
        self.onSubmit = onSubmit
        _selectedHostID = State(initialValue: hosts.first?.id ?? HerdrModel.localHostID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Create Task")
                .font(.title2.weight(.semibold))
            Text("Start a persistent shell command through Herdr Core.")
                .foregroundStyle(.secondary)

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 12) {
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
                    Text("Task name")
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
                            Text(location.label).tag(location.id)
                        }
                    }
                    .labelsHidden()
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

            Text("Leave Command blank to start the host's login shell. A blank local Working directory starts in your home folder.")
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
            if !parentCandidates.contains(where: { $0.address == selectedParentAddress }) {
                selectedParentAddress = ""
            }
            if !locationCandidates.contains(where: { $0.id == selectedLocationID }) {
                selectedLocationID = ""
            }
        }
        .onExitCommand(perform: onCancel)
    }

    private var parentCandidates: [HerdrTask] {
        tasks.filter {
            !$0.isFinished && ($0.machine ?? HerdrModel.localHostID) == selectedHostID
        }
    }

    private var locationCandidates: [HerdrLocationChoice] {
        locations.filter { $0.hostID == selectedHostID }
    }

    private func submit() {
        let trimmedCommand = command.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedName = taskName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDirectory = workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedDirectory: String?
        if !trimmedDirectory.isEmpty {
            resolvedDirectory = trimmedDirectory
        } else {
            resolvedDirectory = HerdrModel.defaultWorkingDirectory(
                hostID: selectedHostID
            )
        }
        onSubmit(
            NewTaskRequest(
                host: selectedHostID == HerdrModel.localHostID ? nil : selectedHostID,
                name: trimmedName.isEmpty ? nil : trimmedName,
                command: trimmedCommand.isEmpty ? nil : trimmedCommand,
                workingDirectory: resolvedDirectory,
                parent: selectedParentAddress.isEmpty ? nil : selectedParentAddress,
                whereLabel: locationCandidates
                    .first(where: { $0.id == selectedLocationID })?
                    .label
            )
        )
    }
}

@MainActor
struct AddHostDialog: View {
    let onCancel: () -> Void
    let onSubmit: (NewHostRequest) -> Void

    @State private var hostName = ""
    @State private var sshTarget = ""
    @State private var installCore = true
    @State private var validationError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add Host")
                .font(.title2.weight(.semibold))
            Text("Connect another machine through your existing SSH configuration.")
                .foregroundStyle(.secondary)

            Form {
                TextField("Display name (optional)", text: $hostName)
                TextField("SSH target", text: $sshTarget)
                Toggle("Install herdr-core if missing", isOn: $installCore)
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
        .onExitCommand(perform: onCancel)
    }

    private func submit() {
        let trimmedTarget = sshTarget.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTarget.isEmpty else {
            validationError = "SSH target is required."
            return
        }

        let trimmedName = hostName.trimmingCharacters(in: .whitespacesAndNewlines)
        onSubmit(
            NewHostRequest(
                name: trimmedName.isEmpty ? nil : trimmedName,
                target: trimmedTarget,
                installCore: installCore
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
