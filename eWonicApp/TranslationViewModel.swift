//
//  TranslationViewModel.swift
//  eWonicApp
//

import Foundation
import Combine
import Speech

// ──────────────────────────────────────────────────────────
// MARK: – Make the global STTError equatable so `==` works
// ──────────────────────────────────────────────────────────
extension STTError: Equatable {
  public static func == (lhs: STTError, rhs: STTError) -> Bool {
    switch (lhs, rhs) {
    case (.unavailable,      .unavailable),
         (.permissionDenied, .permissionDenied),
         (.noAudioInput,     .noAudioInput):
      return true
    case (.taskError(let l), .taskError(let r)):
      return l == r
    case (.recognitionError, .recognitionError):
      return true          // we don’t compare the embedded Error
    default:
      return false
    }
  }
}

// ──────────────────────────────────────────────────────────
// MARK: – View-model
// ──────────────────────────────────────────────────────────
@MainActor
final class TranslationViewModel: ObservableObject {

  // Public services
  @Published var multipeerSession = MultipeerSession()
  @Published var sttService       = NativeSTTService()
  @Published var ttsService       = AppleTTSService()

  // UI-bound state
  @Published var myTranscribedText         = "Tap 'Start Listening' to speak."
  @Published var peerSaidText              = ""
  @Published var translatedTextForMeToHear = ""
  @Published var translationForPeerToSend  = ""

  @Published var connectionStatus        = "Not Connected"
  @Published var isProcessing            = false
  @Published var permissionStatusMessage = "Checking permissions…"
  @Published var hasAllPermissions       = false

  // Language selection
  @Published var myLanguage: String = "en-US" {
    didSet { sttService.setupSpeechRecognizer(languageCode: myLanguage) }
  }
  @Published var peerLanguage: String = "es-ES"

  struct Language: Identifiable, Hashable { let id = UUID(); let name: String; let code: String }
  let availableLanguages: [Language] = [
    .init(name: "English (US)", code: "en-US"),
    .init(name: "Spanish (Spain)", code: "es-ES"),
    .init(name: "French (France)",  code: "fr-FR"),
    .init(name: "German (Germany)", code: "de-DE"),
    .init(name: "Japanese (Japan)", code: "ja-JP"),
    .init(name: "Chinese (Mandarin, Simplified)", code: "zh-CN")
  ]

  // Internals
  private var lastReceivedTimestamp: TimeInterval = 0
  private var cancellables = Set<AnyCancellable>()

  // ────────────────────────────────
  // MARK: Init
  // ────────────────────────────────
  init() {
    checkAllPermissions()
    sttService.setupSpeechRecognizer(languageCode: myLanguage)

    // ––––– MC-session state → connection pill –––––
    multipeerSession.onMessageReceived = { [weak self] msg in
      self?.handleReceivedMessage(msg)
    }

    multipeerSession.$connectionState
      .receive(on: RunLoop.main)   // << guarantee main thread
      .map { [weak self] state -> String in
        guard let self else { return "Not Connected" }
        let peer = multipeerSession.connectedPeers.first?.displayName ?? "peer"
        switch state {
        case .notConnected: return "Not Connected"
        case .connecting:   return "Connecting…"
        case .connected:    return "Connected to \(peer)"
        @unknown default:   return "Unknown Connection State"
        }
      }
      .assign(to: &$connectionStatus)

    // ––––– STT partials –––––
    sttService.partialResultSubject
      .receive(on: RunLoop.main)
      .sink { [weak self] txt in
        guard let self else { return }
        myTranscribedText = "Listening: \(txt)…"
        sendTextToPeer(originalText: txt, isFinal: false)
      }
      .store(in: &cancellables)

    // ––––– STT finals / errors –––––
    sttService.finalResultSubject
      .receive(on: RunLoop.main)
      .sink(receiveCompletion: { [weak self] comp in
        guard let self else { return }
        isProcessing = false
        if case .failure(let e) = comp {
          myTranscribedText = "STT Error: \(e.localizedDescription)"
          if e == .noAudioInput { myTranscribedText = "Didn't hear that. Try again." }
        }
      }, receiveValue: { [weak self] txt in
        guard let self else { return }
        myTranscribedText = "You said: \(txt)"
        sendTextToPeer(originalText: txt, isFinal: true)
      })
      .store(in: &cancellables)

    // ––––– TTS finished –––––
    ttsService.finishedSubject
      .receive(on: RunLoop.main)
      .sink { [weak self] in self?.isProcessing = false }
      .store(in: &cancellables)
  }

