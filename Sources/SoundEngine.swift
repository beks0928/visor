import AppKit
import AVFoundation
import Observation

enum SoundEvent: String, CaseIterable, Identifiable {
    case finish, approval, error, timer

    var id: String { rawValue }

    var title: String {
        switch self {
        case .finish: "Агент закончил работу"
        case .approval: "Агенту нужен ответ"
        case .error: "Ошибка"
        case .timer: "Таймер закончился"
        }
    }

    var kindName: String {
        switch self {
        case .finish: "Колокольчик"
        case .approval: "Два тона"
        case .error: "Низкий"
        case .timer: "Три удара"
        }
    }
}

/// Звуки событий. Свои звуки синтезируются в коде, файлов в приложении нет.
/// Файл с именем события (finish.wav, approval.mp3, error.m4a) в папке Sounds заменяет встроенный звук.
@MainActor @Observable
final class SoundEngine {
    static let shared = SoundEngine()

    /// Кнопка звука в шапке острова.
    var isMuted = false
    private(set) var volume: Double
    private(set) var quietHoursEnabled: Bool
    private(set) var quietStart: Int
    private(set) var quietEnd: Int
    private(set) var skipWhenTerminalFocused: Bool

    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private var live: [AVAudioPlayer] = []

    private enum Key {
        static let volume = "sound.volume"
        static let quiet = "sound.quiet.enabled"
        static let quietStart = "sound.quiet.start"
        static let quietEnd = "sound.quiet.end"
        static let skipFocused = "sound.skipTerminalFocused"
    }

    /// Окна, в которых вы и так смотрите на агента.
    private static let focusedApps: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "com.mitchellh.ghostty",
        "net.kovidgoyal.kitty", "com.github.wez.wezterm", "org.alacritty",
    ]

    private init() {
        let d = UserDefaults.standard
        volume = d.object(forKey: Key.volume) as? Double ?? 0.6
        quietHoursEnabled = d.bool(forKey: Key.quiet)
        quietStart = d.object(forKey: Key.quietStart) as? Int ?? 8 * 60
        quietEnd = d.object(forKey: Key.quietEnd) as? Int ?? 15 * 60
        skipWhenTerminalFocused = d.bool(forKey: Key.skipFocused)
    }

    func setVolume(_ value: Double) { volume = value; defaults.set(value, forKey: Key.volume) }
    func setQuietHours(_ on: Bool) { quietHoursEnabled = on; defaults.set(on, forKey: Key.quiet) }
    func setQuietStart(_ minutes: Int) { quietStart = minutes; defaults.set(minutes, forKey: Key.quietStart) }
    func setQuietEnd(_ minutes: Int) { quietEnd = minutes; defaults.set(minutes, forKey: Key.quietEnd) }
    func setSkipWhenTerminalFocused(_ on: Bool) { skipWhenTerminalFocused = on; defaults.set(on, forKey: Key.skipFocused) }

    // MARK: Воспроизведение

    /// `preview` это кнопка «Проверить»: играет всегда, кроме выключенного звука.
    func play(_ event: SoundEvent, preview: Bool = false) {
        guard !isMuted else { return }
        if !preview {
            if quietHoursEnabled, isQuietNow() { return }
            if skipWhenTerminalFocused, let id = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
               Self.focusedApps.contains(id) { return }
        }
        guard let player = makePlayer(for: event) else { return }
        player.volume = Float(volume)
        player.play()
        live.append(player)
        let keepFor = player.duration + 0.5
        Task { [weak self, weak player] in
            try? await Task.sleep(for: .seconds(keepFor))
            guard let self, let player else { return }
            self.live.removeAll { $0 === player }
        }
    }

    private func isQuietNow() -> Bool {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: Date())
        let now = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        if quietStart <= quietEnd { return now >= quietStart && now < quietEnd }
        return now >= quietStart || now < quietEnd // интервал через полночь
    }

    private func makePlayer(for event: SoundEvent) -> AVAudioPlayer? {
        for ext in ["wav", "aiff", "caf", "m4a", "mp3"] {
            let url = VisorPaths.soundsDir.appendingPathComponent(event.rawValue).appendingPathExtension(ext)
            if FileManager.default.isReadableFile(atPath: url.path), let player = try? AVAudioPlayer(contentsOf: url) {
                return player
            }
        }
        return try? AVAudioPlayer(data: Self.synthesize(event))
    }

    func revealCustomFolder() {
        try? FileManager.default.createDirectory(at: VisorPaths.soundsDir, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([VisorPaths.soundsDir])
    }

    // MARK: Синтез

    private struct Note {
        let frequency: Double
        let duration: Double
        let start: Double
    }

    nonisolated static func synthesize(_ event: SoundEvent) -> Data {
        switch event {
        case .finish: // восходящий колокольчик
            return wav(notes: [Note(frequency: 659.25, duration: 0.5, start: 0),
                               Note(frequency: 880.0, duration: 0.5, start: 0.13),
                               Note(frequency: 1108.7, duration: 0.9, start: 0.26)], triangle: false)
        case .approval: // два одинаковых тона
            return wav(notes: [Note(frequency: 783.99, duration: 0.3, start: 0),
                               Note(frequency: 783.99, duration: 0.4, start: 0.18)], triangle: false)
        case .timer: // три удара, последний выше
            return wav(notes: [Note(frequency: 880.0, duration: 0.3, start: 0),
                               Note(frequency: 880.0, duration: 0.3, start: 0.22),
                               Note(frequency: 1174.66, duration: 0.7, start: 0.44)], triangle: false)
        case .error: // нисходящий низкий
            return wav(notes: [Note(frequency: 246.94, duration: 0.4, start: 0),
                               Note(frequency: 185.0, duration: 0.7, start: 0.22)], triangle: true)
        }
    }

    private nonisolated static func wav(notes: [Note], triangle: Bool) -> Data {
        let rate = 44100.0
        let total = (notes.map { $0.start + $0.duration }.max() ?? 0.5) + 0.05
        var samples = [Double](repeating: 0, count: Int(total * rate))
        for note in notes {
            let begin = Int(note.start * rate)
            let count = Int(note.duration * rate)
            for i in 0..<count where begin + i < samples.count {
                let t = Double(i) / rate
                let attack = min(1, t / 0.008)
                let decay = exp(-t * 5.5 / note.duration)
                let phase = 2 * Double.pi * note.frequency * t
                let tone: Double
                if triangle {
                    tone = (2 / Double.pi) * asin(sin(phase))
                } else {
                    tone = sin(phase) + 0.3 * sin(2 * phase) + 0.08 * sin(3 * phase)
                }
                samples[begin + i] += tone * attack * decay
            }
        }
        let peak = max(samples.map { abs($0) }.max() ?? 1, 0.0001)
        var pcm = Data()
        for sample in samples {
            let value = Int16(max(-1, min(1, sample / peak * 0.8)) * Double(Int16.max))
            withUnsafeBytes(of: value.littleEndian) { pcm.append(contentsOf: $0) }
        }

        var header = Data()
        func put32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { header.append(contentsOf: $0) } }
        func put16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { header.append(contentsOf: $0) } }
        header.append(contentsOf: Array("RIFF".utf8)); put32(UInt32(36 + pcm.count))
        header.append(contentsOf: Array("WAVEfmt ".utf8)); put32(16); put16(1); put16(1)
        put32(UInt32(rate)); put32(UInt32(rate) * 2); put16(2); put16(16)
        header.append(contentsOf: Array("data".utf8)); put32(UInt32(pcm.count))
        return header + pcm
    }
}
