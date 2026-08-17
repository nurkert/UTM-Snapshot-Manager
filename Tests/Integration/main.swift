import Foundation

// Integration test: exercises the real write paths against real qcow2 images.

func say(_ s: String) { fputs(s + "\n", stderr) }

guard let qemuImg = QemuImg.locate() else {
    say("qemu-img not found"); exit(1)
}

let fm = FileManager.default
let lib = VMLibrary(qemuImgPath: qemuImg)
let root = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("usm-itest-\(ProcessInfo.processInfo.processIdentifier)")

final class Tally: @unchecked Sendable {
    var passed = 0
    var failed = 0
    func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        if ok { passed += 1; say("  PASS  \(name)") }
        else { failed += 1; say("  FAIL  \(name)  \(detail)") }
    }
}
let t = Tally()

@discardableResult
func runTool(_ path: String, _ args: [String]) throws -> String {
    let r = ProcessRunner.runSync(path, args, timeout: 60)
    guard r.ok else {
        throw NSError(domain: "tool", code: 1, userInfo: [NSLocalizedDescriptionKey: r.message])
    }
    return r.stdout
}

/// Builds a fake `.utm` bundle, including a CD-ROM that is itself a qcow2 —
/// which a directory scan would happily mistake for a system disk.
func makeBundle(name: String, diskCount: Int) throws -> URL {
    let bundle = root.appendingPathComponent("\(name).utm")
    let data = bundle.appendingPathComponent("Data")
    try fm.createDirectory(at: data, withIntermediateDirectories: true)

    try runTool(qemuImg, ["create", "-f", "qcow2",
                          data.appendingPathComponent("installer.qcow2").path, "64M"])
    var drives: [[String: Any]] = [[
        "ImageType": "CD", "Identifier": "cd-0", "ImageName": "installer.qcow2",
        "Interface": "USB", "ReadOnly": true
    ]]

    for i in 0..<diskCount {
        let file = "disk-\(i).qcow2"
        try runTool(qemuImg, ["create", "-f", "qcow2",
                              data.appendingPathComponent(file).path, "64M"])
        drives.append([
            "ImageType": "Disk", "Identifier": "disk-\(i)", "ImageName": file,
            "Interface": "VirtIO", "ReadOnly": false
        ])
    }

    let plist: [String: Any] = [
        "Backend": "QEMU",
        "ConfigurationVersion": 4,
        "Information": ["Name": name, "UUID": UUID().uuidString],
        "Drive": drives
    ]
    try PropertyListSerialization
        .data(fromPropertyList: plist, format: .xml, options: 0)
        .write(to: bundle.appendingPathComponent("config.plist"))
    return bundle
}

func machine(from bundle: URL) -> VirtualMachine {
    let info = VMDiscovery.read(bundle: bundle)
    return VirtualMachine(
        url: info.url, uuid: info.uuid, name: info.name, backend: info.backend,
        disks: info.disks, snapshots: [], state: .stopped, isRegisteredWithUTM: false,
        hasAccess: true, hasUnreadableDisk: false, usedBytes: 0, virtualBytes: 0
    )
}

func names(on disk: DiskImage) async -> Set<String> {
    guard let info = await QemuImg.info(qemuImg: qemuImg, disk: disk.url) else { return [] }
    return Set((info.snapshots ?? []).map(\.name))
}

func point(_ name: String, on disks: [DiskImage], missing: [DiskImage] = []) -> Snapshot {
    Snapshot(name: name, date: Date(), stateBytes: 0, presentOn: disks, missingFrom: missing)
}

