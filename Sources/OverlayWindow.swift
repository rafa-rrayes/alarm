import AppKit
import Observation
import SwiftUI

/// Live numbers for the overlay, updated once a second by the controller.
@Observable
final class OverlayState {
    var remaining: TimeInterval = 0
    var escapeHold: TimeInterval?
    var escapeProgress: Double?
}

/// Blacks out every display while the alarm sounds.
///
/// The windows sit at the shielding level — the one screen savers use — so they
/// cover full-screen apps and the menu bar too.
@MainActor
final class OverlayController {

    private var windows: [NSWindow] = []
    let state = OverlayState()

    var isShowing: Bool { !windows.isEmpty }

    func show() {
        guard windows.isEmpty else { return }
        for screen in NSScreen.screens {
            let window = NSWindow(
                contentRect: screen.frame,
                styleMask: .borderless,
                backing: .buffered,
                defer: false,
                screen: screen
            )
            window.isReleasedWhenClosed = false
            window.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
            window.backgroundColor = .black
            window.isOpaque = true
            window.hasShadow = false
            window.collectionBehavior = [
                .canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle,
            ]
            window.contentView = NSHostingView(rootView: OverlayView(state: state))
            window.setFrame(screen.frame, display: true)
            window.orderFrontRegardless()
            windows.append(window)
        }
    }

    func hide() {
        for window in windows {
            window.orderOut(nil)
            window.close()
        }
        windows.removeAll()
    }
}

private struct OverlayView: View {
    @Bindable var state: OverlayState

    var body: some View {
        ZStack {
            Color.black
            VStack(spacing: 24) {
                Text(Date(), style: .time)
                    .font(.system(size: 96, weight: .thin, design: .rounded))
                    .monospacedDigit()

                Text(Format.clock(state.remaining))
                    .font(.system(size: 22, weight: .regular, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)

                if let hold = state.escapeHold {
                    escapeHint(hold: hold)
                }
            }
            .foregroundStyle(.white)
        }
        .ignoresSafeArea()
    }

    @ViewBuilder
    private func escapeHint(hold: TimeInterval) -> some View {
        VStack(spacing: 10) {
            if let progress = state.escapeProgress {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .frame(width: 220)
                    .tint(.white)
                Text("keep holding…")
            } else {
                Text("hold ⎋ for \(Int(hold))s to stop")
            }
        }
        .font(.system(size: 14, design: .rounded))
        .foregroundStyle(.white.opacity(0.55))
        .padding(.top, 20)
    }
}

enum Format {
    /// "01:23" / "1:02:03" — matches the countdown the CLI printed.
    static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        let hours = total / 3600
        let minutes = (total / 60) % 60
        let secs = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%02d:%02d", minutes, secs)
    }

    /// "in 2d 3h" / "in 8h 12m" / "in 45s"
    static func relative(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        if total < 60 { return "in \(total)s" }
        let days = total / 86400
        let hours = (total / 3600) % 24
        let minutes = (total / 60) % 60
        if days > 0 { return "in \(days)d \(hours)h" }
        if hours > 0 { return "in \(hours)h \(minutes)m" }
        return "in \(minutes)m"
    }

    /// "5m" / "1h" / "1h 30m" — a countdown length.
    static func duration(_ minutes: Int) -> String {
        let hours = minutes / 60
        let rest = minutes % 60
        if hours == 0 { return "\(rest)m" }
        return rest == 0 ? "\(hours)h" : "\(hours)h \(rest)m"
    }

    /// "07:30" today, "tomorrow 07:30", otherwise "Mon 07:30".
    static func when(_ date: Date, now: Date = Date()) -> String {
        let calendar = Calendar.current
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDate(date, inSameDayAs: now) { return time }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now),
           calendar.isDate(date, inSameDayAs: tomorrow) {
            return "tomorrow \(time)"
        }
        return "\(date.formatted(.dateTime.weekday(.abbreviated))) \(time)"
    }
}