  // ────────────────────────────────
  // MARK: Permissions
  // ────────────────────────────────
  func checkAllPermissions() {
    sttService.requestPermission { [weak self] ok in
      guard let self else { return }
      if ok {
        permissionStatusMessage = "Permissions granted."
        hasAllPermissions = true
        sttService.setupSpeechRecognizer(languageCode: myLanguage)
      } else {
        let micDenied = AVAudioSession.sharedInstance().recordPermission != .granted
        let spDenied  = SFSpeechRecognizer.authorizationStatus() != .authorized
        permissionStatusMessage =
          "\(spDenied ? "Speech" : "")\(spDenied && micDenied ? " & " : "")\(micDenied ? "Microphone" : "") permission denied."
        hasAllPermissions = false
      }
    }
  }

  // ────────────────────────────────
  // MARK: STT control
  // ────────────────────────────────
  func startListening() {
    guard hasAllPermissions else { myTranscribedText = "Missing permissions."; return }
    guard multipeerSession.connectionState == .connected else {
      myTranscribedText = "Not connected."
      return
    }
    guard !sttService.isListening else { return }

    isProcessing = true
    myTranscribedText = "Listening…"
    peerSaidText = ""
    translatedTextForMeToHear = ""

    sttService.startTranscribing(languageCode: myLanguage)
  }

  func stopListening() {
    if sttService.isListening { sttService.stopTranscribing() }
  }

  // ────────────────────────────────
  // MARK: Messaging helpers
  // ────────────────────────────────
  private func sendTextToPeer(originalText: String, isFinal: Bool) {
    guard !originalText.isEmpty else { return }

    translationForPeerToSend = originalText
    let msg = MessageData(id: UUID(),
                          originalText: originalText,
                          sourceLanguageCode: myLanguage,
                          targetLanguageCode: peerLanguage,
                          isFinal: isFinal,
                          timestamp: Date().timeIntervalSince1970)
    multipeerSession.send(message: msg)
  }

  private func handleReceivedMessage(_ m: MessageData) {
    guard m.timestamp > lastReceivedTimestamp else { return }
    lastReceivedTimestamp = m.timestamp

    peerSaidText = "Peer (\(m.sourceLanguageCode)): \(m.originalText)"
    translatedTextForMeToHear = m.isFinal ? "Translating…" : ""
    myTranscribedText = ""
    isProcessing = m.isFinal
    guard m.isFinal else { return }

    Task {
      do {
        let tx = try await UnifiedTranslateService.translate(m.originalText,
                                                             from: m.sourceLanguageCode,
                                                             to:   m.targetLanguageCode)
        translatedTextForMeToHear = "You hear: \(tx)"
        ttsService.speak(text: tx, languageCode: m.targetLanguageCode)
      } catch {
        translatedTextForMeToHear = "Local translation unavailable."
        isProcessing = false
      }
    }
  }

  // ────────────────────────────────
  // MARK: Utilities
  // ────────────────────────────────
  func resetConversationHistory() {
    myTranscribedText = "Tap 'Start Listening' to speak."
    peerSaidText = ""
    translatedTextForMeToHear = ""
    sttService.recognizedText = ""
  }

  deinit {
    cancellables.forEach { $0.cancel() }
    Task { @MainActor in multipeerSession.disconnect() }
  }
}
