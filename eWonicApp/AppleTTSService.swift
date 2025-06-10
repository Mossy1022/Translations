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

//      for voice in AVSpeechSynthesisVoice.speechVoices() {
//        print("🔈 Available voice: \(voice.identifier), lang: \(voice.language), name: \(voice.name)")
//      }

      AudioSessionManager.shared.begin()

      let utterance = AVSpeechUtterance(string: text)
      utterance.voice = bestVoice(for: languageCode)
      utterance.rate = AVSpeechUtteranceDefaultSpeechRate

      synthesizer.speak(utterance)
      isSpeaking = true
    }

  /// Choose the highest quality voice for a given language, if available.
  private func bestVoice(for languageCode: String) -> AVSpeechSynthesisVoice? {
    // Search for a premium voice first when running on iOS 17 or later.
    if #available(iOS 17.0, *) {
      if let v = AVSpeechSynthesisVoice.speechVoices()
                   .first(where: { $0.language == languageCode && $0.quality == .premium }) {
        return v
      }
    }

    // Fallback to any enhanced voice for this language.
    if let v = AVSpeechSynthesisVoice.speechVoices()
                 .first(where: { $0.language == languageCode && $0.quality == .enhanced }) {
      return v
    }

    // Otherwise use the default voice.
    return AVSpeechSynthesisVoice(language: languageCode)
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
    AudioSessionManager.shared.end()
    finishedSubject.send(())
  }
}
