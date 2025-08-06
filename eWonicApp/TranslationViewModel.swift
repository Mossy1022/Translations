//
//  TranslationViewModel.swift
//  eWonicApp
//
//  2025-06-11 – speaks **only** incoming translations
//

import Foundation
import Combine
import Speech
import AVFoundation

@MainActor
final class TranslationViewModel: ObservableObject {

  // ─────────────────────────────── Services
  @Published var multipeerSession = MultipeerSession()
  @Published var sttService       = AzureSpeechTranslationService()
  @Published var ttsService       = AppleTTSService()

  // ─────────────────────────────── UI state
  @Published var myTranscribedText         = "Tap 'Start' to speak."
  @Published var peerSaidText              = ""
  @Published var translatedTextForMeToHear = ""

  @Published var connectionStatus        = "Not Connected"
  @Published var isProcessing            = false
  @Published var permissionStatusMessage = "Checking permissions…"
  @Published var hasAllPermissions       = false
  @Published var errorMessage: String?

  // ─────────────────────────────── Languages
  @Published var myLanguage   = "en-US" { didSet { refreshVoices() } }
  @Published var peerLanguage = "es-ES" { didSet { refreshVoices() } }

  struct Language: Identifiable, Hashable {
    let id   = UUID()
    let name: String
    let code: String
  }

  let availableLanguages: [Language] = [
    .init(name:"English (US)",        code:"en-US"),
    .init(name:"Spanish (Spain)",     code:"es-ES"),
    .init(name:"French (France)",     code:"fr-FR"),
    .init(name:"German (Germany)",    code:"de-DE"),
    .init(name:"Japanese (Japan)",    code:"ja-JP"),
    .init(name:"Chinese (Simplified)",code:"zh-CN")
  ]
    
    @Published var micSensitivity: Float = 0.6   // 0...1, higher = more sensitive

  // ─────────────────────────────── Voices
  struct Voice: Identifiable, Hashable {
    let id         = UUID()
    let language:  String      // full BCP-47
    let name:      String
    let identifier:String
  }

  @Published var availableVoices: [Voice] = []

  /// languageCode → chosen voice identifier
  @Published var voice_for_lang: [String:String] = [:]

  // ─────────────────────────────── Internals
  private var cancellables            = Set<AnyCancellable>()
  private var lastReceivedTimestamp   : TimeInterval = 0
  private var wasListeningPrePlayback = false

  // ─────────────────────────────── Init
  init() {
    checkAllPermissions()
    refreshVoices()
    wireConnectionBadge()
    wirePipelines()
    wireMicPauseDuringPlayback()
      
      // Whenever the user changes voice_for_lang, push it into AppleTTSService
      $voice_for_lang
        .receive(on: RunLoop.main)
        .sink { [weak self] mapping in
          guard let self = self else { return }
          for (lang, id) in mapping {
            self.ttsService.setPreferredVoice(identifier: id, for: lang)
          }
        }
        .store(in: &cancellables)
      
    multipeerSession.errorSubject
      .receive(on: RunLoop.main)
      .sink { [weak self] msg in self?.errorMessage = msg }
      .store(in: &cancellables)
    (sttService as! AzureSpeechTranslationService).errorSubject
      .receive(on: RunLoop.main)
      .sink { [weak self] msg in self?.errorMessage = msg }
      .store(in: &cancellables)
    AudioSessionManager.shared.errorSubject
      .receive(on: RunLoop.main)
      .sink { [weak self] msg in self?.errorMessage = msg }
      .store(in: &cancellables)
    multipeerSession.onMessageReceived = { [weak self] m in
      self?.handleReceivedMessage(m)
    }
      
      $micSensitivity
          .receive(on: RunLoop.main)
          .sink { [weak self] s in
              (self?.sttService as? NativeSTTService)?.sensitivity = s
          }
          .store(in: &cancellables)
  }

  // ─────────────────────────────── Permissions
  func checkAllPermissions() {
    sttService.requestPermission { [weak self] ok in
      guard let self else { return }
      hasAllPermissions       = ok
      permissionStatusMessage = ok ? "Permissions granted."
                                   : "Speech & Microphone permission denied."
      if ok { sttService.setupSpeechRecognizer(languageCode: myLanguage) }
    }
  }

  // ─────────────────────────────── Mic control
  func startListening() {
    guard hasAllPermissions else { myTranscribedText = "Missing permissions."; return }
    guard multipeerSession.connectionState == .connected else { myTranscribedText = "Not connected."; return }
    guard !sttService.isListening else { return }

    isProcessing              = true
    myTranscribedText         = "Listening…"
    peerSaidText              = ""
    translatedTextForMeToHear = ""

    (sttService as! AzureSpeechTranslationService)
      .start(src: myLanguage, dst: peerLanguage)
  }

