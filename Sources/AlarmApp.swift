import AppKit
import SwiftUI

/// Shared model. A static let keeps one instance for both the scene and the app
/// delegate, which needs it to clean up at quit.
@MainActor
enum AppCore {
    static let settings = AlarmSettings()
    static let controller = AlarmController(settings: settings)
}

@main
struct AlarmApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            ContentView(controller: AppCore.controller, settings: AppCore.settings)
        } label: {
            StatusLabel(controller: AppCore.controller)
        }
        .menuBarExtraStyle(.window)
    }
}

/// What the menu bar shows when the panel is closed — which is nearly always.
///
/// Everything here is derived from `phase` and `fireDate`, never from the
/// per-second countdown, so the item doesn't twitch while an alarm is pending.
private struct StatusLabel: View {
    let controller: AlarmController

    var body: some View {
        switch controller.phase {
        case .idle:
            Image(systemName: "alarm")
        case .arming:
            Image(systemName: "hourglass")
        case .armed:
            HStack(spacing: 4) {
                Image(systemName: "alarm.fill")
                if let fireDate = controller.fireDate {
                    // Weekday only when it isn't today, so a repeating alarm
                    // set for Monday doesn't read as "07:30" on a Friday.
                    Text(Calendar.current.isDateInToday(fireDate)
                        ? fireDate.formatted(date: .omitted, time: .shortened)
                        : fireDate.formatted(.dateTime.weekday(.abbreviated).hour().minute()))
                }
            }
        case .firing:
            Image(systemName: "alarm.waves.left.and.right.fill")
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        // `LSUIElement` already makes this an agent app; no window to raise and
        // nothing to steal focus for.
        installSignalHandlers()
    }

    /// The panel closing, or the overlay tearing down, must not kill a pending
    /// alarm — the menu bar item is what brings the panel back.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Don't ask while the alarm is sounding — input is blocked, so nobody
        // could answer. Only an armed-but-waiting alarm is worth confirming.
        guard AppCore.controller.phase == .armed else { return .terminateNow }

        // An agent app isn't frontmost when ⌘Q arrives, and an unactivated alert
        // opens behind whatever is.
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = "The alarm is still armed."
        alert.informativeText = "Quitting now means it won't go off."
        alert.addButton(withTitle: "Quit anyway")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppCore.controller.teardown()
    }

    /// Logout and shutdown send SIGTERM; without this the volume and the
    /// lid-sleep setting would be left where the alarm put them.
    private func installSignalHandlers() {
        for code in [SIGTERM, SIGINT] {
            signal(code, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: code, queue: .main)
            source.setEventHandler {
                MainActor.assumeIsolated {
                    AppCore.controller.teardown()
                    NSApp.terminate(nil)
                }
            }
            source.resume()
            signalSources.append(source)
        }
    }
}
