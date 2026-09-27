import AppKit
import SwiftUI

// Instrumentation is inserted into temporary source copies by the benchmark runner.
// The window ignores mouse input, and no forced display API is used.
enum PerformanceProbe {
    private static let lock = NSLock()
    private static var values: [String: Double] = [:]
    static func record(_ key: String, _ value: Double) {
        lock.lock(); defer { lock.unlock() }
        values[key] = value
    }
    static func frameFinished() {
        lock.lock(); defer { lock.unlock() }
        if values["first_frame_at"] == nil {
            values["first_frame_at"] = ProcessInfo.processInfo.systemUptime
        }
    }
    static func snapshot() -> [String: Double] {
        lock.lock(); defer { lock.unlock() }
        return values
    }
}

@main
struct FirstFrameBenchmark {
    @MainActor static func main() {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        let model = ScannerModel()
        let window = NSWindow(contentRect: NSRect(x: 20, y: 20, width: 1440, height: 940),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.ignoresMouseEvents = true
        window.contentView = NSHostingView(rootView: ContentView(model: model))
        window.orderFrontRegardless()
        let fixture = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(200))
            let started = ProcessInfo.processInfo.systemUptime
            model.start(fixture)
            let deadline = ContinuousClock.now + .seconds(30)
            while ContinuousClock.now < deadline {
                var result = PerformanceProbe.snapshot()
                if let frameAt = result.removeValue(forKey: "first_frame_at"), let snapshot = model.snapshot {
                    let preparedAt = result.removeValue(forKey: "prepared_at") ?? frameAt
                    result["first_frame_ms"] = (frameAt - started) * 1000
                    result["prepare_to_frame_ms"] = (frameAt - preparedAt) * 1000
                    result["scan_ms"] = snapshot.payload.elapsed * 1000
                    result["files"] = Double(snapshot.payload.fileCount)
                    result["logical_bytes"] = Double(snapshot.nodes[0].logical)
                    result["allocated_bytes"] = Double(snapshot.nodes[0].allocated)
                    var usage = rusage()
                    getrusage(RUSAGE_SELF, &usage)
                    result["peak_rss_bytes"] = Double(usage.ru_maxrss)
                    let data = try! JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
                    print(String(decoding: data, as: UTF8.self))
                    model.cancel(showNotice: false)
                    window.orderOut(nil)
                    exit(0)
                }
                if let error = model.error { fputs("\(error)\n", stderr); exit(1) }
                try? await Task.sleep(for: .milliseconds(2))
            }
            fputs("Timed out waiting for first Canvas frame\n", stderr)
            model.cancel(showNotice: false)
            window.orderOut(nil)
            exit(1)
        }
        application.run()
    }
}
