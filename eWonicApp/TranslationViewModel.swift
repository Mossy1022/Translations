//
//  TranslationViewModel.swift
//  eWonicApp
//
//  One Phone: EN ↔ ES with clear voice mapping per language.
//  Defaults: Left = English (US), Right = Spanish (Latin America / es‑US)
//

import Foundation
import Combine
import Speech
import AVFoundation

@MainActor
final class TranslationViewModel: ObservableObject {

  // ─────────────────────────────── Mode
  enum Mode: String, CaseIterable {
    case peer     = "Peer"
    case onePhone = "One Phone"
  }
  @Published var mode: Mode = .peer

  // ─────────────────────────────── Services
  @Published var multipeerSession = MultipeerSession()
  @Published var sttService       = AzureSpeechTranslationService()   // Peer mode (mic → translation to peer)
  @Published var autoService      = AzureAutoConversationService()    // One‑Phone auto‑detect
  @Published var ttsService       = AppleTTSService()

  // ─────────────────────────────── UI state (Peer screen)
  @Published var myTranscribedText         = "Tap 'Start' to speak."
  @Published var peerSaidText              = ""
  @Published var translatedTextForMeToHear = ""

  @Published var connectionStatus        = "Not Connected"
  @Published var isProcessing            = false
  @Published var permissionStatusMessage = "Checking permissions…"
  @Published var hasAllPermissions       = false
  @Published var errorMessage: String?

  // ─────────────────────────────── Languages
  /// On Peer screen: me → peer. On One‑Phone screen: left tile ↔ right tile.
  @Published var myLanguage   = "en-US"  { didSet { refreshVoices() } }
  @Published var peerLanguage = "es-US"  { didSet { refreshVoices() } } // Spanish (Latin America)

  struct Language: Identifiable, Hashable {
    let id   = UUID()
    let name: String
    let code: String
  }

  let availableLanguages: [Language] = [
    .init(name:"English (US)",             code:"en-US"),
    .init(name:"Spanish (Latin America)",  code:"es-US"),
    .init(name:"Spanish (Mexico)",         code:"es-MX"),
    .init(name:"Spanish (Spain)",          code:"es-ES"),
    .init(name:"French (France)",          code:"fr-FR"),
    .init(name:"German (Germany)",         code:"de-DE"),
    .init(name:"Japanese (Japan)",         code:"ja-JP"),
    .init(name:"Chinese (Simplified)",     code:"zh-CN")
  ]

  // ─────────────────────────────── Voices
  struct Voice: Identifiable, Hashable {
    let id = UUID()
    let language:  String      // full BCP‑47, e.g. "es-MX"
    let name:      String
    let identifier:String
  }
  @Published var availableVoices: [Voice] = []

  /// Per‑language chosen voice (key = BCP‑47 language)
  @Published var voice_for_lang: [String:String] = [:]

  // ─────────────────────────────── Settings
  @Published var micSensitivity: Double = 0.5 {
    didSet { AudioSessionManager.shared.setInputGain(Float(micSensitivity)) }
  }
  @Published var playbackSpeed: Double = 0.55 {
    didSet { ttsService.speech_rate = Float(playbackSpeed) }
  }

  // ─────────────────────────────── One‑Phone: history + drafts
  struct LocalTurn: Identifiable {
    let id: UUID
    let sourceLang: String
    let sourceText: String
    let targetLang: String
    let translatedText: String
    let timestamp: TimeInterval

    init(id: UUID = UUID(),
         sourceLang: String,
         sourceText: String,
         targetLang: String,
         translatedText: String,
         timestamp: TimeInterval) {
      self.id = id
      self.sourceLang = sourceLang
      self.sourceText = sourceText
      self.targetLang = targetLang
      self.translatedText = translatedText
      self.timestamp = timestamp
    }
  }

  @Published var localTurns: [LocalTurn] = []
  @Published var leftDraft:  String = ""   // myLanguage
  @Published var rightDraft: String = ""   // peerLanguage
  @Published var isAutoListening: Bool = false

