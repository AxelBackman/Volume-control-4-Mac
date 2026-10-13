import AppKit
import SwiftUI

@main
struct VolumeMixerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra("Volume Mixer", systemImage: "slider.vertical.3") {
            MixerView(viewModel: delegate.viewModel)
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let viewModel = MixerViewModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        viewModel.start()
    }

    /// Taps mute the apps they capture, so teardown has to finish before we exit.
    func applicationWillTerminate(_ notification: Notification) {
        viewModel.stop()
    }
}
