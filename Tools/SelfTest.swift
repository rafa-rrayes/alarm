// Exercises the parts of Alarm that are hard to eyeball in the GUI: the CoreAudio
// volume round trip, the next-occurrence scheduling rule, the lid-block lockfile
// and pmset round trip, and the event tap actually starting, suppressing, and
// stopping on its deadline.
//
// Built and run by `./selftest.sh`. It briefly blocks input for about a second
// and briefly moves the system volume, restoring both.

import AppKit
import Foundation

@main
struct SelfTest {

    static var failures = 0

    static func check(_ label: String, _ condition: Bool, _ detail: String = "") {
        let mark = condition ? "ok  " : "FAIL"
        if !condition { failures += 1 }
        print("\(mark) \(label)\(detail.isEmpty ? "" : "  — \(detail)")")
    }

    static func main() async {
        print("Alarm self-test\n")

        testFormatting()
        testScheduling()
        testRepeatAndCountdown()
        await testFolderSource()
        testVolume()
        testLidLockfile()
        await testLidSleepRoundTrip()
        await testInputBlocker()

        print("")
        if failures == 0 {
            print("all checks passed")
        } else {
            print("\(failures) check(s) failed")
            exit(1)
        }
    }

    // MARK: - Formatting

    static func testFormatting() {
        print("countdown formatting")
        check("clock 0s", Format.clock(0) == "00:00", Format.clock(0))
        check("clock 75s", Format.clock(75) == "01:15", Format.clock(75))
        check("clock 3725s", Format.clock(3725) == "1:02:05", Format.clock(3725))
        check("clock negative clamps", Format.clock(-10) == "00:00", Format.clock(-10))
        check("relative 45s", Format.relative(45) == "in 45s", Format.relative(45))
        check("relative 90m", Format.relative(5400) == "in 1h 30m", Format.relative(5400))
        check("relative 2d 3h", Format.relative(183_600) == "in 2d 3h", Format.relative(183_600))
        check("duration 90m", Format.duration(90) == "1h 30m", Format.duration(90))
        check("duration 2h", Format.duration(120) == "2h", Format.duration(120))
        check("weekday summary", Weekdays.summary([2, 3, 4, 5, 6]) == "Weekdays"
              && Weekdays.summary([]) == "Once" && Weekdays.summary(Set(1...7)) == "Every day")
        print("")
    }

    // MARK: - Scheduling

    static func testScheduling() {
        print("next-occurrence scheduling")
        let suite = "alarm.selftest.\(ProcessInfo.processInfo.processIdentifier)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            check("isolated defaults", false)
            return
        }
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = MainActor.assumeIsolated { AlarmSettings(defaults: defaults) }
        let calendar = Calendar.current
        let now = Date()

        // An hour from now should land today.
        let soon = calendar.dateComponents([.hour, .minute], from: now.addingTimeInterval(3600))
        MainActor.assumeIsolated {
            settings.hour = soon.hour ?? 0
            settings.minute = soon.minute ?? 0
        }
        let ahead = MainActor.assumeIsolated { settings.nextFireDate(after: now) }
        check(
            "time later today is today",
            ahead > now && ahead.timeIntervalSince(now) < 3700,
            "\(Int(ahead.timeIntervalSince(now)))s away"
        )

        // An hour ago should roll to tomorrow.
        let past = calendar.dateComponents([.hour, .minute], from: now.addingTimeInterval(-3600))
        MainActor.assumeIsolated {
            settings.hour = past.hour ?? 0
            settings.minute = past.minute ?? 0
        }
        let tomorrow = MainActor.assumeIsolated { settings.nextFireDate(after: now) }
        let hoursAway = tomorrow.timeIntervalSince(now) / 3600
        check(
            "time earlier today rolls to tomorrow",
            hoursAway > 22 && hoursAway < 24,
            String(format: "%.1fh away", hoursAway)
        )

