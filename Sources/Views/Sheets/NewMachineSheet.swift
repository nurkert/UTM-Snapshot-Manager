import SwiftUI

/// Turns a restore point into a machine of its own.
///
/// Rolling back is a move: you go to the point and leave where you were. This
/// is the copy — keep the branch you are on and the one you were about to try,
/// as two machines that can run side by side.
struct NewMachineSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    let snapshot: Snapshot
    let machineID: VirtualMachine.ID

    @State private var name = ""
    @State private var addToUTM = true
    @State private var hasLoaded = false
    @FocusState private var isFieldFocused: Bool

    private var vm: VirtualMachine? { model.machines.first { $0.id == machineID } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "square.on.square.dashed")
                    .font(.system(size: 28, weight: .light))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.tint)

                VStack(alignment: .leading, spacing: 4) {
                    Text("New Machine from “\(snapshot.name)”")
                        .font(.title3.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text("A separate machine frozen at this point. “\(vm?.name ?? "")” is not changed and keeps all of its restore points.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.bottom, 18)

            Text("Name")
                .font(.callout.weight(.medium))
                .padding(.bottom, 4)

            TextField("", text: $name)
                .textFieldStyle(.roundedBorder)
                .controlSize(.large)
                .focused($isFieldFocused)
                .onSubmit { submit() }

            Text(destinationLine)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 6)
                .lineLimit(2)
                .truncationMode(.middle)

            StepList {
                Step(number: 1, text: pointLine)
                // Not optional and not a detail: without it UTM would hold two
                // machines under one identifier and be unable to tell which one
                // a command means.
                Step(number: 2, text: String(localized: "It gets an identifier of its own, so UTM can tell the two apart."))
                Step(number: 3, text: String(localized: "The new machine starts out with no restore points — this point is its present."))
            }
            .padding(.top, 14)

            if vm?.state == .running {
                Label("“\(vm?.name ?? "")” is running. Its disks are only read, so it keeps going.",
                      systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 10)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Toggle("Add it to UTM afterwards", isOn: $addToUTM)
                .toggleStyle(.checkbox)
                .padding(.top, 12)
                .disabled(!UTMControl.isInstalled)

            Divider().padding(.vertical, 16)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create") { submit() }
                    .keyboardShortcut(.defaultAction)
                    .primaryActionStyle()
                    .disabled(trimmed.isEmpty || !snapshot.isComplete)
            }
        }
        .padding(22)
        .frame(width: 500)
        .onAppear {
            guard !hasLoaded else { return }
            hasLoaded = true
            name = String(localized: "\(vm?.name ?? "Machine") — \(snapshot.name)")
            isFieldFocused = true
        }
    }

    private var trimmed: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var destinationLine: String {
        guard let vm else { return "" }
        let folder = trimmed.isEmpty ? "…" : VMLibrary.folderName(for: trimmed)
        return String(localized: "Created in \(vm.locationDescription) as \(folder)")
    }

    private var pointLine: String {
        guard let vm else { return "" }
        return vm.disks.count > 1
            ? String(localized: "All \(vm.disks.count) disks are written out at this point.")
            : String(localized: "The disk is written out at this point.")
    }

    private func submit() {
        guard !trimmed.isEmpty, snapshot.isComplete else { return }
        let finalName = trimmed
        let add = addToUTM && UTMControl.isInstalled
        dismiss()
        Task {
            await model.createMachine(
                from: snapshot, on: machineID, named: finalName, addingToUTM: add
            )
        }
    }
}
