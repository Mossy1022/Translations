//
//  TranslationViewModel.swift
//  eWonicApp
//
//  2025-08-09 – boundary-aware commit for higher accuracy in head-final/agreeing languages
//

import Foundation
import Combine
import Speech
import AVFoundation

@MainActor
final class TranslationViewModel: ObservableObject {

  // services
  @Published var multipeerSession = MultipeerSession()
  @Published var sttService       = NativeSTTService()
  @Published var ttsService       = AppleTTSService()
  private let textTranslator: TextTranslateService = TextTranslatorFactory.make()
  private let assembler = TurnAssembler()

  // UI state
  @Published var myTranscribedText         = "Tap 'Start' to speak."
  @Published var peerSaidText              = ""
  @Published var translatedTextForMeToHear = ""

  @Published var connectionStatus        = "Not Connected"
  @Published var isProcessing            = false
  @Published var permissionStatusMessage = "Checking permissions…"
  @Published var hasAllPermissions       = false
  @Published var errorMessage: String?

  // languages
  @Published var myLanguage   = "en-US" { didSet { refreshVoices(); assembler.updateTargetLanguage(myLanguage) } }
  @Published var peerLanguage = "es-ES" { didSet { refreshVoices() } }

  struct Language: Identifiable, Hashable {
    let id = UUID()
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

  // voices
  struct Voice: Identifiable, Hashable {
    let id = UUID()
    let language:  String
    let name:      String
    let identifier:String
  }

  @Published var availableVoices: [Voice] = []
  @Published var voice_for_lang: [String:String] = [:]

  // settings
  @Published var micSensitivity: Double = 0.5 {
    didSet { AudioSessionManager.shared.setInputGain(Float(micSensitivity)) }
  }
  @Published var playbackSpeed: Double = 0.55 {
    didSet { ttsService.speech_rate = Float(playbackSpeed) }
  }

  // internals
  private var cancellables            = Set<AnyCancellable>()
  private var lastReceivedTimestamp   : TimeInterval = 0
  private var wasListeningPrePlayback = false
  private var currentTurnId = UUID()
  private var currentSegmentIx = 0

  init() {
    assembler.updateTargetLanguage(myLanguage)
    assembler.onCommit = { [weak self] (committedSource: String, _: BoundaryReason) in
      self?.translateAndSpeakCommitted(committedSource)
    }

    checkAllPermissions()
    refreshVoices()
    wireConnectionBadge()
    wirePipelines()
    wireMicPauseDuringPlayback()
    AudioSessionManager.shared.setInputGain(Float(micSensitivity))
    ttsService.speech_rate = Float(playbackSpeed)

    $voice_for_lang
      .receive(on: RunLoop.main)
      .sink { [weak self] mapping in
        guard let self else { return }
        for (lang, id) in mapping { self.ttsService.setPreferredVoice(identifier: id, for: lang) }
      }
      .store(in: &cancellables)

    multipeerSession.errorSubject
      .receive(on: RunLoop.main)
      .sink { [weak self] msg in self?.errorMessage = msg }
      .store(in: &cancellables)

    AudioSessionManager.shared.errorSubject
      .receive(on: RunLoop.main)
      .sink { [weak self] msg in self?.errorMessage = msg }
      .store(in: &cancellables)

    multipeerSession.onMessageReceived = { [weak self] m in self?.handleReceivedMessage(m) }
  }

  // permissions
  func checkAllPermissions() {
    sttService.requestPermission { [weak self] ok in
      guard let self else { return }
      hasAllPermissions       = ok
      permissionStatusMessage = ok ? "Permissions granted." : "Speech & Microphone permission denied."
      if ok { sttService.setupSpeechRecognizer(languageCode: myLanguage) }
    }
  }

  // mic control
  func startListening() {
    guard hasAllPermissions else { myTranscribedText = "Missing permissions."; return }
    guard multipeerSession.connectionState == .connected else {
      myTranscribedText = "Not connected."
      return
    }
    guard !sttService.isListening else { return }

    isProcessing              = true
    myTranscribedText         = "Listening…"
    peerSaidText              = ""
    translatedTextForMeToHear = ""

    currentTurnId   = UUID()
    currentSegmentIx = 0

    sttService.startTranscribing(languageCode: myLanguage)
  }

