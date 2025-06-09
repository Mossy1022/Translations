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
         (.permissionDenied, .permissionDenied):
      return true
    case (.taskError(let l), .taskError(let r)):
      return l == r
    case (.recognitionError, .recognitionError):
      return true          // we don’t compare embedded Error values
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
  @Published var sttService       = AzureSpeechTranslationService()
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
    
  private var liveTranslationTask: Task<Void, Never>?

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

    multipeerSession.$connectionState
      .receive(on: RunLoop.main)
      .sink { [weak self] state in
        guard let self else { return }
        switch state {
        case .connected:
          startListening()
        default:
          stopListening()
        }
      }
      .store(in: &cancellables)

      (sttService as! AzureSpeechTranslationService).partialResult
        .receive(on: RunLoop.main)
        .sink { [weak self] txt in
          self?.translatedTextForMeToHear = txt
        }
        .store(in: &cancellables)

      (sttService as! AzureSpeechTranslationService).finalResult
        .receive(on: RunLoop.main)
        .sink { [weak self] txt in
          guard let self else { return }
          isProcessing = false
          translatedTextForMeToHear = txt
        }
        .store(in: &cancellables)

      (sttService as! AzureSpeechTranslationService).sourceFinalResult
        .receive(on: RunLoop.main)
        .sink { [weak self] txt in
          guard let self else { return }
          myTranscribedText = txt
          sendTextToPeer(originalText: txt, isFinal: true)
        }
        .store(in: &cancellables)



    // ––––– TTS finished –––––
    ttsService.finishedSubject
      .receive(on: RunLoop.main)
      .sink { [weak self] in
        guard let self else { return }
        isProcessing = false
        if multipeerSession.connectionState == .connected {
          startListening()
        }
      }
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
        liveTranslationTask?.cancel()
        guard hasAllPermissions else {
            myTranscribedText = "Missing permissions."
            return
        }
        guard multipeerSession.connectionState == .connected else {
            myTranscribedText = "Not connected."
            return
        }
        guard !sttService.isListening else { return }

        isProcessing = false
        myTranscribedText = "Listening…"
        peerSaidText = ""
        translatedTextForMeToHear = ""

            // Actually start speech recognition
        (sttService as! AzureSpeechTranslationService)
          .start(src: myLanguage, dst: peerLanguage)   // pass full “es-ES”            // ── ④ Immediately kick off streaming translation task
//            let tokenStream = sttService.partialTokensStream()
//            liveTranslationTask = Task {
//                do {
//                    // Consume the stream of partial‐speech tokens and forward to Apple’s translator:
//                    for try await translatedToken in try await Apple18StreamingTranslationService
//                            .shared
//                            .stream(tokenStream, from: myLanguage, to: peerLanguage) {
//                        // Each `translatedToken` is a piece of text as soon as it’s available.
//                        // Dispatch back to the main actor to update UI:
//                        await MainActor.run {
//                            // Append each new token so the UI shows gradual build‐up:
//                            if translatedTextForMeToHear.isEmpty {
//                                translatedTextForMeToHear = translatedToken
//                            } else {
//                                translatedTextForMeToHear += translatedToken
//                            }
//                        }
//                    }
//                } catch {
//                    // If streaming fails (e.g. iOS < 18.4 at runtime), fallback to single-shot:
//                    await MainActor.run {
//                        translatedTextForMeToHear = "Streaming Translation Unavailable"
//                        isProcessing = false
//                    }
//                }
//            }
        }

    func stopListening() {
            if sttService.isListening {
                (sttService as! AzureSpeechTranslationService).stop()
                isProcessing = false
            }
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
    guard m.isFinal else { return }

    stopListening()
    isProcessing = true

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
        startListening()
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
        liveTranslationTask?.cancel()          // 🔴 add this
        cancellables.forEach { $0.cancel() }
        Task { @MainActor in multipeerSession.disconnect() }
    }
}
