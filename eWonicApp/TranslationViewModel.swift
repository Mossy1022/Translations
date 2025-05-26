//
//  TranslationViewModel.swift
//  eWonicMVP
//
//  Created by Evan Moscoso on 5/18/25.
//

import Foundation
import Combine
import Speech // For SFSpeechRecognizerAuthorizationStatus

class TranslationViewModel: ObservableObject {
    
    enum STTError: Error, LocalizedError, Equatable {
      case unavailable
      case permissionDenied
      case recognitionError(Error)
      case taskError(String)
      case noAudioInput

      var errorDescription: String? {
        switch self {
        case .unavailable:
          return "Speech recognition is not available on this device or for the selected language."
        case .permissionDenied:
          return "Speech recognition permission was denied."
        case .recognitionError(let e):
          return "Recognition failed: \(e.localizedDescription)"
        case .taskError(let msg):
          return msg
        case .noAudioInput:
          return "No audio input was detected or the input was too quiet."
        }
      }

      static func == (lhs: STTError, rhs: STTError) -> Bool {
        switch (lhs, rhs) {
        case (.unavailable, .unavailable),
             (.permissionDenied, .permissionDenied),
             (.noAudioInput, .noAudioInput):
          return true
        case (.taskError(let lMsg), .taskError(let rMsg)):
          return lMsg == rMsg
        case (.recognitionError, .recognitionError):
          // Since Error doesn't conform to Equatable, we consider all recognitionErrors as equal
          return true
        default:
          return false
        }
      }
    }

    
    @Published var multipeerSession = MultipeerSession()
    @Published var sttService = NativeSTTService()
    @Published var ttsService = AppleTTSService()
    private var translateService = GoogleTranslateService()
    private var cancellables = Set<AnyCancellable>()

    @Published var myTranscribedText: String = "Tap 'Start Listening' to speak."
    @Published var peerSaidText: String = "" // What the peer said in their original language
    @Published var translatedTextForMeToHear: String = "" // What I hear translated from peer
    @Published var translationForPeerToSend: String = "" // Text to send to peer (not displayed directly, but good for debug)

    @Published var connectionStatus: String = "Not Connected"
    @Published var isProcessing: Bool = false // Generic processing flag for STT, Translation, TTS chain
    @Published var permissionStatusMessage: String = "Checking permissions..."
    @Published var hasAllPermissions: Bool = false

    // Language Selection
    @Published var myLanguage: String = "en-US" {
        didSet { sttService.setupSpeechRecognizer(languageCode: myLanguage) } // Re-setup STT for new lang
    }
    @Published var peerLanguage: String = "es-ES"

    struct Language: Identifiable, Hashable {
        let id = UUID()
        let name: String
        let code: String // BCP-47
    }

    let availableLanguages: [Language] = [
        Language(name: "English (US)", code: "en-US"),
        Language(name: "Spanish (Spain)", code: "es-ES"),
        Language(name: "French (France)", code: "fr-FR"),
        Language(name: "German (Germany)", code: "de-DE"),
        Language(name: "Japanese (Japan)", code: "ja-JP"),
        Language(name: "Chinese (Mandarin, Simplified)", code: "zh-CN"),
        // Add more supported by SFSpeechRecognizer & Google Translate
    ]

