import Darwin
import Foundation

setbuf(stdout, nil)

/// Xcode's "Terminal" console mode pastes an LLDB command that is too long
/// for Terminal.app, so the quote never closes and Forth never starts.
/// A Run from Xcode opens one short command in Terminal instead.
func launchedFromXcode() -> Bool {
    if CommandLine.arguments.dropFirst().contains("--in-terminal") { return false }
    if getenv("__XCODE_BUILT_PRODUCTS_DIR_PATHS") != nil { return true }
    var buffer = [CChar](repeating: 0, count: 4096)
    let length = proc_pidpath(getppid(), &buffer, UInt32(buffer.count))
    guard length > 0 else { return false }
    let parent = String(cString: buffer)
    for marker in ["Xcode", "lldb", "debugserver", "darwin-debug"] {
        if parent.contains(marker) { return true }
    }
    return false
}

func openInTerminal() -> Bool {
    let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().path
    let command = "exec '\(exe.replacingOccurrences(of: "'", with: "'\\''"))' --in-terminal"
    let apple = command
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    process.arguments = [
        "-e", "tell application \"Terminal\"",
        "-e", "activate",
        "-e", "do script \"\(apple)\"",
        "-e", "end tell",
    ]
    do {
        try process.run()
        process.waitUntilExit()
    } catch {
        fputs("Could not open Terminal: \(error)\n", stderr)
        return false
    }
    return process.terminationStatus == 0
}

if launchedFromXcode() {
    if openInTerminal() {
        print("Forth is running in Terminal.")
        exit(0)
    }
    fputs("Could not open Terminal. Running here instead.\n", stderr)
}

/// Locates the transcribed 1968 sources.
///
/// A Copy Files phase places Resources beside the built tool. The directory
/// next to this source file is the fallback when the tool is run by hand
/// from the project tree.
func resourceDirectory() -> URL {
    let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    let besideTool = exe.deletingLastPathComponent().appendingPathComponent("Resources")
    if FileManager.default.fileExists(atPath: besideTool.path) {
        return besideTool
    }
    let besideSource = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Resources")
    if FileManager.default.fileExists(atPath: besideSource.path) {
        return besideSource
    }
    fputs("Could not find Resources.\n", stderr)
    exit(1)
}

func load(_ root: URL, _ name: String) -> String {
    let url = root.appendingPathComponent(name)
    guard let text = try? String(contentsOf: url, encoding: .utf8) else {
        fputs("Missing \(name)\n", stderr)
        exit(1)
    }
    return text
}

let root = resourceDirectory()
let assembly = Assembler.assemble(load(root, "FORTH.asm"))
if !assembly.errors.isEmpty {
    for message in assembly.errors.prefix(40) {
        fputs(message + "\n", stderr)
    }
    fputs("\(assembly.errors.count) assembler error(s)\n", stderr)
    exit(1)
}

let listingDir = root.appendingPathComponent("listing")
let pages = (try? FileManager.default.contentsOfDirectory(at: listingDir, includingPropertiesForKeys: nil))?
    .filter { $0.lastPathComponent.hasPrefix("asm-page-") }
    .sorted { $0.lastPathComponent < $1.lastPathComponent } ?? []
if pages.isEmpty {
    fputs("No listing pages\n", stderr)
    exit(1)
}
var listing = ""
for page in pages {
    listing += load(listingDir, page.lastPathComponent)
    if !listing.hasSuffix("\n") { listing += "\n" }
}
let mismatches = compareListing(assembly, listing: listing)
if !mismatches.isEmpty {
    for row in mismatches.prefix(30) {
        fputs(row.detail + "\n", stderr)
    }
    fputs("\(mismatches.count) listing mismatch(es)\n", stderr)
    exit(1)
}

let lo = assembly.image.keys.min() ?? 0
let hi = assembly.image.keys.max() ?? 0
print("Assembled FORTH.asm: \(hex4(lo))–\(hex4(hi)), entry \(hex4(assembly.entry)), listing matches.")

let machine = Machine(assembly: assembly, source: load(root, "FO.FO"))
let record = machine.firstRecord().trimmingCharacters(in: .whitespaces)
print("First disk record: \(record)")

let reason = machine.run(limit: 200_000_000)
print(reason)
let produced = machine.output.joined(separator: "\n")
if produced.contains("HI THERE") {
    exit(0)
}
fputs(machine.trace + "\n", stderr)
fputs("Did not print HI THERE\n", stderr)
exit(1)
