#if canImport(UIKit)
import AVFoundation
import Combine
import Foundation

final class SpeechPlaybackController: NSObject, ObservableObject {
    @Published private(set) var isSpeaking = false

    var onRangeChange: ((NSRange?) -> Void)?

    private let synthesizer = AVSpeechSynthesizer()
    private var currentUtterance: AVSpeechUtterance?
    private var audioPlayer: AVAudioPlayer?
    private var speechTask: Task<Void, Never>?
    private var progressTimer: Timer?
    private var timedRanges: [TimedRange] = []
    private var currentRange: NSRange?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    deinit {
        speechTask?.cancel()
        progressTimer?.invalidate()
        audioPlayer?.stop()
        synthesizer.stopSpeaking(at: .immediate)
    }

    func speak(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        stop()
        prepareAudioSession()
        isSpeaking = true

        guard UserDefaults.standard.bool(forKey: EdgeTTSClient.enabledDefaultsKey) else {
            speakWithSystemVoice(trimmed)
            return
        }

        speechTask = Task { [weak self] in
            do {
                let result = try await EdgeTTSClient.synthesize(trimmed)
                try Task.checkCancellation()
                self?.playEdgeSynthesis(result, sourceText: trimmed)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                print("Yomi Edge TTS failed, falling back to the system voice: \(error)")
                self?.speakWithSystemVoice(trimmed)
            }
        }
    }

    func toggle(_ text: String) {
        if isSpeaking {
            stop()
        } else {
            speak(text)
        }
    }

    func stop() {
        speechTask?.cancel()
        speechTask = nil
        progressTimer?.invalidate()
        progressTimer = nil
        audioPlayer?.stop()
        audioPlayer = nil
        currentUtterance = nil
        synthesizer.stopSpeaking(at: .immediate)
        timedRanges = []
        isSpeaking = false
        updateRange(nil)
    }

    private func prepareAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            try session.setActive(true)
        } catch {
            print("Yomi TTS audio session setup failed: \(error)")
        }
    }

    private func speakWithSystemVoice(_ text: String) {
        let utterance = AVSpeechUtterance(string: text)
        if let japaneseVoice = AVSpeechSynthesisVoice(language: "ja-JP") {
            utterance.voice = japaneseVoice
        } else {
            utterance.voice = AVSpeechSynthesisVoice()
        }
        currentUtterance = utterance
        synthesizer.speak(utterance)
    }

    private func playEdgeSynthesis(_ synthesis: EdgeTTSSynthesis, sourceText: String) {
        do {
            let player = try AVAudioPlayer(data: synthesis.audio)
            player.delegate = self
            audioPlayer = player
            timedRanges = makeTimedRanges(sourceText: sourceText, boundaries: synthesis.boundaries)
            player.prepareToPlay()

            progressTimer = Timer.scheduledTimer(
                withTimeInterval: 1.0 / 30.0,
                repeats: true
            ) { [weak self] _ in
                self?.updateEdgeProgress()
            }
            if let progressTimer {
                RunLoop.main.add(progressTimer, forMode: .common)
            }
            guard player.play() else {
                finishPlayback()
                return
            }
        } catch {
            print("Yomi Edge TTS audio playback failed: \(error)")
            finishPlayback()
        }
    }

    private func makeTimedRanges(
        sourceText: String,
        boundaries: [SpeechBoundary]
    ) -> [TimedRange] {
        let source = sourceText as NSString
        var searchLocation = 0
        var result: [TimedRange] = []

        for boundary in boundaries {
            guard searchLocation <= source.length else { break }
            let searchRange = NSRange(
                location: searchLocation,
                length: source.length - searchLocation
            )
            let range = source.range(of: boundary.text, options: [], range: searchRange)
            guard range.location != NSNotFound else { continue }

            result.append(
                TimedRange(
                    range: range,
                    offset: boundary.offset,
                    duration: boundary.duration
                )
            )
            searchLocation = NSMaxRange(range)
        }
        return result
    }

    private func updateEdgeProgress() {
        guard let player = audioPlayer, player.isPlaying else { return }
        let time = player.currentTime
        var activeRange: NSRange?

        for (index, item) in timedRanges.enumerated() where time >= item.offset {
            let nextOffset = timedRanges.indices.contains(index + 1)
                ? timedRanges[index + 1].offset
                : item.offset + max(item.duration, 0.12)
            if time < nextOffset {
                activeRange = item.range
                break
            }
        }

        updateRange(activeRange)
    }

    private func updateRange(_ range: NSRange?) {
        guard !rangesEqual(currentRange, range) else { return }
        currentRange = range
        onRangeChange?(range)
    }

    private func finishPlayback() {
        progressTimer?.invalidate()
        progressTimer = nil
        audioPlayer = nil
        speechTask = nil
        currentUtterance = nil
        timedRanges = []
        isSpeaking = false
        updateRange(nil)
    }

    private func rangesEqual(_ lhs: NSRange?, _ rhs: NSRange?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            return true
        case let (lhs?, rhs?):
            return NSEqualRanges(lhs, rhs)
        default:
            return false
        }
    }
}

extension SpeechPlaybackController: AVSpeechSynthesizerDelegate {
    func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        willSpeakRangeOfSpeechString characterRange: NSRange,
        utterance: AVSpeechUtterance
    ) {
        updateRange(characterRange)
    }

    func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didFinish utterance: AVSpeechUtterance
    ) {
        guard utterance === currentUtterance else { return }
        finishPlayback()
    }

    func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didCancel utterance: AVSpeechUtterance
    ) {
        guard utterance === currentUtterance else { return }
        finishPlayback()
    }
}

extension SpeechPlaybackController: AVAudioPlayerDelegate {
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        finishPlayback()
    }
}

private extension SpeechPlaybackController {
    struct TimedRange {
        let range: NSRange
        let offset: TimeInterval
        let duration: TimeInterval
    }
}
#endif
