import AVFoundation
import CryptoKit
import Foundation
import UniformTypeIdentifiers

/// Gets the alarm track onto disk before the alarm, then plays it: on loop, or
/// for a folder, one random song after another.
///
/// Downloading at arm time rather than at fire time is deliberate: the blocked
/// window should be nothing but playback, never a network stall.
@MainActor
final class AudioEngine: NSObject, AVAudioPlayerDelegate {

    enum AudioError: LocalizedError {
        case noFileChosen
        case fileMissing
        case noFolderChosen
        case folderMissing
        case folderEmpty
        case badURL
        case ytDlpMissing
        case downloadFailed(String)
        case unplayable(String)

        var errorDescription: String? {
            switch self {
            case .noFileChosen:
                return "Choose an audio file first."
            case .fileMissing:
                return "That audio file has moved or been deleted. Choose it again."
            case .noFolderChosen:
                return "Choose a folder of songs first."
            case .folderMissing:
                return "That folder has moved or been deleted. Choose it again."
            case .folderEmpty:
                return "No playable audio in that folder."
            case .badURL:
                return "That doesn't look like a valid URL."
            case .ytDlpMissing:
                return "yt-dlp not found. Install it with: brew install yt-dlp"
            case .downloadFailed(let detail):
                return "Could not download the audio.\n\(detail)"
            case .unplayable(let detail):
                return "Could not play that audio: \(detail)"
            }
        }
    }

    private var player: AVAudioPlayer?

    /// The last folder song played, so a ring never starts on the song the
    /// previous one ended with.
    private var lastPick: URL?

    /// Every song in the folder, scanned once at arm time. Empty for a file or
    /// YouTube source, which is what makes `play` loop instead of moving on.
    private var folderFiles: [URL] = []

    /// The shuffled order the folder's songs play in, refilled when it runs out.
    private var upNext: [URL] = []

    /// Called each time a folder alarm moves on to another song.
    var onTrackChange: ((URL) -> Void)?

    private static let cacheDirectory = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Caches/Alarm")

    /// GUI apps inherit a bare PATH, so `yt-dlp` has to be looked up by hand.
    private static let ytDlpCandidates = [
        "/opt/homebrew/bin/yt-dlp",
        "/usr/local/bin/yt-dlp",
        "/opt/local/bin/yt-dlp",
        NSHomeDirectory() + "/.local/bin/yt-dlp",
    ]

    static var ytDlpPath: String? {
        ytDlpCandidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    var isPlaying: Bool { player?.isPlaying ?? false }

    // MARK: - Preparing

    /// Resolves the sound to a local file, downloading it if needed.
    func prepare(settings: AlarmSettings) async throws -> URL {
        folderFiles = []
        upNext = []
        switch settings.source {
        case .file:
            guard settings.soundFileName != nil else { throw AudioError.noFileChosen }
            guard let url = settings.resolvedSoundFile() else { throw AudioError.fileMissing }
            return url
        case .folder:
            guard settings.folderName != nil else { throw AudioError.noFolderChosen }
            guard let folder = settings.resolvedSoundFolder() else { throw AudioError.folderMissing }
            return try pickTrack(in: folder)
        case .youtube:
            return try await download(settings.youtubeURL)
        }
    }

    /// A random playable track from the folder. Each candidate is opened here,
    /// at arm time, so a DRM-locked or corrupt file is skipped now rather than
    /// discovered as silence when the alarm goes off. The rest of the shuffle
    /// is kept for when that song ends.
    private func pickTrack(in folder: URL) throws -> URL {
        folderFiles = Self.audioFiles(in: folder)
        guard let next = nextPlayable(after: lastPick) else { throw AudioError.folderEmpty }
        return next.url
    }

    /// Takes songs off the shuffle until one actually opens, reshuffling when it
    /// runs out. A file that won't open is dropped from the folder, so the loop
    /// ends even when nothing plays.
    private func nextPlayable(after previous: URL?) -> (url: URL, player: AVAudioPlayer)? {
        while !folderFiles.isEmpty {
            if upNext.isEmpty {
                upNext = folderFiles.shuffled()
                // Push the previous song to the back rather than dropping it, so
                // a folder with one song still works.
                if upNext.count > 1, let previous, let index = upNext.firstIndex(of: previous) {
                    upNext.append(upNext.remove(at: index))
                }
            }
            let candidate = upNext.removeFirst()
            if let player = try? AVAudioPlayer(contentsOf: candidate) {
                lastPick = candidate
                return (candidate, player)
            }
            folderFiles.removeAll { $0 == candidate }
        }
        return nil
    }

    /// Every audio file under `folder`, subfolders included, hidden files and
    /// package contents skipped.
    nonisolated static func audioFiles(in folder: URL) -> [URL] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentTypeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        return enumerator.compactMap { $0 as? URL }.filter { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true,
                  let type = values.contentType else { return false }
            return type.conforms(to: .audio)
        }
    }

