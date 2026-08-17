import AppKit
import SwiftUI

struct AppAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    /// Critical alerts describe a machine left in a broken state. They are
    /// styled and worded so they cannot be mistaken for a routine hiccup.
    var isCritical = false
}

/// Something long-running is happening. Writes are not cancellable — pulling
/// the rug out from under `qemu-img` mid-write is how images get damaged — but
/// read-only work like an integrity check is.
struct Activity: Equatable {
    let title: String
    var detail: String?
    var isCancellable = false
    var startedAt = Date()
}

/// Every sheet that acts on a machine carries which machine it meant.
///
/// Resolving the target from the current selection at confirmation time is a
/// trap: a background rescan can drop a machine and move the selection while
/// the dialog is still on screen, and the action then lands somewhere the
/// dialog never named.
enum SheetRoute: Identifiable, Equatable {
    case newSnapshot(machine: VirtualMachine.ID)
    case restore(Snapshot, machine: VirtualMachine.ID, restartAfter: Bool)
    case delete(Snapshot, machine: VirtualMachine.ID)
    case checkReport([String])
    case automationHelp
    case welcome
    case note(Snapshot, machine: VirtualMachine.ID)
    case addToUTM(machine: VirtualMachine.ID)
    case trash(machine: VirtualMachine.ID)
    case rename(machine: VirtualMachine.ID)
    case newMachine(Snapshot, machine: VirtualMachine.ID)
    case cleanUp(machine: VirtualMachine.ID)

    var id: String {
        switch self {
        case .newSnapshot(let m): return "new-\(m)"
        case .restore(let s, let m, _): return "restore-\(m)-\(s.id)"
        case .delete(let s, let m): return "delete-\(m)-\(s.id)"
        case .checkReport: return "check"
        case .automationHelp: return "automation"
        case .welcome: return "welcome"
        case .note(let s, let m): return "note-\(m)-\(s.id)"
        case .addToUTM(let m): return "add-\(m)"
        case .trash(let m): return "trash-\(m)"
        case .rename(let m): return "rename-\(m)"
        case .newMachine(let s, let m): return "fork-\(m)-\(s.id)"
        case .cleanUp(let m): return "cleanup-\(m)"
        }
    }
}

/// Coordinates the UI. Holds no logic about disks or processes — that lives in
/// `VMLibrary` — and exists to keep exactly one copy of "what is on screen".
@MainActor
final class AppModel: ObservableObject {

    // MARK: - Environment

    @Published private(set) var qemuImgPath: String?
    @Published private(set) var qemuVersion: String?
    @Published private(set) var utmAvailability: UTMControl.Availability = .notInstalled

    var isReady: Bool { qemuImgPath != nil }
    var canControlMachines: Bool { utmAvailability == .ready || utmAvailability == .notRunning }

    // MARK: - Library

    @Published private(set) var machines: [VirtualMachine] = []

    @Published var selectedMachineID: VirtualMachine.ID?
    @Published var selectedSnapshotID: Snapshot.ID?

    /// Points the snapshot selection at the current machine.
    ///
    /// Restore points are identified by name, and two machines can easily both
    /// have one called "Baseline" — so the selection has to be reset when the
    /// machine changes, or it silently carries over to a different machine's
    /// identically named point.
    ///
    /// This deliberately is *not* a `didSet` on `selectedMachineID`. That
    /// property is bound straight to the sidebar's `List`, so the setter runs
    /// inside SwiftUI's view update, and publishing a second change from there
    /// is a state mutation during an update: the run loop bails out mid-pass and
    /// leaves the window half-drawn — empty sidebar, missing detail header.
    /// Called from `onChange` instead, which runs after the update completes.
    func syncSnapshotSelection() {
        guard let vm = selectedMachine else {
            selectedSnapshotID = nil
            return
        }
        if !vm.snapshots.contains(where: { $0.id == selectedSnapshotID }) {
            selectedSnapshotID = orderedSnapshots.first?.id
        }
    }

    @Published private(set) var isScanning = false
    @Published private(set) var scanWasIncomplete = false
    @Published private(set) var restrictedFolders: [String] = []
    /// macOS is showing a consent dialog the user hasn't answered yet.
    @Published private(set) var permissionPending = false
    /// UTM is installed but its library could not be read, so no machine can be
    /// shown to be the one UTM manages.
    @Published private(set) var utmLibraryUnreadable = false

    private var lastScanFinishedAt: Date?

    // MARK: - Presentation

    @Published private(set) var activity: Activity?
    @Published var alert: AppAlert?
    @Published var sheet: SheetRoute?

    /// Confirmation of what just happened, shown briefly in place of nothing at
    /// all. Rolling a disk back is a big event and deserves an acknowledgement.
    @Published var lastOutcome: String?

    // MARK: - Baselines

    /// The restore point a machine is reset to over and over. Analysis work is
    /// a loop — roll back, run the sample, roll back — and picking the right row
    /// out of thirty every single time is both slow and an invitation to pick
    /// the wrong one.
    @Published private(set) var baselines: [String: String] = [:]

    // MARK: - Lineage

    enum DetailMode: String, CaseIterable, Identifiable {
        case list, tree
        var id: String { rawValue }
        var label: String {
            switch self {
            case .list: return String(localized: "List")
            case .tree: return String(localized: "Tree")
            }
        }
        var symbol: String {
            switch self {
            case .list: return "list.bullet"
            case .tree: return "point.topleft.down.to.point.bottomright.curvepath"
            }
        }
    }

    @Published var detailMode: DetailMode = .list {
        didSet { UserDefaults.standard.set(detailMode.rawValue, forKey: detailModeKey) }
    }

    /// Recorded ancestry per machine. See `Lineage` for why this is kept here
    /// rather than read from the image.
    @Published private(set) var lineages: [String: Lineage] = [:]

    func lineage(for vm: VirtualMachine) -> Lineage {
        var value = lineages[vm.recordKey] ?? Lineage()
        value.prune(to: Set(vm.snapshots.map(\.name)))
        return value
    }

    private func updateLineage(for machineID: VirtualMachine.ID, _ change: (inout Lineage) -> Void) {
        let key = recordKey(for: machineID)
        var value = lineages[key] ?? Lineage()
        change(&value)
        lineages[key] = value
        saveLineages()
    }

    /// Resolves a machine's storage key from its path. Falls back to the path
    /// for a bundle with no readable UUID — such a machine cannot be told apart
    /// from a copy of itself anyway, so its records stay tied to where it lies.
    private func recordKey(for machineID: VirtualMachine.ID) -> String {
        machines.first { $0.id == machineID }?.recordKey ?? machineID
    }

