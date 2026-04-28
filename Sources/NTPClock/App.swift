import SwiftUI

@main
struct NTPClockApp: App {
    @StateObject private var viewModel = ClockViewModel()

    var body: some Scene {
        WindowGroup {
            ClockView(viewModel: viewModel)
                .frame(minWidth: 640, minHeight: 420)
                .navigationTitle(viewModel.windowTitle)
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