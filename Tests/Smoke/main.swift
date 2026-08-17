import AppKit
import Foundation

// Launches the built application and checks that its content area draws
// something. See WindowCheck.swift for why this exists and why it measures
// where it does.
//
// Usage: smoke-test <path to .app> [minimum content ratio]
//
// Needs a logged-in graphical session and Screen Recording permission for
// whatever runs it. Without either it reports that it could not check rather
// than failing: "this machine cannot run the test" and "the app is broken" are
// different answers, and only one of them should stop a build.

let arguments = CommandLine.arguments
guard arguments.count > 1 else {
    FileHandle.standardError.write("usage: smoke-test <app bundle> [ratio]\n".data(using: .utf8)!)
    exit(2)
}

// `open -a` only accepts an absolute path, and a relative one fails in a way
// that looks exactly like the application refusing to start.
let bundlePath = URL(fileURLWithPath: arguments[1]).standardizedFileURL.path
let threshold = arguments.count > 2 ? Double(arguments[2]) ?? 0.03 : 0.03
let ownerName = "UTM Snapshot Manager"

func fail(_ message: String) -> Never {
    print("  FAIL  \(message)")
    print("\n  0 passed, 1 failed")
    exit(1)
}

func skip(_ message: String) -> Never {
    print("      (skipped — \(message))")
    exit(0)
}

func shell(_ path: String, _ arguments: [String]) {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: path)
    task.arguments = arguments
    try? task.run()
    task.waitUntilExit()
}

guard FileManager.default.fileExists(atPath: bundlePath) else {
    fail("no application bundle at \(bundlePath)")
}
guard !NSScreen.screens.isEmpty else { skip("no graphical session") }

print("[1] The window draws its content")

// Anything left from an earlier run would be measured instead of this build.
shell("/usr/bin/pkill", ["-f", "\(bundlePath)/Contents/MacOS"])
Thread.sleep(forTimeInterval: 2)
shell("/usr/bin/open", ["-a", bundlePath])

// The first scan can take a while; the window appears long before it finishes.
var found: WindowInfo?
let deadline = Date().addingTimeInterval(60)
while Date() < deadline, found == nil {
    Thread.sleep(forTimeInterval: 2)
    found = windows(ownedBy: ownerName).first
}
guard let window = found else { fail("no window appeared within 60 seconds") }

print("        window “\(window.title)” at \(Int(window.bounds.width))x\(Int(window.bounds.height))")

// A window captured the instant it appears is legitimately still empty.
Thread.sleep(forTimeInterval: 8)

guard let shot = capture(window) else {
    skip("the window could not be captured — Screen Recording permission?")
}
guard let content = contentArea(of: shot) else {
    fail("the window is too small to have a content area at all")
}

let ratio = contentRatio(of: content)
let percent = String(format: "%.1f%%", ratio * 100)
let limit = String(format: "%.1f%%", threshold * 100)

defer { shell("/usr/bin/pkill", ["-f", "\(bundlePath)/Contents/MacOS"]) }

if ratio >= threshold {
    print("  PASS  the content area is not blank (\(percent) differs from its background, needs \(limit))")
    print("\n  1 passed, 0 failed")
} else {
    fail("the content area is blank — only \(percent) differs from its background, needs \(limit)")
}
