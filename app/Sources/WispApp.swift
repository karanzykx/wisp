// Wisp: a window around the wisp cleaner engine (engine/wisp.sh).
// The app never deletes anything itself: it runs the bundled script, first as a
// preview (--dry-run) and, only after you press Clean, for real with the exact
// categories you selected. Built for macOS 11+ so it runs on every Apple Silicon Mac.

import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .darkAqua)
        NSWindow.allowsAutomaticWindowTabbing = false
        let env = ProcessInfo.processInfo.environment

        DispatchQueue.main.async {
            if let window = NSApp.windows.first {
                window.titlebarAppearsTransparent = true
                window.titleVisibility = .hidden
                window.isMovableByWindowBackground = true
                window.isRestorable = false
                window.backgroundColor = Theme.windowColor        // any extra window area matches the app
                window.minSize = NSSize(width: 700, height: 560)
                var size = NSSize(width: 780, height: 680)
                if let wh = env["WISP_SIZE"]?.components(separatedBy: "x"), wh.count == 2,
                   let w = Double(wh[0]), let h = Double(wh[1]) { size = NSSize(width: w, height: h) }   // test hook
                window.setContentSize(size)
                window.center()
                NSApp.activate(ignoringOtherApps: true)
            }
            if let demo = env["WISP_DEMO"] {
                Engine.shared.loadDemo(demo)
            } else {
                Engine.shared.scan()
            }
        }

        // Test hook: WISP_SNAPSHOT=/path/shot.png saves the window as an image and quits.
        if let path = env["WISP_SNAPSHOT"] {
            let delay = Double(env["WISP_SNAPSHOT_DELAY"] ?? "") ?? 12
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                if let view = NSApp.windows.first?.contentView {
                    let b = view.bounds
                    // Render at 2x so README images stay sharp on Retina screens.
                    if let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(b.width * 2), pixelsHigh: Int(b.height * 2),
                                                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                  colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) {
                        rep.size = b.size
                        view.cacheDisplay(in: b, to: rep)
                        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                    }
                }
                NSApp.terminate(nil)
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) { Engine.shared.stopAll() }
}

@main
struct WispApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        WindowGroup {
            RootView()
        }
        .windowStyle(HiddenTitleBarWindowStyle())
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Clean") {
                Button("Rescan") { Engine.shared.scan() }.keyboardShortcut("r")
            }
        }
    }
}
