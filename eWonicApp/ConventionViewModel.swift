import Foundation
import Combine
import Speech
import AVFoundation

@MainActor
final class ConventionViewModel: ObservableObject {
  // Services
  @Published var sttService = AzureSpeechTranslationService()
  @Published var ttsService = AppleTTSService()

  // UI state
  @Published var speakerTranscribedText = "Tap 'Start' to listen."
  @Published var translatedTextForMeToHear = ""
  @Published var isProcessing = false
  @Published var permissionStatusMessage = "Checking permissions…"
  @Published var hasAllPermissions = false
  @Published var errorMessage: String?

  // Languages
  @Published var myLanguage = "en-US" { didSet { refreshVoices() } }
  @Published var incomingLanguage = "en-US" { didSet { sttService.setupSpeechRecognizer(languageCode: incomingLanguage) } }

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

  // Voices
  struct Voice: Identifiable, Hashable {
    let id = UUID()
    let language: String
    let name: String
    let identifier: String
  }

  @Published var availableVoices: [Voice] = []
  @Published var voice_for_lang: [String:String] = [:]

  // Settings
  @Published var micSensitivity: Double = 0.5 {
    didSet { AudioSessionManager.shared.setInputGain(Float(micSensitivity)) }
  }
  @Published var playbackSpeed: Double = 0.55 {
    didSet { ttsService.speech_rate = Float(playbackSpeed) }
  }

  // Internals
  private var cancellables = Set<AnyCancellable>()
  private var partialBuffer = ""
  private var lastSentPartial = ""
  private var partialTimer: Timer?

  init() {
    checkAllPermissions()
    refreshVoices()
    AudioSessionManager.shared.setInputGain(Float(micSensitivity))
    ttsService.speech_rate = Float(playbackSpeed)

    $voice_for_lang
      .receive(on: RunLoop.main)
      .sink { [weak self] mapping in
        guard let self = self else { return }
        for (lang, id) in mapping {
          self.ttsService.setPreferredVoice(identifier: id, for: lang)
        }
      }
      .store(in: &cancellables)

    (sttService as! AzureSpeechTranslationService).errorSubject
      .receive(on: RunLoop.main)
      .sink { [weak self] msg in self?.errorMessage = msg }
      .store(in: &cancellables)

    AudioSessionManager.shared.errorSubject
      .receive(on: RunLoop.main)
      .sink { [weak self] msg in self?.errorMessage = msg }
      .store(in: &cancellables)

    $micSensitivity
      .receive(on: RunLoop.main)
      .sink { [weak self] s in
        (self?.sttService as? NativeSTTService)?.sensitivity = Float(s)
      }
      .store(in: &cancellables)

    wirePipelines()
  }

  // Permissions
  func checkAllPermissions() {
    sttService.requestPermission { [weak self] ok in
      guard let self else { return }
      hasAllPermissions = ok
      permissionStatusMessage = ok ? "Permissions granted." : "Speech & Microphone permission denied."
      if ok { sttService.setupSpeechRecognizer(languageCode: incomingLanguage) }
    }
  }

  // Mic control
  func startListening() {
    guard hasAllPermissions else { speakerTranscribedText = "Missing permissions."; return }
    guard !sttService.isListening else { return }
    isProcessing = true
    speakerTranscribedText = "Listening…"
    translatedTextForMeToHear = ""
    (sttService as! AzureSpeechTranslationService).start(src: incomingLanguage, dst: incomingLanguage)
  }

  func stopListening() {
    (sttService as! AzureSpeechTranslationService).stop()
    isProcessing = false
  }

  private func wirePipelines() {
    (sttService as! AzureSpeechTranslationService)
      .sourcePartialResult
      .receive(on: RunLoop.main)
      .sink { [weak self] raw in self?.handlePartial(raw) }
      .store(in:&cancellables)

    (sttService as! AzureSpeechTranslationService)
      .sourceFinalResult
      .receive(on: RunLoop.main)
      .sink { [weak self] raw in self?.handleFinal(raw) }
      .store(in:&cancellables)
  }

  // Partial buffering
  private func handlePartial(_ raw: String) {
    speakerTranscribedText = raw
    partialBuffer = raw
    partialTimer?.invalidate()
    partialTimer = Timer.scheduledTimer(withTimeInterval: 4.0, repeats: false) { [weak self] _ in
      self?.flushPartial(isFinal: false)
    }
  }

  private func handleFinal(_ raw: String) {
    speakerTranscribedText = raw
    partialBuffer = raw
    flushPartial(isFinal: true)
    isProcessing = false
  }

  private func flushPartial(isFinal: Bool) {
    partialTimer?.invalidate(); partialTimer = nil
    guard partialBuffer.count > lastSentPartial.count else { return }
    let start = partialBuffer.index(partialBuffer.startIndex, offsetBy: lastSentPartial.count)
    let diff = String(partialBuffer[start...]).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !diff.isEmpty else { return }
    lastSentPartial = partialBuffer
    translateAndSpeak(diff)
    if isFinal {
      lastSentPartial = ""
      partialBuffer = ""
    }
  }

  private func translateAndSpeak(_ text: String) {
    Task {
      let translated = (try? await UnifiedTranslateService.translate(text, from: incomingLanguage, to: myLanguage)) ?? text
      await MainActor.run {
        translatedTextForMeToHear += translated
        ttsService.speak(text: translated, languageCode: myLanguage)
      }
    }
  }

  // Voice helpers
  private func refreshVoices() {
    let langs: Set<String> = [myLanguage]
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      guard let self else { return }
      let rawVoices = AVSpeechSynthesisVoice.speechVoices()
      let filtered = rawVoices.filter { langs.contains($0.language) }
      let converted = filtered.map { Voice(language: $0.language, name: $0.name, identifier: $0.identifier) }
      let sorted = converted.sorted { $0.name < $1.name }
      DispatchQueue.main.async { self.availableVoices = sorted }
    }
  }

  func resetConversationHistory() {
    speakerTranscribedText = "Tap 'Start' to listen."
    translatedTextForMeToHear = ""
  }
}

