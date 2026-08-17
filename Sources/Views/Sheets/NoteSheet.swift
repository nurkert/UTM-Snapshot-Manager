import SwiftUI

/// What a restore point was for.
///
/// The note lives in this app's records, never in the image — qcow2 has room
/// for a name and a timestamp and nothing else. The dialog says so, because a
/// note that quietly disappears when the machine is opened on another Mac is
/// worse than no note at all.
struct NoteSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    let snapshot: Snapshot
    let machineID: VirtualMachine.ID

    @State private var text = ""
    @FocusState private var isFieldFocused: Bool

    private var vm: VirtualMachine? { model.machines.first { $0.id == machineID } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "text.append")
                    .font(.system(size: 28, weight: .light))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.tint)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Note for “\(snapshot.name)”")
                        .font(.title3.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text("What this point is for — the ticket, the sample, the build under test. A name has to stay short; this does not.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.bottom, 16)

            TextEditor(text: $text)
                .font(.body)
                .focused($isFieldFocused)
                .frame(height: 140)
                .padding(6)
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(.separator, lineWidth: 1)
                }
                .scrollContentBackground(.hidden)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(.background.secondary)
                )

            Label("Kept by this app, alongside the branch record. It is not written into the disk image.",
                  systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 8)
                .fixedSize(horizontal: false, vertical: true)

            Divider().padding(.vertical, 16)

            HStack {
                if hasExistingNote {
                    Button("Remove Note", role: .destructive) {
                        if let vm { model.setNote(nil, for: snapshot, in: vm) }
                        dismiss()
                    }
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    if let vm { model.setNote(text, for: snapshot, in: vm) }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .primaryActionStyle()
            }
        }
        .padding(22)
        .frame(width: 480)
        .onAppear {
            if let vm { text = model.note(for: snapshot, in: vm) ?? "" }
            isFieldFocused = true
        }
    }

    /// Nil when the machine vanished while the dialog was open — the buttons
    /// then act on nothing rather than on the wrong machine.
    private var hasExistingNote: Bool {
        vm.flatMap { model.note(for: snapshot, in: $0) } != nil
    }
}
