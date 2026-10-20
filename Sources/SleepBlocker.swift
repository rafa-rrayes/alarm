import Foundation
import IOKit.pwr_mgt

/// Keeps the Mac awake long enough to actually reach the alarm.
///
/// Two independent levers, because they cover different things:
///
/// * An IOKit power assertion stops *idle* sleep. No privileges, no prompt.
/// * `pmset -a disablesleep 1` is the only thing that stops *clamshell* sleep,
///   and it needs root: through a passwordless sudo rule if one is installed,
///   otherwise one admin prompt. Either way the call also detaches a watcher
///   that puts the setting back when our lockfile disappears — or when a hard
///   deadline passes, so a crash can't leave the machine unable to sleep.
@MainActor
final class SleepBlocker {

    enum LidBlockError: LocalizedError {
        case cancelled
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .cancelled:
                return "Admin permission was declined, so the lid-close block is off."
            case .failed(let detail):
                return "Could not disable lid sleep: \(detail)"
            }
        }
    }

    private var idleAssertion: IOPMAssertionID = 0
    private var displayAssertion: IOPMAssertionID = 0
    private(set) var lidBlockActive = false

    /// Root watcher polls this; its absence is the signal to restore.
    private let lockURL = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Caches/Alarm/lidblock.lock")

    // MARK: - Idle sleep (no privileges)

    func preventIdleSleep(reason: String) {
        guard idleAssertion == 0 else { return }
        var id: IOPMAssertionID = 0
        let status = IOPMAssertionCreateWithName(
            kIOPMAssertPreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason as CFString,
            &id
        )
        if status == kIOReturnSuccess { idleAssertion = id }
    }

    func allowIdleSleep() {
        guard idleAssertion != 0 else { return }
        IOPMAssertionRelease(idleAssertion)
        idleAssertion = 0
    }

    /// Only held while the alarm is actually sounding — no point burning the
    /// display awake all night.
    func preventDisplaySleep(reason: String) {
        guard displayAssertion == 0 else { return }
        var id: IOPMAssertionID = 0
        let status = IOPMAssertionCreateWithName(
            kIOPMAssertPreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason as CFString,
            &id
        )
        if status == kIOReturnSuccess { displayAssertion = id }
    }

    func allowDisplaySleep() {
        guard displayAssertion != 0 else { return }
        IOPMAssertionRelease(displayAssertion)
        displayAssertion = 0
    }

    // MARK: - Lid close (no prompt with the sudo rule, one without)

    /// `restoreBy` is a backstop: the watcher gives up and restores at that time
    /// no matter what we do.
    func blockLidSleep(restoreBy deadline: Date) async throws {
        guard !lidBlockActive else { return }

        // Already off — by LidLock, say. Nothing to do, and nothing of ours to
        // restore: turning lid sleep back on afterwards would undo that choice.
        if await Task.detached(operation: { Self.isLidSleepDisabled() }).value == true {
            lidBlockActive = true
            return
        }

        try? FileManager.default.createDirectory(
            at: lockURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: lockURL.path, contents: Data())

        do {
            // A sudoers rule for exactly these two pmset lines (LidLock installs
            // one) makes this promptless; without it, ask for the admin password.
            let set = try await Task.detached {
                try Self.execute("/usr/bin/sudo", ["-n", "/usr/bin/pmset", "-a", "disablesleep", "1"])
            }.value
            if set.status == 0 {
                let watcher = watcherCommand(
                    restore: "/usr/bin/sudo -n /usr/bin/pmset -a disablesleep 0", deadline: deadline
                )
                _ = try await Task.detached { try Self.execute("/bin/sh", ["-c", watcher]) }.value
            } else {
                let command = "/usr/bin/pmset -a disablesleep 1; "
                    + watcherCommand(restore: "/usr/bin/pmset -a disablesleep 0", deadline: deadline)
                try await runOsascript(
                    "do shell script \(appleScriptQuoted(command)) with administrator privileges"
                )
            }
            lidBlockActive = true
        } catch {
            try? FileManager.default.removeItem(at: lockURL)
            throw error
        }
    }

    /// Dropping the lockfile is enough — the watcher restores within ~2s.
    func allowLidSleep() {
        try? FileManager.default.removeItem(at: lockURL)
        lidBlockActive = false
    }

    /// Called at launch: if a previous run died mid-alarm its watcher may still
    /// be holding sleep off, and clearing the lock releases it.
    func clearStaleLidBlock() {
        try? FileManager.default.removeItem(at: lockURL)
    }

    /// `pmset -g` reports `SleepDisabled 1` while lid sleep is off; nil if it
    /// can't be read.
    nonisolated static func isLidSleepDisabled() -> Bool? {
        guard let result = try? execute("/usr/bin/pmset", ["-g"]), result.status == 0 else { return nil }
        guard let line = result.output.split(separator: "\n").first(where: { $0.contains("SleepDisabled") })
        else { return false }
        return line.split(whereSeparator: \.isWhitespace).last == "1"
    }

    // MARK: - Plumbing

    /// Detaches a watcher that runs `restore` once the lockfile is gone or the
    /// deadline passes. The loop is a fixed literal; the two variable parts
    /// arrive as $1 and $2 so nothing user-controlled is ever parsed as shell.
    private func watcherCommand(restore: String, deadline: Date) -> String {
        let watcher = """
            while [ -f "$1" ] && [ "$(date +%s)" -lt "$2" ]; do /bin/sleep 2; done; \(restore)
            """
        return """
            /usr/bin/nohup /bin/sh -c \(shellQuoted(watcher)) alarm-lid-watcher \
            \(shellQuoted(lockURL.path)) \(shellQuoted(String(Int(deadline.timeIntervalSince1970)))) \
            >/dev/null 2>&1 &
            """
    }

    private func runOsascript(_ script: String) async throws {
        let result: (status: Int32, output: String, error: String)
        do {
            result = try await Task.detached { try Self.execute("/usr/bin/osascript", ["-e", script]) }.value
        } catch {
            throw LidBlockError.failed(error.localizedDescription)
        }
        guard result.status != 0 else { return }
        // -128 is the standard "user cancelled" AppleScript code.
        if result.status == 1, result.error.contains("-128") {
            throw LidBlockError.cancelled
        }
        throw LidBlockError.failed(result.error.isEmpty ? "unknown error" : result.error)
    }

    /// Runs a command to completion. Blocking, so call it off the main actor.
    nonisolated private static func execute(
        _ path: String, _ arguments: [String]
    ) throws -> (status: Int32, output: String, error: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        try process.run()

        let output = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let error = errorPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (
            process.terminationStatus,
            String(decoding: output, as: UTF8.self),
            String(decoding: error, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    private func shellQuoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func appleScriptQuoted(_ text: String) -> String {
        let escaped = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"" + escaped + "\""
    }
}