  // ─────────────────────────────── Internals
  private var cancellables            = Set<AnyCancellable>()
  private var lastReceivedTimestamp   : TimeInterval = 0
  private var wasListeningPrePlayback = false
    
    
    // ─────────────────────────────── Early‑TTS (Peer mode) config/state
    private let earlyTTSBailSeconds: TimeInterval = 8
    private let earlyTTSMinChunkChars = 24    // avoid tiny staccato chunks

    private var earlyTTSSentPrefix = 0        // chars already sent/spoken this turn
    private var earlyTTSTimer: DispatchSourceTimer?
    private var lastPartialForTurn = ""

    private func resetEarlyTTSState() {
      earlyTTSTimer?.cancel(); earlyTTSTimer = nil
      earlyTTSSentPrefix = 0
      lastPartialForTurn = ""
    }

    private func startEarlyTTSBailTimer() {
      earlyTTSTimer?.cancel()
      let t = DispatchSource.makeTimerSource(queue: .main)
      t.schedule(deadline: .now() + earlyTTSBailSeconds)
      t.setEventHandler { [weak self] in self?.fireEarlyTTSBailout() }
      t.resume()
      earlyTTSTimer = t
    }

    private func fireEarlyTTSBailout() {
      guard mode == .peer else { return }
      let s = lastPartialForTurn
      guard !s.isEmpty, s.count > earlyTTSSentPrefix + earlyTTSMinChunkChars else { return }
      if let cut = lastWordBoundary(in: s, fromOffset: earlyTTSSentPrefix) {
        let start = s.index(s.startIndex, offsetBy: earlyTTSSentPrefix)
        let chunk = String(s[start..<cut])
        sendTextToPeer(chunk, isFinal: false, reliable: false)
        earlyTTSSentPrefix = s.distance(from: s.startIndex, to: cut)
      }
      // schedule next bailout window
      startEarlyTTSBailTimer()
    }

    private func handlePeerPartial(_ s: String) {
      translatedTextForMeToHear = s
      lastPartialForTurn = s
      if earlyTTSTimer == nil { startEarlyTTSBailTimer() }

      // Try to emit any full sentence(s) we haven’t sent yet
      if let cut = lastSentenceBoundary(in: s, fromOffset: earlyTTSSentPrefix) {
        let start = s.index(s.startIndex, offsetBy: earlyTTSSentPrefix)
        let chunk = String(s[start..<cut])
        if chunk.count >= earlyTTSMinChunkChars {
          sendTextToPeer(chunk, isFinal: false, reliable: false)
          earlyTTSSentPrefix = s.distance(from: s.startIndex, to: cut)
          // Reset the 8s timer to wait for next clause
          startEarlyTTSBailTimer()
        }
      }
    }

    private func finalizePeerTurn(with final: String) {
      earlyTTSTimer?.cancel(); earlyTTSTimer = nil

      // send only what hasn't been spoken yet
      let s = final
      let safeStart = min(earlyTTSSentPrefix, s.count)
      let startIdx  = s.index(s.startIndex, offsetBy: safeStart)
      let tail = String(s[startIdx..<s.endIndex])
                  .trimmingCharacters(in: .whitespacesAndNewlines)

      translatedTextForMeToHear = final
      if !tail.isEmpty {
        sendTextToPeer(tail, isFinal: true, reliable: true)
      }
      resetEarlyTTSState()
    }

    // Boundary helpers
    private func lastSentenceBoundary(in s: String, fromOffset off: Int) -> String.Index? {
      guard s.count > off else { return nil }
      let start = s.index(s.startIndex, offsetBy: off)
      let marks: Set<Character> = [".","!","?","…","。","！","？"]
      var last: String.Index? = nil
      var i = start
      while i < s.endIndex {
        if marks.contains(s[i]) { last = s.index(after: i) }
        i = s.index(after: i)
      }
      return last
    }

    private func lastWordBoundary(in s: String, fromOffset off: Int) -> String.Index? {
      guard s.count > off else { return nil }
      let start = s.index(s.startIndex, offsetBy: off)
      var last: String.Index? = nil
      var i = start
      while i < s.endIndex {
        if s[i].isWhitespace { last = i }
        i = s.index(after: i)
      }
      return last
    }
    

