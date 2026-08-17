import SwiftUI

struct NewSnapshotSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    /// The machine this dialog names, fixed at the moment it opened.
    let machineID: VirtualMachine.ID

    @State private var name = ""
    @State private var makeBaseline = false
    @State private var note = ""
    @FocusState private var isFieldFocused: Bool

    private var vm: VirtualMachine? { model.machines.first { $0.id == machineID } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "camera.aperture")
                    .font(.system(size: 30, weight: .light))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Take Snapshot")
                        .font(.title3.weight(.semibold))
                    Text(needsShutdown
                         ? String(localized: "“\(vm?.name ?? "")” is still running, so it is shut down first and the state it stops in is saved. \(diskPhrase) You can come back to this point at any time.")
                         : String(localized: "Freezes “\(vm?.name ?? "")” exactly as it is now. \(diskPhrase) You can come back to this point at any time."))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.bottom, 18)

            Text("Name")
                .font(.callout.weight(.medium))
                .padding(.bottom, 4)

            TextField("e.g. Clean install, before sample run", text: $name)
                .textFieldStyle(.roundedBorder)
                .controlSize(.large)
                .focused($isFieldFocused)
                .onSubmit { submit() }

            Text(validation ?? String(localized: "A name you will still recognise in three weeks beats a timestamp."))
                .font(.caption)
                .foregroundStyle(validation == nil ? Color.secondary : Color.red)
                .padding(.top, 6)
                .frame(minHeight: 26, alignment: .topLeading)
                .fixedSize(horizontal: false, vertical: true)

            // A running machine is not a dead end: the shutdown becomes the
            // first step of this operation. Spelled out before committing,
            // because a Save button that silently powers a machine off would
            // be a nasty surprise.
            if needsShutdown {
                StepList {
                    Step(number: 1, text: String(localized: "Shut “\(vm?.name ?? "")” down — a restore point cannot be written while the machine is using its disk."))
                    Step(number: 2, text: String(localized: "Save the state it shut down in as “\(displayName)”."))
                }
                .padding(.bottom, 14)
            }

            Text("Note")
                .font(.callout.weight(.medium))
                .padding(.bottom, 4)

            TextField("Optional — what this point is for", text: $note, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...4)
                .padding(.bottom, 14)

            Toggle(isOn: $makeBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Make this the baseline")
                    Text("The point “Reset to Baseline” returns to. Useful for the state you want to come back to over and over.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.checkbox)

            Divider().padding(.vertical, 14)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(needsShutdown ? "Shut Down & Save" : "Save") { submit() }
                    .keyboardShortcut(.defaultAction)
                    .primaryActionStyle()
                    .disabled(validation != nil)
            }
        }
        .padding(22)
        .frame(width: 480)
        .onAppear {
            name = model.suggestedSnapshotName()
            isFieldFocused = true
        }
    }

    /// True when this save has to shut the machine down first. The dialog says
    /// so before the user commits, rather than surprising them with a shutdown.
    private var needsShutdown: Bool {
        vm?.canBecomeWritableByShuttingDown == true
    }

    private var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? String(localized: "the new restore point") : trimmed
    }

    private var diskPhrase: String {
        let count = vm?.disks.count ?? 1
        return count > 1
            ? String(localized: "All \(count) disks are captured together as one restore point.")
            : ""
    }

    private var validation: String? {
        model.validationMessage(for: name)
    }

    private func submit() {
        guard validation == nil, vm != nil else { return }
        let finalName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let pin = makeBaseline
        let text = note
        // Dismiss first, then act: mutating model state while the sheet is
        // still on screen is what produced AttributeGraph cycle warnings.
        dismiss()
        Task {
            await model.createSnapshot(named: finalName, on: machineID)
            // Look the saved point up again rather than trusting the name: the
            // create may have failed, and marking a baseline that is not there
            // would leave the machine pointing at nothing.
            guard let machine = model.machines.first(where: { $0.id == machineID }),
                  let saved = machine.snapshots.first(where: { $0.name == finalName })
            else { return }
            if pin { model.setBaseline(saved, for: machine) }
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                model.setNote(text, for: saved, in: machine)
            }
        }
    }
}
