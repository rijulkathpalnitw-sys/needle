#if canImport(SwiftUI)
import SwiftUI
import NeedleCore
#if os(macOS)
import AppKit
#endif

@main
struct NeedleApp: App {
    #if os(macOS)
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #endif
    @StateObject private var model = SearchViewModel()

    var body: some Scene {
        WindowGroup("Needle") {
            ContentView()
                .environmentObject(model)
                #if os(macOS)
                .frame(minWidth: 880, minHeight: 540)
                #endif
                .task {
                    if case .empty = model.state { model.buildDemo(count: 5_000) }
                }
        }
        #if os(macOS)
        .defaultSize(width: 1100, height: 700)
        #endif
    }
}

#if os(macOS)
/// Lets the app come to the front and take keyboard focus even when started with `swift run`.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}
#endif
#endif
