//
//  AppleTTSService.swift
//  eWonicApp
//
//  Updated 2025-06-10
//  • optional voiceIdentifier override
//  • per-language preferred voice registry
//

import AVFoundation
import Combine

/// Thin wrapper around `AVSpeechSynthesizer`
final class AppleTTSService: NSObject, ObservableObject {

  private let synthesizer = AVSpeechSynthesizer()

  /// (`0.0` … `1.0`) — 0.55 ≈ normal speed.
  @Published var speech_rate: Float = 0.5

  @Published var isSpeaking = false
  let finishedSubject = PassthroughSubject<Void, Never>()

  /// Map languageCode → preferred AVSpeech voice identifier
  private var preferred_voices: [String: String] = [:]

  override init() {
    super.init()
    synthesizer.delegate = self
  }

  // ─────────────────────────────────────────────
  // MARK: – Public API
  // ─────────────────────────────────────────────

  /// Register a default voice for the given language (e.g. once at launch).
  func setPreferredVoice(identifier: String, for languageCode: String) {
    preferred_voices[languageCode] = identifier
  }

  /// Speak *text* in **languageCode**.
  /// Pass **voiceIdentifier** to override the choice just for this call.
  func speak(
    text: String,
    languageCode: String,
    voiceIdentifier: String? = nil
  ) {
    guard !text.isEmpty else { return }

    AudioSessionManager.shared.begin()

    let utt = AVSpeechUtterance(string: text)

    // 1️⃣ explicit argument
    if let id = voiceIdentifier,
       let v  = AVSpeechSynthesisVoice(identifier: id) {
      utt.voice = v

    // 2️⃣ app-wide preference
    } else if let id = preferred_voices[languageCode],
              let v  = AVSpeechSynthesisVoice(identifier: id) {
      utt.voice = v

    // 3️⃣ automatic best match
    } else {
      utt.voice = bestVoice(for: languageCode)
    }

    // rate & padding
    utt.rate              =  speech_rate
    utt.preUtteranceDelay  = 0
    utt.postUtteranceDelay = 0
      
      if let id = voiceIdentifier, let v = AVSpeechSynthesisVoice(identifier: id) {
        print("[TTS] override voice: \(v.name)")
        utt.voice = v

      } else if let id = preferred_voices[languageCode],
                let v  = AVSpeechSynthesisVoice(identifier: id) {
        print("[TTS] preferred voice: \(v.name)")
        utt.voice = v

      } else {
        let v = bestVoice(for: languageCode)
        print("[TTS] fallback voice: \(v?.name ?? "<none>")")
        utt.voice = v
      }

    synthesizer.speak(utt)
    isSpeaking = true
  }

  /// Cancel immediately.
  func stop() {
    synthesizer.stopSpeaking(at: .immediate)
    isSpeaking = false
  }

  // ─────────────────────────────────────────────
  // MARK: – Private helpers
  // ─────────────────────────────────────────────

  private func bestVoice(for languageCode: String) -> AVSpeechSynthesisVoice? {
    if #available(iOS 17.0, *) {
        print(AVSpeechSynthesisVoice.speechVoices())
      if let v = AVSpeechSynthesisVoice.speechVoices()
        .first(where: { $0.language == languageCode && $0.quality == .premium }) {
          print("my voice", v)

        return v
      }
    }
    if let v = AVSpeechSynthesisVoice.speechVoices()
      .first(where: { $0.language == languageCode && $0.quality == .enhanced }) {
        print("my voice2", v)

      return v
    }
    
      print(languageCode)
    return AVSpeechSynthesisVoice(language: languageCode)
  }

  private func clamp(_ x: Float, min: Float, max: Float) -> Float {
    Swift.min(Swift.max(x, min), max)
  }
}

// ─────────────────────────────────────────────
// MARK: – AVSpeechSynthesizerDelegate
// ─────────────────────────────────────────────

extension AppleTTSService: AVSpeechSynthesizerDelegate {
  func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish _: AVSpeechUtterance) {
    isSpeaking = false
    AudioSessionManager.shared.end()
    finishedSubject.send(())
  }
}
