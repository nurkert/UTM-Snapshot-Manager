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
        let showsCurrentMarker = lineage.current == nil && !vm.snapshots.isEmpty

        ScrollView {
            // One container for all the cards: neighbouring glass surfaces
            // blend into each other instead of stacking into a frosted mess.
            GlassGroup(spacing: 18) {
                VStack(alignment: .leading, spacing: TreeMetrics.rowGap) {
                    ForEach(roots) { node in
                        TreeBranch(node: node, vm: vm, current: lineage.current)
                    }

                    if showsCurrentMarker {
                        unmarkedStateNote
                    }
                    if lineage.parents.isEmpty && vm.snapshots.count > 1 {
                        flatHistoryNote
                    }
                }
            }
            .padding(.horizontal, 26)
            .padding(.vertical, 22)
            .frame(maxWidth: .infinity, alignment: .leading)
            // Connectors are drawn behind the cards from the dots' *measured*
            // positions. The previous version positioned them from constants —
            // a card that grew a second tag left its line pointing at nothing.
            .backgroundPreferenceValue(DotAnchors.self) { anchors in
                GeometryReader { proxy in
                    TreeConnectors(
                        spine: spine(of: roots, includingCurrentMarker: showsCurrentMarker),
                        edges: edges(of: roots),
                        anchors: anchors,
                        proxy: proxy
                    )
                }
            }
        }
    }

    /// The points that sit on the trunk, top to bottom.
    ///
    /// Restore points with no recorded parent are roots, and a machine whose
    /// history was never observed by this app is *all* roots — which drew as a
    /// stack of identical cards and read as a plain list. They are not unrelated
    /// though: they are the same machine at successive moments. One rail down
    /// through them says that, and it is the line the branches peel off from
    /// once there is a lineage to draw.
    private func spine(of roots: [LineageNode], includingCurrentMarker: Bool) -> [String] {
        var ids = roots.map(\.id)
        if includingCurrentMarker { ids.append(TreeMetrics.currentMarkerID) }
        return ids
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

    /// The machine has moved past every recorded point.
    ///
    /// Laid out exactly like a card — same marker column, same insets — so it
    /// sits on the rail as the last stop rather than looking like a caption
    /// that slid out from under the tree. It is deliberately not a card: there
    /// is nothing here to restore to, and giving it a surface would invite the
    /// click that a bordered box promises.
    private var unmarkedStateNote: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(Color(nsColor: .windowBackgroundColor))
                    .frame(width: 14, height: 14)
                Circle()
                    .strokeBorder(.tint.opacity(0.45), style: StrokeStyle(lineWidth: 2, dash: [2.5, 2.5]))
                    .frame(width: 14, height: 14)
            }
            .frame(width: TreeMetrics.markerSize, height: TreeMetrics.markerSize)
            .anchorPreference(key: DotAnchors.self, value: .center) {
                [TreeMetrics.currentMarkerID: $0]
            }

            VStack(alignment: .leading, spacing: 1) {
                // The symbol sits inside the title rather than in a column of
                // its own: a card's text starts right after the marker, and an
                // extra icon column here would push this line out of step with
                // every card above it.
                Label("Current state", systemImage: "clock.badge.questionmark")
                    .font(.body.weight(.medium))
                    .symbolRenderingMode(.hierarchical)
                Text("Not saved to any restore point yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)
        }
        // Matches TreeNodeCard's insets so the text starts on the same line as
        // every card above it.
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: TreeMetrics.cardMaxWidth, alignment: .leading)
        .padding(.top, 2)
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
    static let rowGap: CGFloat = 6
    static let markerSize: CGFloat = 26
    static let dotRadius: CGFloat = 7
    static let corner: CGFloat = 11
    static let cardMaxWidth: CGFloat = 620
    /// The trailing point on the rail when the machine has moved past every
    /// recorded restore point.
    static let currentMarkerID = "«current-state»"
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
    let spine: [String]
    let edges: [TreeEdge]
    let anchors: [String: Anchor<CGPoint>]
    let proxy: GeometryProxy

    var body: some View {
        ZStack {
            trunk
            branches
        }
        .allowsHitTesting(false)
    }

    /// The straight rail through every point that has no parent, drawn fainter
    /// than the branches so the eye reads it as ground rather than structure.
    private var trunk: some View {
        Path { path in
            let points = spine.compactMap { anchors[$0] }.map { proxy[$0] }
            guard let first = points.first, let last = points.last, points.count > 1 else { return }
            path.move(to: CGPoint(x: first.x, y: first.y + TreeMetrics.dotRadius + 3))
            path.addLine(to: CGPoint(x: last.x, y: last.y - TreeMetrics.dotRadius - 3))
        }
        .stroke(.quaternary, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
    }

    private var branches: some View {
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
            .tertiary,
            style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round)
        )
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
                        .padding(.top, 1)
                }
            }

            Spacer(minLength: 12)

            actions
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: TreeMetrics.cardMaxWidth, alignment: .leading)
        // Quiet by default. The earlier version filled the current node with
        // solid accent and gave every card a drop shadow, which turned a list
        // of five points into five heavy blocks. On macOS the surface carries
        // the grouping and the accent marks one thing: where the machine is.
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(fill)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(borderStyle, lineWidth: isSelected ? 2 : 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        .help(snapshot.absoluteDate)
        .onTapGesture { model.selectedSnapshotID = snapshot.id }
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.14), value: isHovering)
        .animation(.easeOut(duration: 0.18), value: isCurrent)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var fill: AnyShapeStyle {
        if isCurrent { return AnyShapeStyle(Color.accentColor.opacity(0.10)) }
        if isHovering { return AnyShapeStyle(Color.primary.opacity(0.06)) }
        return AnyShapeStyle(Color.primary.opacity(0.035))
    }

    private var borderStyle: AnyShapeStyle {
        if isSelected { return AnyShapeStyle(Color.accentColor) }
        if isCurrent { return AnyShapeStyle(Color.accentColor.opacity(0.40)) }
        return AnyShapeStyle(Color.primary.opacity(0.07))
    }

    /// The dot on the spine. Publishes its centre so the connectors can be drawn
    /// to it rather than to an assumed offset.
    private var marker: some View {
        ZStack {
            if isCurrent {
                Circle().fill(Color.accentColor.opacity(0.18)).frame(width: 24, height: 24)
            }
            Circle()
                .fill(Color(nsColor: .windowBackgroundColor))
                .frame(width: 14, height: 14)
            Circle()
                .strokeBorder(
                    (isCurrent || isBaseline ? Color.accentColor : .secondary)
                        .opacity(isCurrent ? 1 : 0.45),
                    lineWidth: 2
                )
                .frame(width: 14, height: 14)
            if isCurrent {
                Circle().fill(Color.accentColor).frame(width: 7, height: 7)
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
                TagLabel(text: String(localized: "You are here"),
                         symbol: "location.fill", tint: .accentColor)
            } else {
                // Click restores; the arrow adds "and start again", which is the
                // loop this view exists for.
                Menu {
                    Button("Restore and Start…") {
                        model.sheet = .restore(snapshot, machine: vm.id, restartAfter: true)
                    }
                    .disabled(!vm.isRegisteredWithUTM)
                } label: {
                    Text("Restore")
                } primaryAction: {
                    model.sheet = .restore(snapshot, machine: vm.id, restartAfter: false)
                }
                .menuStyle(.button)
                .controlSize(.small)
                .fixedSize()
                .disabled(!vm.canReachWritableState || !snapshot.isComplete)
                .help(vm.canBecomeWritableByShuttingDown
                      ? String(localized: "Shut the machine down and roll the disk back to this point (⌘↩)")
                      : String(localized: "Roll the disk back to this point (⌘↩)"))
            }

            Menu {
                Button(isBaseline ? "Remove as Baseline" : "Set as Baseline") {
                    model.setBaseline(isBaseline ? nil : snapshot, for: vm)
                }
                Button(model.note(for: snapshot, in: vm) == nil ? "Add Note…" : "Edit Note…") {
                    model.sheet = .note(snapshot, machine: vm.id)
                }
                Menu("Export") {
                    Button("As a Machine…") { Task { await model.exportMachine(snapshot, on: vm.id, asArchive: false) } }
                    Button("As a Compressed Archive…") { Task { await model.exportMachine(snapshot, on: vm.id, asArchive: true) } }
                    Divider()
                    Button("Disk Image Only…") { Task { await model.exportSnapshot(snapshot, on: vm.id) } }
                }

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
