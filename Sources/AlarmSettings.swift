import Foundation
import Observation

/// Everything the user can set, persisted to `UserDefaults`.
///
/// The chosen audio file is kept as a bookmark rather than a path so it survives
/// being moved or renamed. The app isn't sandboxed, so a plain bookmark is
/// enough — no security scope to start and stop.
@Observable
final class AlarmSettings {

    enum SoundSource: String, CaseIterable, Identifiable {
        case file
        case folder
        case youtube

        var id: String { rawValue }
        var label: String {
            switch self {
            case .file: return "Audio file"
            case .folder: return "Folder"
            case .youtube: return "YouTube"
            }
        }
    }

    /// Ring at a clock time, or a fixed while from the moment you arm.
    enum ScheduleMode: String, CaseIterable, Identifiable {
        case at
        case after

        var id: String { rawValue }
        var label: String { self == .at ? "At" : "In" }
    }

    static let defaultYouTubeURL = "https://www.youtube.com/watch?v=zAfrHPeHZeg"

    /// Matches `DURATION` in the original script.
    static let durationChoices: [Int] = [30, 60, 180, 300, 600, 900]

    /// "In X" tops out just short of a day — past that, a clock time is clearer.
    static let countdownRange = 1...1439

    private let defaults: UserDefaults

    var hour: Int { didSet { defaults.set(hour, forKey: Key.hour) } }
    var minute: Int { didSet { defaults.set(minute, forKey: Key.minute) } }
    var duration: Int { didSet { defaults.set(duration, forKey: Key.duration) } }
    var volume: Double { didSet { defaults.set(volume, forKey: Key.volume) } }
    var source: SoundSource { didSet { defaults.set(source.rawValue, forKey: Key.source) } }
    var youtubeURL: String { didSet { defaults.set(youtubeURL, forKey: Key.youtubeURL) } }
    var showOverlay: Bool { didSet { defaults.set(showOverlay, forKey: Key.showOverlay) } }
    var escapeEnabled: Bool { didSet { defaults.set(escapeEnabled, forKey: Key.escapeEnabled) } }
    var escapeHold: Double { didSet { defaults.set(escapeHold, forKey: Key.escapeHold) } }
    var blockLidSleep: Bool { didSet { defaults.set(blockLidSleep, forKey: Key.blockLidSleep) } }
    var mode: ScheduleMode { didSet { defaults.set(mode.rawValue, forKey: Key.mode) } }

    /// `Calendar` weekdays, 1 = Sunday … 7 = Saturday. Empty means ring once.
    var repeatDays: Set<Int> {
        didSet { defaults.set(repeatDays.sorted(), forKey: Key.repeatDays) }
    }

    var countdownMinutes: Int {
        didSet {
            // Under @Observable, assigning here re-enters `didSet`; the second
            // pass is already in range and saves.
            let clamped = countdownMinutes.clamped(to: Self.countdownRange)
            guard clamped == countdownMinutes else { countdownMinutes = clamped; return }
            defaults.set(countdownMinutes, forKey: Key.countdownMinutes)
        }
    }

    /// Only a clock-time alarm repeats; "in 20 minutes" is inherently one-off.
    var repeats: Bool { mode == .at && !repeatDays.isEmpty }

    private var soundBookmark: Data? {
        didSet { defaults.set(soundBookmark, forKey: Key.soundBookmark) }
    }

    /// Cached so the UI can show a name without resolving the bookmark on every
    /// redraw (and still show something if the file has since vanished).
    private(set) var soundFileName: String? {
        didSet { defaults.set(soundFileName, forKey: Key.soundFileName) }
    }

    private var folderBookmark: Data? {
        didSet { defaults.set(folderBookmark, forKey: Key.folderBookmark) }
    }