  func stopListening() {
    sttService.stopTranscribing()
    isProcessing = false
  }

  // pipelines
  private func wirePipelines() {
    // live partials → UI only (gist)
    sttService.partialResultSubject
      .receive(on: RunLoop.main)
      .removeDuplicates()
      .throttle(for: .milliseconds(500), scheduler: RunLoop.main, latest: true)
      .assign(to: &$translatedTextForMeToHear)

    // finalized chunk → send to peers with boundary reason
    sttService.finalResultSubject
      .receive(on: RunLoop.main)
      .sink { [weak self] txt in
        guard let self else { return }
        isProcessing = false
        myTranscribedText = txt
        sendTranscriptChunkToPeers(txt, reason: sttService.lastBoundaryReason)
      }
      .store(in: &cancellables)
  }

  private func wireConnectionBadge() {
    multipeerSession.$connectionState
      .receive(on: RunLoop.main)
      .map { [weak self] state -> String in
        guard let self else { return "Not Connected" }
        let first = multipeerSession.connectedPeers.first?.displayName ?? "peer"
        switch state {
        case .notConnected: return "Not Connected"
        case .connecting:   return "Connecting…"
        case .connected:    return "Connected to \(first)"
        @unknown default:   return "Unknown"
        }
      }
      .assign(to: &$connectionStatus)
  }

  // pause mic while we speak an incoming message
  private func wireMicPauseDuringPlayback() {
    ttsService.$isSpeaking
      .receive(on: RunLoop.main)
      .removeDuplicates()
      .sink { [weak self] speaking in
        guard let self else { return }
        if speaking {
          wasListeningPrePlayback = sttService.isListening
          if wasListeningPrePlayback { sttService.stopTranscribing() }
        } else {
          if wasListeningPrePlayback {
            sttService.startTranscribing(languageCode: myLanguage)
            wasListeningPrePlayback = false
          }
          isProcessing = false
        }
      }
      .store(in:&cancellables)
  }

  // messaging
  private func sendTranscriptChunkToPeers(_ text: String, reason: BoundaryReason) {
    guard !text.isEmpty else { return }
    let msg = MessageData(
      id: UUID(),
      originalText: text,
      sourceLanguageCode: myLanguage,
      isFinal: true,
      timestamp: Date().timeIntervalSince1970,
      turnId: currentTurnId,
      segmentIndex: currentSegmentIx,
      boundaryReason: reason
    )
    currentSegmentIx += 1
    multipeerSession.send(message: msg, reliable: true)
  }

  private func handleReceivedMessage(_ m: MessageData) {
    guard m.timestamp > lastReceivedTimestamp else { return }
    lastReceivedTimestamp = m.timestamp

    // show what peer said (pre-translate), but do not speak yet
    peerSaidText = "Peer: \(m.originalText)"
    isProcessing = true

    assembler.ingest(m)
  }

  private func translateAndSpeakCommitted(_ source: String) {
    Task { [weak self] in
      guard let self else { return }
      let tgt = myLanguage

      let translated = try? await textTranslator.translate(source, from: nil, to: tgt)
      let trimmed = translated?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      let finalText = trimmed.isEmpty ? source : trimmed

      await MainActor.run {
        translatedTextForMeToHear = finalText
        let voiceOverride = voice_for_lang[tgt]
        ttsService.speak(text: finalText, languageCode: tgt, voiceIdentifier: voiceOverride)
      }
    }
  }

  // voices
  private func refreshVoices() {
    let langs = Set([myLanguage, peerLanguage])
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      guard let self else { return }
      let raw = AVSpeechSynthesisVoice.speechVoices()
      let filtered = raw.filter { langs.contains($0.language) }
      let converted = filtered.map {
        Voice(language: $0.language, name: $0.name, identifier: $0.identifier)
      }
      let sorted = converted.sorted { $0.language == $1.language ? $0.name < $1.name
                                                                 : $0.language < $1.language }
      DispatchQueue.main.async { self.availableVoices = sorted }
    }
  }

  // utils
  func resetConversationHistory() {
    myTranscribedText         = "Tap 'Start' to speak."
    peerSaidText              = ""
    translatedTextForMeToHear = ""
    assembler.reset()
  }
}
