import AppKit
import SwiftUI

// The runner adds a passive probe to a temporary copy of the real Canvas renderer.
// No mouse events, forced display calls, or extra SwiftUI state drive the test.
@MainActor
enum RenderProbe {
    struct Frame {
        let names: [String]
        let bytes: [UInt64]
        let rectangles: [CGRect]
        let selectedID: Int?
    }
    static var frames: [Frame] = []
    static func record(names: [String], bytes: [UInt64], rectangles: [CGRect], selectedID: Int?) {
        frames.append(Frame(names: names, bytes: bytes, rectangles: rectangles, selectedID: selectedID))
    }
}

struct HarnessView: View {
    @ObservedObject var model: ScannerModel
    var body: some View {
        if model.scanning { Text("Scanning") }
        else if model.snapshot != nil { TreemapView(model: model) }
        else { Text("Ready") }
    }
}

@main
struct RenderHarness {
    @MainActor static func expect(_ name: String, action: () throws -> Void,
                                  matches: (RenderProbe.Frame) -> Bool) async throws {
        RenderProbe.frames.removeAll()
        try action()
        let deadline = ContinuousClock.now + .seconds(3)
        while ContinuousClock.now < deadline {
            if RenderProbe.frames.contains(where: matches) {
                print("PASS: \(name)")
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw NSError(domain: "RenderingRegression", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "\(name): no matching Canvas frame; drew \(RenderProbe.frames.map(\.names))"
        ])
    }

    @MainActor static func main() {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        let model = ScannerModel()
        let window = NSWindow(contentRect: NSRect(x: 20, y: 20, width: 700, height: 450),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.ignoresMouseEvents = true
        window.contentView = NSHostingView(rootView: HarnessView(model: model))
        window.orderFrontRegardless()
        let fixture = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        Task { @MainActor in
            do {
                try await Task.sleep(for: .milliseconds(200))
                try await expect("initial scan without mouse input", action: { model.start(fixture) }) {
                    $0.names.contains("notes.txt") && $0.names.contains("movie.mp4")
                }
                try await expect("metric change without mouse input", action: { model.metric = .logical }) {
                    guard let index = $0.names.firstIndex(of: "notes.txt") else { return false }
                    return $0.bytes[index] == 8193
                }
                guard let folder = model.snapshot?.nodes.first(where: { $0.name == "photos" })?.id,
                      let movie = model.snapshot?.nodes.first(where: { $0.name == "movie.mp4" })?.id else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                try await expect("selection redraw without mouse input", action: { model.selectedID = movie }) {
                    $0.selectedID == movie
                }
                try await expect("folder navigation without mouse input", action: { model.navigate(folder) }) {
                    $0.names == ["image.png"]
                }
                try await expect("parent navigation without mouse input", action: { model.up() }) {
                    $0.names.contains("movie.mp4")
                }
                try await expect("resize without mouse input", action: {
                    window.setContentSize(NSSize(width: 850, height: 500))
                }) {
                    abs(($0.rectangles.map(\.maxX).max() ?? 0) - 850) < 0.01
                }
                let originalCount = model.snapshot?.nodes.count
                try await expect("rescan with unchanged item count", action: {
                    try Data(repeating: 77, count: 131073).write(to: fixture.appendingPathComponent("movie.mp4"))
                    model.start(fixture)
                }) {
                    guard let index = $0.names.firstIndex(of: "movie.mp4") else { return false }
                    return $0.bytes[index] == 131073 && model.snapshot?.nodes.count == originalCount
                }
                // Cancel before completion, then start a different root immediately.
                // A late result or error from the cancelled scan must not replace it.
                let replacement = fixture.deletingLastPathComponent().appendingPathComponent("replacement", isDirectory: true)
                try FileManager.default.createDirectory(at: replacement, withIntermediateDirectories: true)
                try Data([1, 2, 3]).write(to: replacement.appendingPathComponent("replacement.txt"))
                try await expect("rapid replacement ignores cancelled results", action: {
                    for _ in 0..<8 { model.start(fixture); model.cancel(showNotice: false) }
                    model.start(replacement)
                }) { $0.names == ["replacement.txt"] }
                try await Task.sleep(for: .milliseconds(250))
                guard model.rootURL == replacement, model.snapshot?.nodes[0].name == "replacement",
                      model.snapshot?.payload.fileCount == 1, model.error == nil, !model.scanning else {
                    throw NSError(domain: "RenderingRegression", code: 2, userInfo: [
                        NSLocalizedDescriptionKey: "A cancelled scan replaced the new root or its result"
                    ])
                }
                model.start(fixture)
                model.cancel(showNotice: false)
                try await Task.sleep(for: .milliseconds(250))
                guard !model.scanning, model.snapshot == nil, model.error == nil else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                print("PASS: cancellation stays idle without late publication")
                model.start(fixture.appendingPathComponent("missing"))
                let failureDeadline = ContinuousClock.now + .seconds(3)
                while model.scanning && ContinuousClock.now < failureDeadline {
                    try await Task.sleep(for: .milliseconds(20))
                }
                guard !model.scanning, model.error != nil else { throw CocoaError(.fileReadCorruptFile) }
                print("PASS: failed scan exits completion wait")
                model.cancel(showNotice: false)
                window.orderOut(nil)
                exit(0)
            } catch {
                fputs("FAIL: \(error.localizedDescription)\n", stderr)
                model.cancel(showNotice: false)
                window.orderOut(nil)
                exit(1)
            }
        }
        application.run()
    }
}
