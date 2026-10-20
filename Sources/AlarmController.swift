import AppKit
import Foundation
import Observation

/// The state machine: idle → arming → armed → firing → idle.
///
/// Every path out of `firing` funnels through `teardown()`, which is idempotent,
/// so the volume, the power assertions, the overlay and the tap all get put back
/// exactly once no matter which of them ended the alarm.
@MainActor
@Observable
final class AlarmController {

    enum Phase: Equatable {
        case idle
        case arming
        case armed
        case firing
    }

    let settings: AlarmSettings

    private(set) var phase: Phase = .idle
    private(set) var fireDate: Date?
    private(set) var remaining: TimeInterval = 0
    private(set) var blockRemaining: TimeInterval = 0
    private(set) var hasAccessibility = InputBlocker.hasPermission
    private(set) var isPreviewing = false
    /// What's queued (or playing) — matters in folder mode, where it's random.
    private(set) var trackName: String?
    var errorMessage: String?
    var warningMessage: String?

    private let audio = AudioEngine()
    private let blocker = InputBlocker()
    private let sleep = SleepBlocker()
    let overlay = OverlayController()

    private var ticker: Timer?
    private var track: URL?
    private var blockDeadline: Date?
    private var priorVolume: Float?

    var isBusy: Bool { phase == .arming }
    var canArm: Bool { hasAccessibility && phase == .idle }

    init(settings: AlarmSettings) {
        self.settings = settings
        // A previous run that died mid-alarm may have left sleep disabled.
        sleep.clearStaleLidBlock()
        observeWake()
        audio.onTrackChange = { [weak self] url in self?.trackName = Self.displayName(url) }
    }

    // MARK: - Permission

    func refreshPermission() {
        hasAccessibility = InputBlocker.hasPermission
    }

    func requestPermission() {
        InputBlocker.requestPermission()
        // The grant lands asynchronously, once the user flips the switch.
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { timer in
            MainActor.assumeIsolated {
                self.refreshPermission()
                if self.hasAccessibility { timer.invalidate() }
            }
        }
    }

    // MARK: - Arming

    func arm() async {
        guard phase == .idle else { return }
        stopPreview()
        errorMessage = nil
        warningMessage = nil
        phase = .arming

        let target = settings.fireDate(from: Date())

        do {
            let prepared = try await audio.prepare(settings: settings)
            track = prepared
            trackName = Self.displayName(prepared)
        } catch {
            errorMessage = error.localizedDescription
            phase = .idle
            return
        }

        if settings.blockLidSleep {
            // Backstop the root watcher well past the end of the alarm, so a
            // crash can't leave the Mac unable to sleep.
            let restoreBy = target.addingTimeInterval(Double(settings.duration) + 300)
            do {
                try await sleep.blockLidSleep(restoreBy: restoreBy)
            } catch {
                // Not fatal — the alarm still fires with the lid open.
                warningMessage = error.localizedDescription
            }
        }

        sleep.preventIdleSleep(reason: "Alarm is armed")
        fireDate = target
        phase = .armed
        startTicker()
        tick()
    }

    func disarm() {
        guard phase != .idle else { return }
        teardown()
    }

    // MARK: - Preview

    /// Plays the chosen sound at the *current* system volume so you can check it
    /// works without waking the house.
    func togglePreview() async {
        guard phase == .idle else { return }
        if isPreviewing {
            audio.stop()
            isPreviewing = false
            return
        }
        errorMessage = nil
        do {
            let url = try await audio.prepare(settings: settings)
            try audio.play(url)
            trackName = Self.displayName(url)
            isPreviewing = true
        } catch {
            errorMessage = error.localizedDescription
            isPreviewing = false
        }
    }

    private func stopPreview() {
        guard isPreviewing else { return }
        audio.stop()
        isPreviewing = false
    }

    // MARK: - Firing

    private func fire() {
        guard phase == .armed, let track else { return }
        phase = .firing

        let deadline = Date().addingTimeInterval(Double(settings.duration))
        blockDeadline = deadline

        priorVolume = SystemVolume.current()
        SystemVolume.set(Float(settings.volume))

        do {
            try audio.play(track)
        } catch {
            errorMessage = error.localizedDescription
        }

        sleep.preventDisplaySleep(reason: "Alarm is sounding")

        if settings.showOverlay {
            overlay.state.escapeHold = settings.escapeEnabled ? settings.escapeHold : nil
            overlay.state.remaining = Double(settings.duration)
            overlay.show()
        }

        do {
            try blocker.start(
                until: deadline,
                escapeHoldSeconds: settings.escapeEnabled ? settings.escapeHold : nil
            ) { [weak self] _ in
                self?.finish()
            }
        } catch {
            // Losing the tap shouldn't lose the alarm — keep sounding, and let
            // the ticker end it on schedule.
            errorMessage = error.localizedDescription
            hasAccessibility = InputBlocker.hasPermission
        }

        startTicker()
        tick()
    }

    /// The alarm ran its course, or was escaped. A repeating alarm lines up
    /// the next one straight away (with a fresh random pick in folder mode);
    /// only an explicit Disarm ends the series.
    private func finish() {
        guard phase == .firing else { return }
        teardown()
        if settings.repeats {
            Task { await arm() }
        }
    }

    // MARK: - Teardown

    /// Safe to call from any phase, and safe to call twice.
    func teardown() {
        blocker.stop()
        audio.stop()
        isPreviewing = false
        overlay.hide()

        if let priorVolume {
            SystemVolume.set(priorVolume)
            self.priorVolume = nil
        }

        sleep.allowDisplaySleep()
        sleep.allowIdleSleep()
        sleep.allowLidSleep()

        ticker?.invalidate()
        ticker = nil
        fireDate = nil
        blockDeadline = nil
        track = nil
        trackName = nil
        remaining = 0
        blockRemaining = 0
        phase = .idle
    }

    /// YouTube downloads are cached under a hash, so there's no useful name.
    private static func displayName(_ url: URL) -> String? {
        url.path.hasPrefix(NSHomeDirectory() + "/Library/Caches/Alarm")
            ? nil
            : url.deletingPathExtension().lastPathComponent
    }

    // MARK: - Clock

    private func startTicker() {
        ticker?.invalidate()
        // Fine-grained while firing so the escape-hold bar moves smoothly.
        let interval: TimeInterval = phase == .firing ? 0.1 : 1
        let timer = Timer(timeInterval: interval, repeats: true) { _ in
            MainActor.assumeIsolated { self.tick() }
        }
        timer.tolerance = interval / 4
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    private func tick() {
        let now = Date()
        switch phase {
        case .armed:
            guard let fireDate else { return }
            remaining = fireDate.timeIntervalSince(now)
            if remaining <= 0 { fire() }
        case .firing:
            guard let blockDeadline else { return }
            blockRemaining = blockDeadline.timeIntervalSince(now)
            overlay.state.remaining = max(0, blockRemaining)
            overlay.state.escapeProgress = blocker.escapeProgress()
            // Belt and braces: the tap thread ends the block on its own, but if
            // the tap never came up this is what stops the alarm.
            if blockRemaining <= 0 { finish() }
        case .idle, .arming:
            break
        }
    }

    /// Waking from sleep can leave the timer behind by however long we were out;
    /// re-checking immediately means a late alarm still rings.
    private func observeWake() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { self.tick() }
        }
    }
}
