import SwiftUI

/// Confirms moving a whole machine to the Trash.
///
/// This is the only action in the app that removes a machine rather than a
/// restore point, so it spells out the full extent: the folder, every disk, and
/// every point saved inside them. The Trash is the safety net — nothing is
/// actually gone until it is emptied — and the dialog says so, because a
/// confirmation that overstates the danger gets clicked through just as fast as
/// one that understates it.
struct TrashMachineSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    let machineID: VirtualMachine.ID

    private var vm: VirtualMachine? { model.machines.first { $0.id == machineID } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "trash")
                    .font(.system(size: 28, weight: .light))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.red)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Move “\(vm?.name ?? "")” to the Trash?")
                        .font(.title3.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(summary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.bottom, 16)

            if let vm {
                StepList {
                    Step(number: 1, text: String(localized: "The folder \(vm.locationDescription)/\(vm.url.lastPathComponent) goes to the Trash."))
                    Step(number: 2, text: pointsLine(vm))
                    Step(number: 3, text: String(localized: "Nothing is deleted until you empty the Trash."))
                }
            }

            // UTM keeps its own library entry, and this app cannot edit it.
            // Leaving that unsaid produces a machine in UTM that opens to an
            // error, with no clue why.
            if vm?.isRegisteredWithUTM == true {
                Label("UTM will still list this machine and its entry will point at nothing. Remove it in UTM as well.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .padding(.top, 12)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider().padding(.vertical, 16)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                // Not the default action: Return should not throw a machine away.
                Button("Move to Trash") {
                    dismiss()
                    Task { await model.moveToTrash(machineID) }
                }
                .primaryActionStyle()
                .tint(.red)
            }
        }
        .padding(22)
        .frame(width: 500)
    }

    private var summary: String {
        guard let vm else { return "" }
        return String(localized: "This removes the machine itself, not just a restore point. It is refused while anything is still using its disks.")
            + " " + String(localized: "\(vm.usedDescription) will be freed once the Trash is emptied.")
    }

    private func pointsLine(_ vm: VirtualMachine) -> String {
        switch vm.snapshots.count {
        case 0: return String(localized: "It has no restore points.")
        case 1: return String(localized: "Its one restore point goes with it — they live inside the disks.")
        default: return String(localized: "All \(vm.snapshots.count) restore points go with it — they live inside the disks.")
        }
    }
}
