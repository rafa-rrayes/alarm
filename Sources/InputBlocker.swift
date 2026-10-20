import ApplicationServices
import CoreGraphics
import Foundation
import os

/// Swallows every input event at the HID layer for a bounded window.
///
/// A tap at `.cghidEventTap` sits below the window server, so it catches things
/// a keyboard+mouse mask misses — media and brightness keys (which arrive as
/// `NSSystemDefined`) and trackpad gestures. Despite the old documentation, an
/// active suppressing tap there does not need root on current macOS; the
/// Accessibility grant is enough.
///
/// The tap runs on its own thread with its own run loop, and that thread owns
/// the whole lifecycle: it starts the block, times it, and ends it. Nothing here
/// depends on the main thread still being responsive, which matters a lot when
/// the failure mode is "the Mac ignores its owner".
final class InputBlocker {

    enum StopReason {
        case completed  // ran the full duration
        case escaped    // user held the escape key
        case cancelled  // app tore it down
    }

    enum BlockError: LocalizedError {
        case tapCreationFailed

        var errorDescription: String? {
            "Could not create the input tap. Grant Alarm permission under "
                + "System Settings › Privacy & Security › Accessibility."
        }
    }

    /// Where the tap ended up sitting. HID is preferred — it's below the window
    /// server, so it catches anything a session tap could be ordered behind —
    /// but a session tap suppresses keyboard, trackpad and media keys just as
    /// completely for the logged-in user, and it's the level that's reliably
    /// available with only an Accessibility grant.
    enum Level: String {
        case hid = "HID"
        case session = "session"
    }

    static let escapeKeyCode: Int64 = 53  // Esc

    private struct State {
        var deadline = Date.distantPast
        var escapeHold: TimeInterval?
        var escapeDownAt: Date?
        var stopping = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    // Touched only on the tap thread, apart from `runLoop`, which is published
    // before `start(...)` returns and read-only afterwards.
    private var tapPort: CFMachPort?
    private var source: CFRunLoopSource?
    private var timer: CFRunLoopTimer?
    private var runLoop: CFRunLoop?
    private var thread: Thread?
    private var didTearDown = false
    private var onStop: ((StopReason) -> Void)?

    var isRunning: Bool { thread != nil }

    /// Which tap level the current (or last) block used.
    private(set) var level: Level?

    /// True if the app currently holds the Accessibility grant.
    static var hasPermission: Bool { AXIsProcessTrusted() }

    /// Asks the system to show its "open Privacy & Security" prompt.
    @discardableResult
    static func requestPermission() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    // MARK: - Lifecycle

    /// Blocks input until `deadline`. `onStop` is delivered on the main queue
    /// exactly once.
    func start(
        until deadline: Date,
        escapeHoldSeconds: TimeInterval?,
        onStop: @escaping (StopReason) -> Void
    ) throws {
        guard thread == nil else { return }

        state.withLock {
            $0 = State(deadline: deadline, escapeHold: escapeHoldSeconds)
        }
        self.onStop = onStop
        didTearDown = false

        let started = OSAllocatedUnfairLock(initialState: false)
        let ready = DispatchSemaphore(value: 0)

        let thread = Thread { [weak self] in
            guard let self else {
                ready.signal()
                return
            }
            let ok = self.setUpTap()
            started.withLock { $0 = ok }
            ready.signal()
            guard ok else { return }
            CFRunLoopRun()
        }
        thread.name = "com.rafa.alarm.eventtap"
        thread.qualityOfService = .userInteractive
        self.thread = thread
        thread.start()

        ready.wait()
        guard started.withLock({ $0 }) else {
            self.thread = nil
            self.onStop = nil
            throw BlockError.tapCreationFailed
        }
    }

    /// Ends the block early. Safe to call when nothing is running.
    func stop() {
        guard let runLoop, thread != nil else { return }
        let alreadyStopping = state.withLock { state -> Bool in
            defer { state.stopping = true }
            return state.stopping
        }
        guard !alreadyStopping else { return }

        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue) { [weak self] in
            self?.tearDown(reason: .cancelled)
        }
        CFRunLoopWakeUp(runLoop)
    }