    // MARK: - Automatic safety copies

    /// Which restore points this app made on its own before a rollback.
    ///
    /// Recorded rather than recognised by name. The name is localised and the
    /// user can rename nothing in qcow2 but could well have their own point
    /// called "Automatic backup" — and the one thing pruning must never do is
    /// delete something a person saved deliberately. A recorded set cannot be
    /// fooled by a coincidence of wording.
    @Published private(set) var automaticBackups: [String: Set<String>] = [:]

    /// How many automatic copies to keep per machine.
    ///
    /// The loop this app is built for — roll back, run, roll back — makes one
    /// of these every time round. Keeping all of them turns a week of work into
    /// a list nobody reads; keeping none removes the only way back from a
    /// rollback you regret. Three is enough to undo a mistake you notice late,
    /// and few enough to stay invisible.
    @Published var automaticBackupsKept: Int = 3 {
        didSet { UserDefaults.standard.set(automaticBackupsKept, forKey: autoKeepKey) }
    }

    /// Whether a rollback of this machine saves the current state first.
    ///
    /// Remembered per machine: someone who turns it off for a scratch VM should
    /// not have to turn it off again on every single rollback. Mandatory on
    /// multi-disk machines regardless — there a half-failed rollback cannot be
    /// undone any other way.
    func keepsSafetyCopy(for vm: VirtualMachine) -> Bool {
        if vm.disks.count > 1 { return true }
        return safetyCopyChoices[vm.recordKey] ?? true
    }

    func setKeepsSafetyCopy(_ keep: Bool, for vm: VirtualMachine) {
        guard vm.disks.count <= 1 else { return }
        safetyCopyChoices[vm.recordKey] = keep
        UserDefaults.standard.set(safetyCopyChoices, forKey: safetyChoiceKey)
    }

    @Published private(set) var safetyCopyChoices: [String: Bool] = [:]

    func isAutomaticBackup(_ snapshot: Snapshot, in vm: VirtualMachine) -> Bool {
        automaticBackups[vm.recordKey]?.contains(snapshot.name) ?? false
    }

    private func recordAutomaticBackup(named name: String, for key: String) {
        automaticBackups[key, default: []].insert(name)
        saveAutomaticBackups()
    }

    private func forgetAutomaticBackup(named name: String, for key: String) {
        automaticBackups[key]?.remove(name)
        if automaticBackups[key]?.isEmpty == true { automaticBackups[key] = nil }
        saveAutomaticBackups()
    }

    /// Removes automatic copies beyond the keep count, oldest first.
    ///
    /// Deliberately narrow. It only ever touches points this app recorded as its
    /// own, never the baseline, and never the point the machine is currently
    /// sitting on — losing the way back to where you are would be a strange way
    /// to tidy up. Failures are swallowed: this is housekeeping that ran after
    /// the operation the user actually asked for succeeded, and turning it into
    /// an error message would report a success as a failure.
    private func pruneAutomaticBackups(on machineID: VirtualMachine.ID) async {
        guard automaticBackupsKept > 0, let vm = machine(machineID), let library else { return }
        let key = vm.recordKey
        guard let recorded = automaticBackups[key], !recorded.isEmpty else { return }

        let protectedNames = Set([baselines[key], lineage(for: vm).current].compactMap { $0 })
        let candidates = vm.snapshots
            .filter { recorded.contains($0.name) && !protectedNames.contains($0.name) }
            .sorted { $0.date > $1.date }

        guard candidates.count > automaticBackupsKept else { return }

        for snapshot in candidates.dropFirst(automaticBackupsKept) {
            do {
                try await library.delete(snapshot, on: vm)
                updateLineage(for: vm.id) { $0.forget(snapshot.name) }
                forgetAutomaticBackup(named: snapshot.name, for: key)
            } catch {
                return
            }
        }
    }

    private func saveAutomaticBackups() {
        let plain = automaticBackups.mapValues(Array.init)
        guard let data = try? JSONEncoder().encode(plain) else { return }
        UserDefaults.standard.set(data, forKey: autoBackupKey)
    }

    private func loadAutomaticBackups() {
        if let data = UserDefaults.standard.data(forKey: autoBackupKey),
           let decoded = try? JSONDecoder().decode([String: [String]].self, from: data) {
            automaticBackups = decoded.mapValues(Set.init)
        }
        safetyCopyChoices = UserDefaults.standard.dictionary(forKey: safetyChoiceKey) as? [String: Bool] ?? [:]
        if UserDefaults.standard.object(forKey: autoKeepKey) != nil {
            automaticBackupsKept = UserDefaults.standard.integer(forKey: autoKeepKey)
        }
    }

    // MARK: - Notes

    /// What a restore point was for, in the user's own words.
    ///
    /// Kept beside the lineage rather than in the image: qcow2 stores a name
    /// and a timestamp per snapshot and nothing else, and there is no way to
    /// attach text to one without rewriting it. Machine key → point name → note.
    ///
    /// A name has to stay short enough to read in a row; the reason a point
    /// exists — the CVE, the ticket, the build under test — does not fit there
    /// and is exactly what is missing three weeks later.
    @Published private(set) var notes: [String: [String: String]] = [:]

    func note(for snapshot: Snapshot, in vm: VirtualMachine) -> String? {
        let text = notes[vm.recordKey]?[snapshot.name]
        return (text?.isEmpty ?? true) ? nil : text
    }

    func setNote(_ text: String?, for snapshot: Snapshot, in vm: VirtualMachine) {
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var forMachine = notes[vm.recordKey] ?? [:]
        if trimmed.isEmpty {
            forMachine.removeValue(forKey: snapshot.name)
        } else {
            forMachine[snapshot.name] = trimmed
        }
        notes[vm.recordKey] = forMachine.isEmpty ? nil : forMachine
        saveNotes()
    }

    /// Drops notes for points that no longer exist, so a name reused later does
    /// not inherit the previous point's description.
    private func pruneNotes() {
        var changed = false
        for vm in machines {
            guard var forMachine = notes[vm.recordKey] else { continue }
            let existing = Set(vm.snapshots.map(\.name))
            let stale = forMachine.keys.filter { !existing.contains($0) }
            guard !stale.isEmpty else { continue }
            stale.forEach { forMachine.removeValue(forKey: $0) }
            notes[vm.recordKey] = forMachine.isEmpty ? nil : forMachine
            changed = true
        }
        if changed { saveNotes() }
    }

    private func saveNotes() {
        guard let data = try? JSONEncoder().encode(notes) else { return }
        UserDefaults.standard.set(data, forKey: notesKey)
    }

