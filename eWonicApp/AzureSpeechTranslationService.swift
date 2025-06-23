//
//  AzureSpeechTranslationService.swift
//  eWonicApp
//
//  Speech SDK mic-to-translation service.
//  2025-06-11 – **Audio synthesis removed**
//

import Foundation
import Combine
import AVFoundation
import Speech
import MicrosoftCognitiveServicesSpeech

@MainActor
final class AzureSpeechTranslationService: NSObject, ObservableObject {

  // ─────────────────────────────────────────────
  // MARK: – Secrets
  // ─────────────────────────────────────────────
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

  // ─────────────────────────────────────────────
  // MARK: – Public surface
  // ─────────────────────────────────────────────
  @Published private(set) var isListening = false

  let partialResult     = PassthroughSubject<String,Never>() // live streaming
  let finalResult       = PassthroughSubject<String,Never>() // translated sentence
  let sourceFinalResult = PassthroughSubject<String,Never>() // raw sentence
  let audioChunk        = PassthroughSubject<Data,  Never>() // (unused)
  let errorSubject      = PassthroughSubject<String,Never>()

  private let partialStreamCont : AsyncStream<String>.Continuation
  public  let partialStream     : AsyncStream<String>

  private var recognizer : SPXTranslationRecognizer?
  private var dst_lang_2 = "es"

  // — state to auto-reconnect
  private var last_src_lang = "en-US"
  private var last_dst_lang = "es-ES"

  override init() {
    let (stream, cont) = AsyncStream<String>.makeStream(
                           bufferingPolicy:.bufferingNewest(64))
    partialStream     = stream
    partialStreamCont = cont
    super.init()
  }

  // ─────────────────────────────────────────────
  // MARK: – Permissions
  // ─────────────────────────────────────────────
  func requestPermission(_ done:@escaping(Bool)->Void) {
    SFSpeechRecognizer.requestAuthorization { auth in
      DispatchQueue.main.async {
        guard auth == .authorized else { done(false); return }
        AVAudioSession.sharedInstance().requestRecordPermission { micOK in
          DispatchQueue.main.async { done(micOK) }
        }
      }
    }
  }

  // no-op – API parity with NativeSTT
  func setupSpeechRecognizer(languageCode _: String) {}

  // ─────────────────────────────────────────────
  // MARK: – Continuous STT → translation
  // ─────────────────────────────────────────────
  func start(src: String = "en-US", dst: String = "es-ES") {
    guard !isListening else { return }

    AudioSessionManager.shared.begin()

    do {
      let cfg = try SPXSpeechTranslationConfiguration(
        subscription: AZ_KEY, region: AZ_REGION)

      cfg.speechRecognitionLanguage = src
      dst_lang_2 = String(dst.prefix(2).lowercased())
      cfg.addTargetLanguage(dst_lang_2)

      // ✂️  REMOVE built-in Azure TTS.
      // We will speak locally with AppleTTSService instead so that
      // per-language voice selections apply on device.

      last_src_lang = src
      last_dst_lang = dst

      recognizer = try SPXTranslationRecognizer(
        speechTranslationConfiguration: cfg,
        audioConfiguration: try SPXAudioConfiguration())

      hookEvents()
      try recognizer?.startContinuousRecognition()
      isListening = true

    } catch {
      var msg = "Azure recognizer failed: \(error.localizedDescription)"
      if msg.lowercased().contains("network") || msg.lowercased().contains("internet") {
        msg += "\nPlease move to an area with better signal."
      }
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

  // ─────────────────────────────────────────────
  // MARK: – Event wiring
  // ─────────────────────────────────────────────
  private func hookEvents() {

    // Live partial translation tokens
    recognizer!.addRecognizingEventHandler { [weak self] _, ev in
      guard let self,
            let txt = ev.result.translations[self.dst_lang_2] as? String
      else { return }
      DispatchQueue.main.async {
        self.partialResult.send(txt)
        self.partialStreamCont.yield(txt)
      }
    }

    // Final sentence
    recognizer!.addRecognizedEventHandler { [weak self] _, ev in
      guard let self else { return }

      let translated = (ev.result.translations[self.dst_lang_2] as? String)?
                         .trimmingCharacters(in:.whitespacesAndNewlines)

      let raw = (ev.result.text ?? "")
                  .trimmingCharacters(in:.whitespacesAndNewlines)

      DispatchQueue.main.async {
        if let tx = translated, !tx.isEmpty {
          self.finalResult.send(tx)
        } else if !raw.isEmpty {
          self.finalResult.send(raw)          // fallback
        }
        if !raw.isEmpty { self.sourceFinalResult.send(raw) }
      }
    }

    // Synth-audio passthrough now redundant (kept for future use)
    recognizer!.addSynthesizingEventHandler { [weak self] _, ev in
      guard let self, let data = ev.result.audio else { return }
      DispatchQueue.main.async { self.audioChunk.send(data) }
    }

    // Auto-reconnect on cancellation
    recognizer!.addCanceledEventHandler { [weak self] _, ev in
      guard let self else { return }
      let wasListening = self.isListening
      self.recognizer  = nil
      self.isListening = false
      var msg = "Azure cancelled (\(ev.errorCode.rawValue)): \(ev.errorDetails)"
      if ev.errorDetails.lowercased().contains("network") ||
         ev.errorDetails.lowercased().contains("internet") {
        msg += "\nPlease move to an area with better signal."
      }
      print("⚠️ \(msg)")
      errorSubject.send(msg)
      AudioSessionManager.shared.end()
      if wasListening {
        DispatchQueue.main.async {
          self.start(src:self.last_src_lang, dst:self.last_dst_lang)
        }
      }
    }
  }
}