let sem = DispatchSemaphore(value: 0)
Task {
    defer { sem.signal() }
    try? fm.removeItem(at: root)
    try! fm.createDirectory(at: root, withIntermediateDirectories: true)

    // ---------------------------------------------------------------------
    say("\n[1] Disks come from config.plist, not from a directory scan")
    let single = try! makeBundle(name: "Single", diskCount: 1)
    let info = VMDiscovery.read(bundle: single)
    t.check("a qcow2 CD-ROM is not treated as a disk", info.disks.count == 1,
            "got \(info.disks.map(\.fileName))")
    t.check("name and UUID read from the config", info.name == "Single" && info.uuid != nil)

    // ---------------------------------------------------------------------
    say("\n[2] Create, restore and delete on a single disk")
    let vm = machine(from: single)
    do {
        try await lib.createSnapshot(named: "base", on: vm)
        t.check("restore point created", await names(on: vm.disks[0]).contains("base"))
    } catch { t.check("restore point created", false, "\(error)") }

    do {
        try await lib.restore(point("base", on: vm.disks), on: vm)
        t.check("restore succeeded", true)
    } catch { t.check("restore succeeded", false, "\(error)") }

    do {
        try await lib.delete(point("base", on: vm.disks), on: vm)
        t.check("restore point deleted", await !names(on: vm.disks[0]).contains("base"))
    } catch { t.check("restore point deleted", false, "\(error)") }

    // ---------------------------------------------------------------------
    say("\n[3] Multi-disk machines are handled as one unit")
    let multi = try! makeBundle(name: "Multi", diskCount: 3)
    let mvm = machine(from: multi)
    t.check("three disks detected", mvm.disks.count == 3, "got \(mvm.disks.count)")

    do {
        try await lib.createSnapshot(named: "all", on: mvm)
        var everywhere = true
        for d in mvm.disks where await !names(on: d).contains("all") { everywhere = false }
        t.check("written to every disk", everywhere)
    } catch { t.check("written to every disk", false, "\(error)") }

    // ---------------------------------------------------------------------
    say("\n[4] An incomplete restore point is refused before anything is written")
    try? await QemuImg.deleteSnapshot(qemuImg: qemuImg, disk: mvm.disks[2], name: "all")

    let incomplete = point("all", on: [mvm.disks[0], mvm.disks[1]], missing: [mvm.disks[2]])
    t.check("the model marks it incomplete", !incomplete.isComplete)
    do {
        try await lib.restore(incomplete, on: mvm)
        t.check("refused", false, "it went through")
    } catch let e as AppError {
        if case .incompleteSnapshot = e { t.check("refused with the right error", true) }
        else { t.check("refused with the right error", false, "\(e)") }
    } catch { t.check("refused with the right error", false, "\(error)") }

    // A caller claiming completeness must not be believed.
    do {
        try await lib.restore(point("all", on: mvm.disks), on: mvm)
        t.check("a false 'complete' claim is caught by the disk re-check", false, "it went through")
    } catch { t.check("a false 'complete' claim is caught by the disk re-check", true) }

    // ---------------------------------------------------------------------
    say("\n[5] A failed create rolls the other disks back")
    let rb = try! makeBundle(name: "Rollback", diskCount: 3)
    let rvm = machine(from: rb)
    try! fm.setAttributes([.posixPermissions: 0o444], ofItemAtPath: rvm.disks[2].url.path)
    do {
        try await lib.createSnapshot(named: "doomed", on: rvm)
        t.check("the create failed as set up", false, "it succeeded unexpectedly")
    } catch let e as AppError {
        if case .rolledBack = e { t.check("reported as rolled back", true) }
        else { t.check("reported as rolled back", false, "\(e)") }
    } catch { t.check("reported as rolled back", false, "\(error)") }

    var leftovers: [String] = []
    for d in [rvm.disks[0], rvm.disks[1]] where await names(on: d).contains("doomed") {
        leftovers.append(d.fileName)
    }
    t.check("no half-made restore point survives", leftovers.isEmpty, "left on \(leftovers)")
    try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: rvm.disks[2].url.path)

    // ---------------------------------------------------------------------
    say("\n[6] UTM's reserved suspend state blocks writes")
    let susp = try! makeBundle(name: "Susp", diskCount: 1)
    let svm = machine(from: susp)
    try! await QemuImg.createSnapshot(qemuImg: qemuImg, disk: svm.disks[0], name: "suspend")
    do {
        try await lib.createSnapshot(named: "after", on: svm)
        t.check("a suspended machine is refused", false, "it went through")
    } catch let e as AppError {
        if case .notStopped(_, let st) = e, st == .suspended {
            t.check("a suspended machine is refused", true)
        } else { t.check("a suspended machine is refused", false, "\(e)") }
    } catch { t.check("a suspended machine is refused", false, "\(error)") }

    // ---------------------------------------------------------------------
    say("\n[7] Read-only tools")
    let reports = await lib.check(vm)
    t.check("integrity check reports healthy", reports.allSatisfy(\.isHealthy),
            reports.map(\.detail).joined(separator: " | "))

    try? await QemuImg.createSnapshot(qemuImg: qemuImg, disk: vm.disks[0], name: "exportme")
    let out = root.appendingPathComponent("exported.qcow2")
    do {
        try await lib.exportSnapshot(point("exportme", on: vm.disks), from: vm.disks[0], to: out)
        let ok = await QemuImg.info(qemuImg: qemuImg, disk: out) != nil
        t.check("export produced a readable image", ok)
    } catch { t.check("export produced a readable image", false, "\(error)") }

    // ---------------------------------------------------------------------
    say("\n[8] Names with characters that would break a shell")
    let awkward = "; rm -rf ~ && echo \"pwned\" 'x'"
    do {
        try await lib.createSnapshot(named: awkward, on: vm)
        t.check("a hostile name is stored verbatim, not executed",
                await names(on: vm.disks[0]).contains(awkward))
        t.check("home directory still intact",
                fm.fileExists(atPath: fm.homeDirectoryForCurrentUser.path))
        try await lib.delete(point(awkward, on: vm.disks), on: vm)
    } catch { t.check("a hostile name is stored verbatim, not executed", false, "\(error)") }

    // ---------------------------------------------------------------------
    say("\n[9] Telling a duplicated bundle from the machine UTM manages")
    // A copied .utm keeps the original's UUID, so identity alone cannot decide
    // which one UTM would start.
    let sharedUUID = UUID().uuidString.uppercased()
    let originalPath = root.appendingPathComponent("Original.utm")
    let copyPath = root.appendingPathComponent("Copy.utm")

    func bundleInfo(_ url: URL) -> VMDiscovery.BundleInfo {
        VMDiscovery.BundleInfo(url: url, uuid: sharedUUID, name: "Shared",
                               backend: .qemu, disks: [], isReadable: true)
    }
    let original = bundleInfo(originalPath)
    let copy = bundleInfo(copyPath)
    let registry = [sharedUUID: UTMRegistry.Entry(
        uuid: sharedUUID, path: originalPath.path, name: "Shared", isSuspended: false
    )]

    t.check("the bundle at UTM's recorded path is managed",
            VMLibrary.isManagedByUTM(bundle: original, registry: registry))

    t.check("a copy with the same UUID elsewhere is not",
            !VMLibrary.isManagedByUTM(bundle: copy, registry: registry))

    // The regression this replaced: a lone copy found by an incomplete scan
    // looked unique, and "UTM knows this UUID" was taken as proof of identity.
    // Identity now requires the recorded path, so an unreadable registry can
    // never produce a false claim, however the scan went.
    t.check("without the registry nothing claims to be managed",
            !VMLibrary.isManagedByUTM(bundle: original, registry: nil)
            && !VMLibrary.isManagedByUTM(bundle: copy, registry: nil))

    t.check("a UUID the registry does not list is not managed",
            !VMLibrary.isManagedByUTM(bundle: original, registry: [:]))

    // Trailing slashes and symlink-free normalisation must not defeat the
    // path comparison.
    let oddlyWritten = VMDiscovery.BundleInfo(
        url: URL(fileURLWithPath: root.path + "/./Original.utm"), uuid: sharedUUID,
        name: "Shared", backend: .qemu, disks: [], isReadable: true
    )
    t.check("the path comparison is normalised",
            VMLibrary.isManagedByUTM(bundle: oddlyWritten, registry: registry))

    // ---------------------------------------------------------------------
    say("\n[9b] A copy is not reported as running just because the original is")
    // The defect this covers: two Debian bundles in different folders, one
    // running, both shown as running. Two separate causes, both real.

    // (a) UTM names disk images after a UUID, so a copied bundle has a disk with
    //     the *same file name*. Matching a running process on the bare name
    //     therefore matched the copy too.
    let liveBundle = try! makeBundle(name: "Live", diskCount: 1)
    let copyBundle = try! makeBundle(name: "Idle", diskCount: 1)
    let liveVM = machine(from: liveBundle)
    let copyVM = machine(from: copyBundle)

    // Give both bundles a disk with an identical file name, as UTM would.
    let sharedName = "\(UUID().uuidString.uppercased()).qcow2"
    func renamedDisk(_ vm: VirtualMachine) -> DiskImage {
        let target = vm.disks[0].url.deletingLastPathComponent()
            .appendingPathComponent(sharedName)
        try? FileManager.default.moveItem(at: vm.disks[0].url, to: target)
        return DiskImage(identifier: vm.disks[0].identifier, url: target,
                         interface: vm.disks[0].interface)
    }
    let liveDisk = renamedDisk(liveVM)
    let copyDisk = renamedDisk(copyVM)

    t.check("both bundles really do share a disk file name",
            liveDisk.url.lastPathComponent == copyDisk.url.lastPathComponent)

    // One QEMU, holding the live bundle's image by absolute path.
    let qemuLine = "/usr/bin/qemu-system-aarch64 -drive if=none,media=disk,"
        + "file.filename=\(liveDisk.url.path),discard=unmap"

    t.check("the machine whose image is open is in use",
            ProcessTable.diskUse(of: [liveDisk], commandLines: [qemuLine]) == .inUse)

    t.check("the copy with the same file name is free",
            ProcessTable.diskUse(of: [copyDisk], commandLines: [qemuLine]) == .free)

    t.check("an unreadable process table answers unknown, never free",
            ProcessTable.diskUse(of: [copyDisk], commandLines: nil) == .unknown)

    // (b) The run state is looked up by the identifier in config.plist, which a
    //     copy carries verbatim. Taking UTM's answer for a bundle UTM does not
    //     manage handed the original's state straight to the copy.
    t.check("the managed bundle takes UTM's running state",
            VMLibrary.resolveState(
                utmState: .running, isRegistered: true, hasSuspendState: false,
                diskUse: .free, utmAvailability: .ready
            ) == .running)

    t.check("an unmanaged copy does not inherit it",
            VMLibrary.resolveState(
                utmState: .running, isRegistered: false, hasSuspendState: false,
                diskUse: .free, utmAvailability: .ready
            ) == .stopped)

    // The copy is still caught when a process really does hold *its* image —
    // a QEMU started by hand, or one UTM has since lost track of.
    t.check("a process holding the copy's own image still marks it running",
            VMLibrary.resolveState(
                utmState: nil, isRegistered: false, hasSuspendState: false,
                diskUse: .inUse, utmAvailability: .ready
            ) == .running)

    // And an unmanaged bundle whose disks cannot be checked stays unknown,
    // which blocks every write. Not knowing is never a reason to unlock a disk.
    t.check("unmanaged and unverifiable stays unknown",
            VMLibrary.resolveState(
                utmState: nil, isRegistered: false, hasSuspendState: false,
                diskUse: .unknown, utmAvailability: .ready
            ) == .unknown)

    // ---------------------------------------------------------------------
    say("\n[9d] What to offer for a bundle UTM does not manage")
    // Adding a machine UTM has never seen is safe. Adding one whose identifier
    // UTM already has elsewhere would leave UTM unable to tell them apart.
    func membership(path: URL, registryPath: String?) -> VirtualMachine {
        VirtualMachine(
            url: path, uuid: sharedUUID, name: "Shared", backend: .qemu, disks: [],
            snapshots: [], state: .stopped,
            isRegisteredWithUTM: registryPath.map {
                URL(fileURLWithPath: $0).standardizedFileURL.path == path.standardizedFileURL.path
            } ?? false,
            utmLibraryPath: registryPath,
            hasAccess: true, hasUnreadableDisk: false, usedBytes: 0, virtualBytes: 0
        )
    }

    let unknownToUTM = membership(path: copyPath, registryPath: nil)
    t.check("a machine UTM has never seen can be added", unknownToUTM.canBeAddedToUTM)
    t.check("and is not treated as a copy", !unknownToUTM.isCopyOfLibraryMachine)

    let duplicate = membership(path: copyPath, registryPath: originalPath.path)
    t.check("a bundle whose identifier UTM has elsewhere is a copy",
            duplicate.isCopyOfLibraryMachine)
    t.check("and adding it is not offered", !duplicate.canBeAddedToUTM)

    let managed = membership(path: originalPath, registryPath: originalPath.path)
    t.check("the managed original is neither", !managed.canBeAddedToUTM && !managed.isCopyOfLibraryMachine)

    // ---------------------------------------------------------------------
    say("\n[9c] Exporting a whole machine at one restore point")
    // A bare qcow2 is not a machine. The export has to carry the configuration
    // too, and must not hand the copy the original's identifier.
    let exportSource = try! makeBundle(name: "Exportable", diskCount: 2)
    var exportVM = machine(from: exportSource)
    for disk in exportVM.disks {
        try! await QemuImg.createSnapshot(qemuImg: qemuImg, disk: disk, name: "shipped")
    }
    exportVM = machine(from: exportSource)
    let shipped = point("shipped", on: exportVM.disks)

    let exported = root.appendingPathComponent("Shipped.utm")
    try! await lib.exportBundle(shipped, on: exportVM, to: exported,
                                    compressDisks: true) { _ in }

    t.check("the export is a bundle, not a bare image",
            FileManager.default.fileExists(atPath: exported.appendingPathComponent("config.plist").path))

    let exportedPlist = try! PropertyListSerialization.propertyList(
        from: Data(contentsOf: exported.appendingPathComponent("config.plist")),
        format: nil) as! [String: Any]
    let exportedInfo = exportedPlist["Information"] as! [String: Any]

    t.check("the copy has its own identifier",
            (exportedInfo["UUID"] as? String)?.uppercased() != exportVM.uuid?.uppercased())

    t.check("the copy is named after the point it was taken from",
            (exportedInfo["Name"] as? String)?.contains("shipped") == true)

    let exportedDisks = machine(from: exported).disks
    t.check("every disk came along", exportedDisks.count == exportVM.disks.count)

    var allReadable = true
    for disk in exportedDisks {
        if await QemuImg.info(qemuImg: qemuImg, disk: disk.url) == nil { allReadable = false }
    }
    t.check("every exported disk is a readable qcow2", allReadable)

    // The point is baked into the image, so the copy carries no restore points
    // of its own — it *is* that state.
    var carried = Set<String>()
    for disk in exportedDisks { carried.formUnion(await names(on: disk)) }
    t.check("the exported disks are flat — the point is the current state",
            carried.isEmpty)

    var originalStillHas = true
    for disk in exportVM.disks where !(await names(on: disk)).contains("shipped") {
        originalStillHas = false
    }
    t.check("the original is untouched", originalStillHas)

    // A point missing from one disk would boot with the disks out of step.
    let lopsided = try! makeBundle(name: "Lopsided", diskCount: 2)
    let lopsidedVM = machine(from: lopsided)
    try! await QemuImg.createSnapshot(qemuImg: qemuImg, disk: lopsidedVM.disks[0], name: "half")
    let halfVM = machine(from: lopsided)
    let half = point("half", on: [halfVM.disks[0]], missing: [halfVM.disks[1]])
    var refused = false
    do {
        try await lib.exportBundle(half, on: halfVM,
                                       to: root.appendingPathComponent("Half.utm"),
                                       compressDisks: false) { _ in }
    } catch { refused = true }
    t.check("an incomplete point is refused", refused)
    t.check("and leaves nothing behind",
            !FileManager.default.fileExists(atPath: root.appendingPathComponent("Half.utm").path))

    // ---------------------------------------------------------------------
    say("\n[9e] Renaming a machine")
    let renamable = try! makeBundle(name: "Before", diskCount: 1)
    let renameVM = machine(from: renamable)
    try! await QemuImg.createSnapshot(qemuImg: qemuImg, disk: renameVM.disks[0], name: "kept")

    // Name only: the folder is untouched, so UTM's library entry still resolves.
    try! await lib.rename(renameVM, to: "After", renamingFolder: false)
    t.check("the display name changed", machine(from: renamable).name == "After")
    t.check("the folder did not", FileManager.default.fileExists(atPath: renamable.path))

    // Name and folder.
    let movedTo = try! await lib.rename(machine(from: renamable), to: "Renamed", renamingFolder: true)
    t.check("the folder moved", movedTo.lastPathComponent == "Renamed.utm")
    t.check("the old folder is gone", !FileManager.default.fileExists(atPath: renamable.path))
    t.check("both names agree", machine(from: movedTo).name == "Renamed")

    // Restore points live in the disks, so they travel with the folder.
    t.check("the restore point came along",
            await names(on: machine(from: movedTo).disks[0]).contains("kept"))

    // The identifier is what this app files its records under, so it must not
    // change — otherwise a rename would orphan the baseline and the tree.
    t.check("the identifier is unchanged",
            machine(from: movedTo).uuid == renameVM.uuid)

    // A collision must not clobber whatever is already there.
    let occupied = try! makeBundle(name: "Taken", diskCount: 1)
    var collided = false
    do { _ = try await lib.rename(machine(from: movedTo), to: "Taken", renamingFolder: true) }
    catch { collided = true }
    t.check("renaming onto an existing folder is refused", collided)
    t.check("and the existing folder is intact",
            FileManager.default.fileExists(atPath: occupied.appendingPathComponent("config.plist").path))

    // Characters that cannot survive in a path are replaced; the rest are kept.
    t.check("a slash cannot escape the folder name",
            !VMLibrary.folderName(for: "a/b").contains("/"))
    t.check("a leading dot cannot hide the machine",
            !VMLibrary.folderName(for: "...hidden").hasPrefix("."))
    t.check("ordinary punctuation is left alone",
            VMLibrary.folderName(for: "Debian 12 — clean") == "Debian 12 — clean.utm")

    // ---------------------------------------------------------------------
    say("\n[10] A disk added since the last scan stops the write")
    // The model carries the disk list from the last scan. Adding a disk in UTM
    // and then restoring must not roll back the known disks and quietly leave
    // the new one in the present.
    let grown = try! makeBundle(name: "Grown", diskCount: 1)
    let staleModel = machine(from: grown)
    try! await QemuImg.createSnapshot(qemuImg: qemuImg, disk: staleModel.disks[0], name: "before")

    // Add a second disk to the configuration behind the model's back.
    let data = grown.appendingPathComponent("Data")
    try! runTool(qemuImg, ["create", "-f", "qcow2",
                           data.appendingPathComponent("disk-1.qcow2").path, "64M"])
    var plist = try! PropertyListSerialization.propertyList(
        from: Data(contentsOf: grown.appendingPathComponent("config.plist")),
        format: nil) as! [String: Any]
    var drives = plist["Drive"] as! [[String: Any]]
    drives.append(["ImageType": "Disk", "Identifier": "disk-1", "ImageName": "disk-1.qcow2",
                   "Interface": "VirtIO", "ReadOnly": false])
    plist["Drive"] = drives
    try! PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        .write(to: grown.appendingPathComponent("config.plist"))

    t.check("the freshly read config now has two disks",
            VMDiscovery.read(bundle: grown).disks.count == 2)

    do {
        try await lib.createSnapshot(named: "after", on: staleModel)
        t.check("creating against a stale disk list is refused", false, "it went through")
    } catch let e as AppError {
        if case .diskLayoutChanged = e { t.check("creating against a stale disk list is refused", true) }
        else { t.check("creating against a stale disk list is refused", false, "\(e)") }
    } catch { t.check("creating against a stale disk list is refused", false, "\(error)") }

    do {
        try await lib.restore(point("before", on: staleModel.disks), on: staleModel)
        t.check("restoring against a stale disk list is refused", false, "it went through")
    } catch let e as AppError {
        if case .diskLayoutChanged = e { t.check("restoring against a stale disk list is refused", true) }
        else { t.check("restoring against a stale disk list is refused", false, "\(e)") }
    } catch { t.check("restoring against a stale disk list is refused", false, "\(error)") }

    // ---------------------------------------------------------------------
    say("\n[11] The safeguard against a genuinely running machine")
    // Needs a real, running machine, so it is opt-in rather than hardcoded to
    // one developer's Mac:
    //   USM_RUNNING_VM="/path/to/Machine.utm" Scripts/run-tests.sh
    let realPath = ProcessInfo.processInfo.environment["USM_RUNNING_VM"]
    let real = URL(fileURLWithPath: realPath ?? "")
    if realPath != nil, fm.fileExists(atPath: real.path) {
        let rvm2 = machine(from: real)
        let lines = await ProcessTable.qemuCommandLines()
        let use = ProcessTable.diskUse(of: rvm2.disks, commandLines: lines)
        say("      observed disk use: \(use)")
        if use == .inUse {
            do {
                try await lib.verifyWritable(rvm2)
                t.check("a running machine is refused", false, "verifyWritable let it through")
            } catch { t.check("a running machine is refused", true) }
        } else {
            say("      (not running right now — this check needs a running VM)")
        }
    } else {
        say("      (skipped — set USM_RUNNING_VM to a running machine's .utm bundle)")
    }

    try? fm.removeItem(at: root)
}
sem.wait()

say("\n=====================================")
say("  \(t.passed) passed, \(t.failed) failed")
say("=====================================")
exit(t.failed == 0 ? 0 : 1)
