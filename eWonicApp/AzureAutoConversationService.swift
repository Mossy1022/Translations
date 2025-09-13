//
//  AzureAutoConversationService.swift
//  eWonicApp
//
//  Mic → auto-detect (EN/ES) → live translations to the opposite side.
//  Detect pool obeys Azure’s limit of 4 candidates.
//  Always includes: en-US, es-US, es-MX, plus the first of (a,b) not already present.
//

import Foundation
import Combine
import AVFoundation
import MicrosoftCognitiveServicesSpeech
import NaturalLanguage

@MainActor
final class AzureAutoConversationService: NSObject, ObservableObject {

  // Public
  @Published private(set) var isListening = false

  /// Live partials: (detectedSourceLang?, partialTranslatedText, chosenTarget2Key)
  let partial = PassthroughSubject<(String?, String, String), Never>()

  /// Finals: (detectedSourceLang, rawSource, finalTranslatedText, chosenTarget2Key)
  let final   = PassthroughSubject<(String, String, String, String), Never>()

  let errorSubject = PassthroughSubject<String, Never>()

  // Private
  private var recognizer: SPXTranslationRecognizer?

  private let AZ_KEY: String = {
    guard let k = Bundle.main.object(forInfoDictionaryKey: "AZ_KEY") as? String
    else { fatalError("AZ_KEY missing from Info.plist") }
    return k.trimmingCharacters(in: .whitespacesAndNewlines)
  }()

  private let AZ_REGION: String = {
    guard let r = Bundle.main.object(forInfoDictionaryKey: "AZ_REGION") as? String
    else { fatalError("AZ_REGION missing from Info.plist") }
    return r.trimmingCharacters(in: .whitespacesAndNewlines)
  }()

  private var langA = "en-US"   // UI left
  private var langB = "es-US"   // UI right (LatAm)
  private var tgtA2 = "en"
  private var tgtB2 = "es"

  // MARK: Start/Stop
  func start(between a: String, and b: String) {
    guard !isListening else { return }
    AudioSessionManager.shared.begin()

    langA = a; langB = b
    tgtA2 = String(a.prefix(2)).lowercased()
    tgtB2 = String(b.prefix(2)).lowercased()

    do {
      let cfg = try SPXSpeechTranslationConfiguration(subscription: AZ_KEY, region: AZ_REGION)
      cfg.addTargetLanguage(tgtA2)
      cfg.addTargetLanguage(tgtB2)

      // Build ≤4 detect candidates
      let candidates = detectPool(for: a, and: b)
      print("[Auto] Detect pool: \(candidates)")
      let auto  = try SPXAutoDetectSourceLanguageConfiguration(candidates)
      let audio = try SPXAudioConfiguration()

      recognizer = try SPXTranslationRecognizer(
        speechTranslationConfiguration: cfg,
        autoDetectSourceLanguageConfiguration: auto,
        audioConfiguration: audio
      )

      hookEvents()
      try recognizer?.startContinuousRecognition()
      isListening = true

    } catch {
      let msg = "Azure auto-conversation failed: \(error.localizedDescription)"
      print("❌ \(msg)")
      errorSubject.send(msg)
      AudioSessionManager.shared.end()
    }
  }

  func stop() {
    guard isListening else { return }
    try? recognizer?.stopContinuousRecognition()
    recognizer = nil
    isListening = false
    AudioSessionManager.shared.end()
  }

  // MARK: Detect Pool (max 4)
  private func detectPool(for a: String, and b: String) -> [String] {
    var pool: [String] = ["en-US", "es-US", "es-MX"]
    func add(_ code: String) {
      if pool.count < 4 && !pool.contains(code) { pool.append(code) }
    }
    add(a)
    add(b)
    return pool
  }

  // MARK: Event wiring
  private func hookEvents() {

    // Live partial translation tokens
    recognizer!.addRecognizingEventHandler { [weak self] _, ev in
      guard let self else { return }

      let rawText = (ev.result.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

      let rawDet = ev.result.properties?
        .getPropertyByName("SpeechServiceConnection_AutoDetectSourceLanguageResult") ?? ""
      let azDet2 = String(rawDet.trimmingCharacters(in: .whitespacesAndNewlines).prefix(2)).lowercased()

      var det2: String = azDet2
      if det2.isEmpty {
        det2 = Self.guessBase2(from: rawText) ?? self.tgtA2
      }
      let target2 = (det2 == self.tgtA2) ? self.tgtB2 : self.tgtA2
      let safeDetectedFull = (det2 == self.tgtA2) ? self.langA : self.langB

      if let text = ev.result.translations[target2] as? String, !text.isEmpty {
        DispatchQueue.main.async { self.partial.send((safeDetectedFull, text, target2)) }
      }
    }

    // Final sentence
    recognizer!.addRecognizedEventHandler { [weak self] _, ev in
      guard let self else { return }

      let rawText = (ev.result.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

      let rawDet = ev.result.properties?
        .getPropertyByName("SpeechServiceConnection_AutoDetectSourceLanguageResult") ?? ""
      var azDet2 = String(rawDet.trimmingCharacters(in: .whitespacesAndNewlines).prefix(2)).lowercased()

      let enTx = (ev.result.translations["en"] as? String)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      let esTx = (ev.result.translations["es"] as? String)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

      var det2 = azDet2
      if det2.isEmpty && !rawText.isEmpty {
        if enTx == rawText && esTx != rawText { det2 = "en" }
        else if esTx == rawText && enTx != rawText { det2 = "es" }
      }
      if det2.isEmpty {
        det2 = Self.guessBase2(from: rawText) ?? self.tgtA2
      }

      let target2 = (det2 == self.tgtA2) ? self.tgtB2 : self.tgtA2
      let safeDetectedFull = (det2 == self.tgtA2) ? self.langA : self.langB

      let raw = rawText
      let tx  = (ev.result.translations[target2] as? String)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

      if !tx.isEmpty || !raw.isEmpty {
        DispatchQueue.main.async { self.final.send((safeDetectedFull, raw, tx, target2)) }
      }
    }

    // Cancellation
    recognizer!.addCanceledEventHandler { [weak self] _, ev in
      guard let self else { return }
      let msg = "Auto-conversation cancelled (\(ev.errorCode.rawValue)): \(ev.errorDetails ?? "")"
      print("⚠️ \(msg)")
      DispatchQueue.main.async {
        self.errorSubject.send(msg)
        self.stop()
      }
    }
  }
}

// MARK: - Helpers
private extension AzureAutoConversationService {
  /// Guess "en" vs "es" using NaturalLanguage + heuristics.
  static func guessBase2(from raw: String) -> String? {
    guard !raw.isEmpty else { return nil }
    if #available(iOS 12.0, *) {
      let r = NLLanguageRecognizer()
      r.processString(raw)
      if let lang = r.dominantLanguage {
        if lang == .english { return "en" }
        if lang == .spanish { return "es" }
      }
    }
    // Simple heuristic for Spanish characters
    if raw.range(of: #"[áéíóúñ¿¡]"#, options: .regularExpression) != nil { return "es" }
    return nil
  }
}