    /// Downloads with the same yt-dlp invocation the script used. Cached by URL,
    /// so re-arming the same track costs nothing.
    private func download(_ urlString: String) async throws -> URL {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let parsed = URL(string: trimmed), parsed.scheme != nil
        else { throw AudioError.badURL }
        guard let ytDlp = Self.ytDlpPath else { throw AudioError.ytDlpMissing }

        try? FileManager.default.createDirectory(
            at: Self.cacheDirectory, withIntermediateDirectories: true
        )
        let digest = SHA256.hash(data: Data(trimmed.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        let destination = Self.cacheDirectory.appendingPathComponent("\(digest).m4a")
        if FileManager.default.fileExists(atPath: destination.path) { return destination }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: ytDlp)
                process.arguments = [
                    "-q", "--no-playlist",
                    "-f", "bestaudio[ext=m4a]/bestaudio",
                    "-o", destination.path,
                    trimmed,
                ]
                let errorPipe = Pipe()
                process.standardError = errorPipe
                process.standardOutput = Pipe()

                do {
                    try process.run()
                } catch {
                    continuation.resume(
                        throwing: AudioError.downloadFailed(error.localizedDescription))
                    return
                }
                let stderr = errorPipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()

                let succeeded = process.terminationStatus == 0
                    && FileManager.default.fileExists(atPath: destination.path)
                if succeeded {
                    continuation.resume()
                } else {
                    try? FileManager.default.removeItem(at: destination)
                    let message = String(decoding: stderr, as: UTF8.self)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    continuation.resume(
                        throwing: AudioError.downloadFailed(
                            message.isEmpty ? "yt-dlp exited with \(process.terminationStatus)" : message
                        ))
                }
            }
        }
        return destination
    }

    // MARK: - Playback

    /// A file or YouTube track loops indefinitely, because `afplay` stopped at the
    /// end of the track and left silence whenever the track was shorter than the
    /// block. A folder song hands over to another random song when it ends.
    func play(_ url: URL) throws {
        stop()
        do {
            start(try AVAudioPlayer(contentsOf: url))
        } catch {
            throw AudioError.unplayable(error.localizedDescription)
        }
    }

    func stop() {
        player?.stop()
        player = nil
    }

    private func start(_ player: AVAudioPlayer) {
        player.numberOfLoops = folderFiles.isEmpty ? -1 : 0
        player.volume = 1
        player.delegate = self
        player.prepareToPlay()
        player.play()
        self.player = player
    }

    /// The folder song that just ended gives way to the next one. If no other
    /// song opens (say the folder was on a drive that got unplugged), the one
    /// that ended loops rather than leaving silence.
    private func advance(from finished: ObjectIdentifier) {
        guard let current = player, ObjectIdentifier(current) == finished else { return }
        if let next = nextPlayable(after: current.url) {
            start(next.player)
            onTrackChange?(next.url)
        } else {
            // `nextPlayable` has emptied `folderFiles`, so this now loops.
            current.currentTime = 0
            start(current)
        }
    }

    /// Only reached in folder mode, since a looping player never finishes.
    /// Hops to the main actor and passes an identity, not the player, so a
    /// finish that arrives after `stop()` is ignored.
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let finished = ObjectIdentifier(player)
        Task { @MainActor in self.advance(from: finished) }
    }
}