    /// 0...1 while the escape key is being held, nil otherwise. Drives the
    /// "keep holding" hint on the overlay.
    func escapeProgress() -> Double? {
        state.withLock { state in
            guard let hold = state.escapeHold, hold > 0, let downAt = state.escapeDownAt
            else { return nil }
            return min(1, Date().timeIntervalSince(downAt) / hold)
        }
    }

    // MARK: - Tap thread

    private func setUpTap() -> Bool {
        // Ask for the HID layer, settle for the session layer. Both need the
        // Accessibility grant; neither needs root.
        var port: CFMachPort?
        var chosen: Level?
        for candidate in [(Level.hid, CGEventTapLocation.cghidEventTap),
                          (Level.session, CGEventTapLocation.cgSessionEventTap)] {
            port = CGEvent.tapCreate(
                tap: candidate.1,
                place: .headInsertEventTap,     // first in line
                options: .defaultTap,           // not listen-only: we can suppress
                eventsOfInterest: ~CGEventMask(0),
                callback: { _, type, event, refcon in
                    guard let refcon else { return Unmanaged.passUnretained(event) }
                    let blocker = Unmanaged<InputBlocker>.fromOpaque(refcon).takeUnretainedValue()
                    return blocker.handle(type: type, event: event)
                },
                userInfo: Unmanaged.passUnretained(self).toOpaque()
            )
            if port != nil {
                chosen = candidate.0
                break
            }
        }
        guard let port, let chosen else { return false }
        level = chosen

        let loop = CFRunLoopGetCurrent()
        let source = CFMachPortCreateRunLoopSource(nil, port, 0)
        CFRunLoopAddSource(loop, source, .commonModes)

        // Owning the clock here — rather than relying on a main-thread timer —
        // is what guarantees the block ends even if the UI wedges.
        let timer = CFRunLoopTimerCreateWithHandler(
            nil, CFAbsoluteTimeGetCurrent() + 0.1, 0.1, 0, 0
        ) { [weak self] _ in
            self?.tick()
        }
        CFRunLoopAddTimer(loop, timer, .commonModes)

        tapPort = port
        self.source = source
        self.timer = timer
        runLoop = loop
        CGEvent.tapEnable(tap: port, enable: true)
        return true
    }

    private func tick() {
        let now = Date()
        let reason = state.withLock { state -> StopReason? in
            guard !state.stopping else { return nil }
            if now >= state.deadline {
                state.stopping = true
                return .completed
            }
            if let hold = state.escapeHold, let downAt = state.escapeDownAt,
               now.timeIntervalSince(downAt) >= hold {
                state.stopping = true
                return .escaped
            }
            return nil
        }
        if let reason { tearDown(reason: reason) }
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let now = Date()

        // Hard stop. If we somehow outlive the deadline, hand the event back
        // rather than swallow it — better a late unblock than a stuck one.
        let expired = state.withLock { now >= $0.deadline }
        if expired { return Unmanaged.passUnretained(event) }

        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tapPort { CGEvent.tapEnable(tap: tapPort, enable: true) }
            return Unmanaged.passUnretained(event)
        }

        if type == .keyDown || type == .keyUp,
           event.getIntegerValueField(.keyboardEventKeycode) == Self.escapeKeyCode {
            state.withLock { state in
                guard state.escapeHold != nil else { return }
                if type == .keyDown {
                    // Ignore auto-repeat so the hold is timed from first press.
                    if state.escapeDownAt == nil { state.escapeDownAt = now }
                } else {
                    state.escapeDownAt = nil
                }
            }
        }

        return nil  // drop it
    }

    private func tearDown(reason: StopReason) {
        guard !didTearDown else { return }
        didTearDown = true

        if let tapPort {
            CGEvent.tapEnable(tap: tapPort, enable: false)
            if let source, let runLoop {
                CFRunLoopRemoveSource(runLoop, source, .commonModes)
            }
            CFMachPortInvalidate(tapPort)
        }
        if let timer, let runLoop {
            CFRunLoopRemoveTimer(runLoop, timer, .commonModes)
            CFRunLoopTimerInvalidate(timer)
        }
        tapPort = nil
        source = nil
        timer = nil

        if let runLoop { CFRunLoopStop(runLoop) }

        let handler = onStop
        DispatchQueue.main.async { [weak self] in
            self?.thread = nil
            self?.runLoop = nil
            self?.onStop = nil
            handler?(reason)
        }
    }
}