    private func loadNotes() {
        guard let data = UserDefaults.standard.data(forKey: notesKey),
              let decoded = try? JSONDecoder().decode([String: [String: String]].self, from: data)
        else { return }
        notes = decoded
    }

    private func saveLineages() {
        guard let data = try? JSONEncoder().encode(lineages) else { return }
        UserDefaults.standard.set(data, forKey: lineageKey)
    }

    private func loadLineages() {
        guard let data = UserDefaults.standard.data(forKey: lineageKey),
              let decoded = try? JSONDecoder().decode([String: Lineage].self, from: data)
        else { return }
        lineages = decoded
    }

    private let baselineKey = "baselineSnapshots"
    private let welcomeKey = "hasSeenWelcome"
    private let lineageKey = "snapshotLineages"
    private let notesKey = "snapshotNotes"
    private let autoBackupKey = "automaticBackups"
    private let autoKeepKey = "automaticBackupsKept"
    private let safetyChoiceKey = "safetyCopyChoices"
    private let detailModeKey = "detailMode"

    private var hasLoadedOnce = false
    private var isRefreshing = false
    /// A refresh asked for while another was running. Without this the refresh
    /// that follows a write is silently dropped, and the in-flight scan then
    /// overwrites the list with data from before the change.
    private var refreshQueued = false
    private var pollTask: Task<Void, Never>?

    // MARK: - Derived

    var selectedMachine: VirtualMachine? {
        machines.first { $0.id == selectedMachineID }
    }

    var selectedSnapshot: Snapshot? {
        guard let snapshots = selectedMachine?.snapshots else { return nil }
        return snapshots.first { $0.id == selectedSnapshotID }
    }

    /// Snapshots with the pinned baseline floated to the top.
    var orderedSnapshots: [Snapshot] {
        guard let vm = selectedMachine else { return [] }
        let baseline = baselines[vm.recordKey]
        return vm.snapshots.sorted { lhs, rhs in
            if lhs.name == baseline { return true }
            if rhs.name == baseline { return false }
            return lhs.date > rhs.date
        }
    }

    func isBaseline(_ snapshot: Snapshot, in vm: VirtualMachine) -> Bool {
        baselines[vm.recordKey] == snapshot.name
    }

    var baselineSnapshot: Snapshot? {
        guard let vm = selectedMachine, let name = baselines[vm.recordKey] else { return nil }
        return vm.snapshots.first { $0.name == name }
    }

    /// Names that appear more than once — the folder is then shown instead, so
    /// three machines called "Debian 12" stay distinguishable.
    var ambiguousNames: Set<String> {
        var seen = Set<String>()
        var duplicates = Set<String>()
        for machine in machines {
            if !seen.insert(machine.name).inserted { duplicates.insert(machine.name) }
        }
        return duplicates
    }

    private var library: VMLibrary? {
        qemuImgPath.map { VMLibrary(qemuImgPath: $0) }
    }

    // MARK: - Lifecycle

    func bootstrap() async {
        guard !hasLoadedOnce else { return }
        hasLoadedOnce = true

        baselines = (UserDefaults.standard.dictionary(forKey: baselineKey) as? [String: String]) ?? [:]
        loadLineages()
        loadNotes()
        loadAutomaticBackups()
        if let raw = UserDefaults.standard.string(forKey: detailModeKey),
           let mode = DetailMode(rawValue: raw) {
            detailMode = mode
        }
        if !UserDefaults.standard.bool(forKey: welcomeKey) { sheet = .welcome }

        await checkPrerequisites()
        await refresh()
    }

    /// Safe to call repeatedly — the window may be closed and reopened, and
    /// `bootstrap` returns immediately on the second run, so tying polling to it
    /// left the state frozen for the rest of the session.
    func startPollingIfNeeded() {
        guard pollTask == nil else { return }
        startPolling()
    }

    func markWelcomeSeen() {
        UserDefaults.standard.set(true, forKey: welcomeKey)
    }

    func checkPrerequisites() async {
        let path = await ProcessRunner.timeboxed(12, fallback: String?.none) { QemuImg.locate() }
        qemuImgPath = path

        if let path {
            qemuVersion = await ProcessRunner.timeboxed(8, fallback: String?.none) {
                QemuImg.version(at: path)
            }
        } else {
            qemuVersion = nil
        }
    }

    /// Keeps the run state fresh without rescanning the whole disk.
    ///
    /// Asking UTM is cheap and the answer is what every destructive button is
    /// gated on, so it is polled. Without this the Take Snapshot button stays
    /// enabled for however long it takes the user to notice, on a machine they
    /// started in UTM ten seconds ago.
    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                // Frequent enough that the buttons react while you are looking
                // at them, and near-idle when you are not. Each poll spawns an
                // osascript process and makes UTM answer an Apple Event, so
                // there is no reason to keep that up in the background.
                let isActive = await MainActor.run { NSApp.isActive }
                try? await Task.sleep(for: .seconds(isActive ? 5 : 30))
                guard !Task.isCancelled else { return }
                await self?.refreshRunStates()
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// Re-scans when the window comes back to the front, but only if the last
    /// scan admitted to being incomplete.
    ///
    /// Granting access happens *outside* this app — in a consent dialog or in
    /// System Settings — and nothing tells the app afterwards. Without this the
    /// short list simply stays on screen until something else happens to trigger
    /// a scan, and the machines then appear out of nowhere, seemingly at random.
    func applicationBecameActive() async {
        guard !isScanning, activity == nil else { return }

        // First thing on coming back: ask UTM what is running.
        //
        // The usual reason to leave this window is to do something to a machine
        // in UTM — most often shut it down so a restore point can be taken. The
        // poll would catch it, but only after its next tick, so the window
        // greeted you with a banner still insisting you shut the machine down
        // that you just shut down. One Apple Event is a cheap price for the
        // state being right the moment you look at it.
        await refreshRunStates()

        // A sheet holds a machine and a restore point the user picked. Swapping
        // the list underneath it can move the selection, and the confirmed
        // action would then land on a different machine than the one named in
        // the dialog.
        guard sheet == nil else { return }

        // Several of these conditions can never resolve themselves — a denied
        // folder permission never re-prompts, and a Mac with no machines stays
        // that way. Without a floor, every single switch back to the window
        // would launch a full scan: mdfind, six folder walks, ps and an Apple
        // Event to UTM, forever.
        if let lastScanFinishedAt, Date().timeIntervalSince(lastScanFinishedAt) < 60 { return }

        guard permissionPending || scanWasIncomplete || !restrictedFolders.isEmpty else { return }
        await refresh()
    }

