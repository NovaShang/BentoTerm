import Foundation
import Speech
import AVFoundation

/// SFSpeechRecognizer-based streaming transcription. Cross-platform: the only
/// iOS-specific bit is the AVAudioSession setup (macOS uses AVAudioEngine with
/// no session). Shared by iOS + macOS.
public final class AppleSpeechEngine: NSObject, SpeechEngine, @unchecked Sendable {
    private var speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()
    private var latestTranscript = ""
    public private(set) var isRecording = false

    /// Resolves `finishRecording()` once the recognizer delivers its final result
    /// (or the grace window elapses). Guarded by `finalLock` since the recognition
    /// callback and the timeout race to resume it.
    private var finalContinuation: CheckedContinuation<String, Never>?
    private let finalLock = NSLock()

    public override init() {
        super.init()
        refreshRecognizer()
    }

    /// Recreate recognizer with the locale from Settings.
    private func refreshRecognizer() {
        let key = UserDefaults.standard.string(forKey: "speech_locale") ?? "auto"
        let locale: Locale = (key == "auto") ? .current : Locale(identifier: key)
        speechRecognizer = SFSpeechRecognizer(locale: locale)
    }

    public static func requestAuthorization() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    public func startRecording(onPartialResult: @escaping @Sendable (String) -> Void) async throws {
        refreshRecognizer()
        guard let speechRecognizer, speechRecognizer.isAvailable else {
            throw SpeechError.notAvailable
        }

        #if os(iOS)
        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.record, mode: .measurement, options: .duckOthers)
        try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
        #endif

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        recognitionRequest = request

        recognitionTask = speechRecognizer.recognitionTask(with: request) { [weak self] result, error in
            if let result {
                let transcript = result.bestTranscription.formattedString
                self?.latestTranscript = transcript
                onPartialResult(transcript)
            }
            if error != nil || (result?.isFinal ?? false) {
                // Hand the final to a pending finishRecording() before tearing down.
                self?.resolveFinal()
                self?.cleanupAudio()
            }
        }

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
        }

        audioEngine.prepare()
        try audioEngine.start()
        isRecording = true
    }

    public func stopRecording() -> String? {
        guard isRecording else { return nil }
        cleanupAudio()
        let result = latestTranscript
        latestTranscript = ""
        return result.isEmpty ? nil : result
    }

    /// Stop capturing but WAIT for the recognizer's final result before returning,
    /// so a quick release doesn't drop the tail of the utterance. `endAudio()`
    /// flushes the buffered samples; the final arrives via the recognition
    /// callback (which resumes our continuation). Bounded by a grace window so a
    /// missing final can't hang the release.
    public func finishRecording() async -> String {
        guard isRecording else { return latestTranscript }
        isRecording = false
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()   // flush; final result follows

        let final = await withCheckedContinuation { (cont: CheckedContinuation<String, Never>) in
            finalLock.lock()
            finalContinuation = cont
            finalLock.unlock()
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(1500))
                self?.resolveFinal()
            }
        }
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        latestTranscript = ""
        return final
    }

    /// Resume a pending `finishRecording()` exactly once with the latest text.
    private func resolveFinal() {
        finalLock.lock()
        let cont = finalContinuation
        finalContinuation = nil
        finalLock.unlock()
        cont?.resume(returning: latestTranscript)
    }

    private func cleanupAudio() {
        isRecording = false
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        recognitionTask?.cancel()
        recognitionTask = nil
    }
}
