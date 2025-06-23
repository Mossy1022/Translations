//
//  TranslationViewModel.swift
//  eWonicApp
//
//  v2.2  2025-06-23
//  • Speak picker now drives Hear picker automatically
//  • refreshVoices() call consolidated
//

import Foundation
import Combine
import AVFoundation
import Speech

@MainActor
final class TranslationViewModel: ObservableObject {

  // ───────────── Services
  @Published var multipeerSession = MultipeerSession()
  @Published var sttService       = NativeSTTService()        // mic → text only
  @Published var ttsService       = AppleTTSService()

  // ───────────── UI state
  @Published var speak_language = "en-US" {
    didSet {
      hear_language = speak_language        // auto-mirror
      refreshVoices()
    }
  }

  @Published var hear_language  = "en-US" {
    didSet { refreshVoices() }
  }

  @Published var liveTranscript        = "Tap Start to speak."
  @Published var lastIncomingTranslated = ""
  @Published var connectionStatus      = "Not Connected"
  @Published var isProcessing          = false
  @Published var errorMessage          : String?

  // ───────────── Permissions
  @Published var hasAllPermissions     = false
  @Published var permissionStatusMessage = "Speech & microphone permissions are required."

  // ───────────── Languages / Voices
  struct Language: Identifiable, Hashable {
    let id = UUID()
    let code: String
    let name: String
  }

  struct Voice: Identifiable, Hashable {
    let id = UUID()
    let language: String, name: String, identifier: String
  }

  @Published var availableLanguages: [Language] = []
  @Published var availableVoices   : [Voice]    = []
  @Published var voice_for_lang    : [String:String] = [:]     // lang → voice id

  // ───────────── Internals
  private var cancellables = Set<AnyCancellable>()
  private var lastReceived = TimeInterval.zero
  private var spokeBeforePlayback = false

  init() {
    hear_language = speak_language
    wirePermissions()
    wireSTT()
    wireMultipeer()
    wirePlaybackPause()
    buildLanguages()
    refreshVoices()
  }

  // ─────────────────────────────── Permissions
  private func wirePermissions() {
    sttService.requestPermission { [weak self] ok in
      guard let self else { return }
      hasAllPermissions = ok
      if !ok {
        permissionStatusMessage = "Please enable both Speech Recognition and Microphone access in Settings."
      }
    }
  }

  func checkAllPermissions() { sttService.requestPermission { _ in } }

  // ─────────────────────────────── Speaking
  func startMicrophone() {
    guard !sttService.isListening,
          multipeerSession.connectionState == .connected
    else { return }

    liveTranscript = "Listening…"
    sttService.startTranscribing(languageCode: speak_language)
  }

  func stopMicrophone() { sttService.stopTranscribing() }

  private func wireSTT() {
    sttService.finalResultSubject
      .receive(on: RunLoop.main)
      .sink { [weak self] txt in
        guard let self else { return }
        liveTranscript = txt
        broadcast(text: txt, isFinal: true)
      }
      .store(in: &cancellables)

    sttService.partialResultSubject
      .receive(on: RunLoop.main)
      .throttle(for: .milliseconds(400),
                scheduler: RunLoop.main,
                latest: true)
      .sink { [weak self] txt in
        self?.broadcast(text: txt, isFinal: false)
      }
      .store(in: &cancellables)
  }

  private func broadcast(text: String, isFinal: Bool) {
    guard !text.isEmpty else { return }
    let msg = MessageData(id: UUID(),
                          text: text,
                          source_language_code: speak_language,
                          is_final: isFinal,
                          timestamp: Date().timeIntervalSince1970)

    multipeerSession.send(message: msg, reliable: isFinal)
  }

  // ─────────────────────────────── Receiving
  private func wireMultipeer() {

    multipeerSession.$connectionState
      .receive(on: RunLoop.main)
      .map { [weak self] st -> String in
        guard let self else { return "Not Connected" }
        switch st {
        case .connected:
          return "Lobby: \(multipeerSession.connectedPeers.count + 1)/\(MultipeerSession.peerLimit)"
        case .connecting:
          return "Connecting…"
        default:
          return "Not Connected"
        }
      }
      .assign(to: \.connectionStatus, on: self)
      .store(in: &cancellables)

    multipeerSession.onMessageReceived = { [weak self] m in
      Task { await self?.handleIncoming(m) }
    }

    multipeerSession.errorSubject
      .receive(on: RunLoop.main)
      .sink { [weak self] msg in self?.errorMessage = msg }
      .store(in: &cancellables)
  }

    private func handleIncoming(_ m: MessageData) async {
       // ignore live fragments – only act on final sentences
       guard m.is_final else { return }

       guard m.timestamp > lastReceived else { return }
       lastReceived = m.timestamp

       do {
         let translated = try await LocalTextTranslator.shared
                             .translate(m.text,
                                        from: m.source_language_code,
                                        to:   hear_language)

         await MainActor.run {
           lastIncomingTranslated = translated
           isProcessing           = true
         }

         let voice = voice_for_lang[hear_language]
         ttsService.speak(text: translated,
                          languageCode: hear_language,
                          voiceIdentifier: voice)

       } catch {
          await MainActor.run {
            errorMessage = "Translation failed – \(error.localizedDescription)"
          }
          print("❌ Translation error:", error)
        }
     }

  private func wirePlaybackPause() {
    ttsService.$isSpeaking
      .removeDuplicates()
      .sink { [weak self] speaking in
        guard let self else { return }
        if speaking {
          spokeBeforePlayback = sttService.isListening
          if spokeBeforePlayback { sttService.stopTranscribing() }
        } else {
          if spokeBeforePlayback {
            sttService.startTranscribing(languageCode: speak_language)
            spokeBeforePlayback = false
          }
          isProcessing = false
        }
      }
      .store(in: &cancellables)
  }

  // ─────────────────────────────── Languages & Voices
  private func buildLanguages() {
    let unique = Set(AVSpeechSynthesisVoice.speechVoices().map { $0.language })
    availableLanguages = unique.sorted().map { code in
      let name = Locale.current.localizedString(forIdentifier: code) ?? code
      return Language(code: code, name: name)
    }
  }

  private func refreshVoices() {
    let need = Set([speak_language])
    availableVoices = AVSpeechSynthesisVoice.speechVoices()
      .filter { need.contains($0.language) }
      .map { Voice(language: $0.language,
                   name: $0.name,
                   identifier: $0.identifier) }
      .sorted {
        $0.language == $1.language ? $0.name < $1.name
                                   : $0.language < $1.language
      }
  }
}
