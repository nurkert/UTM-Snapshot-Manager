import SwiftUI

/// Restore points drawn as the tree they actually form.
///
/// The shape comes from the app's own record of what grew out of what — see
/// `Lineage`. It is the view that matches how the machine is used: a clean
/// baseline, a branch per experiment, and a marker for where the machine is
/// sitting right now.
///
/// Deliberately not a list with indentation. A branch only reads as a branch if
/// you can see it leave its parent, so the connectors are drawn as real curves
/// and each point is a card rather than a row.
struct SnapshotTreeView: View {
    @EnvironmentObject private var model: AppModel
    let vm: VirtualMachine

    private var lineage: Lineage { model.lineage(for: vm) }

    var body: some View {
        let roots = lineage.tree(from: vm.snapshots)

        ScrollView {
            // One container for all the cards: neighbouring glass surfaces
            // blend into each other instead of stacking into a frosted mess.
            GlassGroup(spacing: 18) {
                VStack(alignment: .leading, spacing: TreeMetrics.rowGap) {
                    ForEach(roots) { node in
                        TreeBranch(node: node, vm: vm, current: lineage.current)
                    }

                    if lineage.current == nil && !vm.snapshots.isEmpty {
                        unmarkedStateNote
                    }
                    if lineage.parents.isEmpty && vm.snapshots.count > 1 {
                        flatHistoryNote
                    }
                }
            }
            .padding(.horizontal, 26)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
            // Connectors are drawn behind the cards from the dots' *measured*
            // positions. The previous version positioned them from constants —
            // a card that grew a second tag left its line pointing at nothing.
            .backgroundPreferenceValue(DotAnchors.self) { anchors in
                GeometryReader { proxy in
                    TreeConnectors(edges: edges(of: roots), anchors: anchors, proxy: proxy)
                }
            }
        }
        .background(alignment: .top) { wash }
    }

    /// A faint wash at the top so the cards sit on something rather than
    /// floating on the window's bare background. Bounded by the scroll view —
    /// it must not bleed up into the toolbar.
    private var wash: some View {
        LinearGradient(
            colors: [.accentColor.opacity(0.05), .clear],
            startPoint: .top, endPoint: .bottom
        )
        .frame(height: 240)
        .allowsHitTesting(false)
    }

    /// Every parent → child pair in the drawn tree, flattened.
    private func edges(of roots: [LineageNode]) -> [TreeEdge] {
        var result: [TreeEdge] = []
        func walk(_ node: LineageNode) {
            for child in node.children {
                result.append(TreeEdge(from: node.id, to: child.id))
                walk(child)
            }
        }
        roots.forEach(walk)
        return result
    }

    // MARK: - Notes

    private var unmarkedStateNote: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle().fill(.tint.opacity(0.16)).frame(width: 26, height: 26)
                Circle().fill(.tint).frame(width: 9, height: 9)
            }
            .frame(width: TreeMetrics.markerSize, height: TreeMetrics.markerSize)

            VStack(alignment: .leading, spacing: 1) {
                Text("Current state")
                    .font(.callout.weight(.medium))
                Text("Not saved to any restore point yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.top, 6)
    }

    private var flatHistoryNote: some View {
        Text("These points sit side by side because nothing is recorded about what grew out of what. Restore one and save from there, and the branch appears here.")
            .font(.caption)
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 480, alignment: .leading)
            .padding(.top, 18)
    }
}

// MARK: - Layout constants

private enum TreeMetrics {
    /// How far a child sits to the right of its parent.
    static let indent: CGFloat = 30
    static let rowGap: CGFloat = 10
    static let markerSize: CGFloat = 30
    static let dotRadius: CGFloat = 8
    static let corner: CGFloat = 11
    static let cardMaxWidth: CGFloat = 620
}

// MARK: - Connectors

private struct TreeEdge {
    let from: String
    let to: String
}

/// Where one card's dot sits, in the tree canvas's coordinate space.
private struct DotAnchors: PreferenceKey {
    static var defaultValue: [String: Anchor<CGPoint>] = [:]

    static func reduce(
        value: inout [String: Anchor<CGPoint>],
        nextValue: () -> [String: Anchor<CGPoint>]
    ) {
        value.merge(nextValue()) { _, new in new }
    }
}

/// The lines from each parent dot down into its children.
///
/// One path per edge, all sharing the parent's x — so several children read as
/// one spine with a branch peeling off at each row, and the geometry stays
/// correct no matter how tall a card turns out to be.
private struct TreeConnectors: View {
    let edges: [TreeEdge]
    let anchors: [String: Anchor<CGPoint>]
    let proxy: GeometryProxy

    var body: some View {
        Path { path in
            for edge in edges {
                guard let fromAnchor = anchors[edge.from],
                      let toAnchor = anchors[edge.to] else { continue }

                let start = proxy[fromAnchor]
                let end = proxy[toAnchor]
                let drop = end.y - start.y
                guard drop > 0 else { continue }

                let corner = min(TreeMetrics.corner, drop / 2)

                path.move(to: CGPoint(x: start.x, y: start.y + TreeMetrics.dotRadius + 3))
                path.addLine(to: CGPoint(x: start.x, y: end.y - corner))
                path.addQuadCurve(
                    to: CGPoint(x: start.x + corner, y: end.y),
                    control: CGPoint(x: start.x, y: end.y)
                )
                path.addLine(to: CGPoint(x: end.x - TreeMetrics.dotRadius - 3, y: end.y))
            }
        }
        .stroke(
            .quaternary,
            style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round)
        )
        .allowsHitTesting(false)
    }
}

// MARK: - Branch

/// One node plus everything descended from it.
private struct TreeBranch: View {
    let node: LineageNode
    let vm: VirtualMachine
    let current: String?

