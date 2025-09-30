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

  /// Normalized 0…1 value bound to UI controls.
  /// Converted to an actual AVSpeechUtterance rate using ``actualRate(forNormalized:)``.
    @Published var speech_rate: Float = AppleTTSService.normalizedDefaultRate {
      didSet {
        // Clamp without reassigning the same value repeatedly
        let clamped = max(0, min(1, speech_rate))
        if clamped != speech_rate {
          speech_rate = clamped
        }
      }
    }

  private let synthesizer = AVSpeechSynthesizer()

  @Published var isSpeaking = false
  let finishedSubject = PassthroughSubject<Void, Never>()
  let startedSubject  = PassthroughSubject<Void, Never>()

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
    utt.rate              =  AppleTTSService.actualRate(forNormalized: speech_rate)
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

  func stopAtBoundary() {
    synthesizer.stopSpeaking(at: .word)
  }

  // ─────────────────────────────────────────────
  // MARK: – Private helpers
  // ─────────────────────────────────────────────

    private func bestVoice(for languageCode: String) -> AVSpeechSynthesisVoice? {
      let base = String(languageCode.prefix(2))

      if #available(iOS 17.0, *) {
        // 1) Exact dialect, Premium
        if let v = AVSpeechSynthesisVoice.speechVoices()
          .first(where: { $0.language == languageCode && $0.quality == .premium }) {
          return v
        }
        // 2) Any same-base dialect, Premium (e.g., any "es-*")
        if let v = AVSpeechSynthesisVoice.speechVoices()
          .first(where: { $0.language.hasPrefix(base + "-") && $0.quality == .premium }) {
          return v
        }
      }

      // 3) Exact dialect, Enhanced
      if let v = AVSpeechSynthesisVoice.speechVoices()
        .first(where: { $0.language == languageCode && $0.quality == .enhanced }) {
        return v
      }
      // 4) Any same-base dialect, Enhanced
      if let v = AVSpeechSynthesisVoice.speechVoices()
        .first(where: { $0.language.hasPrefix(base + "-") && $0.quality == .enhanced }) {
        return v
      }

      // 5) System default for the base language
      return AVSpeechSynthesisVoice(language: base)
    }


  private static let rateBounds: (min: Float, max: Float) = {
    let base = AVSpeechUtteranceDefaultSpeechRate
    let proposedMin = max(AVSpeechUtteranceMinimumSpeechRate, base * 0.6)
    let proposedMax = min(AVSpeechUtteranceMaximumSpeechRate, base * 1.4)
    if proposedMax - proposedMin < 0.05 {
      return (AVSpeechUtteranceMinimumSpeechRate, AVSpeechUtteranceMaximumSpeechRate)
    }
    return (proposedMin, proposedMax)
  }()

  static let normalizedDefaultRate: Float = {
    let range = rateBounds.max - rateBounds.min
    guard range > 0 else { return clamp(AVSpeechUtteranceDefaultSpeechRate,
                                        min: 0, max: 1) }
    let normalized = (AVSpeechUtteranceDefaultSpeechRate - rateBounds.min) / range
    return clamp(normalized, min: 0, max: 1)
  }()

  static func actualRate(forNormalized normalized: Float) -> Float {
    let clamped = clamp(normalized, min: 0, max: 1)
    let range = rateBounds.max - rateBounds.min
    guard range > 0 else { return AVSpeechUtteranceDefaultSpeechRate }
    return rateBounds.min + (range * clamped)
  }
}

private func clamp<T: Comparable>(_ value: T, min lower: T, max upper: T) -> T {
  precondition(lower <= upper)
  if value < lower { return lower }
  if value > upper { return upper }
  return value
}

// ─────────────────────────────────────────────
// MARK: – AVSpeechSynthesizerDelegate
// ─────────────────────────────────────────────

extension AppleTTSService: AVSpeechSynthesizerDelegate {
  func speechSynthesizer(_ s: AVSpeechSynthesizer, didStart _: AVSpeechUtterance) {
    isSpeaking = true
    startedSubject.send(())
  }

  func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish _: AVSpeechUtterance) {
    isSpeaking = false
    AudioSessionManager.shared.end()
    finishedSubject.send(())
  }
}
