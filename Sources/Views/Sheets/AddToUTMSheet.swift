import SwiftUI

/// Offers to put a machine into UTM's library.
///
/// Restore points never needed UTM — this app reads the bundle and drives
/// `qemu-img` itself. Starting and stopping do need it: those go through UTM's
/// scripting interface and are addressed by the identifier UTM has on file. So
/// a `.utm` sitting in Downloads is fully usable here and still cannot be
/// started, which reads as an arbitrary restriction until somebody says why.
///
/// This dialog says why, and offers the one step that removes it.
struct AddToUTMSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    let machineID: VirtualMachine.ID

    private var vm: VirtualMachine? { model.machines.first { $0.id == machineID } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "plus.rectangle.on.folder")
                    .font(.system(size: 28, weight: .light))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.tint)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Add “\(vm?.name ?? "")” to UTM?")
                        .font(.title3.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Restore points work without UTM. Starting and shutting down do not — those go through UTM, and it only accepts machines that are in its library.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.bottom, 16)

            StepList {
                Step(number: 1, text: String(localized: "UTM opens with this machine. Confirm there if it asks."))
                Step(number: 2, text: String(localized: "This window waits until the machine shows up in UTM's library."))
                Step(number: 3, text: String(localized: "Start and Shut Down become available here."))
            }

            Label("The folder stays where it is. Depending on UTM's settings it may reference the machine in place or take its own copy — either way nothing here is moved or deleted.", systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 10)
                .fixedSize(horizontal: false, vertical: true)

            Divider().padding(.vertical, 16)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add to UTM") {
                    dismiss()
                    Task { await model.addToUTM(machineID) }
                }
                .keyboardShortcut(.defaultAction)
                .primaryActionStyle()
            }
        }
        .padding(22)
        .frame(width: 500)
    }
}
