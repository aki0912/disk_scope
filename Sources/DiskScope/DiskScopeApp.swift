import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct DiskScopeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = ScannerModel()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .preferredColorScheme(.dark)
                .frame(minWidth: 1060, minHeight: 820)
                .onAppear {
                    let args = CommandLine.arguments
                    if let index = args.firstIndex(of: "--scan"), args.count > index + 1, model.rootURL == nil {
                        model.start(URL(fileURLWithPath: args[index + 1]))
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in model.cancel(showNotice: false) }
        }
        .defaultSize(width: 1440, height: 940)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("フォルダを選択…", action: model.chooseFolder).keyboardShortcut("o")
                Button("再解析") { if let url = model.rootURL { model.start(url) } }
                    .keyboardShortcut("r").disabled(model.rootURL == nil || model.scanning)
                Button("上の階層へ", action: model.up).keyboardShortcut(.upArrow, modifiers: .command)
                    .disabled(model.current?.parent == nil)
            }
        }
    }
}
