import SwiftUI

@MainActor
enum MainWindowController {
    static let windowID = "main-window"

    static func configure(_ window: NSWindow, menuBarOnlyModeEnabled: Bool) {
        window.identifier = NSUserInterfaceItemIdentifier(windowID)
        if menuBarOnlyModeEnabled {
            window.orderOut(nil)
        }
    }

    static func hideMainWindow() {
        mainWindow?.orderOut(nil)
    }

    static func showMainWindow(using openWindow: OpenWindowAction) {
        if let mainWindow {
            NSApp.activate(ignoringOtherApps: true)
            mainWindow.makeKeyAndOrderFront(nil)
            return
        }

        openWindow(id: windowID)
        NSApp.activate(ignoringOtherApps: true)
    }

    private static var mainWindow: NSWindow? {
        NSApp.windows.first { $0.identifier?.rawValue == windowID }
    }
}

@main
struct NTPClockApp: App {
    @StateObject private var viewModel = ClockViewModel()

    var body: some Scene {
        WindowGroup(id: MainWindowController.windowID) {
            ClockView(viewModel: viewModel)
                .frame(minWidth: 640, minHeight: 420)
                .navigationTitle(viewModel.windowTitle)
                .background {
                    WindowAccessor { window in
                        MainWindowController.configure(window, menuBarOnlyModeEnabled: viewModel.isMenuBarOnlyModeEnabled)
                    }
                }
        }
        .windowResizability(.contentSize)

        MenuBarExtra {
            MenuBarClockView(viewModel: viewModel)
        } label: {
            Label(viewModel.menuBarLabel, systemImage: viewModel.menuBarSymbolName)
        }
        .menuBarExtraStyle(.window)
    }
}

private struct WindowAccessor: NSViewRepresentable {
    let onResolve: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let window = view.window {
                onResolve(window)
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            if let window = nsView.window {
                onResolve(window)
            }
        }
    }
}