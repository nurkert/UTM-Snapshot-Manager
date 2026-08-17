import SwiftUI

struct MachineDetailView: View {
    @EnvironmentObject private var model: AppModel
    let vm: VirtualMachine

    var body: some View {
        // The header keeps its natural height and `content` takes whatever is
        // left. The stack itself must NOT be given an infinite height: with a
        // height-filling child inside it, the stack grew past the column, the
        // header was pushed above the visible top edge, and the oversized
        // layout dragged the sidebar's own geometry with it — the window then
        // read as completely empty even though every body had run with correct
        // data.
        VStack(spacing: 0) {
            header
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle(vm.name)
        .navigationSubtitle(vm.locationDescription)
        .toolbar { toolbar }
    }

    // MARK: - Toolbar

    /// Three fixed slots, always in the same place.
    ///
    /// An earlier version added and removed toolbar items as the machine's
    /// state changed, so the buttons shifted sideways under the pointer the
    /// moment a machine started. Controls that cannot be used are disabled and
    /// say why in their tooltip instead.
    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        // Everything in one region on purpose. With the view switcher in
        // `.automatic` and the actions in `.primaryAction`, collapsing the
        // sidebar made AppKit re-home the items between regions and a button
        // flashed in and out at the top right on every toggle.
        ToolbarItemGroup(placement: .primaryAction) {
            Picker("View", selection: $model.detailMode) {
                ForEach(AppModel.DetailMode.allCases) { mode in
                    Label(mode.label, systemImage: mode.symbol).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(vm.snapshots.isEmpty)
            .help("Switch between a plain list and the branching view")

            powerButton

            Button {
                model.beginNewSnapshot()
            } label: {
                Label("Take Snapshot", systemImage: "camera.aperture")
            }
            .disabled(!vm.canReachWritableState)
            .help(snapshotHelp)
        }
    }

    /// One slot, two labels. Start and Shut Down are never both usable, so
    /// giving them a button each only guarantees that one of them is always
    /// greyed out.
    private var powerButton: some View {
        let isUp = vm.state == .running || vm.state == .paused
        return Button {
            Task {
                if isUp {
                    await model.stop(vm, method: .request)
                } else {
                    await model.start(vm)
                }
            }
        } label: {
            Label(isUp ? "Shut Down" : "Start", systemImage: isUp ? "stop.fill" : "play.fill")
        }
        .disabled(isUp ? !vm.canStop : !vm.canStart)
        .help(powerHelp(isUp: isUp))
    }

    private func powerHelp(isUp: Bool) -> String {
        guard vm.isRegisteredWithUTM else {
            return String(localized: "UTM does not manage this machine, so it cannot be started from here.")
        }
        if isUp { return String(localized: "Ask the guest to shut down (⇧⌘P)") }
        if vm.state == .unknown {
            return String(localized: "UTM could not be asked what this machine is doing.")
        }
        return String(localized: "Start this machine in UTM (⇧⌘S)")
    }

    private var snapshotHelp: String {
        if vm.canBecomeWritableByShuttingDown {
            return String(localized: "Shut the machine down and save that state (⌘N)")
        }
        if vm.canModifyDisks {
            return String(localized: "Save the current state (⌘N)")
        }
        guard let blocker = vm.blocker else { return String(localized: "Save the current state (⌘N)") }
        switch blocker {
        case .appleBackend:
            return String(localized: "Apple Virtualization disks have no snapshots.")
        case .noSupportedDisk:
            return String(localized: "This machine has no writable qcow2 disk.")
        case .unreadableDisk:
            return String(localized: "One disk could not be read, so nothing is written.")
        case .noAccess:
            return String(localized: "macOS is blocking access to this machine's folder.")
        case .notStopped(let state):
            return state == .suspended
                ? String(localized: "Start the machine and shut it down from inside the guest first.")
                : String(localized: "The state of this machine is unknown, so nothing is written.")
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: vm.symbolName)
                    .font(.system(size: 32, weight: .light))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.tint)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(vm.name).font(.title2.weight(.semibold))
                        StateChip(state: vm.state)
                    }
                    Text(metaLine)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 12)

