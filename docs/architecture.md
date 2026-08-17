# Architecture

A SwiftUI application for macOS 14 and newer, built with Xcode 26 against the macOS 26 SDK.
The Xcode project is generated from `project.yml` by XcodeGen and is not checked in, so it
never appears in diffs.

```
Sources/
├── App/
│   ├── UTMSnapshotManagerApp.swift   Scene, menu bar, keyboard shortcuts
│   └── AppModel.swift                UI state, action coordination
├── Model/
│   ├── RunState.swift                The gate every destructive action passes
│   ├── VirtualMachine.swift          A machine and why it may be blocked
│   ├── DiskImage.swift               A writable disk and what qemu-img read from it
│   ├── Snapshot.swift                A restore point spanning several disks
│   ├── Lineage.swift                 Recorded ancestry for the branching view
│   └── AppError.swift                Every user-visible failure
├── Services/
│   ├── ProcessRunner.swift           External commands, always with a deadline
│   ├── QemuImg.swift                 info / snapshot / check / convert
│   ├── UTMControl.swift              UTM's scripting interface
│   ├── UTMRegistry.swift             UUID → bundle path, plus the process table
│   ├── VMDiscovery.swift             Locating bundles, reading their configuration
│   └── VMLibrary.swift               Orchestration and every disk-modifying operation
└── Views/                            Sidebar, detail, list, tree, sheets, design system
```

## Layering

Dependencies point downwards only.

**Views** hold no logic beyond presentation. They read from `AppModel` and call its methods.

**AppModel** is `@MainActor` and owns exactly one copy of what is on screen. It knows nothing
about disks or processes; it coordinates, presents progress, and turns errors into messages.

**VMLibrary** is where the three data sources are joined and where every write happens.
Keeping that join in one place is what allows every write to share one pre-flight check
instead of each call site remembering to perform it.

**Services** wrap one external surface each and have no knowledge of the interface.

## Data sources

Three sources are combined on every scan:

| Source | Provides | Read via |
| --- | --- | --- |
| The file system | Which `.utm` bundles exist, and their configuration | Spotlight plus a narrow folder walk |
| UTM | Which machines it manages, and their run state | AppleScript through `osascript`; registry from its preferences |
| `qemu-img` | Sizes, snapshots, image health | `--output=json` exclusively |

Disks come from the machine's `config.plist`, which states which drives are real disks and
which are CD-ROMs or read-only. Scanning for `*.qcow2` instead treats a mounted installer
image as a system disk and puts read-only drives into the write path.

`qemu-img` output is parsed as JSON only. Regular expressions over human-readable output break
whenever that output is reworded.

## Discovery

Spotlight and a folder walk run in parallel, each with its own deadline. Spotlight is not
present on every Mac, and on those the walk is the only source — hence the walk covering the
locations UTM actually uses, including its own container under `~/Library`, which is otherwise
excluded wholesale.

Each root gets its own deadline rather than sharing one budget. A folder blocked behind an
unanswered permission dialog would otherwise consume the entire allowance, and the roots after
it would never be visited.

Folders are excluded deliberately, not accidentally: `Pictures` and `Music` trigger unrelated
Photos and Media permission dialogs, and cloud folders can block in the kernel until the
network answers.

## Concurrency

`AppModel` is `@MainActor`; everything expensive happens off it.

**Deadlines everywhere.** A Swift task group cannot enforce one over blocking work: cancelling
a child does not interrupt a blocking syscall, and the group waits for every child regardless.
`ProcessRunner.timeboxed` and `withDeadline` race the work against a timer through a
resume-once continuation, releasing the caller on time and leaving the loser to finish
unobserved.

**Bounded parallelism.** Scanning inspects at most six machines at once — see
[security-model.md §5](security-model.md#5-resource-exhaustion) for why the number matters.

**Coalesced refreshes.** A refresh requested while one is running sets a flag rather than
being dropped; without it the refresh following a write is discarded and the in-flight scan
then overwrites the list with pre-write data.

**State mutation and the view update.** Publishing a change from a setter that SwiftUI itself
invokes during a view update aborts the update mid-pass and leaves the window half-drawn. The
snapshot selection is therefore synchronised from `onChange`, which runs afterwards. This is
recorded because it was a real defect, not a hypothetical one.

## The branching view

qcow2 stores snapshots as a flat list; the format has no parent link and a tree cannot be read
from an image. `Lineage` records ancestry as the application observes it — restoring a point
and saving from there makes the new point a branch of the old — and persists it per machine.

It is presented as the application's own record. A restore point with no recorded parent
appears as a root, which is what points created before this feature, or created in UTM
directly, look like. Nothing depends on the record being complete.

## Error handling

`AppError` enumerates every user-visible failure, and each case carries what the user needs in
order to decide what to do next. This is not stylistic: after a partial write, the correct
recovery depends entirely on how far the write got, and a generic "operation failed" would be
worse than useless. `partialWrite` and `strandedSnapshot` describe superficially similar
situations with opposite advice — one machine needs care before being started, the other is
untouched and safe.