        // Persistence round trip.
        MainActor.assumeIsolated {
            settings.duration = 42
            settings.volume = 0.5
            settings.youtubeURL = "https://example.com/x"
        }
        let reloaded = MainActor.assumeIsolated { AlarmSettings(defaults: defaults) }
        let persisted = MainActor.assumeIsolated {
            reloaded.duration == 42 && reloaded.volume == 0.5
                && reloaded.youtubeURL == "https://example.com/x"
        }
        check("settings persist", persisted)
        print("")
    }

    // MARK: - Repeat days and "in X"

    static func testRepeatAndCountdown() {
        print("repeat days and countdown")
        let suite = "alarm.selftest.repeat.\(ProcessInfo.processInfo.processIdentifier)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            check("isolated defaults", false)
            return
        }
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = MainActor.assumeIsolated { AlarmSettings(defaults: defaults) }
        let calendar = Calendar.current
        let now = Date()
        let today = calendar.component(.weekday, from: now)
        let weekday = { (offset: Int) in (today - 1 + offset + 7) % 7 + 1 }

        // Same clock time as an hour ago, so today's slot has already gone.
        let past = calendar.dateComponents([.hour, .minute], from: now.addingTimeInterval(-3600))
        let future = calendar.dateComponents([.hour, .minute], from: now.addingTimeInterval(3600))

        func next(_ days: Set<Int>, _ time: DateComponents) -> Date {
            MainActor.assumeIsolated {
                settings.mode = .at
                settings.hour = time.hour ?? 0
                settings.minute = time.minute ?? 0
                settings.repeatDays = days
                return settings.fireDate(from: now)
            }
        }
        func days(_ date: Date) -> Double { date.timeIntervalSince(now) / 86400 }

        let inThree = next([weekday(3)], future)
        check("single day later this week",
              calendar.component(.weekday, from: inThree) == weekday(3)
                  && days(inThree) > 2.9 && days(inThree) < 3.1,
              String(format: "%.2fd away", days(inThree)))

        let nextWeek = next([today], past)
        check("today's slot gone rolls a full week",
              days(nextWeek) > 6.9 && days(nextWeek) < 7.0,
              String(format: "%.2fd away", days(nextWeek)))

        let laterToday = next([today], future)
        check("today's slot ahead rings today", calendar.isDateInToday(laterToday)
              || laterToday.timeIntervalSince(now) < 3700)

        let soonest = next([weekday(5), weekday(2), weekday(4)], past)
        check("several days pick the soonest",
              calendar.component(.weekday, from: soonest) == weekday(2),
              String(format: "%.2fd away", days(soonest)))

        let repeatsAt = MainActor.assumeIsolated { settings.repeats }
        check("clock mode with days repeats", repeatsAt)

        // "In X": a fixed offset, and never repeating even with days set.
        let (inX, repeatsAfter) = MainActor.assumeIsolated {
            settings.mode = .after
            settings.countdownMinutes = 25
            return (settings.fireDate(from: now), settings.repeats)
        }
        check("in 25m is now + 25m", abs(inX.timeIntervalSince(now) - 1500) < 0.001)
        check("in X never repeats", !repeatsAfter)

        let clamped = MainActor.assumeIsolated { () -> (Int, Int) in
            settings.countdownMinutes = 0
            let low = settings.countdownMinutes
            settings.countdownMinutes = 5000
            return (low, settings.countdownMinutes)
        }
        check("countdown clamps", clamped == (1, 1439), "\(clamped)")

        MainActor.assumeIsolated {
            settings.countdownMinutes = 45
            settings.repeatDays = [2, 4, 6]
        }
        let reloaded = MainActor.assumeIsolated { AlarmSettings(defaults: defaults) }
        let persisted = MainActor.assumeIsolated {
            reloaded.mode == .after && reloaded.countdownMinutes == 45
                && reloaded.repeatDays == [2, 4, 6]
        }
        check("mode, days and countdown persist", persisted)
        print("")
    }

    // MARK: - Folder source

    @MainActor
    static func testFolderSource() async {
        print("folder source")
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("alarm-selftest-\(ProcessInfo.processInfo.processIdentifier)")
        let sub = root.appendingPathComponent("nested")
        let empty = root.appendingPathComponent("empty")
        try? FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let songs = ["a.wav", "b.wav", "nested/c.wav"].map { root.appendingPathComponent($0) }
        for song in songs { try? silentWAV().write(to: song) }
        try? Data("not audio".utf8).write(to: root.appendingPathComponent("notes.txt"))
        try? silentWAV().write(to: root.appendingPathComponent(".hidden.wav"))
        // Claims to be audio but isn't — must be skipped at pick time.
        try? Data("garbage".utf8).write(to: empty.appendingPathComponent("broken.mp3"))

        let found = Set(AudioEngine.audioFiles(in: root).map { $0.resolvingSymlinksInPath().path })
        let expected = Set(songs.map { $0.resolvingSymlinksInPath().path })
        check("finds audio, skips text and hidden, recurses",
              found.isSuperset(of: expected) && found.count == 4,  // + empty/broken.mp3
              "\(found.count) files")

        let suite = "alarm.selftest.folder.\(ProcessInfo.processInfo.processIdentifier)"
        guard let defaults = UserDefaults(suiteName: suite) else { return }
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = AlarmSettings(defaults: defaults)
        let engine = AudioEngine()
        settings.source = .folder
        settings.setSoundFolder(root)

        var picks: [URL] = []
        for _ in 0..<8 {
            if let pick = try? await engine.prepare(settings: settings) { picks.append(pick) }
        }
        let pickedPaths = picks.map { $0.resolvingSymlinksInPath().path }
        check("every pick is a real song",
              picks.count == 8 && pickedPaths.allSatisfy(expected.contains),
              "\(picks.count) picks")
        check("never the same song twice running",
              zip(picks, picks.dropFirst()).allSatisfy { $0 != $1 })

        // Played for real: each 0.1s song hands over to a different one, while a
        // single file keeps looping the same track.
        var played: [URL] = []
        engine.onTrackChange = { played.append($0) }
        if let first = try? await engine.prepare(settings: settings) {
            played.append(first)
            try? engine.play(first)
        }
        try? await Task.sleep(for: .seconds(1.5))
        engine.stop()
        let playedPaths = played.map { $0.resolvingSymlinksInPath().path }
        check("a folder moves on to another song when one ends",
              played.count >= 4 && playedPaths.allSatisfy(expected.contains),
              "\(played.count) songs")
        check("and never plays the same song twice running",
              zip(played, played.dropFirst()).allSatisfy { $0 != $1 })

        var changes = 0
        engine.onTrackChange = { _ in changes += 1 }
        settings.source = .file
        settings.setSoundFile(songs[0])
        if let file = try? await engine.prepare(settings: settings) { try? engine.play(file) }
        try? await Task.sleep(for: .seconds(0.5))
        check("a single file loops instead", changes == 0 && engine.isPlaying)
        engine.stop()
        engine.onTrackChange = nil
        settings.source = .folder

        settings.setSoundFolder(empty)
        do {
            _ = try await engine.prepare(settings: settings)
            check("unplayable-only folder refused", false, "picked something")
        } catch {
            check("unplayable-only folder refused",
                  error.localizedDescription == AudioEngine.AudioError.folderEmpty.errorDescription)
        }

        try? FileManager.default.removeItem(at: empty)
        do {
            _ = try await engine.prepare(settings: settings)
            check("vanished folder reported", false)
        } catch {
            check("vanished folder reported",
                  error.localizedDescription == AudioEngine.AudioError.folderMissing.errorDescription)
        }
        print("")
    }

    /// A tenth of a second of 8 kHz mono silence — the smallest file
    /// `AVAudioPlayer` will happily open.
    static func silentWAV() -> Data {
        let samples = 800
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36 + samples * 2))
        data.append(contentsOf: Array("WAVEfmt ".utf8)); append(UInt32(16))
        append(UInt16(1)); append(UInt16(1)); append(UInt32(8000)); append(UInt32(16000))
        append(UInt16(2)); append(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); append(UInt32(samples * 2))
        data.append(Data(count: samples * 2))
        return data
    }

    // MARK: - Volume

    static func testVolume() {
        print("system volume (CoreAudio)")
        guard let original = SystemVolume.current() else {
            check("read current volume", false, "no settable output device")
            print("")
            return
        }
        check("read current volume", true, String(format: "%.2f", original))

        let probe: Float = original > 0.5 ? 0.25 : 0.75
        let wrote = SystemVolume.set(probe)
        check("write volume", wrote)
        usleep(150_000)
        let readBack = SystemVolume.current() ?? -1
        check(
            "read back matches", abs(readBack - probe) < 0.05,
            String(format: "wanted %.2f got %.2f", probe, readBack)
        )

        SystemVolume.set(original)
        usleep(150_000)
        let restored = SystemVolume.current() ?? -1
        check(
            "restored to original", abs(restored - original) < 0.05,
            String(format: "%.2f", restored)
        )
        print("")
    }

    // MARK: - Lid block

    static func testLidLockfile() {
        print("lid-block lockfile")
        let before = SleepBlocker.isLidSleepDisabled()
        let blocker = MainActor.assumeIsolated { SleepBlocker() }
        let lock = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Caches/Alarm/lidblock.lock")

        // The privileged half needs a password, so only the lockfile side of the
        // handshake — the bit that tells the root watcher to restore — is checked.
        try? FileManager.default.createDirectory(
            at: lock.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: lock.path, contents: Data())
        check("lockfile created", FileManager.default.fileExists(atPath: lock.path))

        MainActor.assumeIsolated { blocker.allowLidSleep() }
        check("allowLidSleep clears it", !FileManager.default.fileExists(atPath: lock.path))

        FileManager.default.createFile(atPath: lock.path, contents: Data())
        MainActor.assumeIsolated { blocker.clearStaleLidBlock() }
        check("stale lock cleared at launch", !FileManager.default.fileExists(atPath: lock.path))

        check("pmset disablesleep untouched", SleepBlocker.isLidSleepDisabled() == before)
        print("")
    }

    /// The real pmset round trip, from both starting states — but only where it
    /// can't prompt, i.e. with a passwordless sudo rule for these two lines.
    @MainActor
    static func testLidSleepRoundTrip() async {
        print("lid-block round trip")
        guard run("/usr/bin/sudo", ["-n", "-l", "/usr/bin/pmset", "-a", "disablesleep", "1"]) == 0 else {
            print("skip no passwordless sudo rule for pmset\n")
            return
        }
        let original = SleepBlocker.isLidSleepDisabled()
        for start in [false, true] {
            _ = run("/usr/bin/sudo", ["-n", "/usr/bin/pmset", "-a", "disablesleep", start ? "1" : "0"])
            let blocker = SleepBlocker()
            do {
                try await blocker.blockLidSleep(restoreBy: Date().addingTimeInterval(60))
            } catch {
                check("blocks without a prompt (from \(start ? "off" : "on"))", false, error.localizedDescription)
                continue
            }
            check("lid sleep off while armed (was \(start ? "off" : "on"))", SleepBlocker.isLidSleepDisabled() == true)
            blocker.allowLidSleep()
            // The watcher polls every 2s.
            try? await Task.sleep(for: .seconds(3))
            check(
                start ? "an already-off setting is left alone" : "watcher turns lid sleep back on",
                SleepBlocker.isLidSleepDisabled() == start
            )
        }
        if let original {
            _ = run("/usr/bin/sudo", ["-n", "/usr/bin/pmset", "-a", "disablesleep", original ? "1" : "0"])
        }
        check("original setting restored", SleepBlocker.isLidSleepDisabled() == original)
        print("")
    }

    static func run(_ path: String, _ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return -1 }
        process.waitUntilExit()
        return process.terminationStatus
    }

    // MARK: - Input tap

    static func testInputBlocker() async {
        print("input tap")
        print("     AXIsProcessTrusted = \(InputBlocker.hasPermission)")

        // 1. Runs to its deadline and stops itself.
        let blocker = InputBlocker()
        var reason: InputBlocker.StopReason?
        let started = Date()
        do {
            try blocker.start(until: Date().addingTimeInterval(1.0), escapeHoldSeconds: 5) {
                reason = $0
            }
            check("tap created", true, "level=\(blocker.level?.rawValue ?? "?")")
        } catch {
            // Without the Accessibility grant no tap of any level can be made,
            // so this is a skip rather than a failure of the code under test.
            print("SKIP tap tests — this process has no Accessibility grant")
            print("     grant it to your terminal, or test via Alarm.app itself\n")
            return
        }

        while reason == nil, Date().timeIntervalSince(started) < 4 {
            try? await Task.sleep(for: .milliseconds(50))
        }
        let elapsed = Date().timeIntervalSince(started)
        check("stopped on its own", reason == .completed, "reason=\(String(describing: reason))")
        check(
            "stopped on schedule", elapsed > 0.9 && elapsed < 2.0,
            String(format: "%.2fs", elapsed)
        )
        try? await Task.sleep(for: .milliseconds(300))
        check("tap thread released", !blocker.isRunning)

        // 2. Can be torn down early, and the instance is reusable afterwards.
        let second = InputBlocker()
        var earlyReason: InputBlocker.StopReason?
        do {
            try second.start(until: Date().addingTimeInterval(30), escapeHoldSeconds: nil) {
                earlyReason = $0
            }
        } catch {
            check("second tap created", false, error.localizedDescription)
            return
        }
        check("second tap at same level", second.level == blocker.level)
        try? await Task.sleep(for: .milliseconds(200))
        second.stop()

        let cancelStarted = Date()
        while earlyReason == nil, Date().timeIntervalSince(cancelStarted) < 3 {
            try? await Task.sleep(for: .milliseconds(50))
        }
        check("stop() cancels early", earlyReason == .cancelled,
              "reason=\(String(describing: earlyReason))")
        check("no escape in progress", second.escapeProgress() == nil)
        print("")
    }
}
