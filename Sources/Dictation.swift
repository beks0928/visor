import AVFoundation
import Observation
@preconcurrency import Speech

/// Диктовка по-русски: микрофон слушается только пока кнопка включена.
/// Если система умеет распознавать речь на устройстве, звук никуда не уходит.
@MainActor @Observable
final class Dictation {
    static let shared = Dictation()

    enum State: Equatable {
        case idle, listening
        case failed(String)
    }

    private(set) var state: State = .idle
    var isListening: Bool { state == .listening }

    @ObservationIgnored private var engine: AVAudioEngine?
    @ObservationIgnored private var request: SFSpeechAudioBufferRecognitionRequest?
    @ObservationIgnored private var task: SFSpeechRecognitionTask?
    @ObservationIgnored private var base = ""
    @ObservationIgnored private var update: ((String) -> Void)?

    /// Включает или выключает диктовку. `update` получает уже склеенный текст: то, что было в поле, и сказанное.
    func toggle(current: String, update: @escaping (String) -> Void) {
        if isListening { stop() } else { Task { await start(current: current, update: update) } }
    }

    func start(current: String, update: @escaping (String) -> Void) async {
        guard !isListening else { return }
        let speech = await Self.speechAuthorization()
        guard speech == .authorized else {
            state = .failed("Нет доступа к распознаванию речи. Разрешите его в «Конфиденциальность и безопасность».")
            return
        }
        guard await AVCaptureDevice.requestAccess(for: .audio) else {
            state = .failed("Нет доступа к микрофону. Разрешите его в «Конфиденциальность и безопасность».")
            return
        }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "ru-RU")), recognizer.isAvailable else {
            state = .failed("Распознавание русской речи сейчас недоступно.")
            return
        }
        self.update = update
        base = current.trimmingCharacters(in: .whitespacesAndNewlines)

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        let engine = AVAudioEngine()
        Self.installTap(on: engine.inputNode, request: request)
        do {
            engine.prepare()
            try engine.start()
        } catch {
            state = .failed("Микрофон не включился.")
            return
        }
        self.request = request
        self.engine = engine
        task = Self.recognize(recognizer, request: request) { [weak self] text, finished in
            Task { @MainActor in self?.received(text, finished: finished) }
        }
        state = .listening
    }

    func stop() {
        guard engine != nil else { return }
        engine?.stop()
        engine?.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        engine = nil
        request = nil
        update = nil
        state = .idle
    }

    private func received(_ text: String?, finished: Bool) {
        if let text, isListening, let update {
            update(base.isEmpty ? text : base + " " + text)
        }
        if finished { task?.cancel(); task = nil }
    }

    // Обработчики звука, распознавания и запроса доступа вызываются не на главном потоке (запрос доступа вызывает фоновый
    // поток системы), поэтому создаются вне изоляции класса. Иначе Swift останавливает приложение проверкой изоляции.
    private nonisolated static func speechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
    }

    private nonisolated static func installTap(on node: AVAudioInputNode, request: SFSpeechAudioBufferRecognitionRequest) {
        let format = node.outputFormat(forBus: 0)
        node.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in request.append(buffer) }
    }

    private nonisolated static func recognize(_ recognizer: SFSpeechRecognizer, request: SFSpeechAudioBufferRecognitionRequest,
                                              handler: @escaping @Sendable (String?, Bool) -> Void) -> SFSpeechRecognitionTask {
        recognizer.recognitionTask(with: request) { result, error in
            handler(result?.bestTranscription.formattedString, result?.isFinal == true || error != nil)
        }
    }
}
