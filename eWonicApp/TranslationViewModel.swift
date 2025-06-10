//
//  TranslationViewModel.swift
//  eWonicApp
//
//  Mic is now auto-paused while TTS audio plays and
//  auto-resumed when playback finishes.
//  Updated 2025-06-10
//

import Foundation
import Combine
import Speech

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

  // ─────────────────────────────── Languages
  @Published var myLanguage   = "en-US" { didSet { sttService.setupSpeechRecognizer(languageCode: myLanguage) } }
  @Published var peerLanguage = "es-ES"

  struct Language: Identifiable, Hashable { let id = UUID(); let name, code: String }
  let availableLanguages: [Language] = [
    .init(name:"English (US)",        code:"en-US"),
    .init(name:"Spanish (Spain)",     code:"es-ES"),
    .init(name:"French (France)",     code:"fr-FR"),
    .init(name:"German (Germany)",    code:"de-DE"),
    .init(name:"Japanese (Japan)",    code:"ja-JP"),
    .init(name:"Chinese (Simplified)",code:"zh-CN")
  ]

  // ─────────────────────────────── Internals
  private var cancellables            = Set<AnyCancellable>()
  private var lastReceivedTimestamp   : TimeInterval = 0
  private var wasListeningPrePlayback = false       // remembers live-mic state

  // ─────────────────────────────── Init
  init() {
    checkAllPermissions()
    wireConnectionBadge()
    wireOutgoingPipelines()
    wireMicPauseDuringPlayback()
    multipeerSession.onMessageReceived = { [weak self] m in self?.handleReceivedMessage(m) }
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

  // ─────────────────────────────── Combine wiring
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

  private func wireOutgoingPipelines() {
    // Live partials – local only
    (sttService as! AzureSpeechTranslationService)
      .partialResult
      .receive(on: RunLoop.main)
      .removeDuplicates()
      .throttle(for: .milliseconds(600), scheduler: RunLoop.main, latest: true)
      .assign(to: &$translatedTextForMeToHear)

    // FINAL translation (already in peer language) → send to peer
    (sttService as! AzureSpeechTranslationService)
      .finalResult
      .receive(on: RunLoop.main)
      .sink { [weak self] tx in
        guard let self else { return }
        isProcessing              = false
        translatedTextForMeToHear = tx
        sendTextToPeer(tx)                                  // 🚀 ship it
      }
      .store(in:&cancellables)

    // ORIGINAL sentence – only for UI
    (sttService as! AzureSpeechTranslationService)
      .sourceFinalResult
      .receive(on: RunLoop.main)
      .assign(to: &$myTranscribedText)
  }

  /// Pause mic while TTS plays; resume automatically afterwards.
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
      .store(in: &cancellables)
  }

  // ─────────────────────────────── Messaging
  private func sendTextToPeer(_ translated: String) {
    guard !translated.isEmpty else { return }
    let msg = MessageData(id: UUID(),
                          originalText:       translated,      // already peer language
                          sourceLanguageCode: peerLanguage,   // store the *actual* language
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

    // 🔑 Use the message’s declared language for TTS so the correct accent is chosen
    ttsService.speak(text: m.originalText,
                     languageCode: m.sourceLanguageCode)
  }

  // ─────────────────────────────── Utilities
  func resetConversationHistory() {
    myTranscribedText         = "Tap 'Start' to speak."
    peerSaidText              = ""
    translatedTextForMeToHear = ""
  }
}
