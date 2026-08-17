import SwiftUI

@main
struct UTMSnapshotManagerApp: App {

    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .task { await model.bootstrap() }
        }
        .defaultSize(width: 1080, height: 720)
        .commands { AppCommands(model: model) }
    }
}

/// Every action in the app is reachable from the menu bar, and everything worth
/// repeating has a shortcut.
///
/// This matters more here than in most apps: the workflow it is built for is a
/// loop — roll back, run something, roll back again — and a loop driven by
/// hunting for buttons with the mouse is a slow loop.
struct AppCommands: Commands {

    @ObservedObject var model: AppModel

    private var vm: VirtualMachine? { model.selectedMachine }
    private var snapshot: Snapshot? { model.selectedSnapshot }
    private var isBusy: Bool { model.activity != nil }

    var body: some Commands {

        CommandGroup(replacing: .newItem) {
            // Enabled for a running machine too: the dialog then offers the
            // shutdown as the first step instead of refusing.
            Button("Take Snapshot…") { model.beginNewSnapshot() }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(vm?.canReachWritableState != true || isBusy)
        }

        CommandMenu("Machine") {
            Button("Start") {
                if let vm { Task { await model.start(vm) } }
            }
            .keyboardShortcut("s", modifiers: [.command, .shift])
            .disabled(vm?.canStart != true || isBusy)

            Button("Shut Down") {
                if let vm { Task { await model.stop(vm, method: .request) } }
            }
            .keyboardShortcut("p", modifiers: [.command, .shift])
            .disabled(vm?.canStop != true || isBusy)

            Button("Suspend") {
                if let vm { Task { await model.suspend(vm) } }
            }
            .keyboardShortcut("u", modifiers: [.command, .shift])
            .disabled(vm?.state != .running || isBusy)

            // Deliberately without a shortcut: this is the equivalent of
            // pulling the power cable and should take a moment of aiming.
            Button("Force Off…") {
                if let vm { Task { await model.stop(vm, method: .force) } }
            }
            .disabled(vm?.canStop != true || isBusy)

            Divider()

            Button("Verify Disks…") {
                if let vm { Task { await model.verifyDisks(on: vm.id) } }
            }
            .keyboardShortcut("k", modifiers: [.command, .shift])
            .disabled(vm == nil || isBusy)

            Divider()

            // Everything this app deliberately leaves alone — hardware, ports,
            // shared folders, display — is one keystroke away in UTM, on the
            // machine that is selected here.
            Button("Open in UTM") {
                if let vm { model.openInUTM(vm) } else { model.openUTM() }
            }
            .keyboardShortcut("u", modifiers: .command)
            .disabled(!UTMControl.isInstalled)

            Button("Rename…") {
                if let vm { model.sheet = .rename(machine: vm.id) }
            }
            .disabled(vm == nil || isBusy)

            Button("Add to UTM…") {
                if let vm { model.sheet = .addToUTM(machine: vm.id) }
            }
            .disabled(vm?.canBeAddedToUTM != true || isBusy)

            Button("Show in Finder") {
                if let vm { model.revealInFinder(vm) }
            }
            .keyboardShortcut("i", modifiers: [.command, .shift])
            .disabled(vm == nil)
        }

        CommandMenu("Restore Point") {
            Button("Restore…") {
                if let snapshot, let vm { model.sheet = .restore(snapshot, machine: vm.id, restartAfter: false) }
            }
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(snapshot == nil || vm == nil || isBusy)

            Button("Restore and Start…") {
                if let snapshot, let vm { model.sheet = .restore(snapshot, machine: vm.id, restartAfter: true) }
            }
            .keyboardShortcut(.return, modifiers: [.command, .option])
            .disabled(snapshot == nil || vm?.isRegisteredWithUTM != true || isBusy)

            Button("Reset to Baseline…") {
                if let baseline = model.baselineSnapshot, let vm {
                    model.sheet = .restore(baseline, machine: vm.id, restartAfter: true)
                }
            }
            .keyboardShortcut(.return, modifiers: [.command, .shift])
            .disabled(model.baselineSnapshot == nil || isBusy)

            Divider()

            Button(isSelectedBaseline ? "Remove as Baseline" : "Set as Baseline") {
                guard let vm, let snapshot else { return }
                model.setBaseline(isSelectedBaseline ? nil : snapshot, for: vm)
            }
            .keyboardShortcut("b", modifiers: .command)
            .disabled(snapshot == nil || vm == nil)

            Button("Add or Edit Note…") {
                if let snapshot, let vm { model.sheet = .note(snapshot, machine: vm.id) }
            }
            .keyboardShortcut("n", modifiers: [.command, .option])
            .disabled(snapshot == nil || vm == nil)

            Button("New Machine from This Point…") {
                if let snapshot, let vm { model.sheet = .newMachine(snapshot, machine: vm.id) }
            }
            .keyboardShortcut("d", modifiers: [.command, .shift])
            .disabled(snapshot == nil || isBusy)

            Divider()

            Button("Export as Machine…") {
                if let snapshot, let vm { Task { await model.exportMachine(snapshot, on: vm.id, asArchive: false) } }
            }
            .keyboardShortcut("e", modifiers: [.command, .shift])
            .disabled(snapshot == nil || isBusy)

            Button("Export as Compressed Archive…") {
                if let snapshot, let vm { Task { await model.exportMachine(snapshot, on: vm.id, asArchive: true) } }
            }
            .keyboardShortcut("e", modifiers: [.command, .shift, .option])
            .disabled(snapshot == nil || isBusy)

            Button("Export Disk Image Only…") {
                if let snapshot, let vm { Task { await model.exportSnapshot(snapshot, on: vm.id) } }
            }
            .disabled(snapshot == nil || isBusy)

            Divider()

            Button("Clean Up…") {
                if let vm { model.sheet = .cleanUp(machine: vm.id) }
            }
            .keyboardShortcut("k", modifiers: [.command, .option])
            .disabled(vm?.snapshots.isEmpty != false || isBusy)

            Button("Delete…") {
                if let snapshot, let vm { model.sheet = .delete(snapshot, machine: vm.id) }
            }
            .keyboardShortcut(.delete, modifiers: .command)
            .disabled(snapshot == nil || vm?.canModifyDisks != true || isBusy)
        }

        CommandGroup(after: .sidebar) {
            Divider()
            Button("Rescan for Machines") {
                Task { await model.refresh() }
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(model.isScanning || isBusy)
        }

        CommandGroup(replacing: .help) {
            Button("Quick Introduction") { model.sheet = .welcome }
            Divider()
            Button("Project Page on GitHub") {
                if let url = URL(string: "https://github.com/nurkert/UTM-Snapshot-Manager") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }

    private var isSelectedBaseline: Bool {
        guard let vm, let snapshot else { return false }
        return model.isBaseline(snapshot, in: vm)
    }
}