    init() {
        checkAllPermissions()
        sttService.setupSpeechRecognizer(languageCode: myLanguage) // Initial setup

        multipeerSession.onMessageReceived = { [weak self] messageData in
            self?.handleReceivedMessage(messageData)
        }

    
        multipeerSession.$connectionState
            .map { state -> String in
                let peerName = self.multipeerSession.connectedPeers.first?.displayName ?? "peer"
                switch state {
                case .notConnected: return "Not Connected"
                case .connecting: return "Connecting..."
                case .connected: return "Connected to \(peerName)"
                @unknown default: return "Unknown Connection State"
                }
            }
            .receive(on: DispatchQueue.main)
            .assign(to: &$connectionStatus)
        
        // Handle STT results
        sttService.partialResultSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] partialText in
                self?.myTranscribedText = "Listening: \(partialText)..."
            }
            .store(in: &cancellables)

        sttService.finalResultSubject
            .receive(on: DispatchQueue.main)
            .sink(receiveCompletion: { [weak self] completion in
                guard let self = self else { return }
                self.isProcessing = false // STT part is done or failed
                if case .failure(let error) = completion {
                    self.myTranscribedText = "STT Error: \(error.localizedDescription)"
                    if error as? STTError == .noAudioInput {
                        self.myTranscribedText = "Didn't hear that. Try again."
                    }
                }
            }, receiveValue: { [weak self] finalText in
                guard let self = self else { return }
                self.myTranscribedText = "You said: \(finalText)"
                self.sendTextToPeer(originalText: finalText)
            })
            .store(in: &cancellables)
        
        ttsService.finishedSubject
          .receive(on: DispatchQueue.main)
          .sink { [weak self] in self?.isProcessing = false }
          .store(in: &cancellables)
    }

    func checkAllPermissions() {
        sttService.requestPermission { [weak self] granted in
            guard let self = self else { return }
            if granted {
                self.permissionStatusMessage = "Permissions granted."
                self.hasAllPermissions = true
                self.sttService.setupSpeechRecognizer(languageCode: self.myLanguage) // Ensure setup after permission
            } else {
                let speechAuthStatus = SFSpeechRecognizer.authorizationStatus()
                let micAuthStatus = AVAudioSession.sharedInstance().recordPermission
                var messages: [String] = []
                if speechAuthStatus != .authorized { messages.append("Speech recognition permission denied.") }
                if micAuthStatus != .granted { messages.append("Microphone permission denied.") }
                self.permissionStatusMessage = messages.joined(separator: " ") + " Please enable in Settings."
                self.hasAllPermissions = false
            }
        }
    }
    
    // User A: Starts STT
    func startListening() {
        guard hasAllPermissions else {
            myTranscribedText = "Missing permissions. Check settings."
            checkAllPermissions() // Prompt again or guide user
            return
        }
        guard multipeerSession.connectionState == .connected else {
            myTranscribedText = "Not connected to a peer."
            return
        }
        guard !sttService.isListening else { return }

        myTranscribedText = "Listening..."
        peerSaidText = "" // Clear previous peer text
        translatedTextForMeToHear = "" // Clear previous translation for me
        isProcessing = true
        sttService.startTranscribing(languageCode: myLanguage)
    }

    // User A: Stops STT (or it stops automatically on final result/error)
    func stopListening() {
        if sttService.isListening {
            sttService.stopTranscribing() // This will trigger the finalResultSubject completion
            // isProcessing will be set to false in the finalResultSubject completion handler
        }
    }

    // User A: Sends their transcribed text to User B
    private func sendTextToPeer(originalText: String) {
      guard !originalText.isEmpty else {
        print("⚠️ sendTextToPeer: originalText is empty, skipping send")
        myTranscribedText = "Nothing to send."
        isProcessing = false
        return
      }

      translationForPeerToSend = originalText
      print("📤 Preparing message to send: '\(originalText)'")
      print("   Source: \(myLanguage), Target: \(peerLanguage)")
      print("   Peers connected: \(multipeerSession.connectedPeers.map { $0.displayName })")

      let message = MessageData(
        id: UUID(),
        originalText: originalText,
        sourceLanguageCode: myLanguage,
        targetLanguageCode: peerLanguage
      )

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
          self.multipeerSession.send(message: message)
        }
      print("✅ Sent message to peer(s)")
    }

    // User B: Handles message received from User A
    private func handleReceivedMessage(_ message: MessageData) {
      print("📨 handleReceivedMessage triggered")
      print("   ID: \(message.id)")
      print("   From: \(message.sourceLanguageCode) → \(message.targetLanguageCode)")
      print("   Text: '\(message.originalText)'")

      DispatchQueue.main.async {
        self.isProcessing = true
        self.myTranscribedText = ""
        self.peerSaidText = "Peer (\(message.sourceLanguageCode)): \(message.originalText)"
        self.translatedTextForMeToHear = "Translating..."
      }

        Task {
          do {
            let (translated, engine) = try await UnifiedTranslateService.translate(
                  message.originalText,
                  from: message.sourceLanguageCode,
                  to:   message.targetLanguageCode)

            print("✅ \(engine) translated: '\(translated)'")
            await MainActor.run {
              self.translatedTextForMeToHear = "You hear: \(translated)"
              self.synthesizeAndPlay(text: translated,
                                     languageCode: message.targetLanguageCode)
            }
          } catch {
            await MainActor.run {
              self.translatedTextForMeToHear = "Local translation unavailable."
              self.isProcessing = false
            }
          }
        }
    }

    // User B: Synthesizes and plays the translated text (in their own language)
    private func synthesizeAndPlay(text: String, languageCode: String) {
        ttsService.speak(text: text, languageCode: languageCode)
        
        print("🔊 synthesizeAndPlay called with text: \(text), lang: \(languageCode)")

        // isProcessing will be set to false once TTS finishes or if an error occurs during translation.
        // If TTS is quick, we can set isProcessing = false here.
        // For more robust state, AVSpeechSynthesizerDelegate could signal completion.
        // For now, let's assume translation was the longer part.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { // Small delay to allow TTS to start
             self.isProcessing = false
        }
    }
    
    func resetConversationHistory() {
        myTranscribedText = "Tap 'Start Listening' to speak."
        peerSaidText = ""
        translatedTextForMeToHear = ""
        translationForPeerToSend = ""
        sttService.recognizedText = "" // Clear any lingering STT text
    }

    deinit {
        cancellables.forEach { $0.cancel() }
        multipeerSession.disconnect()
    }
}


