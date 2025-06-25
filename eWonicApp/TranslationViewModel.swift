//
//  TranslationViewModel.swift
//  eWonicApp
//
//  v2.0 – six-way multilingual lobby
//  • broadcasts raw speech to everyone
//  • each phone translates inbound text to *its* language
//  • preserves all previous error / permission plumbing
//

import Foundation
import Combine
import Speech
import AVFoundation

@MainActor
final class TranslationViewModel: ObservableObject {

  // ─────────────────────────────── Services
  @Published var multipeerSession = MultipeerSession()
  @Published var sttService       = NativeSTTService()        // raw STT only
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
  @Published var peerLanguage = "es-ES" { didSet { refreshVoices() } } // kept for UI compatibility

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
    wireSTTPipelines()
    wireMicPauseDuringPlayback()

    // Multipeer errors
    multipeerSession.errorSubject
      .receive(on: RunLoop.main)
      .sink { [weak self] msg in self?.errorMessage = msg }
      .store(in: &cancellables)

    // STT errors
    sttService.errorSubject
      .receive(on: RunLoop.main)
      .sink { [weak self] err in self?.errorMessage = err.localizedDescription }
      .store(in:&cancellables)

    // Inbound messages
    multipeerSession.onMessageReceived = { [weak self] m in
      self?.handleReceivedMessage(m)
    }
  }

  // ─────────────────────────────── Permissions
  func checkAllPermissions() {
    sttService.requestPermission { [weak self] ok in
      guard let self else { return }
      hasAllPermissions       = ok
      permissionStatusMessage = ok ? "Permissions granted."
                                   : "Speech & Microphone permission denied."
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

    sttService.startTranscribing(languageCode: myLanguage)
  }

  func stopListening() {
    sttService.stopTranscribing()
    isProcessing = false
  }

  // ─────────────────────────────── Combine pipelines
  private func wireSTTPipelines() {

    // Live partials → UI only
    sttService.partialResultSubject
      .receive(on: RunLoop.main)
      .removeDuplicates()
      .throttle(for: .milliseconds(600), scheduler: RunLoop.main, latest: true)
      .assign(to: &$translatedTextForMeToHear)

    // FINAL raw sentence – broadcast to lobby
    sttService.finalResultSubject
      .receive(on: RunLoop.main)
      .sink { [weak self] raw in
        guard let self else { return }
        isProcessing              = false
        translatedTextForMeToHear = ""            // clear live overlay

        // UI mirror of what *I* just said
        myTranscribedText = raw

        sendRawToPeers(raw)
      }
      .store(in:&cancellables)
  }

  private func wireConnectionBadge() {
    multipeerSession.$connectionState
      .receive(on: RunLoop.main)
      .map { [weak self] state -> String in
        guard let self else { return "Not Connected" }
        let count = multipeerSession.connectedPeers.count
        switch state {
        case .notConnected: return "Not Connected"
        case .connecting:   return "Connecting…"
        case .connected:    return "Connected (\(count))"
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
              sttService.pause()
            } else {
              sttService.resume()
            }
      }
      .store(in:&cancellables)
  }

  // ─────────────────────────────── Messaging
  private func sendRawToPeers(_ raw: String) {
    guard !raw.isEmpty else { return }
    let pkt = MessageData(
      id: UUID(),
      text: raw,
      source_language: myLanguage,
      is_final: true,
      timestamp: Date().timeIntervalSince1970
    )
      multipeerSession.send(message: pkt, reliable: true)
  }

  private func handleReceivedMessage(_ m: MessageData) {
    guard m.timestamp > lastReceivedTimestamp else { return }
    lastReceivedTimestamp = m.timestamp

    // Show raw for debugging
    peerSaidText = "Peer: \(m.text)"
    isProcessing = true

    Task { [mLang = myLanguage] in
      let translated = try? await UnifiedTranslateService.translate(
        m.text, from: m.source_language, to: mLang)
      await MainActor.run {
        translatedTextForMeToHear = translated ?? m.text
        let chosen = voice_for_lang[mLang]          // may be nil
        ttsService.speak(text: translated ?? m.text,
                         languageCode: mLang,
                         voiceIdentifier: chosen)
      }
    }
  }

  // ─────────────────────────────── Voice helpers
  private func refreshVoices() {
    let langs = Set([myLanguage, peerLanguage])          // BCP-47 codes

    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      guard let self else { return }

      let filtered = AVSpeechSynthesisVoice.speechVoices().filter {
        langs.contains($0.language)
      }

      let converted = filtered.map {
        Voice(language: $0.language,
              name: $0.name,
              identifier: $0.identifier)
      }
      let sorted = converted.sorted {
        $0.language == $1.language ? $0.name < $1.name
                                   : $0.language < $1.language
      }
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
