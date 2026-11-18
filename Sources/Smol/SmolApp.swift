import AppKit
import SmolCore
import SwiftUI

@main
struct SmolApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel.shared

    var body: some Scene {
        Window("Smol", id: "main") {
            RootView()
                .environment(model)
                .frame(minWidth: 940, minHeight: 640)
        }
        .defaultSize(width: 1240, height: 820)
        .commands { SmolCommands(model: model) }

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Files dropped on the Dock icon or opened with "Open With → Smol".
    func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in AppModel.shared.add(urls: urls) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillFinishLaunching(_ notification: Notification) {
        Task { @MainActor in NSApp.appearance = AppModel.shared.preferences.appearance.nsAppearance }
        // Plain ⌘V adds whatever image is on the clipboard, unless a text field wants the paste.
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
            guard modifiers == .command, event.charactersIgnoringModifiers?.lowercased() == "v" else { return event }
            let handled = MainActor.assumeIsolated {
                guard NSApp.modalWindow == nil, !(NSApp.keyWindow?.firstResponder is NSText) else { return false }
                AppModel.shared.pasteFromClipboard()
                return true
            }
            return handled ? nil : event
        }
    }

    /// Pick up encoders installed with Homebrew while the app was in the background.
    func applicationDidBecomeActive(_ notification: Notification) {
        Task { @MainActor in AppModel.shared.refreshTools() }
    }

    #if DEBUG
    /// Dev aid: `SMOL_SNAPSHOT=/path/prefix SMOL_SCREENS=home,editor,watch .build/debug/Smol [images…]`
    /// writes a PNG of the window for each screen, then quits. The `check` screen runs `selfCheck` first.
    func applicationDidFinishLaunching(_ notification: Notification) {
        let env = ProcessInfo.processInfo.environment
        guard let prefix = env["SMOL_SNAPSHOT"] else { return }
        AppModel.ignoresPointer = true
        if env["SMOL_DARK"] != nil { NSApp.appearance = NSAppearance(named: .darkAqua) }
        let screens = (env["SMOL_SCREENS"] ?? "home").split(separator: ",").map(String.init)
        let files = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-") }.map { URL(fileURLWithPath: $0) }
        Task { @MainActor in
            let model = AppModel.shared
            try? await Task.sleep(for: .seconds(1))
            for screen in screens {
                switch screen {
                case "editor": model.add(urls: files)
                case "watch": model.screen = .watch
                case "settings":
                    // The Settings scene can't be opened programmatically from here, so host the same view.
                    let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView().environment(model)))
                    window.title = "Settings"
                    window.styleMask = [.titled, .closable]
                    window.makeKeyAndOrderFront(nil)
                case "check":
                    await Self.selfCheck(model, sample: files.first, folder: URL(fileURLWithPath: "\(prefix)-check"))
                default: model.screen = .home
                }
                try? await Task.sleep(for: .seconds(screen == "editor" ? Double(env["SMOL_WAIT"] ?? "4") ?? 4 : 1.5))
                let visible = NSApp.windows.filter { $0.isVisible && $0.frame.width > 100 }
                let target = screen == "settings" ? visible.min { $0.frame.width < $1.frame.width } : visible.max { $0.frame.width < $1.frame.width }
                guard let window = target,
                      let view = window.contentView?.superview,
                      let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(prefix)-\(screen).png"))
            }
            NSApp.terminate(nil)
        }
    }

    /// Drives paste, copy and the responsive set on a private pasteboard, so the real clipboard is left alone.
    /// Prints what happened; the snapshot that follows shows the pasted image in the editor.
    @MainActor private static func selfCheck(_ model: AppModel, sample: URL?, folder: URL) async {
        func report(_ line: String) { FileHandle.standardError.write(Data("check: \(line)\n".utf8)) }
        guard let sample, let image = NSImage(contentsOf: sample) else { return report("needs an image argument") }
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        model.clipboard = board
        model.removeAll()
        board.clearContents()
        board.writeObjects([image])
        if let key = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
                                      windowNumber: NSApp.windows.first?.windowNumber ?? 0, context: nil,
                                      characters: "v", charactersIgnoringModifiers: "v", isARepeat: false, keyCode: 9) {
            NSApp.postEvent(key, atStart: false)
        }
        try? await Task.sleep(for: .seconds(3))
        report("⌘V added \(model.items.count) image(s): \(model.items.map(\.name))")
        guard let item = model.selectedItem else { return }
        model.copyCompressed()
        let copied = (board.readObjects(forClasses: [NSURL.self]) as? [URL])?.map(\.lastPathComponent) ?? []
        report("copy put \(copied) on the pasteboard")
        await model.exportSet(item, widths: ResponsiveSet.defaultWidths, to: folder, reveal: false)
        report("set wrote \(((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted())")
        report("tag:\n\(board.string(forType: .string) ?? "none")")
    }
    #endif
}

struct SmolCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Open Images…") { model.presentOpenPanel() }
                .keyboardShortcut("o")
        }
        CommandGroup(replacing: .saveItem) {
            Button("Save All") { model.saveAll() }
                .keyboardShortcut("s")
            Button("Save All To…") { model.exportToChosenFolder() }
                .keyboardShortcut("s", modifiers: [.command, .shift])
            Button("Choose Output Folder…") { model.chooseOutputFolder() }
        }
        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Paste Images") { model.pasteFromClipboard() }
                .keyboardShortcut("v", modifiers: [.command, .shift])
            Button("Copy Compressed Image") { model.copyCompressed() }
                .keyboardShortcut("c", modifiers: [.command, .shift])
        }
        CommandMenu("Go") {
            Button("Home Dial") { model.screen = .home }
                .keyboardShortcut("h", modifiers: [.command, .shift])
            Button("Editor") { if !model.items.isEmpty { model.screen = .editor } }
                .keyboardShortcut("e", modifiers: [.command, .shift])
            Button("Watch Folder") { model.screen = .watch }
                .keyboardShortcut("f", modifiers: [.command, .shift])
            Divider()
            Button("Remove All Images") { model.removeAll() }
                .keyboardShortcut(.delete, modifiers: [.command, .shift])
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ZStack(alignment: .bottom) {
            switch model.screen {
            case .home:
                HomeView().transition(.opacity)
            case .editor where !model.items.isEmpty:
                EditorView().transition(.opacity)
            case .editor:
                HomeView().transition(.opacity)
            case .watch:
                WatchView().transition(.opacity)
            }

            if let toast = model.toast {
                Text(toast)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(DS.canvas)
                    .padding(.horizontal, 14)
                    .frame(height: 30)
                    .background(Color.primary, in: Capsule())
                    .shadow(color: .black.opacity(0.18), radius: 14, y: 6)
                    .padding(.bottom, 28)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .onTapGesture { model.toast = nil }
            }
        }
        .id(model.toolsRevision)
        .animation(.smooth(duration: 0.25), value: model.screen)
        .animation(.smooth(duration: 0.25), value: model.toast)
    }
}
