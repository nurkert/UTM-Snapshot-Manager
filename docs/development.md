# Development

## Prerequisites

```sh
brew install xcodegen qemu
```

Xcode 26 or newer is required. The application targets macOS 14, but the Liquid Glass APIs it
uses on macOS 26 are referenced behind availability checks, and those symbols must exist at
compile time — an older SDK fails to build.

## Everyday commands

| Command | Purpose |
| --- | --- |
| `Scripts/run-tests.sh` | Integration tests against real `qcow2` images |
| `Scripts/build-app.sh` | Universal Release build, ad-hoc signed. Prints the bundle path. |
| `Scripts/make-dmg.sh` | Packages and verifies `dist/UTM-Snapshot-Manager-<version>.dmg` |
| `./install.sh` | Builds and installs into `/Applications` |

To work in Xcode:

```sh
swift Tools/MakeIcon.swift   # draws the app icon from an SF Symbol
xcodegen generate            # writes the .xcodeproj from project.yml
open "UTM Snapshot Manager.xcodeproj"
```

The project file and the generated asset catalogue are both ignored by git. Change build
settings in `project.yml`, never in Xcode, or the change is lost on the next generation.

## Tests

`Tests/Integration/main.swift` compiles against the service and model layer and exercises the
real write paths in a temporary directory. It creates genuine `qcow2` images and calls the
real `qemu-img`.

Mocking was considered and rejected. What this application is *about* is what `qemu-img` does
to a disk; a stubbed `qemu-img` would test the stub. The suite therefore covers the refusals
as thoroughly as the successful paths:

| Group | Covers |
| --- | --- |
| Configuration | A qcow2 CD-ROM is not mistaken for a system disk |
| Single disk | Create, restore, delete |
| Multi-disk | A restore point written across every disk |
| Completeness | An incomplete point refused before any write; a false completeness claim caught by re-reading the images |
| Rollback | A failed create leaving no residue |
| Suspend | A parked memory state blocking writes |
| Identity | A duplicate told from the original by recorded path |
| Disk layout | A disk added since the last scan stopping the write |
| Injection | A name containing shell metacharacters stored, not executed |
| Read-only tools | Integrity check and export |

One test needs a genuinely running machine and is therefore opt-in:

```sh
USM_RUNNING_VM="/path/to/Machine.utm" Scripts/run-tests.sh
```

Without it, that check reports itself as skipped rather than passing silently.

## Continuous integration

`.github/workflows/ci.yml` runs on every push to any branch and on every pull request:

- **Integration tests** — installs QEMU, runs the suite.
- **Build app** — universal Release build, then verifies the bundle carries both
  architectures, a valid signature and its Apple Events usage description.

Both jobs are needed. The test job compiles only the service and model layer, so a broken view
or a missing SDK symbol would otherwise reach a release.

## Releasing

1. Update `MARKETING_VERSION` in `project.yml`.
2. Merge to `main` and confirm CI is green.
3. Tag and push:

```sh
git tag -a v2.1.0 -m "UTM Snapshot Manager 2.1.0"
git push origin v2.1.0
```

The tag triggers `.github/workflows/release.yml`, which runs the tests, builds, packages the
disk image and publishes a GitHub release with the `.dmg` and its checksum.

Releases are signed ad-hoc. Without a paid Apple Developer ID that is the strongest signature
available, and it is why the disk image ships with a note about the first launch.

## Keeping your permissions across rebuilds

macOS ties privacy permissions to an application's code signature, and an ad-hoc signature is
the binary's own hash — so every rebuild is a different application as far as the system is
concerned, and Documents access and UTM control have to be granted again. That is not a small
annoyance: it makes each change cost a trip through System Settings before it can be tested at
all, and it hides real bugs behind an app that simply cannot see anything.

Run this once:

```sh
Scripts/make-signing-cert.sh
```

It puts a local self-signed code-signing certificate in your login keychain, and
`Scripts/build-app.sh` signs with it when it is there. The designated requirement then names
the certificate instead of the hash:

```
identifier "com.github.nurkert.UTMSnapshotManager" and certificate root = H"…"
```

Stable across rebuilds, so the permissions stay. Grant them once more after the first build
that carries the new signature.

The certificate is for local development only — not a Developer ID, no notarisation, and
meaningless on any other Mac. Delete it from Keychain Access to undo; the build then falls
back to ad-hoc. CI has no certificate and signs ad-hoc, which is what a release should be.

## Repository conventions

**Commit messages** describe why a change was made, not what the diff shows. A reader a year
from now can see what changed; what they cannot recover is the reasoning, the alternative that
was rejected, or the failure that prompted it.

**Comments** explain decisions, not mechanics. Where the code does something unexpected —
bounded parallelism, a deadline that deliberately does not wait, a permission read that is
unconditional — the comment says what happens without it. Several of those record real
defects and exist so the next person does not undo the fix.
