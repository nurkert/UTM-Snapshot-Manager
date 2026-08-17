import SwiftUI

/// Removes several restore points in one pass.
///
/// The alternative was deleting them one at a time, each behind its own
/// confirmation — which is how thirty points accumulate: tidying up costs more
/// attention than leaving them alone.
///
/// Nothing is preselected. A cleanup dialog that arrives with boxes already
/// ticked is a dialog people confirm without reading, and every line here is a
/// state somebody deliberately saved.
struct CleanUpSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    let machineID: VirtualMachine.ID

    @State private var selected: Set<String> = []

    private var vm: VirtualMachine? { model.machines.first { $0.id == machineID } }

    /// Newest first, so what is offered for deletion reads oldest-at-the-bottom.
    private var points: [Snapshot] {
        (vm?.snapshots ?? []).sorted { $0.date > $1.date }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "sparkles")
                    .font(.system(size: 28, weight: .light))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.tint)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Clean Up Restore Points")
                        .font(.title3.weight(.semibold))
                    Text("Pick what to remove from “\(vm?.name ?? "")”. The machine's current state is not affected — deleting a point only discards the ability to come back to it.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.bottom, 14)

            list

            HStack(spacing: 12) {
                Button("Select Automatic") { selected = Set(automaticNames) }
                    .disabled(automaticNames.isEmpty)
                Button("Select None") { selected.removeAll() }
                    .disabled(selected.isEmpty)
                Spacer()
                Text(countLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .controlSize(.small)
            .padding(.top, 10)

            // Freed space is deliberately not promised. Restore points share
            // clusters inside the qcow2, so what a given one costs on its own
            // has no answer — and a made-up number in a delete dialog is worse
            // than none.
            Label("How much space comes back depends on what the points share inside the image, so it cannot be stated in advance.",
                  systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 8)
                .fixedSize(horizontal: false, vertical: true)

            Divider().padding(.vertical, 14)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(selected.isEmpty ? "Delete" : "Delete \(selected.count)") {
                    let names = selected
                    dismiss()
                    Task { await model.deletePoints(named: names, on: machineID) }
                }
                .primaryActionStyle()
                .tint(.red)
                .disabled(selected.isEmpty || vm?.canModifyDisks != true)
            }
        }
        .padding(22)
        .frame(width: 540)
    }

    private var list: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(points) { point in
                    row(point)
                    if point.id != points.last?.id { Divider() }
                }
            }
        }
        .frame(height: 240)
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(.separator, lineWidth: 1)
        }
    }

    private func row(_ point: Snapshot) -> some View {
        let isBaseline = vm.map { model.isBaseline(point, in: $0) } ?? false
        let isCurrent = vm.map { model.lineage(for: $0).current == point.name } ?? false
        // The baseline and the point the machine is sitting on are the two the
        // user is most likely to want back, and the two a bulk delete is most
        // likely to take by accident.
        let isProtected = isBaseline || isCurrent

        return Toggle(isOn: Binding(
            get: { selected.contains(point.name) },
            set: { on in
                if on { selected.insert(point.name) } else { selected.remove(point.name) }
            }
        )) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(point.name)
                        .lineLimit(1)
                    Text(point.absoluteDate)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if isBaseline { badge(String(localized: "Baseline"), .accentColor) }
                if isCurrent { badge(String(localized: "You are here"), .accentColor) }
                if vm.map({ model.isAutomaticBackup(point, in: $0) }) == true {
                    badge(String(localized: "Automatic"), .secondary)
                }
            }
        }
        .toggleStyle(.checkbox)
        .disabled(isProtected)
        .help(isProtected
              ? String(localized: "Kept: this is either the baseline or where the machine is now.")
              : point.absoluteDate)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    private func badge(_ text: String, _ tint: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Capsule().fill(tint.opacity(0.15)))
    }

    private var automaticNames: [String] {
        guard let vm else { return [] }
        return points
            .filter { model.isAutomaticBackup($0, in: vm) }
            .filter { model.isBaseline($0, in: vm) == false && model.lineage(for: vm).current != $0.name }
            .map(\.name)
    }

    private var countLine: String {
        String(localized: "\(selected.count) of \(points.count) selected")
    }
}
