import AppKit
import SwiftUI

@MainActor
struct NewTaskDialog: View {
    let hosts: [HerdrHost]
    let onCancel: () -> Void
    let onSubmit: (NewTaskRequest) -> Void

    @State private var selectedHostID: String
    @State private var taskName = ""
    @State private var command = ""
    @State private var workingDirectory = ""
    @State private var validationError: String?

    init(
        hosts: [HerdrHost],
        onCancel: @escaping () -> Void,
        onSubmit: @escaping (NewTaskRequest) -> Void
    ) {
        self.hosts = hosts
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

            Form {
                Picker("Host", selection: $selectedHostID) {
                    ForEach(hosts) { host in
                        Text(host.displayName).tag(host.id)
                    }
                }
                TextField("Task name (optional)", text: $taskName)
                TextField("Command (blank uses your default shell)", text: $command)
                TextField("Working directory (optional)", text: $workingDirectory)
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
                Button("Create Task", action: submit)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 460)
        .onExitCommand(perform: onCancel)
    }

    private func submit() {
        let trimmedCommand = command.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedName = taskName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDirectory = workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        onSubmit(
            NewTaskRequest(
                host: selectedHostID == HerdrModel.localHostID ? nil : selectedHostID,
                name: trimmedName.isEmpty ? nil : trimmedName,
                command: trimmedCommand.isEmpty ? nil : trimmedCommand,
                workingDirectory: trimmedDirectory.isEmpty ? nil : trimmedDirectory
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
        window.contentViewController = NSHostingController(rootView: rootView)
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