    private func refreshRunStates() async {
        // Never poll over a write: the scan would fight the operation for the
        // image lock and the answer would be stale by the time it lands.
        guard activity == nil, !isRefreshing else { return }

        let wasAvailable = utmAvailability
        let (utmMachines, availability) = await UTMControl.machines()
        utmAvailability = availability

        // UTM was launched since the last scan. The machine list was built
        // without it and may say "not in UTM's library" about everything, so it
        // needs rebuilding rather than patching. Checked before the early exit
        // below, which would otherwise leave that state stuck until a manual
        // rescan.
        if availability == .ready, wasAvailable == .notRunning {
            await refresh()
            return
        }

        guard availability == .ready else { return }
        // Nothing here is managed by UTM, so there is nothing left to patch.
        guard machines.contains(where: \.isRegisteredWithUTM) else { return }

        var states: [String: RunState] = [:]
        for machine in utmMachines { states[machine.uuid] = machine.state }

        // Reading the process table costs a command, so it is only paid for when
        // it can actually change an answer: a machine we show as running that
        // UTM now reports as off.
        let needsProcessCheck = machines.contains { vm in
            vm.isRegisteredWithUTM && vm.state == .running
                && vm.uuid.flatMap { states[$0] } == .stopped
        }
        let commandLines = needsProcessCheck ? await ProcessTable.qemuCommandLines() : nil

        machines = machines.map { vm in
            // Only machines UTM manages take their state from UTM. A duplicated
            // bundle carries the original's UUID, and letting it inherit the
            // original's state would report a copy as running.
            guard vm.isRegisteredWithUTM else { return vm }
            guard let uuid = vm.uuid, let state = states[uuid], state != vm.state else { return vm }

            // A suspended machine is decided by the image — UTM reporting
            // "stopped" does not disprove a parked memory state — so the poll
            // never overrides it. That one waits for a full rescan.
            if state == .stopped, vm.state == .suspended { return vm }

            // A machine shown as running that UTM now calls stopped is the
            // ordinary case of the guest having finished shutting down, and
            // refusing to believe it left the banner claiming "is running right
            // now" until the next full scan — with the shutdown button firing
            // into a machine that was already off.
            //
            // It is still checked against the process table first: a QEMU that
            // UTM has lost track of would otherwise light the write buttons back
            // up on an image somebody still holds open. An unreadable process
            // table answers "unknown", which keeps the machine marked running —
            // not knowing is never a reason to unlock a disk.
            if state == .stopped, vm.state == .running,
               ProcessTable.diskUse(of: vm.disks, commandLines: commandLines) != .free {
                return vm
            }

            return vm.with(state: state)
        }
    }

    // MARK: - Scanning

    func refresh() async {
        guard let library else { return }

        if isRefreshing {
            refreshQueued = true
            return
        }
        isRefreshing = true
        isScanning = true
        defer {
            isRefreshing = false
            isScanning = false
        }

        repeat {
            refreshQueued = false

            // Published before the scan, so a window blocked behind a consent
            // dialog says so within seconds instead of showing a spinner for as
            // long as the dialog stands.
            let probe = await VMDiscovery.probePermissions()
            restrictedFolders = probe.restricted
            permissionPending = probe.pending

            // A hard ceiling on the whole scan. Every step inside already has
            // its own deadline, but an unanswered consent dialog can stall
            // several of them at once, and an app stuck on "Searching…" with no
            // way out is indistinguishable from a broken one.
            guard let result = await ProcessRunner.withDeadline(90, { await library.scan() }) else {
                // Deliberately not reported as a pending consent dialog: an
                // overrun has other causes, and claiming macOS is asking for
                // permission when nothing is on screen sends people hunting for
                // a dialog that does not exist.
                scanWasIncomplete = true
                continue
            }

            utmAvailability = result.utmAvailability
            restrictedFolders = result.restrictedFolders
            permissionPending = result.permissionPending
            utmLibraryUnreadable = result.utmLibraryUnreadable
            lastScanFinishedAt = Date()

            // A cut-short scan must never wipe a list that was already good.
            // Spotlight is empty on many Macs, so the folder walk is the only
            // source; if it hits its deadline the result says "nothing found"
            // even though the machines are still right there on disk.
            if result.machines.isEmpty && !machines.isEmpty && result.wasCutShort {
                scanWasIncomplete = true
                continue
            }

            scanWasIncomplete = false
            machines = result.machines
            adoptRecordsFromPreviousLocation()
            pruneNotes()

            if selectedMachineID == nil || !machines.contains(where: { $0.id == selectedMachineID }) {
                selectedMachineID = machines.first?.id
            }
            syncSnapshotSelection()
        } while refreshQueued
    }

    /// Moves records that were filed under a machine's old path onto its UUID.
    ///
    /// Covers both the bundle being moved or renamed and the upgrade from the
    /// builds that filed everything by path. Without it, dragging a `.utm` to
    /// another folder silently flattens its tree and drops its baseline — the
    /// restore points are all still in the image, but the app looks like it
    /// threw them away.
    ///
    /// A record already filed under the UUID wins: it is the newer one, and a
    /// stale path entry from a copy must not overwrite it.
    private func adoptRecordsFromPreviousLocation() {
        var movedBaselines = false
        var movedLineages = false
        var movedNotes = false

        for vm in machines {
            let key = vm.recordKey
            guard key != vm.id else { continue }

            if let orphan = baselines.removeValue(forKey: vm.id) {
                if baselines[key] == nil { baselines[key] = orphan }
                movedBaselines = true
            }
            if let orphan = lineages.removeValue(forKey: vm.id) {
                if lineages[key] == nil { lineages[key] = orphan }
                movedLineages = true
            }
            if let orphan = notes.removeValue(forKey: vm.id) {
                if notes[key] == nil { notes[key] = orphan }
                movedNotes = true
            }
        }

        if movedBaselines { UserDefaults.standard.set(baselines, forKey: baselineKey) }
        if movedLineages { saveLineages() }
        if movedNotes { saveNotes() }
    }

    // MARK: - Baseline

    func setBaseline(_ snapshot: Snapshot?, for vm: VirtualMachine) {
        if let snapshot {
            baselines[vm.recordKey] = snapshot.name
        } else {
            baselines.removeValue(forKey: vm.recordKey)
        }
        UserDefaults.standard.set(baselines, forKey: baselineKey)
    }

    // MARK: - Machine control

    func start(_ vm: VirtualMachine) async {
        guard let uuid = vm.uuid else { return }
        await run(Activity(title: String(localized: "Starting “\(vm.name)”…"))) {
            try await UTMControl.start(machineWith: uuid, name: vm.name)
        }
        // Success or failure, what is on screen has to match reality afterwards.
        await refreshRunStates()
    }