  // ─────────────────────────────── Init
  init() {
    checkAllPermissions()
    refreshVoices()
    wireConnectionBadge()
    wirePeerPipelines()
    wireAutoPipelines()
    wireMicPauseDuringPlayback()

    AudioSessionManager.shared.setInputGain(Float(micSensitivity))
    ttsService.speech_rate = Float(playbackSpeed)

    // Push selected voices into TTS preference registry
    $voice_for_lang
      .receive(on: RunLoop.main)
      .sink { [weak self] mapping in
        guard let self else { return }
        for (lang, id) in mapping {
          self.ttsService.setPreferredVoice(identifier: id, for: lang)
        }
      }
      .store(in: &cancellables)

    // All error banners feed into one place
    multipeerSession.errorSubject
      .merge(with:
        (sttService as! AzureSpeechTranslationService).errorSubject,
        autoService.errorSubject,
        AudioSessionManager.shared.errorSubject
      )
      .receive(on: RunLoop.main)
      .sink { [weak self] msg in self?.errorMessage = msg }
      .store(in: &cancellables)

    // Switching to One Phone disables radios
    $mode.removeDuplicates()
      .sink { [weak self] m in if m == .onePhone { self?.multipeerSession.disconnect() } }
      .store(in: &cancellables)

    multipeerSession.onMessageReceived = { [weak self] msg in
      self?.handleReceivedMessage(msg)
    }
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

  // ─────────────────────────────── Peer mic control
    func startListening() {
      guard hasAllPermissions else { myTranscribedText = "Missing permissions."; return }
      if mode == .peer {
        guard multipeerSession.connectionState == .connected else {
          myTranscribedText = "Not connected."; return
        }
        guard !sttService.isListening else { return }
        resetEarlyTTSState()               // NEW
        isProcessing = true
        myTranscribedText = "Listening…"
        peerSaidText = ""; translatedTextForMeToHear = ""
        (sttService as! AzureSpeechTranslationService).start(src: myLanguage, dst: peerLanguage)
      } else {
        startAuto()
      }
    }


    func stopListening() {
      if mode == .peer {
        (sttService as! AzureSpeechTranslationService).stop()
        resetEarlyTTSState()               // NEW
        isProcessing = false
      } else {
        stopAuto()
      }
    }

  // ─────────────────────────────── One‑Phone mic control
  func startAuto() {
    guard hasAllPermissions else { return }
    guard !autoService.isListening else { return }
    isProcessing = true
    isAutoListening = true
    autoService.start(between: myLanguage, and: peerLanguage)
  }

  func stopAuto() {
    guard autoService.isListening else { return }
    autoService.stop()
    isProcessing = false
    isAutoListening = false
  }

  // ─────────────────────────────── Peer pipelines
    private func wirePeerPipelines() {

      // Partials → early-TTS sentence/bailout logic
      sttService
        .partialResult
        .receive(on: RunLoop.main)
        .removeDuplicates()
        .throttle(for: .milliseconds(350), scheduler: RunLoop.main, latest: true)
        .sink { [weak self] txt in
          self?.handlePeerPartial(txt)
        }
        .store(in: &cancellables)

      // Finals → speak only the unsent tail + clear timers
      sttService
        .finalResult
        .receive(on: RunLoop.main)
        .sink { [weak self] tx in
          guard let self else { return }
          isProcessing = false
          self.finalizePeerTurn(with: tx)
        }
        .store(in: &cancellables)

      // Raw source finals (what I said)
      sttService
        .sourceFinalResult
        .receive(on: RunLoop.main)
        .assign(to: &$myTranscribedText)
    }


  // ─────────────────────────────── One‑Phone pipelines
  private func wireAutoPipelines() {

    // Live partials → UI “Live” line
    autoService.partial
      .receive(on: RunLoop.main)
      .throttle(for: .milliseconds(450), scheduler: RunLoop.main, latest: true)
      .sink { [weak self] (_, tx, _) in
        self?.translatedTextForMeToHear = tx
      }
      .store(in: &cancellables)

    // Finals → speak to the OTHER side
    autoService.final
      .receive(on: RunLoop.main)
      .sink { [weak self] detectedSrc, raw, txFromAzure, target2 in
        guard let self else { return }
        isProcessing = false

        let myBase   = String(myLanguage.prefix(2)).lowercased()
        let peerBase = String(peerLanguage.prefix(2)).lowercased()

        let dstFull: String = (target2 == peerBase) ? peerLanguage : myLanguage
        let fromFull: String = (dstFull == peerLanguage) ? myLanguage : peerLanguage

        Task { [weak self] in
          guard let self else { return }

          var finalTx = txFromAzure.trimmingCharacters(in: .whitespacesAndNewlines)
          let rawTrim = raw.trimmingCharacters(in: .whitespacesAndNewlines)

          if finalTx.isEmpty || finalTx.caseInsensitiveCompare(rawTrim) == .orderedSame {
            if !rawTrim.isEmpty,
               let better = try? await AzureTextTranslator.translate(
                 rawTrim,
                 from: fromFull,
                 to:   dstFull
               ),
               !better.isEmpty {
              finalTx = better
            }
          }

          await MainActor.run {
            localTurns.append(LocalTurn(
              sourceLang:   detectedSrc.isEmpty ? fromFull : detectedSrc,
              sourceText:   rawTrim.isEmpty ? "(inaudible)" : rawTrim,
              targetLang:   dstFull,
              translatedText: finalTx.isEmpty ? "(unavailable)" : finalTx,
              timestamp:    Date().timeIntervalSince1970
            ))

            let override = voice_for_lang[dstFull]
            ttsService.speak(text: finalTx, languageCode: dstFull, voiceIdentifier: override)

            if String(detectedSrc.prefix(2)).lowercased() == myBase {
              myTranscribedText = rawTrim
            } else {
              peerSaidText = rawTrim
            }

            translatedTextForMeToHear = finalTx
          }
        }
      }
      .store(in:&cancellables)
  }

  private func wireConnectionBadge() {
    Publishers.CombineLatest($mode, multipeerSession.$connectionState)
      .receive(on: RunLoop.main)
      .map { [weak self] mode, state -> String in
        guard let self else { return "Not Connected" }
        if mode == .onePhone { return "One Phone" }
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

  /// Pause mic while device is speaking (works for both Peer & One‑Phone).
  private func wireMicPauseDuringPlayback() {
    ttsService.$isSpeaking
      .receive(on: RunLoop.main)
      .removeDuplicates()
      .sink { [weak self] speaking in
        guard let self else { return }
        if speaking {
          wasListeningPrePlayback = sttService.isListening || autoService.isListening
          if sttService.isListening { (sttService as! AzureSpeechTranslationService).stop() }
          if autoService.isListening { autoService.stop() }
        } else {
          if wasListeningPrePlayback {
            if mode == .peer {
              (sttService as! AzureSpeechTranslationService).start(src: myLanguage, dst: peerLanguage)
            } else {
              autoService.start(between: myLanguage, and: peerLanguage)
            }
            wasListeningPrePlayback = false
          }
          isProcessing = false
        }
      }
      .store(in:&cancellables)
  }

  // ─────────────────────────────── Typed input (One‑Phone)
    // ─────────────────────────────── Typed input (One-Phone)
    func submitLeftDraft() {
      let text = leftDraft.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !text.isEmpty else { return }

      let pendingId = UUID()
      let now = Date().timeIntervalSince1970

      localTurns.append(LocalTurn(
        id: pendingId,
        sourceLang: myLanguage,
        sourceText: text,
        targetLang: peerLanguage,
        translatedText: "…",
        timestamp: now
      ))
      leftDraft = ""

      Task {
        do {
          let tx = try await AzureTextTranslator.translate(text, from: myLanguage, to: peerLanguage)
          await MainActor.run {
            replaceLocalTurn(id: pendingId, with: LocalTurn(
              id: pendingId,
              sourceLang: myLanguage,
              sourceText: text,
              targetLang: peerLanguage,
              translatedText: tx,
              timestamp: now
            ))
            ttsService.speak(text: tx, languageCode: peerLanguage,
                             voiceIdentifier: voice_for_lang[peerLanguage])
          }
        } catch {
          await MainActor.run {
            errorMessage = "Text translation failed. Speaking original."
            replaceLocalTurn(id: pendingId, with: LocalTurn(
              id: pendingId,
              sourceLang: myLanguage,
              sourceText: text,
              targetLang: peerLanguage,
              translatedText: "(untranslated) \(text)",
              timestamp: now
            ))
            // Fallback: speak original in the sender’s language to avoid mismatched audio
            ttsService.speak(text: text, languageCode: myLanguage,
                             voiceIdentifier: voice_for_lang[myLanguage])
          }
        }
      }
    }

    func submitRightDraft() {
      let text = rightDraft.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !text.isEmpty else { return }

      let pendingId = UUID()
      let now = Date().timeIntervalSince1970

      localTurns.append(LocalTurn(
        id: pendingId,
        sourceLang: peerLanguage,
        sourceText: text,
        targetLang: myLanguage,
        translatedText: "…",
        timestamp: now
      ))
      rightDraft = ""

      Task {
        do {
          let tx = try await AzureTextTranslator.translate(text, from: peerLanguage, to: myLanguage)
          await MainActor.run {
            replaceLocalTurn(id: pendingId, with: LocalTurn(
              id: pendingId,
              sourceLang: peerLanguage,
              sourceText: text,
              targetLang: myLanguage,
              translatedText: tx,
              timestamp: now
            ))
            ttsService.speak(text: tx, languageCode: myLanguage,
                             voiceIdentifier: voice_for_lang[myLanguage])
          }
        } catch {
          await MainActor.run {
            errorMessage = "Text translation failed. Speaking original."
            replaceLocalTurn(id: pendingId, with: LocalTurn(
              id: pendingId,
              sourceLang: peerLanguage,
              sourceText: text,
              targetLang: myLanguage,
              translatedText: "(untranslated) \(text)",
              timestamp: now
            ))
            ttsService.speak(text: text, languageCode: peerLanguage,
                             voiceIdentifier: voice_for_lang[peerLanguage])
          }
        }
      }
    }

  // Replace a turn by id (preserves scroll position & animation hooks)
  private func replaceLocalTurn(id: UUID, with newTurn: LocalTurn) {
    if let idx = localTurns.firstIndex(where: { $0.id == id }) {
      localTurns[idx] = newTurn
    }
  }

  // ─────────────────────────────── Messaging (Peer mode only)
    private func sendTextToPeer(_ text: String, isFinal: Bool, reliable: Bool) {
      guard !text.isEmpty else { return }
      let msg = MessageData(
        id: UUID(),
        originalText:       text,
        sourceLanguageCode: peerLanguage,   // what the peer should hear
        targetLanguageCode: peerLanguage,
        isFinal:            isFinal,
        timestamp:          Date().timeIntervalSince1970
      )
      multipeerSession.send(message: msg, reliable: reliable)
    }

    private func handleReceivedMessage(_ m: MessageData) {
      guard m.timestamp > lastReceivedTimestamp else { return }
      lastReceivedTimestamp = m.timestamp

      if m.isFinal {
        peerSaidText = "Peer: \(m.originalText)"
      } else {
        translatedTextForMeToHear = m.originalText
      }
      isProcessing = true

      ttsService.speak(text: m.originalText,
                       languageCode: m.sourceLanguageCode,
                       voiceIdentifier: voice_for_lang[m.sourceLanguageCode])
    }


  // ─────────────────────────────── Voices
  private func refreshVoices() {
    // Show all dialects for the active base languages (e.g. any "es-*")
    let bases = Set([myLanguage, peerLanguage].map { String($0.prefix(2)).lowercased() })

    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      guard let self else { return }

      let all = AVSpeechSynthesisVoice.speechVoices()
      let filtered = all.filter {
        guard let base = $0.language.split(separator: "-").first?.lowercased() else { return false }
        return bases.contains(base)
      }

      let models = filtered.map {
        Voice(language: $0.language, name: $0.name, identifier: $0.identifier)
      }

      let sorted = models.sorted {
        let aBase = $0.language.split(separator: "-").first ?? Substring($0.language)
        let bBase = $1.language.split(separator: "-").first ?? Substring($1.language)
        return aBase == bBase ? $0.name < $1.name : aBase < bBase
      }

      DispatchQueue.main.async { self.availableVoices = sorted }
    }
  }

  // ─────────────────────────────── Utilities
  func resetConversationHistory() {
    myTranscribedText         = "Tap 'Start' to speak."
    peerSaidText              = ""
    translatedTextForMeToHear = ""
    localTurns.removeAll()
  }
}
