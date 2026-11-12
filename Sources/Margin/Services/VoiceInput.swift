import AVFoundation
import Speech
import SwiftUI

/// Speaking a note instead of typing it: the microphone into Apple's speech
/// recognition, words arriving as you say them. On this Mac when it can.
@MainActor
final class VoiceInput: ObservableObject {
    @Published private(set) var listening = false
    /// What's been heard so far.
    @Published private(set) var transcript = ""
    /// How loud, 0...1, for the little sound bars.
    @Published private(set) var level: CGFloat = 0
    @Published private(set) var problem: String?

    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private let recognizer = SFSpeechRecognizer(locale: Locale.current) ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))

    func start() {
        guard !listening else { return }
        problem = nil
        transcript = ""
        SFSpeechRecognizer.requestAuthorization { status in
            Task { @MainActor in
                guard status == .authorized else {
                    self.problem = "Allow Speech Recognition for Margin in System Settings"
                    return
                }
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    Task { @MainActor in
                        guard granted else {
                            self.problem = "Allow the microphone for Margin in System Settings"
                            return
                        }
                        self.begin()
                    }
                }
            }
        }
    }

    private func begin() {
        guard let recognizer, recognizer.isAvailable else {
            problem = "Speech recognition isn't available right now"
            return
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        self.request = request

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            request.append(buffer)
            // Loudness for the bars.
            guard let data = buffer.floatChannelData?[0] else { return }
            let count = Int(buffer.frameLength)
            var sum: Float = 0
            for i in 0..<count { sum += data[i] * data[i] }
            let rms = sqrt(sum / Float(max(count, 1)))
            let value = CGFloat(min(1, rms * 12))
            Task { @MainActor in self?.level = value }
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            problem = "Couldn't start the microphone"
            input.removeTap(onBus: 0)
            return
        }
        listening = true
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self else { return }
                if let result { self.transcript = result.bestTranscription.formattedString }
                if error != nil || result?.isFinal == true {
                    if self.listening { self.stop() }
                }
            }
        }
    }

    /// Stops listening; the transcript stays.
    func stop() {
        guard listening else { return }
        listening = false
        level = 0
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.finish()
        request = nil
        task = nil
    }

    /// Stops and forgets what was heard.
    func cancel() {
        stop()
        transcript = ""
    }
}

/// The microphone beside the note field, the size of the header's tools.
/// Listening, it turns into sound bars that move with your voice; click it
/// again (or press Return) and the words stay in the field.
struct VoiceButton: View {
    @ObservedObject var voice: VoiceInput
    let toggle: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: toggle) {
            ZStack {
                if voice.listening {
                    SoundBars(level: voice.level)
                        .transition(.iconSwap)
                } else {
                    Image(systemName: "mic")
                        .font(.system(size: 12, weight: .medium))
                        .transition(.iconSwap)
                }
            }
            .foregroundStyle(Color.primary.opacity(voice.listening || hovering ? 0.85 : 0.55))
            .frame(width: RepoHeader.toolWidth, height: RepoHeader.toolHeight)
            .background(
                RoundedRectangle(cornerRadius: RepoHeader.toolRadius, style: .continuous)
                    .fill(Color.primary.opacity(voice.listening ? 0.08 : hovering ? 0.055 : 0))
            )
            .contentShape(RoundedRectangle(cornerRadius: RepoHeader.toolRadius, style: .continuous))
            .animation(Theme.Motion.snappy, value: voice.listening)
        }
        .buttonStyle(.plain)
        .onHover { inside in withAnimation(.easeOut(duration: 0.12)) { hovering = inside } }
        .help(voice.problem ?? (voice.listening ? "Click or press Return to keep the words" : "Say it instead"))
    }
}

/// Four short bars that rise with the voice, each a little out of step.
private struct SoundBars: View {
    let level: CGFloat

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            HStack(spacing: 2) {
                ForEach(0..<4, id: \.self) { i in
                    let wobble = 0.5 + 0.5 * sin(t * 9 + Double(i) * 1.7)
                    let h = 3 + (9 * level + 2) * CGFloat(0.35 + 0.65 * wobble)
                    Capsule().frame(width: 2, height: min(13, h))
                }
            }
            .frame(height: 14)
        }
    }
}