    func stop(_ vm: VirtualMachine, method: UTMControl.StopMethod = .request) async {
        guard let uuid = vm.uuid else { return }
        let title = method == .request
            ? String(localized: "Asking “\(vm.name)” to shut down…")
            : String(localized: "Forcing “\(vm.name)” off…")
        await run(Activity(title: title, detail: method == .request
            ? String(localized: "The guest decides when it is ready. This can take a moment.")
            : nil)) {
            try await UTMControl.stop(machineWith: uuid, method: method, name: vm.name)
            try await self.waitForStop(uuid: uuid)
        }
        await refreshRunStates()
    }

    func suspend(_ vm: VirtualMachine) async {
        guard let uuid = vm.uuid else { return }
        await run(Activity(title: String(localized: "Suspending “\(vm.name)”…"))) {
            try await UTMControl.suspend(machineWith: uuid, name: vm.name)
        }
        await refreshRunStates()
    }

    /// Brings a machine down as the first step of a disk operation and waits
    /// until it is really down, returning it with its state corrected.
    ///
    /// Shared by every write path so the chained operations — "shut down and
    /// save", "shut down, roll back and start again" — all go through the same
    /// wait. A no-op for a machine that is already off.
    private func shutDownIfNeeded(
        _ machine: VirtualMachine,
        because reason: String
    ) async throws -> VirtualMachine {
        guard !machine.state.allowsDiskWrites, machine.canStop, let uuid = machine.uuid else {
            return machine
        }
        await setActivity(Activity(
            title: String(localized: "Shutting “\(machine.name)” down…"),
            detail: reason
        ))
        try await UTMControl.stop(machineWith: uuid, method: .request, name: machine.name)
        try await waitForStop(uuid: uuid)
        return machine.with(state: .stopped)
    }