  func stopListening() {
    (sttService as! AzureSpeechTranslationService).stop()
    isProcessing = false
  }

  // ─────────────────────────────── Combine pipelines
  private func wirePipelines() {

    // Live partials (UI only)
    (sttService as! AzureSpeechTranslationService)
      .partialResult
      .receive(on: RunLoop.main)
      .removeDuplicates()
      .throttle(for: .milliseconds(600), scheduler: RunLoop.main, latest: true)
      .assign(to: &$translatedTextForMeToHear)

    // FINAL translation – send to peer (NO local TTS)
    (sttService as! AzureSpeechTranslationService)
      .finalResult
      .receive(on: RunLoop.main)
      .sink { [weak self] tx in
        guard let self else { return }
        isProcessing              = false
        translatedTextForMeToHear = tx
        sendTextToPeer(tx)
      }
      .store(in:&cancellables)

    // Raw sentence I spoke → UI
    (sttService as! AzureSpeechTranslationService)
      .sourceFinalResult
      .receive(on: RunLoop.main)
      .assign(to: &$myTranscribedText)
  }

  private func wireConnectionBadge() {
    multipeerSession.$connectionState
      .receive(on: RunLoop.main)
      .map { [weak self] state -> String in
        guard let self else { return "Not Connected" }
        let peer = multipeerSession.connectedPeers.first?.displayName ?? "peer"
        switch state {
        case .notConnected: return "Not Connected"
        case .connecting:   return "Connecting…"
        case .connected:    return "Connected to \(peer)"
        @unknown default:   return "Unknown"
        }
      }
      .assign(to: &$connectionStatus)
  }

  /// Pause mic while my device is **speaking** an incoming message.
  private func wireMicPauseDuringPlayback() {
    ttsService.$isSpeaking
      .receive(on: RunLoop.main)
      .removeDuplicates()
      .sink { [weak self] speaking in
        guard let self else { return }
        if speaking {
          wasListeningPrePlayback = sttService.isListening
          if wasListeningPrePlayback {
            (sttService as! AzureSpeechTranslationService).stop()
          }
        } else {
          if wasListeningPrePlayback {
            (sttService as! AzureSpeechTranslationService)
              .start(src: myLanguage, dst: peerLanguage)
            wasListeningPrePlayback = false
          }
          isProcessing = false
        }
      }
      .store(in:&cancellables)
  }

  // ─────────────────────────────── Messaging
  private func sendTextToPeer(_ translated: String) {
    guard !translated.isEmpty else { return }
    let msg = MessageData(id: UUID(),
                          originalText:       translated,
                          sourceLanguageCode: peerLanguage,
                          targetLanguageCode: peerLanguage,
                          isFinal:            true,
                          timestamp:          Date().timeIntervalSince1970)
    multipeerSession.send(message: msg, reliable: true)
  }

  private func handleReceivedMessage(_ m: MessageData) {
    guard m.timestamp > lastReceivedTimestamp else { return }
    lastReceivedTimestamp = m.timestamp

    peerSaidText              = "Peer: \(m.originalText)"
    translatedTextForMeToHear = m.originalText
    isProcessing              = true

    let chosen = voice_for_lang[m.sourceLanguageCode]   // may be nil
      ttsService.speak(
        text: m.originalText,
        languageCode: m.sourceLanguageCode
      )
  }

  // ─────────────────────────────── Voice helpers
    private func refreshVoices() {
      let langs = Set([myLanguage, peerLanguage])          // BCP-47 codes

      DispatchQueue.global(qos: .userInitiated).async { [weak self] in
        guard let self else { return }

        // 1️⃣ pull the raw list
        let rawVoices = AVSpeechSynthesisVoice.speechVoices()

        // 2️⃣ keep only the two active languages
        let filtered  = rawVoices.filter { langs.contains($0.language) }

        // 3️⃣ convert to our light-weight model
        let converted = filtered.map {
          Voice(language: $0.language,
                name:      $0.name,
                identifier:$0.identifier)
        }

        // 4️⃣ stable sort: language → name
        let sorted    = converted.sorted {
          $0.language == $1.language ? $0.name < $1.name
                                     : $0.language < $1.language
        }

        // 5️⃣ publish on the main thread
        DispatchQueue.main.async { self.availableVoices = sorted }
      }
    }


  // ─────────────────────────────── Utilities
  func resetConversationHistory() {
    myTranscribedText         = "Tap 'Start' to speak."
    peerSaidText              = ""
    translatedTextForMeToHear = ""
  }
}
