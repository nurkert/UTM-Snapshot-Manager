# Security model

This document states what the application guarantees, how each guarantee is enforced, and
where it stops. It is written to be checked rather than believed: every mechanism names the
file it lives in, and the known limits are listed rather than omitted.

The subject matter is destructive. Rolling a virtual disk back discards everything the guest
did since the restore point, and there is no undo. The design consequence is a single rule
that the rest of this document elaborates:

> An operation that cannot prove it is safe does not run.

Not knowing is treated as a reason to stop, never as permission to continue.

---

## 1. No write to a machine that is not shut down

### Why it matters

Writing to a disk that a guest is using corrupts its file system. The guest holds unwritten
data in memory, and an image captured mid-write is internally inconsistent. A **paused**
machine is exactly as dangerous as a running one — the process still holds the image open —
and a **suspended** machine has its memory state parked inside the image, so rolling the disk
back leaves UTM resuming stale memory onto changed data.

### How it is enforced

Four independent sources, evaluated in `VMLibrary.resolveState` and re-checked in
`VMLibrary.verifyWritable`:

| Source | Answers | Notes |
| --- | --- | --- |
| UTM scripting interface | running / paused / stopped | The only source that distinguishes running from paused. |
| Process table | is any process holding this image | Matched on the image path, so a duplicate cannot be mistaken for the original. |
| The image itself | is a `suspend` snapshot present | Read directly from the disk immediately before writing. |
| `qemu-img` image lock | final backstop | Write commands deliberately omit `-U`; if another process holds the lock, the write fails. |

`RunState.allowsDiskWrites` is true for exactly one value, `.stopped`. Every other value —
including `.unknown` — blocks. A failed process-table read yields `.unknown` rather than an
empty result, because "I could not check" must not resemble "nothing is running".

The state is polled every few seconds while the window is active, so a machine started in UTM
disables the controls here within seconds, and it is fetched again immediately before the
write itself.

### Where it stops

- **A window remains between the final check and the first byte written.** It is small, but
  it exists. What closes it is `qemu-img`'s own image lock, which is a property of the tool
  rather than of this application.
- **The process-table check is a heuristic.** It matches on the image path and file name; a
  process referring to the image in some other way would not be recognised. It is a backstop
  for machines UTM does not manage, not a primary source.
- **If both UTM and the process table are unavailable**, machines UTM is known to manage are
  reported as `.unknown` and blocked. Machines UTM does not manage fall back to the image
  lock alone.

---

## 2. No action on the wrong machine

### Why it matters

Duplicating a `.utm` bundle copies its `config.plist`, including the identifier UTM uses.
A backup in `Downloads` is therefore indistinguishable from the machine UTM is running — by
identifier. Acting on the identifier alone means "Start" on the copy starts the original, and
"Reset to Baseline" on the copy shuts the original down.

### How it is enforced

`VMLibrary.isManagedByUTM` decides identity on the **path UTM recorded in its own registry**,
never on the identifier:

```swift
guard let uuid = bundle.uuid, let registry, let entry = registry[uuid] else { return false }
return URL(fileURLWithPath: entry.path).standardizedFileURL.path
    == bundle.url.standardizedFileURL.path
```

If the registry cannot be read, no bundle claims to be the managed one. The failure mode is a
disabled Start button, not an action on someone else's machine.

The safety question of section 1 is deliberately **not** gated on this. Proving library
membership needs a file macOS can refuse to hand over; asking "is this running" needs only the
identifier. Asking too widely costs a refused click; asking too narrowly costs a file system.

### Where it stops

Registry access is subject to macOS consent. Denied, the application loses machine control
entirely — by design, rather than falling back to a guess.

---

## 3. No silent partial write

### Why it matters

A machine with several disks must be rolled back as a unit. Disks at different points in time
produce a guest that boots into an inconsistent state, and the failure surfaces later as
data corruption rather than as an error.

### How it is enforced

| Operation | Guarantee |
| --- | --- |
| **Create** | On failure, snapshots already written to earlier disks are removed. If that cleanup itself fails, the result is reported as a stranded restore point — explicitly distinguished from a failed restore, because the machine's own state was never touched and the recovery advice is different. |
| **Restore** | Completeness is verified against every image *before* the first write. A caller claiming a restore point is complete is not believed; the disks are re-read. A failure partway is reported as critical, naming which disks changed. |
| **Delete** | A partial delete is reported as such, naming the disks it was removed from and the one it was not. |
| **All writes** | The disk list is re-read from `config.plist` immediately beforehand. Acting on a list from the previous scan would silently skip a disk added since. |

On multi-disk machines the safety snapshot before a restore is mandatory, because a rollback
that fails partway cannot be undone and that snapshot is the only way back.

### Where it stops

A rollback cannot be transactional across several files. Verification happens before anything
is written, and failure is reported loudly, but a disk that fails after another has already
been rolled back leaves the machine inconsistent. This is a property of the underlying
mechanism, not something the application can hide.

---

## 4. No shell injection

Every external command is invoked with an argument array through `Process.arguments`, never a
shell string. A restore point named `; rm -rf ~` is stored and displayed as that text; there
is a test asserting it is stored verbatim and that the home directory survives.

Interpolation into AppleScript source is restricted to values that parse as a UUID
(`UTMControl.isValidUUID`). Machine names, which are user-controlled and may contain quotes,
never enter a script.

---

## 5. Resource exhaustion

Every external command carries a deadline and is terminated if it overruns; the timeout path
deliberately does not wait on the process afterwards, since a process wedged in an
uninterruptible kernel wait would defeat the deadline it is meant to enforce.

Scanning inspects at most six machines concurrently. Each external command occupies a
dispatch worker plus two more draining its pipes, and the global pool holds 64; one task per
bundle starved the pool on machines with many bundles, at which point finished commands
reported timeouts and the application declared their disks unreadable.

---

## Reporting a vulnerability

Open an issue at
[nurkert/UTM-Snapshot-Manager/issues](https://github.com/nurkert/UTM-Snapshot-Manager/issues).
For anything you would rather not discuss publicly, note that the repository is a personal
project without a dedicated security contact; say so in the issue and a private channel can be
arranged.

Findings that demonstrate a write to a machine that was not shut down, or an action landing on
a machine other than the one named in the dialog, are the highest-value reports.
