import SwiftUI

/// Renames a machine.
///
/// Two things carry a machine's name and they are not the same thing. The name
/// inside `config.plist` is what UTM and this app display. The folder name is
/// what Finder shows — and what UTM's library points at, which is why renaming
/// the folder of a machine UTM manages is offered with a warning rather than as
/// the obvious default.
struct RenameMachineSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    let machineID: VirtualMachine.ID

    @State private var name = ""
    @State private var renameFolder = true
    @State private var hasLoaded = false
    @FocusState private var isFieldFocused: Bool

    private var vm: VirtualMachine? { model.machines.first { $0.id == machineID } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "pencil.line")
                    .font(.system(size: 28, weight: .light))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.tint)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Rename Machine")
                        .font(.title3.weight(.semibold))
                    Text("Restore points, the baseline and any notes stay with the machine — they are filed under the identifier inside it, not under its name.")
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

            Toggle(isOn: $renameFolder) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Also rename the folder")
                    Text(folderDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.checkbox)
            .padding(.top, 14)

            if renameFolder, vm?.isRegisteredWithUTM == true {
                Label("UTM's library points at the current folder. Renaming it leaves that entry aimed at a path which no longer exists — you would have to add the machine to UTM again.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.top, 8)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider().padding(.vertical, 16)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Rename") { submit() }
                    .keyboardShortcut(.defaultAction)
                    .primaryActionStyle()
                    .disabled(!isValid)
            }
        }
        .padding(22)
        .frame(width: 480)
        .onAppear {
            guard !hasLoaded, let vm else { return }
            hasLoaded = true
            name = vm.name
            // Off by default where it would break UTM's entry: the safe choice
            // should be the one you get by not thinking about it.
            renameFolder = !vm.isRegisteredWithUTM
            isFieldFocused = true
        }
    }

    private var folderDetail: String {
        guard let vm else { return "" }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return String(localized: "The folder in Finder keeps its current name.") }
        return String(localized: "\(vm.url.lastPathComponent) becomes \(VMLibrary.folderName(for: trimmed))")
    }

    private var isValid: Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed != vm?.name || (!trimmed.isEmpty && renameFolder)
    }

    private func submit() {
        guard isValid else { return }
        let finalName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let folder = renameFolder
        dismiss()
        Task { await model.rename(machineID, to: finalName, renamingFolder: folder) }
    }
}
