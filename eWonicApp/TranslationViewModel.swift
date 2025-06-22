//
//  TranslationViewModel.swift
//  eWonicApp
//
//  v2 – 2025‑06‑22
//  • All Azure code removed
//  • Live pipeline: NativeSTTService → Apple26StreamingTranslationService
//

import Foundation
import Combine
import AVFoundation

@available(iOS 26.0, *)
@MainActor
final class TranslationViewModel: ObservableObject {

  // ─────────────────────────────── Services
  @Published var multipeerSession = MultipeerSession()
  @Published var sttService       = NativeSTTService()
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

  // ─────────────────────────────── Voices
  struct Voice: Identifiable, Hashable {
    let id         = UUID()
    let language:  String
    let name:      String
    let identifier:String
  }

  @Published var availableVoices: [Voice] = []
  @Published var voice_for_lang:  [String:String] = [:]

  // ─────────────────────────────── Internals
  private var cancellables            = Set<AnyCancellable>()
  private var live_translation_task:  Task<Void,Never>?
  private var lastReceivedTimestamp   : TimeInterval = 0
  private var wasListeningPrePlayback = false

  // ─────────────────────────────── Init
  init() {
    checkAllPermissions()
    refreshVoices()
    wireConnectionBadge()
    wireMicPauseDuringPlayback()
    multipeerSession.onMessageReceived = { [weak self] m in
      self?.handleReceivedMessage(m)
    }
  }

  // ─────────────────────────────── Permissions
  func checkAllPermissions() {
    sttService.requestPermission { [weak self] ok in
      guard let self else { return }
      hasAllPermissions = ok
      permissionStatusMessage = ok ? "Permissions granted."
                                   : "Speech & Microphone permission denied."
      if ok { sttService.setupSpeechRecognizer(languageCode: myLanguage) }
    }
  }

  // ─────────────────────────────── Mic control
  func startListening() {
    guard hasAllPermissions else {
      myTranscribedText = "Missing permissions."
      return
    }
    guard multipeerSession.connectionState == .connected else {
      myTranscribedText = "Not connected."
      return
    }
    guard !sttService.isListening else { return }

    // Reset UI
    isProcessing              = true
    myTranscribedText         = "Listening…"
    peerSaidText              = ""
    translatedTextForMeToHear = ""

    // (1) Start STT
    sttService.startTranscribing(languageCode: myLanguage)

    // (2) Launch live translator pipeline
    live_translation_task?.cancel()
    live_translation_task = Task { [weak self] in
      await self?.run_live_translation()
    }
  }

  func stopListening() {
    sttService.stopTranscribing()
    live_translation_task?.cancel()
    live_translation_task = nil
    isProcessing = false
  }

  // MARK: – Live streaming pipeline
  private func run_live_translation() async {
    guard let stream = try? await Apple26StreamingTranslationService.shared
      .stream(sttService.partialTokensStream(),
              from: myLanguage,
              to:   peerLanguage)
    else {
      await MainActor.run { self.isProcessing = false }
      return
    }

    do {
      for try await token in stream {
        await MainActor.run {
          self.translatedTextForMeToHear = token
        }
      }
    } catch {
      await MainActor.run {
        self.translatedTextForMeToHear = "⚠️ Translation error"
        self.isProcessing = false
      }
    }
  }

  // ─────────────────────────────── Final sentence hook
  /// Called by STT when a sentence is finished.
  private var final_sub: AnyCancellable?
  private func attach_final_sentence_handler() {
    final_sub?.cancel()
    final_sub = sttService.finalResultSubject
      .receive(on: RunLoop.main)
      .sink { [weak self] sentence in
        guard let self else { return }
        Task { @MainActor in
          self.isProcessing = true
          do {
            let tx = try await Apple26TranslationService.translate(
                sentence, from: self.myLanguage, to: self.peerLanguage)
            self.translatedTextForMeToHear = tx
            self.sendTextToPeer(tx)
            self.isProcessing = false
          } catch {
            self.translatedTextForMeToHear = "⚠️ Translation failed"
            self.isProcessing = false
          }
        }
      }
  }

  // ─────────────────────────────── Peer messaging
  private func sendTextToPeer(_ translated: String) {
    guard !translated.isEmpty else { return }
    let msg = MessageData(
      id:                   UUID(),
      originalText:         translated,
      sourceLanguageCode:   peerLanguage,
      targetLanguageCode:   peerLanguage,
      isFinal:              true,
      timestamp:            Date().timeIntervalSince1970
    )
    multipeerSession.send(message: msg, reliable: true)
  }

  private func handleReceivedMessage(_ m: MessageData) {
    guard m.timestamp > lastReceivedTimestamp else { return }
    lastReceivedTimestamp = m.timestamp

    peerSaidText              = m.originalText
    translatedTextForMeToHear = m.originalText
    isProcessing              = true

    let chosen = voice_for_lang[m.sourceLanguageCode]
    ttsService.speak(text: m.originalText,
                     languageCode: m.sourceLanguageCode,
                     voiceIdentifier: chosen)
  }

  // ─────────────────────────────── Mic pause during playback
  private func wireMicPauseDuringPlayback() {
    ttsService.$isSpeaking
      .receive(on: RunLoop.main)
      .removeDuplicates()
      .sink { [weak self] playing in
        guard let self else { return }
        if playing {
          wasListeningPrePlayback = sttService.isListening
          if wasListeningPrePlayback { stopListening() }
        } else if wasListeningPrePlayback {
          startListening()
          wasListeningPrePlayback = false
        }
      }
      .store(in: &cancellables)
  }

  // ─────────────────────────────── Connection badge
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

  // ─────────────────────────────── Voices
  private func refreshVoices() {
    let langs = Set([myLanguage, peerLanguage])
    availableVoices = AVSpeechSynthesisVoice.speechVoices()
      .filter { langs.contains($0.language) }
      .map  { Voice(language:$0.language,
                    name:     $0.name,
                    identifier:$0.identifier) }
      .sorted { $0.language == $1.language ? $0.name < $1.name
                                           : $0.language < $1.language }
  }

  // ─────────────────────────────── Utilities
  func resetConversationHistory() {
    myTranscribedText         = "Tap 'Start' to speak."
    peerSaidText              = ""
    translatedTextForMeToHear = ""
  }
}