    var body: some View {
        VStack(alignment: .leading, spacing: TreeMetrics.rowGap) {
            TreeNodeCard(
                snapshot: node.snapshot,
                vm: vm,
                isCurrent: current == node.snapshot.name,
                hasChildren: !node.children.isEmpty
            )

            ForEach(node.children) { child in
                TreeBranch(node: child, vm: vm, current: current)
                    .padding(.leading, TreeMetrics.indent)
            }
        }
    }
}

// MARK: - Node

private struct TreeNodeCard: View {
    @EnvironmentObject private var model: AppModel

    let snapshot: Snapshot
    let vm: VirtualMachine
    let isCurrent: Bool
    let hasChildren: Bool

    @State private var isHovering = false

    private var isBaseline: Bool { model.isBaseline(snapshot, in: vm) }
    private var isSelected: Bool { model.selectedSnapshotID == snapshot.id }

    var body: some View {
        HStack(spacing: 14) {
            marker

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(snapshot.name)
                        .font(.body.weight(isCurrent ? .semibold : .medium))
                        .lineLimit(1)

                    if isBaseline {
                        TagLabel(text: String(localized: "Baseline"),
                                 symbol: "flag.fill", tint: .accentColor)
                    }
                    if !snapshot.isComplete {
                        TagLabel(text: String(localized: "Incomplete"),
                                 symbol: "exclamationmark.triangle.fill", tint: .orange)
                    }
                }

                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                if let note = model.note(for: snapshot, in: vm) {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 1)
                }
            }

            Spacer(minLength: 12)

            actions
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: TreeMetrics.cardMaxWidth, alignment: .leading)
        .glassCard(cornerRadius: 13, tint: isCurrent ? .accentColor : nil)
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(borderStyle, lineWidth: isSelected ? 2 : 1.5)
        }
        .shadow(color: .black.opacity(shadowOpacity), radius: isCurrent ? 10 : 5, y: 3)
        .contentShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        .help(snapshot.absoluteDate)
        .onTapGesture { model.selectedSnapshotID = snapshot.id }
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.14), value: isHovering)
        .animation(.easeOut(duration: 0.18), value: isCurrent)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var borderStyle: AnyShapeStyle {
        if isSelected { return AnyShapeStyle(Color.accentColor) }
        if isCurrent { return AnyShapeStyle(Color.accentColor.opacity(0.45)) }
        if isHovering { return AnyShapeStyle(Color.primary.opacity(0.12)) }
        return AnyShapeStyle(Color.clear)
    }

    private var shadowOpacity: Double {
        if isCurrent { return 0.14 }
        return isHovering ? 0.11 : 0.07
    }

    /// The dot on the spine. Publishes its centre so the connectors can be drawn
    /// to it rather than to an assumed offset.
    private var marker: some View {
        ZStack {
            if isCurrent {
                Circle().fill(Color.accentColor.opacity(0.18)).frame(width: 30, height: 30)
            }
            Circle()
                .strokeBorder(
                    (isCurrent || isBaseline ? Color.accentColor : .secondary)
                        .opacity(isCurrent ? 1 : 0.45),
                    lineWidth: 2
                )
                .frame(width: 16, height: 16)
            if isCurrent {
                Circle().fill(Color.accentColor).frame(width: 8, height: 8)
            } else if isBaseline {
                Image(systemName: "flag.fill")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(.tint)
            }
        }
        .frame(width: TreeMetrics.markerSize, height: TreeMetrics.markerSize)
        .anchorPreference(key: DotAnchors.self, value: .center) { [snapshot.id: $0] }
    }

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: 6) {
            if isCurrent {
                Text("You are here")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.tint)
            } else {
                Button("Restore") {
                    model.sheet = .restore(snapshot, machine: vm.id, restartAfter: false)
                }
                .secondaryActionStyle()
                .controlSize(.small)
                .disabled(!vm.canReachWritableState || !snapshot.isComplete)
                .help(vm.canBecomeWritableByShuttingDown
                      ? String(localized: "Shut the machine down and roll the disk back to this point")
                      : String(localized: "Roll the disk back to this point"))
            }

            Menu {
                Button("Restore and Start…") {
                    model.sheet = .restore(snapshot, machine: vm.id, restartAfter: true)
                }
                .disabled(!vm.canReachWritableState || !vm.isRegisteredWithUTM || !snapshot.isComplete)

                Button(isBaseline ? "Remove as Baseline" : "Set as Baseline") {
                    model.setBaseline(isBaseline ? nil : snapshot, for: vm)
                }
                Button(model.note(for: snapshot, in: vm) == nil ? "Add Note…" : "Edit Note…") {
                    model.sheet = .note(snapshot, machine: vm.id)
                }
                Button("Export…") { Task { await model.exportSnapshot(snapshot, on: vm.id) } }

                Divider()

                Button("Delete…", role: .destructive) {
                    model.sheet = .delete(snapshot, machine: vm.id)
                }
                .disabled(!vm.canModifyDisks)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 22)
            .accessibilityLabel("More actions for \(snapshot.name)")
        }
    }

    private var subtitle: String {
        var parts = [snapshot.relativeDate]
        if vm.disks.count > 1 {
            parts.append(String(localized: "\(snapshot.diskCount) of \(vm.disks.count) disks"))
        }
        if hasChildren { parts.append(String(localized: "branches from here")) }
        return parts.joined(separator: " · ")
    }

    private var accessibilityLabel: String {
        var text = snapshot.name
        if isCurrent { text += ", " + String(localized: "current position") }
        if isBaseline { text += ", " + String(localized: "baseline") }
        text += ", " + snapshot.absoluteDate
        return text
    }
}

private struct TagLabel: View {
    let text: String
    let symbol: String
    let tint: Color

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(tint.opacity(0.15)))
    }
}
