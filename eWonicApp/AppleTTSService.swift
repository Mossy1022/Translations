//
//  AppleTTSService.swift
//  eWonicApp
//
//  Created by Evan Moscoso on 5/18/25.
//

import AVFoundation
import Combine

/// Thin wrapper around `AVSpeechSynthesizer`
final class AppleTTSService: NSObject, ObservableObject {
  private let synthesizer = AVSpeechSynthesizer()

  @Published var isSpeaking = false
  let finishedSubject = PassthroughSubject<Void, Never>()

  override init() {
    super.init()
    synthesizer.delegate = self
  }

  /// Speak a phrase in the given BCP-47 language.
    func speak(text: String, languageCode: String) {
      print("🗣 Speaking1:")
      guard !text.isEmpty else { return }

      print("🗣 Speaking: '\(text)' in \(languageCode)")
      print("🔊 Voice available: \(String(describing: AVSpeechSynthesisVoice(language: languageCode)))")

      for voice in AVSpeechSynthesisVoice.speechVoices() {
        print("🔈 Available voice: \(voice.identifier), lang: \(voice.language), name: \(voice.name)")
      }

      // 🔊 Reset the audio session to ensure playback works after STT
      let session = AVAudioSession.sharedInstance()
      do {
        try session.setActive(false, options: .notifyOthersOnDeactivation) // ⛔ deactivate previous STT mode
        try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try session.setActive(true)
        print("✅ Audio session switched to playback")
      } catch {
        print("❌ Audio session config failed: \(error)")
      }

      let utterance = AVSpeechUtterance(string: text)
      utterance.voice = AVSpeechSynthesisVoice(language: languageCode) ?? AVSpeechSynthesisVoice(language: "en-US")
      utterance.rate = AVSpeechUtteranceDefaultSpeechRate

      synthesizer.speak(utterance)
      isSpeaking = true
    }

  /// Stop any current speech immediately.
  func stop() {
    synthesizer.stopSpeaking(at: .immediate)
    isSpeaking = false
  }
}

extension AppleTTSService: AVSpeechSynthesizerDelegate {
  func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                         didFinish utterance: AVSpeechUtterance) {
    isSpeaking = false
    finishedSubject.send(())
  }
}