    /// Polls until the machine is actually down. `stop` returns as soon as the
    /// request is delivered, and writing to a disk that is merely on its way out
    /// is exactly as damaging as writing to a running one.
    private func waitForStop(uuid: String, timeout: TimeInterval = 120) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let state = await UTMControl.state(ofMachineWith: uuid)
            if state == .stopped { return }
            try? await Task.sleep(for: .seconds(1))
        }
        throw AppError.timedOut(what: String(localized: "Shutting the machine down"), seconds: Int(timeout))
    }

    // MARK: - Snapshot actions

    /// Opens the dialog for a machine that is writable *or* can be made writable
    /// by shutting it down. The dialog itself says which of the two it is.
    func beginNewSnapshot() {
        guard let vm = selectedMachine, vm.canReachWritableState else { return }
        sheet = .newSnapshot(machine: vm.id)
    }

    /// Looks the target up by identity rather than by "whatever is selected
    /// now". Returns nil and explains itself if the machine has since gone.
    private func machine(_ id: VirtualMachine.ID) -> VirtualMachine? {
        guard let vm = machines.first(where: { $0.id == id }) else {
            alert = AppAlert(
                title: String(localized: "That machine is no longer there"),
                message: String(localized: "It disappeared from the list while the dialog was open, so nothing was changed.")
            )
            return nil
        }
        return vm
    }

    /// Saves a restore point, shutting the machine down first if it is still
    /// running. The dialog has already said that this is what will happen.
    func createSnapshot(named name: String, on machineID: VirtualMachine.ID) async {
        guard let vm = machine(machineID), let library else { return }
        await run(Activity(title: String(localized: "Preparing…"))) {
            let target = try await self.shutDownIfNeeded(
                vm,
                because: String(localized: "A restore point can only be written while the machine is off.")
            )

            await self.setActivity(Activity(
                title: String(localized: "Saving “\(name)”…"),
                detail: String(localized: "Writing a restore point to \(target.disks.count == 1 ? "the disk" : "\(target.disks.count) disks").")
            ))
            try await library.createSnapshot(named: name, on: target)

            await MainActor.run {
                self.updateLineage(for: target.id) { $0.recordSnapshot(named: name) }
                self.lastOutcome = String(localized: "Saved “\(name)”.")
            }
        }
        await refresh()
    }

    /// The core loop of this app: shut the machine down if needed, roll it back,
    /// and start it again — as one operation with one confirmation, instead of
    /// three trips to UTM and back.
    func restore(
        _ snapshot: Snapshot,
        on machineID: VirtualMachine.ID,
        keepingSafetyCopy: Bool,
        restartAfter: Bool
    ) async {
        guard let vm = machine(machineID), let library else { return }

        await run(Activity(title: String(localized: "Preparing…"))) {
            let machine = try await self.shutDownIfNeeded(
                vm,
                because: String(localized: "A disk cannot be rolled back while the machine is using it.")
            )

            if keepingSafetyCopy {
                let safetyName = self.uniqueName(
                    base: String(localized: "Automatic backup"), in: machine
                )
                await self.setActivity(Activity(
                    title: String(localized: "Saving the current state…"),
                    detail: String(localized: "So this step stays reversible.")
                ))
                try await library.createSnapshot(named: safetyName, on: machine)
                await MainActor.run {
                    self.updateLineage(for: machine.id) { $0.recordSnapshot(named: safetyName) }
                    self.recordAutomaticBackup(named: safetyName, for: machine.recordKey)
                }
            }

            await self.setActivity(Activity(
                title: String(localized: "Restoring “\(snapshot.name)”…"),
                detail: String(localized: "Rolling \(machine.disks.count == 1 ? "the disk" : "all \(machine.disks.count) disks") back.")
            ))
            try await library.restore(snapshot, on: machine)

            if restartAfter, let uuid = machine.uuid, machine.isRegisteredWithUTM {
                await self.setActivity(Activity(title: String(localized: "Starting “\(machine.name)” again…")))
                try await UTMControl.start(machineWith: uuid, name: vm.name)
            }

            await MainActor.run {
                self.updateLineage(for: machine.id) { $0.recordRestore(to: snapshot.name) }
                self.lastOutcome = String(
                    localized: "“\(machine.name)” is back at “\(snapshot.name)” (\(snapshot.absoluteDate))."
                )
            }
        }
        await refresh()
        // Housekeeping, after the thing the user asked for has already worked.
        await pruneAutomaticBackups(on: machineID)
    }

    /// Saves a restore point without shutting the guest down.
    ///
    /// QEMU can snapshot a live machine — `savevm` on its monitor does exactly
    /// what VMware and VirtualBox do. UTM exposes that monitor only over its own
    /// SPICE port, which no other process can reach, and its scripting interface
    /// has no snapshot command. So the live path is closed to us, not by the
    /// format and not by QEMU, but by where the door is.
    ///
    /// What *is* reachable is the same idea one step apart: ask UTM to park the
    /// machine — memory written to the image, QEMU exits — take the point on the
    /// now-quiet disk, then resume. The guest never shuts down and comes back
    /// exactly where it was; it is paused for as long as writing its memory
    /// takes.
    ///
    /// The point captures a disk that was parked cleanly rather than caught
    /// mid-write, which is the property that matters. It does not carry the
    /// memory itself, so restoring it later boots rather than resumes.
    func createSnapshotWhileParked(named name: String, on machineID: VirtualMachine.ID) async {
        guard let vm = machine(machineID), let library,
              let uuid = vm.uuid, vm.isRegisteredWithUTM else { return }

        var parked = false

        await run(Activity(
            title: String(localized: "Pausing “\(vm.name)”…"),
            detail: String(localized: "UTM is writing the machine's memory to disk. The guest is not shut down.")
        )) {
            try await UTMControl.suspend(machineWith: uuid, name: vm.name)
            try await self.waitForStop(uuid: uuid)
            parked = true

            await self.setActivity(Activity(
                title: String(localized: "Saving “\(name)”…"),
                detail: String(localized: "The disk is quiet now, so the point is written from a clean state.")
            ))
            try await library.createSnapshot(
                named: name, on: vm, allowingParkedMemoryState: true
            )

            await MainActor.run {
                self.updateLineage(for: vm.id) { $0.recordSnapshot(named: name) }
            }

            await self.setActivity(Activity(
                title: String(localized: "Resuming “\(vm.name)”…"),
                detail: String(localized: "The machine picks up where it left off.")
            ))
            try await UTMControl.start(machineWith: uuid, name: vm.name)

            await MainActor.run {
                self.lastOutcome = String(localized: "Saved “\(name)” and resumed “\(vm.name)”.")
            }
        }

        // A failure after parking must not leave the machine sitting suspended
        // with no explanation — it looks like the app switched it off.
        if parked, machine(machineID)?.state != .running {
            try? await UTMControl.start(machineWith: uuid, name: vm.name)
        }
        await refresh()
    }

    func delete(_ snapshot: Snapshot, on machineID: VirtualMachine.ID) async {
        guard let vm = machine(machineID), let library else { return }
        await run(Activity(title: String(localized: "Deleting “\(snapshot.name)”…"))) {
            try await library.delete(snapshot, on: vm)
            await MainActor.run {
                if self.baselines[vm.recordKey] == snapshot.name { self.setBaseline(nil, for: vm) }
                self.updateLineage(for: vm.id) { $0.forget(snapshot.name) }
                self.forgetAutomaticBackup(named: snapshot.name, for: vm.recordKey)
                self.lastOutcome = String(localized: "Deleted “\(snapshot.name)”.")
            }
        }
        await refresh()
    }

    /// Deletes several restore points in one operation.
    ///
    /// Reported as one outcome rather than one alert per point, and it does not
    /// stop at the first failure: a point that will not go is named at the end
    /// while the rest are still removed. Stopping halfway would leave the user
    /// to work out which of the twelve they picked actually went.
    func deletePoints(named names: Set<String>, on machineID: VirtualMachine.ID) async {
        guard let vm = machine(machineID), let library, !names.isEmpty else { return }

        let targets = vm.snapshots.filter { names.contains($0.name) }
        var removed = 0
        var failed: [String] = []

        await run(Activity(
            title: String(localized: "Deleting \(targets.count) restore points…")
        )) {
            for (index, snapshot) in targets.enumerated() {
                await self.setActivity(Activity(
                    title: String(localized: "Deleting \(targets.count) restore points…"),
                    detail: String(localized: "\(index + 1) of \(targets.count): “\(snapshot.name)”")
                ))
                do {
                    try await library.delete(snapshot, on: vm)
                    removed += 1
                    await MainActor.run {
                        if self.baselines[vm.recordKey] == snapshot.name { self.setBaseline(nil, for: vm) }
                        self.updateLineage(for: vm.id) { $0.forget(snapshot.name) }
                        self.forgetAutomaticBackup(named: snapshot.name, for: vm.recordKey)
                        self.setNote(nil, for: snapshot, in: vm)
                    }
                } catch {
                    failed.append(snapshot.name)
                }
            }
        }

        await refresh()

        if failed.isEmpty {
            lastOutcome = String(localized: "Deleted \(removed) restore points.")
        } else {
            alert = AppAlert(
                title: String(localized: "\(failed.count) could not be deleted"),
                message: String(localized: "Removed \(removed). These are still there: \(failed.formatted(.list(type: .and))).")
            )
        }
    }

    // MARK: - Read-only tools

    func verifyDisks(on machineID: VirtualMachine.ID) async {
        guard let vm = machine(machineID), let library else { return }
        var lines: [String] = []
        await run(Activity(
            title: String(localized: "Checking “\(vm.name)”…"),
            detail: String(localized: "Reading every block of \(vm.disks.count == 1 ? "the disk" : "\(vm.disks.count) disks"). Nothing is modified."),
            isCancellable: false
        )) {
            let reports = await library.check(vm)
            lines = reports.map { report in
                let mark = report.isHealthy ? "✔︎" : "✖︎"
                return "\(mark) \(report.disk.fileName)\n\(report.detail)"
            }
        }
        if !lines.isEmpty { sheet = .checkReport(lines) }
    }

    func exportSnapshot(_ snapshot: Snapshot, on machineID: VirtualMachine.ID) async {
        guard let vm = machine(machineID), let library,
              let disk = snapshot.presentOn.first else { return }

        let panel = NSSavePanel()
        panel.title = String(localized: "Export Restore Point")

        // On a multi-disk machine this writes one disk, not the machine. Saying
        // so here is the difference between a useful export and someone
        // believing they have a complete copy that they do not.
        let isMultiDisk = vm.disks.count > 1
        let diskLabel = isMultiDisk
            ? (vm.disks.firstIndex(of: disk).map { disk.displayName(index: $0, total: vm.disks.count) } ?? disk.fileName)
            : ""

        panel.message = isMultiDisk
            ? String(localized: "Writes “\(snapshot.name)” from \(diskLabel) as a standalone qcow2 image. “\(vm.name)” has \(vm.disks.count) disks — this exports one of them, and only reads the original.")
            : String(localized: "Writes “\(snapshot.name)” as a standalone qcow2 image. The machine is only read.")

        panel.nameFieldStringValue = isMultiDisk
            ? "\(vm.name) — \(snapshot.name) — \(diskLabel).qcow2"
            : "\(vm.name) — \(snapshot.name).qcow2"

        guard panel.runModal() == .OK, let url = panel.url else { return }

        await run(Activity(
            title: String(localized: "Exporting “\(snapshot.name)”…"),
            detail: String(localized: "This writes a full copy and can take a while.")
        )) {
            try await library.exportSnapshot(snapshot, from: disk, to: url)
            await MainActor.run {
                self.lastOutcome = String(localized: "Exported to \(url.lastPathComponent).")
            }
        }
    }

    /// Exports the whole machine, frozen at one restore point, as something the
    /// other side can actually start.
    ///
    /// The bare disk export above answers "give me this image". This answers the
    /// question people actually ask — "give me this machine, as it was, so I can
    /// run it somewhere else" — and those are not the same file.
    func exportMachine(
        _ snapshot: Snapshot,
        on machineID: VirtualMachine.ID,
        asArchive: Bool
    ) async {
        guard let vm = machine(machineID), let library else { return }

        guard snapshot.isComplete else {
            alert = AppAlert(
                title: String(localized: "“\(snapshot.name)” is not on every disk"),
                message: String(localized: "Exporting it would produce a machine whose disks sit at different points in time, which would not boot cleanly. Nothing was written.")
            )
            return
        }

        let panel = NSSavePanel()
        panel.title = String(localized: "Export Machine")
        panel.message = asArchive
            ? String(localized: "Writes “\(vm.name)” as it was at “\(snapshot.name)”, packed into one archive. Unpack it on the other Mac and open it with UTM. The original is only read.")
            : String(localized: "Writes “\(vm.name)” as it was at “\(snapshot.name)” as a complete machine UTM can open. The original is only read.")
        panel.nameFieldStringValue = asArchive
            ? "\(vm.name) — \(snapshot.name).utm.zip"
            : "\(vm.name) — \(snapshot.name).utm"

        guard panel.runModal() == .OK, let chosen = panel.url else { return }

        // The bundle is built first either way; the archive is packed from it.
        let bundleURL = asArchive
            ? chosen.deletingPathExtension()   // strips .zip, leaving …utm
            : chosen

        await run(Activity(
            title: String(localized: "Exporting “\(vm.name)”…"),
            detail: String(localized: "Every disk is rewritten at this point. Expect this to take a while on a large machine.")
        )) {
            try await library.exportBundle(
                snapshot, on: vm, to: bundleURL,
                // Compressing inside the qcow2 is what makes the result small.
                // Doing it here rather than only zipping afterwards also keeps
                // the unpacked machine small on the far side.
                compressDisks: true
            ) { message in
                await self.setActivity(Activity(title: String(localized: "Exporting “\(vm.name)”…"), detail: message))
            }

            if asArchive {
                await self.setActivity(Activity(
                    title: String(localized: "Packing the archive…"),
                    detail: String(localized: "The finished machine is being wrapped into a single file.")
                ))
                try await VMLibrary.compress(bundle: bundleURL, to: chosen)
            }

            await MainActor.run {
                self.lastOutcome = String(localized: "Exported to \(chosen.lastPathComponent).")
            }
        }
    }

    // MARK: - UTM's library

    /// Hands a bundle to UTM so it appears in its library.
    ///
    /// Until UTM knows a machine, this app cannot start or stop it: every
    /// command goes through UTM's scripting interface and is addressed by the
    /// identifier UTM has on file. Snapshots never needed UTM, which is why a
    /// bundle in Downloads is fully usable here and still cannot be started —
    /// a split that reads as an arbitrary restriction until you know it.
    ///
    /// Deliberately an explicit action rather than something Start does behind
    /// the scenes. It changes UTM's library, not just this window, and the user
    /// should be the one deciding that.
    func addToUTM(_ machineID: VirtualMachine.ID) async {
        guard let vm = machine(machineID), vm.canBeAddedToUTM, let uuid = vm.uuid else { return }

        UTMControl.reveal(bundleAt: vm.url)

        await run(Activity(
            title: String(localized: "Adding “\(vm.name)” to UTM…"),
            detail: String(localized: "UTM is opening the machine. Confirm there if it asks.")
        )) {
            try await self.waitUntilRegistered(uuid: uuid, at: vm.url)
        }
        await refresh()

        if machine(machineID)?.isRegisteredWithUTM == true {
            lastOutcome = String(localized: "“\(vm.name)” is in UTM's library — it can be started from here now.")
        }
    }

    /// Polls UTM's library until it lists this identifier at this folder.
    ///
    /// Matched on the path, not merely on the identifier turning up: UTM may
    /// import a copy elsewhere, and treating that as success would leave the
    /// user with a Start button that drives a different machine.
    private func waitUntilRegistered(
        uuid: String, at url: URL, timeout: TimeInterval = 45
    ) async throws {
        let wanted = url.standardizedFileURL.path
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let entry = UTMRegistry.entries()?[uuid],
               URL(fileURLWithPath: entry.path).standardizedFileURL.path == wanted {
                return
            }
            try? await Task.sleep(for: .seconds(1))
        }
        throw AppError.timedOut(
            what: String(localized: "Waiting for UTM to add the machine"), seconds: Int(timeout)
        )
    }

    /// Turns a restore point into a machine of its own, beside the original.
    ///
    /// The export writes the same thing to a place you pick, for carrying
    /// elsewhere. This is the other half of that idea: keep the branch you are
    /// on *and* the one you were about to try, as two machines you can run side
    /// by side. Which is the thing a restore point cannot give you — rolling
    /// back is a move, not a copy.
    ///
    /// Lands in the original's folder and, when asked, goes straight into UTM's
    /// library so it can be started immediately.
    func createMachine(
        from snapshot: Snapshot,
        on machineID: VirtualMachine.ID,
        named newName: String,
        addingToUTM: Bool
    ) async {
        guard let vm = machine(machineID), let library else { return }

        let destination = vm.url.deletingLastPathComponent()
            .appendingPathComponent(VMLibrary.folderName(for: newName))

        guard !FileManager.default.fileExists(atPath: destination.path) else {
            alert = AppAlert(
                title: String(localized: "“\(destination.lastPathComponent)” already exists"),
                message: String(localized: "There is already a folder with that name beside “\(vm.name)”. Pick a different name.")
            )
            return
        }

        await run(Activity(
            title: String(localized: "Creating “\(newName)”…"),
            detail: String(localized: "Every disk is rewritten at “\(snapshot.name)”. Expect this to take a while on a large machine.")
        )) {
            try await library.exportBundle(
                snapshot, on: vm, to: destination, compressDisks: false
            ) { message in
                await self.setActivity(Activity(title: String(localized: "Creating “\(newName)”…"), detail: message))
            }
            try VMLibrary.setName(newName, in: destination)
        }

        await refresh()

        guard machines.contains(where: { $0.id == destination.standardizedFileURL.path }) else { return }
        selectedMachineID = destination.standardizedFileURL.path
        lastOutcome = String(localized: "“\(newName)” is ready, frozen at “\(snapshot.name)”.")

        if addingToUTM {
            await addToUTM(destination.standardizedFileURL.path)
        }
    }

    /// Renames a machine, its folder, or both.
    ///
    /// Everything this app remembers is filed under the identifier inside the
    /// bundle, so a rename never orphans a baseline, a branch record or a note
    /// — they follow the machine wherever it goes and whatever it is called.
    func rename(
        _ machineID: VirtualMachine.ID,
        to newName: String,
        renamingFolder: Bool
    ) async {
        guard let vm = machine(machineID), let library else { return }

        var moved: URL?
        await run(Activity(title: String(localized: "Renaming “\(vm.name)”…"))) {
            moved = try await library.rename(vm, to: newName, renamingFolder: renamingFolder)
        }
        await refresh()

        // Follow the machine to its new folder, so the rename does not look
        // like the machine vanished from the list.
        if let moved, moved.standardizedFileURL != vm.url.standardizedFileURL {
            selectedMachineID = moved.standardizedFileURL.path
        }
        if machines.contains(where: { $0.id == (moved?.path ?? vm.id) }) {
            lastOutcome = String(localized: "Renamed to “\(newName)”.")
        }
    }

    /// Moves a machine's whole folder to the Trash.
    ///
    /// The Trash rather than a delete, deliberately: this removes every restore
    /// point along with the machine, and the one thing that makes that
    /// recoverable is that macOS keeps it until the user empties it.
    ///
    /// Gated on the same check as a write. A folder whose disks a QEMU process
    /// still holds must not be moved out from under it, and "is anything using
    /// this" is exactly the question `verifyWritable` answers — including the
    /// paused and suspended states that a process listing alone would miss.
    func moveToTrash(_ machineID: VirtualMachine.ID) async {
        guard let vm = machine(machineID), let library else { return }

        await run(Activity(title: String(localized: "Moving “\(vm.name)” to the Trash…"))) {
            try await library.verifyWritable(vm)

            var trashed: NSURL?
            try FileManager.default.trashItem(at: vm.url, resultingItemURL: &trashed)

            await MainActor.run {
                self.lastOutcome = String(localized: "“\(vm.name)” is in the Trash. Nothing is gone until you empty it.")
            }
        }
        await refresh()
    }

    // MARK: - Navigation helpers

    /// Opens Finder on the folder UTM has on file for this identifier.
    func revealLibraryOriginal(of vm: VirtualMachine) {
        guard let path = vm.utmLibraryPath else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    func revealInFinder(_ vm: VirtualMachine) {
        NSWorkspace.shared.activateFileViewerSelecting([vm.url])
    }

    func openUTM() { UTMControl.open() }

    /// Jumps to this machine in UTM — for everything this app deliberately does
    /// not do: editing hardware, ports, shared folders, display settings.
    ///
    /// Falls back to opening UTM plainly for a bundle UTM does not manage,
    /// because handing it that bundle would import it as a second machine.
    func openInUTM(_ vm: VirtualMachine) {
        guard vm.isRegisteredWithUTM else { return openUTM() }
        UTMControl.reveal(bundleAt: vm.url)
    }

    func openPrivacySettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders")
    }

    func openAutomationSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")
    }

    private func open(_ string: String) {
        if let url = URL(string: string) { NSWorkspace.shared.open(url) }
    }

    // MARK: - Names

    func suggestedSnapshotName() -> String {
        guard let vm = selectedMachine else { return String(localized: "State") }
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.setLocalizedDateFormatFromTemplate("d MMM yyyy HH:mm")
        return uniqueName(base: formatter.string(from: Date()), in: vm)
    }

    func validationMessage(for name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return String(localized: "Give the restore point a name.") }
        if trimmed.count > 100 { return String(localized: "That name is too long.") }
        if Int(trimmed) != nil {
            // qemu-img resolves a bare number as a snapshot ID before trying it
            // as a name, so a restore point called "2" can shadow a different
            // one entirely.
            return String(localized: "The name cannot be digits only — qemu would read it as an internal ID.")
        }
        if trimmed.lowercased() == VMLibrary.suspendTag {
            return String(localized: "This name is reserved by UTM.")
        }
        if let vm = selectedMachine, vm.snapshots.contains(where: { $0.name == trimmed }) {
            return String(localized: "A restore point with this name already exists.")
        }
        return nil
    }

    private func uniqueName(base: String, in vm: VirtualMachine) -> String {
        let existing = Set(vm.snapshots.map(\.name))
        guard existing.contains(base) else { return base }
        var index = 2
        while existing.contains("\(base) (\(index))") { index += 1 }
        return "\(base) (\(index))"
    }

    // MARK: - Plumbing

    private func setActivity(_ new: Activity) async {
        await MainActor.run { self.activity = new }
    }

    /// One place where every long operation gets its progress overlay, its
    /// error handling and its guarantee that the overlay comes down again.
    private func run(_ initial: Activity, _ work: @escaping () async throws -> Void) async {
        activity = initial
        lastOutcome = nil
        defer { activity = nil }
        do {
            try await work()
        } catch {
            present(error)
        }
    }

    private func present(_ error: Error) {
        if let appError = error as? AppError {
            alert = AppAlert(
                title: appError.errorDescription ?? String(localized: "Something went wrong"),
                message: appError.recoverySuggestion ?? "",
                isCritical: appError.isCritical
            )
        } else {
            alert = AppAlert(
                title: String(localized: "Something went wrong"),
                message: error.localizedDescription
            )
        }
    }
}

extension VirtualMachine {
    /// Copy with a fresh run state, for the poll that updates status without a
    /// full rescan.
    func with(state newState: RunState) -> VirtualMachine {
        VirtualMachine(
            url: url, uuid: uuid, name: name, backend: backend, disks: disks,
            snapshots: snapshots, state: newState, isRegisteredWithUTM: isRegisteredWithUTM,
            hasAccess: hasAccess, hasUnreadableDisk: hasUnreadableDisk,
            usedBytes: usedBytes, virtualBytes: virtualBytes
        )
    }
}