                if let baseline = model.baselineSnapshot {
                    Button {
                        model.sheet = .restore(baseline, machine: vm.id, restartAfter: true)
                    } label: {
                        Label("Reset to Baseline", systemImage: "arrow.counterclockwise")
                            .padding(.horizontal, 4)
                    }
                    .primaryActionStyle()
                    .controlSize(.large)
                    .disabled(!vm.canReachWritableState)
                    .help("Shut down, roll back to “\(baseline.name)”, and start again (⇧⌘↩)")
                }
            }

            if let blocker = vm.blocker {
                BlockerBanner(blocker: blocker, vm: vm)
            }
        }
        .padding(20)
    }

    private var metaLine: String {
        var parts: [String] = [
            String(localized: "\(vm.usedDescription) used of \(vm.virtualDescription)")
        ]
        if vm.disks.count > 1 {
            parts.append(String(localized: "\(vm.disks.count) disks"))
        }
        if !vm.isRegisteredWithUTM {
            parts.append(String(localized: "not in UTM's library"))
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if vm.snapshots.isEmpty {
            emptyState
        } else {
            switch model.detailMode {
            case .list: SnapshotListView(vm: vm)
            case .tree: SnapshotTreeView(vm: vm)
            }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Restore Points Yet", systemImage: "camera.aperture")
        } description: {
            Text("A restore point freezes the disk exactly as it is now. Take one before you install something risky, run an unknown binary, or hand the machine to someone else — getting back is then a single step.")
        } actions: {
            if vm.canReachWritableState {
                Button(vm.canBecomeWritableByShuttingDown ? "Shut Down & Take Snapshot" : "Take Snapshot") {
                    model.beginNewSnapshot()
                }
                .primaryActionStyle()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Blocker

/// Explains in plain language why changes are unavailable, instead of leaving
/// the user with a greyed-out control and no reason — and, where possible,
/// offers the button that resolves it.
struct BlockerBanner: View {
    @EnvironmentObject private var model: AppModel
    let blocker: VirtualMachine.Blocker
    let vm: VirtualMachine

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(tint)

            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.semibold))
                    // No .fixedSize here. Inside an HStack that also holds a
                    // Spacer, `fixedSize(vertical: true)` makes the text ask for
                    // its unwrapped width, the bar demands that width, and the
                    // whole split view is laid out far wider than the window —
                    // at which point nothing is visible at all. Text wraps on
                    // its own; the modifier is only needed where a parent
                    // actively compresses it.
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            action
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .noticeSurface(tint)
    }

    @ViewBuilder
    private var action: some View {
        switch blocker {
        case .notStopped(let state) where state == .running || state == .paused:
            if vm.canStop {
                Button("Shut Down") { Task { await model.stop(vm, method: .request) } }
                    .secondaryActionStyle()
                    .controlSize(.small)
            }
        case .notStopped(let state) where state == .suspended:
            if vm.canStart {
                Button("Start") { Task { await model.start(vm) } }
                    .secondaryActionStyle()
                    .controlSize(.small)
            }
        case .notStopped:
            Button("How to fix") { model.sheet = .automationHelp }
                .secondaryActionStyle()
                .controlSize(.small)
        case .noAccess:
            Button("Open Settings…") { model.openPrivacySettings() }
                .secondaryActionStyle()
                .controlSize(.small)
        default:
            EmptyView()
        }
    }

    private var tint: Color {
        switch blocker {
        case .notStopped(let state): return state.tint
        case .unreadableDisk, .noAccess: return .orange
        default: return .secondary
        }
    }

    private var symbol: String {
        switch blocker {
        case .notStopped(let state): return state.symbolName
        case .appleBackend: return "apple.logo"
        case .noSupportedDisk: return "externaldrive.badge.questionmark"
        case .unreadableDisk: return "exclamationmark.triangle.fill"
        case .noAccess: return "lock.fill"
        }
    }

    private var title: String {
        switch blocker {
        case .notStopped(let state):
            switch state {
            case .running: return String(localized: "“\(vm.name)” is running right now")
            case .paused: return String(localized: "“\(vm.name)” is paused")
            case .suspended: return String(localized: "“\(vm.name)” is suspended")
            default: return String(localized: "The state of “\(vm.name)” is unknown")
            }
        case .appleBackend: return String(localized: "Restore points aren't possible here")
        case .noSupportedDisk: return String(localized: "No supported disk")
        case .unreadableDisk: return String(localized: "One disk could not be read")
        case .noAccess: return String(localized: "No access to this folder")
        }
    }

    private var message: String {
        switch blocker {
        case .notStopped(let state):
            switch state {
            case .running:
                return vm.canStop
                    ? String(localized: "Nothing is written while the machine is using its disk — unwritten caches would never reach it. Taking a restore point or rolling one back starts by shutting the machine down, and asks you first.")
                    : String(localized: "Changes are disabled while the machine is using its disk. Writing now risks a corrupted file system, because unwritten caches never reach the disk.")
            case .paused:
                return vm.canStop
                    ? String(localized: "A paused machine still holds its disk open. Any change here begins by shutting it down, and asks you first.")
                    : String(localized: "A paused machine still holds its disk open. Resume it and shut it down properly.")
            case .suspended:
                return String(localized: "UTM parked the memory state on the disk. Start the machine and shut it down from inside the guest, then you're good to go.")
            default:
                return String(localized: "UTM could not be asked whether this machine is running. Nothing will be written while that is unclear.")
            }
        case .appleBackend:
            return String(localized: "This machine uses Apple Virtualization instead of QEMU. Its disk format has no notion of snapshots.")
        case .noSupportedDisk:
            return String(localized: "No drive in this machine's configuration is a writable qcow2 disk.")
        case .unreadableDisk:
            return String(localized: "qemu-img could not open one of the disks, so the list of restore points may be incomplete. Changes stay disabled rather than acting on half a picture.")
        case .noAccess:
            return String(localized: "Grant access under System Settings › Privacy & Security › Files and Folders.")
        }
    }
}