    private(set) var folderName: String? {
        didSet { defaults.set(folderName, forKey: Key.folderName) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.hour: 7,
            Key.minute: 30,
            Key.duration: 180,
            Key.volume: 1.0,
            Key.source: SoundSource.youtube.rawValue,
            Key.youtubeURL: AlarmSettings.defaultYouTubeURL,
            Key.showOverlay: true,
            Key.escapeEnabled: false,
            Key.escapeHold: 5.0,
            Key.blockLidSleep: false,
            Key.mode: ScheduleMode.at.rawValue,
            Key.repeatDays: [Int](),
            Key.countdownMinutes: 20,
        ])
        hour = defaults.integer(forKey: Key.hour)
        minute = defaults.integer(forKey: Key.minute)
        duration = defaults.integer(forKey: Key.duration)
        volume = defaults.double(forKey: Key.volume)
        source = SoundSource(rawValue: defaults.string(forKey: Key.source) ?? "") ?? .youtube
        youtubeURL = defaults.string(forKey: Key.youtubeURL) ?? AlarmSettings.defaultYouTubeURL
        showOverlay = defaults.bool(forKey: Key.showOverlay)
        escapeEnabled = defaults.bool(forKey: Key.escapeEnabled)
        escapeHold = defaults.double(forKey: Key.escapeHold)
        blockLidSleep = defaults.bool(forKey: Key.blockLidSleep)
        soundBookmark = defaults.data(forKey: Key.soundBookmark)
        soundFileName = defaults.string(forKey: Key.soundFileName)
        mode = ScheduleMode(rawValue: defaults.string(forKey: Key.mode) ?? "") ?? .at
        repeatDays = Set(
            (defaults.array(forKey: Key.repeatDays) as? [Int] ?? []).filter { (1...7).contains($0) }
        )
        countdownMinutes = defaults.integer(forKey: Key.countdownMinutes)
            .clamped(to: Self.countdownRange)
        folderBookmark = defaults.data(forKey: Key.folderBookmark)
        folderName = defaults.string(forKey: Key.folderName)
    }

    // MARK: - Sound file

    func setSoundFile(_ url: URL) {
        soundBookmark = try? url.bookmarkData()
        soundFileName = url.lastPathComponent
    }

    /// Resolves the stored bookmark, refreshing it if the file has moved.
    func resolvedSoundFile() -> URL? {
        guard let soundBookmark else { return nil }
        var stale = false
        guard let url = try? URL(
            resolvingBookmarkData: soundBookmark, options: [], bookmarkDataIsStale: &stale
        ), FileManager.default.fileExists(atPath: url.path) else { return nil }

        if stale { self.soundBookmark = try? url.bookmarkData() }
        soundFileName = url.lastPathComponent
        return url
    }

    // MARK: - Sound folder

    func setSoundFolder(_ url: URL) {
        folderBookmark = try? url.bookmarkData()
        folderName = url.lastPathComponent
    }

    /// Same as `resolvedSoundFile`, for the folder a random track is drawn from.
    func resolvedSoundFolder() -> URL? {
        guard let folderBookmark else { return nil }
        var stale = false
        var isDirectory: ObjCBool = false
        guard let url = try? URL(
            resolvingBookmarkData: folderBookmark, options: [], bookmarkDataIsStale: &stale
        ), FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
            isDirectory.boolValue else { return nil }

        if stale { self.folderBookmark = try? url.bookmarkData() }
        folderName = url.lastPathComponent
        return url
    }

    // MARK: - Schedule

    /// When an alarm armed at `now` should ring, whichever mode is set.
    func fireDate(from now: Date = Date()) -> Date {
        switch mode {
        case .at: return nextFireDate(after: now)
        case .after: return now.addingTimeInterval(Double(countdownMinutes * 60))
        }
    }

    /// The next occurrence of `hour:minute`, tomorrow if today's has gone —
    /// same rule as `parse_clock_time` in the original script. With repeat days
    /// set, the next occurrence on one of those days.
    func nextFireDate(after now: Date = Date()) -> Date {
        var components = DateComponents()
        components.hour = hour
        components.minute = minute
        components.second = 0
        let calendar = Calendar.current
        // `matchingPolicy: .nextTime` keeps this sane across DST changes, where
        // the requested wall-clock time may not exist on that day.
        let candidates: [Date] = repeatDays.isEmpty
            ? [calendar.nextDate(after: now, matching: components, matchingPolicy: .nextTime)]
                .compactMap { $0 }
            : repeatDays.compactMap { weekday in
                var onDay = components
                onDay.weekday = weekday
                return calendar.nextDate(after: now, matching: onDay, matchingPolicy: .nextTime)
            }
        return candidates.min() ?? now.addingTimeInterval(60)
    }

    var timeAsDate: Date {
        get {
            Calendar.current.date(
                bySettingHour: hour, minute: minute, second: 0, of: Date()
            ) ?? Date()
        }
        set {
            let parts = Calendar.current.dateComponents([.hour, .minute], from: newValue)
            hour = parts.hour ?? hour
            minute = parts.minute ?? minute
        }
    }

    private enum Key {
        static let hour = "alarm.hour"
        static let minute = "alarm.minute"
        static let duration = "alarm.duration"
        static let volume = "alarm.volume"
        static let source = "alarm.source"
        static let youtubeURL = "alarm.youtubeURL"
        static let showOverlay = "alarm.showOverlay"
        static let escapeEnabled = "alarm.escapeEnabled"
        static let escapeHold = "alarm.escapeHold"
        static let blockLidSleep = "alarm.blockLidSleep"
        static let soundBookmark = "alarm.soundBookmark"
        static let soundFileName = "alarm.soundFileName"
        static let folderBookmark = "alarm.folderBookmark"
        static let folderName = "alarm.folderName"
        static let mode = "alarm.mode"
        static let repeatDays = "alarm.repeatDays"
        static let countdownMinutes = "alarm.countdownMinutes"
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

/// Weekday labels for the repeat picker, in the user's locale and week order.
enum Weekdays {
    /// 1…7 starting from the locale's first weekday (Sunday or Monday).
    static var ordered: [Int] {
        let first = Calendar.current.firstWeekday
        return (0..<7).map { (first - 1 + $0) % 7 + 1 }
    }

    static func initial(_ weekday: Int) -> String {
        Calendar.current.veryShortWeekdaySymbols[weekday - 1]
    }

    static func name(_ weekday: Int) -> String {
        Calendar.current.weekdaySymbols[weekday - 1]
    }

    /// "Once", "Every day", "Weekdays", "Weekends", or "Mon, Wed, Fri".
    static func summary(_ days: Set<Int>) -> String {
        switch days {
        case []: return "Once"
        case Set(1...7): return "Every day"
        case [2, 3, 4, 5, 6]: return "Weekdays"
        case [1, 7]: return "Weekends"
        default:
            let symbols = Calendar.current.shortWeekdaySymbols
            return ordered.filter(days.contains).map { symbols[$0 - 1] }.joined(separator: ", ")
        }
    }
}
