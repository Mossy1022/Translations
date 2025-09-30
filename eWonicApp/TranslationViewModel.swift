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
#if canImport(UIKit)
import UIKit
#endif

@MainActor
final class TranslationViewModel: ObservableObject {

  // ─────────────────────────────── Mode
  enum Mode: String, CaseIterable {
    case peer     = "Peer"
    case onePhone = "One Phone"
    case convention = "Convention"
  }
    
    // Debug queue HUD
    struct DebugQ: Identifiable {
      enum State { case queued, speaking, done }
      let id: UUID
      let text: String
      var state: State
      let timestamp: Date
    }

    @Published var debugMode: Bool = true           // toggle if you want
    @Published var debugItems: [DebugQ] = []

    
  @Published var mode: Mode = .peer
    
    private func sameBase(_ a: String, _ b: String) -> Bool {
      return String(a.prefix(2)).lowercased() == String(b.prefix(2)).lowercased()
    }

  // ─────────────────────────────── Services
  @Published var multipeerSession: MultipeerSession
  @Published var sttService       = AzureSpeechTranslationService()   // Peer mode (mic → translation to peer)
  @Published var autoService      = AzureAutoConversationService()    // One‑Phone auto‑detect
  @Published var ttsService       = AppleTTSService()

  // ─────────────────────────────── UI state (Peer screen)
  @Published var myTranscribedText         = "Tap 'Start' to speak.".localized
  @Published var peerSaidText              = ""
  @Published var translatedTextForMeToHear = ""

  @Published var connectionStatus        = "Not Connected".localized
  @Published var isProcessing            = false
  @Published var permissionStatusMessage = "Checking permissions…".localized
  @Published var hasAllPermissions       = false
  @Published var errorMessage: String?
    
    // ─────────────────────────────── Convention tunables/state
    private let conventionChunkSeconds: TimeInterval = 5.0
    private var convContext: TurnContext?
    
    // how many characters of the current STT segment we’ve already committed
    private var convCursor: Int = 0

    // carry the last final text into the next segment to avoid re-speaking
    private var convCarryPrefix: String = ""
    
    private let minConventionCommitChars = 12
    
    // Tail-stability buffer (last few partials within ~300ms)
    private var recentPartials: [(text: String, at: Date)] = []
    private var lastPartialAt: Date = .distantPast
    private let tailStabilityWindow: TimeInterval = 0.30  // 300 ms
    private let tailStabilityTokens = 3
    
    /// Return the last N tokens of a string (lowercased, punctuation stripped)
    private func lastTokens(_ s: String, _ n: Int) -> [String] {
      let t = s.lowercased()
        .components(separatedBy: CharacterSet.alphanumerics.inverted)
        .filter { !$0.isEmpty }
      return Array(t.suffix(n))
    }

    /// True if the last few tokens have been the same across recent snapshots.
    private func tailLooksStable(_ candidate: String, now: Date) -> Bool {
      guard !candidate.isEmpty else { return false }
      let tail = lastTokens(candidate, tailStabilityTokens)
      guard !tail.isEmpty else { return false }

      // Compare against snapshots in the recent window
      let windowed = recentPartials.filter { now.timeIntervalSince($0.at) <= tailStabilityWindow }
      if windowed.count < 2 { return false }  // need at least two points to confirm stability

      return windowed.allSatisfy { snap in
        lastTokens(snap.text, tailStabilityTokens) == tail
      }
    }

    /// True if the final few tokens look like transient one-offs (guard against flickers).
    /// For candidates ≥ 30 chars, if ≥ 3 of the last 5 tokens are hapax and there's no terminal punctuation, defer.
    private func rareTailLooksSuspicious(_ s: String) -> Bool {
      let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
      guard trimmed.count >= 30 else { return false }
      if let last = trimmed.last, ".?!…。！？".contains(last) { return false }

      let toks = lastTokens(trimmed, 5)
      guard !toks.isEmpty else { return false }
      var freq: [String: Int] = [:]
      toks.forEach { freq[$0, default: 0] += 1 }
      let hapaxCount = toks.filter { (freq[$0] ?? 0) == 1 }.count
      return hapaxCount >= 3
    }
    
    // longest common prefix length
    private func commonPrefixCount(_ a: String, _ b: String) -> Int {
      let ax = Array(a), bx = Array(b)
      let n = min(ax.count, bx.count)
      var i = 0
      while i < n, ax[i] == bx[i] { i += 1 }
      return i
    }
    
    // Use early streaming in Peer and Convention (but not One-Phone).
    private var allowEarlyStreaming: Bool {
      return mode == .peer || mode == .convention
    }

  // ─────────────────────────────── Languages
  /// On Peer screen: me → peer. On One‑Phone screen: left tile ↔ right tile.
  @Published var myLanguage   = LanguageSettings.currentLanguage.rawValue  {
    didSet { refreshVoices(); multipeerSession.updateLocalLanguage(myLanguage) }
  }
  @Published var peerLanguage = "es-US"  { didSet { refreshVoices() } } // Spanish (Latin America)

  struct Language: Identifiable, Hashable {
    let id   = UUID()
    let name: String
    let code: String
  }
    
    private func cleanForPresentation(_ s: String) -> String {
      collapseImmediateRepeats(
        s.trimmingCharacters(in: .whitespacesAndNewlines)
          .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
      )
    }
    
    // ─────────────────────────────── One-Phone offline auto state
    private var currentAutoLang: String = ""   // actual lang the native STT is using in One-Phone

    private let nativeSTT = NativeSTTService()
    private var useOfflineOnePhone: Bool {
      if #available(iOS 26.0, *) { return true } else { return false }
    }
    private var useOfflinePeer: Bool {
      if #available(iOS 26.0, *) {
        // all connected peers must be offline capable
        return multipeerSession.connectedPeers.allSatisfy { p in multipeerSession.peerOfflineCapable[p] == true }
      }
      return false
    }
    
  private var expectedBaseAfterResume: String?  // “en” or “es” we *think* we’re hearing next
  private var retargetWindowActive = false
  private var retargetDeadline = Date()

  // Add near other internals:
  private var resumeAfterTTSTask: Task<Void, Never>?
  // Which language STT should use next time we re-open in One-Phone mode
  private var pendingAutoLang: String?

  private var turnContext: TurnContext?
  public var phraseQueue: [PhraseCommit] = []
  private var phraseTranslations: [UUID: String] = [:]
  private var queueDraining = false
  private var activeCommitID: UUID?
  private var activeTTSDestination: String?
  private var lastCommitAt: Date?
  private var hasFloor = false
  private var queueBargeDeadline = Date()
  private var nextContextBiasBase: String?
    
    // De-dup recently spoken texts (normalized) to avoid replays
    private var spokenLRU: [String: Date] = [:]
    private let spokenLRUWindow: TimeInterval = 8.0
    private let spokenLRULimit = 32
    
    private var currentSpeakingID: UUID?


  private let phraseStableCutoff: TimeInterval = 1.3   // NOTE_TUNABLE (Tunables.md → stable cutoff)
  private let phraseStableJitter: TimeInterval = 0.2
  private let phraseLongSpeechCap: TimeInterval = 7.0   // NOTE_TUNABLE
  private let phraseInterGapMax: TimeInterval = 0.15    // NOTE_TUNABLE
    
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
  @Published var playbackSpeed: Double = Double(AppleTTSService.normalizedDefaultRate) {
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

    private var ttsStartedAt: Date?

    
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
      guard allowEarlyStreaming else { return }   // was: guard mode == .peer
      let s = lastPartialForTurn
      guard !s.isEmpty, s.count > earlyTTSSentPrefix + earlyTTSMinChunkChars else { return }
      if let cut = lastWordBoundary(in: s, fromOffset: earlyTTSSentPrefix) {
        let start = s.index(s.startIndex, offsetBy: earlyTTSSentPrefix)
        let chunk = String(s[start..<cut])
        emitChunk(chunk, isFinal: false)
        earlyTTSSentPrefix = s.distance(from: s.startIndex, to: cut)
      }
      startEarlyTTSBailTimer()
    }

    private func handlePeerPartial(_ s: String) {
      translatedTextForMeToHear = s
      lastPartialForTurn = s

      // 🔒 Early-TTS is Peer-only. Convention should not speak partials.
      guard mode == .peer else { return }

      if earlyTTSTimer == nil { startEarlyTTSBailTimer() }

      // Try to emit any full sentence(s) we haven’t sent yet
      if let cut = lastSentenceBoundary(in: s, fromOffset: earlyTTSSentPrefix) {
        let start = s.index(s.startIndex, offsetBy: earlyTTSSentPrefix)
        let chunk = String(s[start..<cut])
        if chunk.count >= earlyTTSMinChunkChars {
          emitChunk(chunk, isFinal: false)
          earlyTTSSentPrefix = s.distance(from: s.startIndex, to: cut)
          // Reset the 8s timer to wait for next clause
          startEarlyTTSBailTimer()
        }
      }
    }
    
    private func handleStreamingPartial(_ s: String) {
      translatedTextForMeToHear = s
      lastPartialForTurn = s

      guard allowEarlyStreaming else { return }

      if earlyTTSTimer == nil { startEarlyTTSBailTimer() }

      if let cut = lastSentenceBoundary(in: s, fromOffset: earlyTTSSentPrefix) {
        let start = s.index(s.startIndex, offsetBy: earlyTTSSentPrefix)
        let chunk = String(s[start..<cut]).trimmingCharacters(in: .whitespacesAndNewlines)
        if chunk.count >= earlyTTSMinChunkChars {
          emitChunk(chunk, isFinal: false)
          earlyTTSSentPrefix = s.distance(from: s.startIndex, to: cut)
          startEarlyTTSBailTimer()
        }
      }
    }

    
    private func normalizedKey(_ s: String) -> String {
      s.lowercased()
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }

    private func allowSpeakAndMark(_ text: String) -> Bool {
      let key = normalizedKey(text)
      let now = Date()
      // purge old
      spokenLRU = spokenLRU.filter { now.timeIntervalSince($0.value) <= spokenLRUWindow }
      if spokenLRU.count > spokenLRULimit {
        // drop oldest few
        let drop = spokenLRU.sorted { $0.value < $1.value }.prefix(8).map { $0.key }
        drop.forEach { spokenLRU.removeValue(forKey: $0) }
      }
      if let last = spokenLRU[key], now.timeIntervalSince(last) <= spokenLRUWindow {
        return false
      }
      spokenLRU[key] = now
      return true
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
        emitChunk(tail, isFinal: true)
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
        let initialLang = LanguageSettings.currentLanguage.rawValue
        self.multipeerSession = MultipeerSession(localLanguage: initialLang)

        checkAllPermissions()
        refreshVoices()
        wireConnectionBadge()
        wirePeerPipelines()
        wireAutoPipelines()
        wireOfflineOnePhonePipelines()
        wirePeerPipelinesOffline()
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

        $micSensitivity
          .receive(on: RunLoop.main)
          .sink { [weak self] v in self?.nativeSTT.sensitivity = Float(v) }
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

        // 🔁 Disconnect radios whenever *not* in Peer mode (prevents stray Multipeer errors in Convention)
        $mode.removeDuplicates()
          .sink { [weak self] m in
            guard let self else { return }
            if m != .peer { self.multipeerSession.disconnect() }
          }
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
      permissionStatusMessage = ok ? "Permissions granted.".localized
                                   : "Speech & Microphone permission denied.".localized
      if ok { sttService.setupSpeechRecognizer(languageCode: myLanguage) }
    }
  }

    private var seenMessageIDs = Set<UUID>()
    private var seenOrder: [UUID] = []
    private let seenCap = 64

    private func markSeen(_ id: UUID) -> Bool {
      if seenMessageIDs.contains(id) { return false }
      seenMessageIDs.insert(id)
      seenOrder.append(id)
      if seenOrder.count > seenCap {
        let drop = seenOrder.removeFirst()
        seenMessageIDs.remove(drop)
      }
      return true
    }
    
  // ─────────────────────────────── Mic control
    func startListening() {
      guard hasAllPermissions else { myTranscribedText = "Missing permissions.".localized; return }

      switch mode {
      case .peer:
        guard multipeerSession.connectionState == .connected else {
          myTranscribedText = "Not connected.".localized; return
        }
        if #available(iOS 26.0, *) {
          guard !nativeSTT.isListening else { return }
          resetEarlyTTSState()
          isProcessing = true
          myTranscribedText = "Listening…".localized
          peerSaidText = ""; translatedTextForMeToHear = ""
          nativeSTT.startTranscribing(languageCode: myLanguage)
        } else {
          // pre-26 behaviour
          guard !sttService.isListening else { return }
          resetEarlyTTSState()
          isProcessing = true
          myTranscribedText = "Listening…".localized
          peerSaidText = ""; translatedTextForMeToHear = ""
          (sttService as! AzureSpeechTranslationService).start(src: myLanguage, dst: peerLanguage)
        }

      case .convention:
        if #available(iOS 26.0, *) {
          guard !nativeSTT.isListening else { return }
          resetEarlyTTSState()
          isProcessing = true
          peerSaidText = ""; translatedTextForMeToHear = ""
          convCursor = 0                                // ← add this
          nativeSTT.startTranscribing(languageCode: peerLanguage)
        }  else {
          guard !sttService.isListening else { return }
          resetEarlyTTSState()
          isProcessing = true
          peerSaidText = ""; translatedTextForMeToHear = ""
          (sttService as! AzureSpeechTranslationService).start(src: peerLanguage, dst: myLanguage)
        }

      case .onePhone:
        startAuto()
      }
    }


    func stopListening() {
      switch mode {
      case .peer, .convention:
        if useOfflinePeer {
          if nativeSTT.isListening { nativeSTT.stopTranscribing() }
        } else {
          if sttService.isListening { (sttService as! AzureSpeechTranslationService).stop() }
        }
        resetEarlyTTSState()
        isProcessing = false

      case .onePhone:
        stopAuto()
      }
    }


  // ─────────────────────────────── One‑Phone mic control
    
    private func startAutoOffline() {
      guard !nativeSTT.isListening else { return }
      isProcessing = false          // UI should show 'Start', not 'Processing…'
      isAutoListening = true
      currentAutoLang = myLanguage

      let now = Date()
      var votes = LangVotes()
      votes.biasToward(base: String(currentAutoLang.prefix(2)))
      turnContext = TurnContext(
        rollingText: "",
        lockedSrcBase: nil,
        votes: votes,
        startedAt: now,
        lastGrowthAt: now,
        committed: false,
        flipUsed: false
      )
      expectedBaseAfterResume = String(currentAutoLang.prefix(2)).lowercased()
      retargetWindowActive = true
      retargetDeadline = now.addingTimeInterval(2.0)
      logBreadcrumb("CAPTURE_START(\(currentAutoLang))")
      fireHaptic(.captureStart)

      // Open mic
      nativeSTT.startTranscribing(languageCode: currentAutoLang)
      Log.d("OnePhone: start native STT @ \(currentAutoLang)")
    }

    private func stopAutoOffline() {
      if nativeSTT.isListening { nativeSTT.stopTranscribing() }
      isAutoListening = false
      isProcessing = false
      retargetWindowActive = false
      expectedBaseAfterResume = nil
      resumeAfterTTSTask?.cancel(); resumeAfterTTSTask = nil
      turnContext = nil
      phraseQueue.removeAll()
      phraseTranslations.removeAll()
      queueDraining = false
      activeCommitID = nil
      hasFloor = false
      pendingAutoLang = nil
      Log.d("OnePhone: stop native STT")
    }
    
    func startAuto() {
      guard hasAllPermissions else { return }
      if #available(iOS 26.0, *) {
        startAutoOffline()   // native STT only
      } else {
        guard !autoService.isListening else { return }
        isProcessing = true; isAutoListening = true
        autoService.start(between: myLanguage, and: peerLanguage)
      }
    }

    func stopAuto() {
      if useOfflineOnePhone {
        stopAutoOffline()
      } else {
        guard autoService.isListening else { return }
        autoService.stop()
        isProcessing = false; isAutoListening = false
      }
    }

  // ─────────────────────────────── Peer pipelines
    private func wirePeerPipelines() {
      sttService
        .partialResult
        .receive(on: RunLoop.main)
        .removeDuplicates()
        .throttle(for: .milliseconds(350), scheduler: RunLoop.main, latest: true)
        .sink { [weak self] txt in
          guard let self, self.mode != .onePhone else { return }
          self.handleStreamingPartial(txt)
        }
        .store(in: &cancellables)

      sttService
        .finalResult
        .receive(on: RunLoop.main)
        .sink { [weak self] tx in
          guard let self, self.mode != .onePhone else { return }
          isProcessing = false
          self.finalizePeerTurn(with: tx)
        }
        .store(in: &cancellables)

      sttService
        .sourceFinalResult
        .receive(on: RunLoop.main)
        .sink { [weak self] txt in
          guard let self, self.mode != .onePhone else { return }
          if mode == .peer { myTranscribedText = txt }
          else if mode == .convention { peerSaidText = txt }
        }
        .store(in: &cancellables)
    }
    
    // TranslationViewModel.swift
    // ─────────────────────────────── Peer pipelines (iOS 26+ native STT → on-device MT)
    private func wirePeerPipelinesOffline() {
      // Live native partials → show line only
      nativeSTT.partialResultSubject
        .receive(on: RunLoop.main)
        .removeDuplicates()
        .throttle(for: .milliseconds(350), scheduler: RunLoop.main, latest: true)
        .sink { [weak self] txt in
          guard let self, self.mode != .onePhone else { return }
          self.translatedTextForMeToHear = txt
        }
        .store(in: &cancellables)

      // Finals from native STT
      nativeSTT.finalResultSubject
        .receive(on: RunLoop.main)
        .sink { [weak self] raw in
          guard let self, self.mode != .onePhone else { return }
          self.isProcessing = false

          if self.mode == .peer {
            // Peer path only (Convention handled elsewhere)
            let src = self.myLanguage
            let dst = self.peerLanguage
            Task {
              let finalTx = (try? await UnifiedTranslateService.translate(raw, from: src, to: dst)) ?? raw
              await MainActor.run {
                self.sendTextToPeer(finalTx, isFinal: true, reliable: true)
                self.finalizePeerTurn(with: finalTx)
                self.myTranscribedText = raw
              }
            }
          } else {
            // Convention: update raw line only; enqueue is handled by handleConventionStableBoundary/Partial
              self.peerSaidText = cleanForPresentation(raw)
          }
        }
        .store(in: &cancellables)
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
               let better = try? await UnifiedTranslateService.translate(
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
              sourceText:   rawTrim.isEmpty ? "(inaudible)".localized : rawTrim,
              targetLang:   dstFull,
              translatedText: finalTx.isEmpty ? "(unavailable)".localized : finalTx,
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
    
    // ─────────────────────────────── Convention commit-on-interval
    private func handleConventionPartial(_ snapshot: NativeSTTService.PartialSnapshot) {
        guard mode == .convention, useOfflineOnePhone else { return }
        
        let full = snapshot.text
        
        print("[Convention] partial len=\(full.count) carry=\(convCarryPrefix.count) cursor=\(convCursor)")

        translatedTextForMeToHear = full
        
        // keep recent partials for tail-stability check
        lastPartialAt = snapshot.timestamp
        recentPartials.append((text: full, at: snapshot.timestamp))
        // keep only last ~6 items
        if recentPartials.count > 6 { recentPartials.removeFirst(recentPartials.count - 6) }
        
        if convContext == nil {
            var votes = LangVotes()
            votes.biasToward(base: String(peerLanguage.prefix(2)))
            convContext = TurnContext(
                rollingText: "",
                lockedSrcBase: String(peerLanguage.prefix(2)).lowercased(),
                votes: votes,
                startedAt: snapshot.timestamp,
                lastGrowthAt: snapshot.timestamp,
                committed: false,
                flipUsed: true
            )
            // On a brand-new segment, assume we might see the previous final repeated at the front.
            // Fast-forward cursor to that common prefix so we never re-speak it.
            let carry = convCarryPrefix
            if !carry.isEmpty {
                convCursor = commonPrefixCount(full, carry)
            } else {
                convCursor = 0
            }
        }
        
        guard var ctx = convContext else { return }
        ctx.update(with: full, now: snapshot.timestamp)
        convContext = ctx
        
        // Safety clamp
        if convCursor > full.count { convCursor = full.count }
        
        // Tail from the last committed character onward
        let tailStart = full.index(full.startIndex, offsetBy: convCursor)
        let tail = String(full[tailStart...])
        
        let elapsed = snapshot.timestamp.timeIntervalSince(ctx.startedAt)
        if elapsed >= conventionChunkSeconds, !tail.isEmpty {
            let speakerBase = String(peerLanguage.prefix(2)).lowercased()
            if let (chunk, consumed) = conventionBestChunk(fromTail: tail,
                                                           base: speakerBase,
                                                           langCode: peerLanguage,
                                                           loose: true) {          // ← loose for mid-speech
                commitConventionPhrase(reason: "interval", finalText: chunk)
                convCursor += consumed
                print("[Convention] interval-commit consumed=\(consumed) newCursor=\(convCursor)")
                
                if !convCarryPrefix.isEmpty && convCursor >= convCarryPrefix.count {
                    convCarryPrefix = ""
                }
                convContext = TurnContext(
                    rollingText: full,
                    lockedSrcBase: String(peerLanguage.prefix(2)).lowercased(),
                    votes: LangVotes(),
                    startedAt: Date(),
                    lastGrowthAt: Date(),
                    committed: false,
                    flipUsed: true
                )
            }
        }
        // If the interval passed but we couldn't find a "complete" chunk,
        // do a conservative commit at a nearby word boundary to keep audio flowing.
        else if elapsed >= (conventionChunkSeconds * 1.7), !tail.isEmpty {
          if let cut = lastWordBoundary(in: tail, fromOffset: max(0, tail.count - 80)) {
            let candidate = String(tail[..<cut]).trimmingCharacters(in: .whitespacesAndNewlines)
            if candidate.count >= minConventionCommitChars {
              let cleaned = collapseImmediateRepeats(candidate)
              commitConventionPhrase(reason: "intervalFallback", finalText: cleaned)
              convCursor += candidate.count
              print("[Convention] interval-commit FALLBACK consumed=\(candidate.count) newCursor=\(convCursor)")

              // reset the interval window
              convContext = TurnContext(
                rollingText: full,
                lockedSrcBase: String(peerLanguage.prefix(2)).lowercased(),
                votes: LangVotes(),
                startedAt: Date(),
                lastGrowthAt: Date(),
                committed: false,
                flipUsed: true
              )
            }
          }
        }

    }


    private func handleConventionStableBoundary(_ boundary: NativeSTTService.StableBoundary) {
      guard mode == .convention, useOfflineOnePhone else { return }

      let full = boundary.text.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !full.isEmpty else { return }
      print("[Convention] stable boundary fullLen=\(full.count) cursor=\(convCursor)")

      if convCursor > full.count { convCursor = full.count }
      let tailStart = full.index(full.startIndex, offsetBy: convCursor)
      let tail = String(full[tailStart...])

      if !tail.isEmpty {
        let speakerBase = String(peerLanguage.prefix(2)).lowercased()
        if let (chunk, consumed) = conventionBestChunk(fromTail: tail,
                                                        base: speakerBase,
                                                        langCode: peerLanguage,
                                                        loose: false) {   // ← strict on stable/final
           commitConventionPhrase(reason: boundary.reason, finalText: chunk)
           convCursor += consumed
           print("[Convention] stable-commit consumed=\(consumed) newCursor=\(convCursor)")
         } else {
           // existing finalTail fallback stays as-is
           let cleaned = collapseImmediateRepeats(tail)
           commitConventionPhrase(reason: "finalTail", finalText: cleaned)
           convCursor = full.count
           print("[Convention] stable-commit FALLBACK consumed=\(full.count) newCursor=\(convCursor)")
         }
      }

      // Carry this final so we don’t re-speak it if OS repeats it
      convCarryPrefix = full
      let cap = 500
      if convCarryPrefix.count > cap { convCarryPrefix = String(convCarryPrefix.suffix(cap)) }
      print("[Convention] carryPrefix set len=\(convCarryPrefix.count)")

      convContext = nil
    }

    private func conventionBestChunk(fromTail tail: String,
                                     base: String,
                                     langCode: String,
                                     loose: Bool) -> (String, Int)? {
      let raw = tail.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !raw.isEmpty else { return nil }

      func ok(_ s: String) -> Bool {
        // In loose mode (interval), be permissive: only structural + length.
        // In strict mode (stable/final), also require tail stability and rarity check.
        let passStructure = isStructurallyComplete(s, base: base, langCode: langCode, minChars: minConventionCommitChars)
        if loose { return passStructure }
        return passStructure && tailLooksStable(s, now: lastPartialAt) && !rareTailLooksSuspicious(s)
      }

      // 1) Prefer a sentence boundary
      if let cut = lastSentenceBoundary(in: raw, fromOffset: 0) {
        let candidate = String(raw[..<cut]).trimmingCharacters(in: .whitespacesAndNewlines)
        let cleaned   = collapseImmediateRepeats(candidate)
        if ok(cleaned) { return (cleaned, candidate.count) }
      }

      // 2) Otherwise try a word boundary near the end (wider window)
      if let cut = lastWordBoundary(in: raw, fromOffset: max(0, raw.count - 100)) {
        let candidate = String(raw[..<cut]).trimmingCharacters(in: .whitespacesAndNewlines)
        let cleaned   = collapseImmediateRepeats(candidate)
        if ok(cleaned) { return (cleaned, candidate.count) }
      }

      // 3) Fallback: whole tail if it’s “complete enough”
      let cleaned = collapseImmediateRepeats(raw)
      if ok(cleaned) { return (cleaned, cleaned.count) }
      return nil
    }
    
    private func tokens(_ s: String) -> [String] {
      s.lowercased()
       .components(separatedBy: CharacterSet.alphanumerics.inverted)
       .filter { !$0.isEmpty }
    }

    private func endsWithConnector(_ s: String, base: String) -> Bool {
      let t = tokens(s)
      guard let last = t.last else { return false }

      // very small language-aware sets (not phrase-specific; just function words)
      let connectorsEN: Set<String> = ["and","or","but","so","because","though","although",
                                       "that","than","then","if","when","while",
                                       "to","of","for","with","at","from","by","about","as"]
      let connectorsES: Set<String> = ["y","o","pero","así","porque","aunque",
                                       "que","si","cuando","mientras",
                                       "a","de","por","con","en","para","como"]
      let connectorsFR: Set<String> = ["et","ou","mais","donc","car","quoique","bienque",
                                       "que","si","quand","lorsque","pendant",
                                       "à","de","pour","avec","en","comme"]
      let connectorsDE: Set<String> = ["und","oder","aber","denn","doch","obwohl",
                                       "dass","wenn","als","während",
                                       "zu","von","für","mit","bei","über","als","in","an"]

      let base2 = String(base.prefix(2)).lowercased()
      let set: Set<String>
      switch base2 {
        case "es": set = connectorsES
        case "fr": set = connectorsFR
        case "de": set = connectorsDE
        default:   set = connectorsEN
      }
      return set.contains(last)
    }

    /// POS-lite: check there is at least one verb in the final span.
    /// Uses NSLinguisticTagger so it works for EN/ES/FR/DE/etc without hardcoding words.
    private func hasVerb(_ s: String, languageCode: String) -> Bool {
      let tagger = NSLinguisticTagger(tagSchemes: [.lexicalClass], options: 0)
      tagger.string = s
      let range = NSRange(location: 0, length: (s as NSString).length)
      var seenVerb = false
      tagger.enumerateTags(in: range, unit: .word, scheme: .lexicalClass, options: [.omitPunctuation, .omitWhitespace]) { tag, _, _ in
        if tag == .verb { seenVerb = true }
      }
      return seenVerb
    }

    /// If the tail *starts* with a subordinator (e.g. “even though / aunque / obwohl …”),
    /// require that a verb appears somewhere in that same tail before we allow commit.
    private func subordinatorOpensClause(_ s: String, base: String) -> Bool {
      let t = tokens(s)
      guard !t.isEmpty else { return false }
      let w1 = t[0]
      let w2 = t.count >= 2 ? t[1] : ""

      let base2 = String(base.prefix(2)).lowercased()
      switch base2 {
      case "es":
        return w1 == "aunque" || w1 == "si" || w1 == "cuando"
      case "fr":
        return (w1 == "bien" && w2 == "que") || w1 == "quoique" || w1 == "si"
      case "de":
        return w1 == "obwohl" || w1 == "wenn" || w1 == "als"
      default: // en
        return (w1 == "even" && w2 == "though") || w1 == "although" || w1 == "if"
      }
    }


    /// Basic repetition cleaner: collapses immediate repeated tokens ("about about", "que que").
    private func collapseImmediateRepeats(_ s: String) -> String {
      let parts = s.split { !$0.isLetter && !$0.isNumber }.map(String.init)
      var out: [String] = []
      for p in parts {
        if out.last?.lowercased() == p.lowercased() { continue }
        out.append(p)
      }
      // Rebuild minimally with single spaces; punctuation will be preserved by caller’s original string.
      return out.joined(separator: " ")
    }

    /// Final structural gate applied to a candidate chunk.
    /// Reject if too short, ends with connector, or opens a clause without a verb yet.
    private func isStructurallyComplete(_ text: String, base: String, langCode: String, minChars: Int) -> Bool {
      let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
      guard trimmed.count >= minChars else { return false }
      if endsWithConnector(trimmed, base: base) { return false }

      // If subordinator detected at the *start* of this piece, require a verb present
      if subordinatorOpensClause(trimmed, base: base) && !hasVerb(trimmed, languageCode: langCode) {
        return false
      }
      return true
    }
    // Light, language-aware clean-up before MT
    private func normalizeNarration(_ s: String, base: String) -> String {
      var out = collapseImmediateRepeats(s)

      if base == "es" {
        // collapse doubled function words
        out = out.replacingOccurrences(of: #"\b(de|que|y|o|para|con|en|a)\s+\1\b"#,
                                       with: "$1",
                                       options: .regularExpression)
        // “del el” → “del”
        out = out.replacingOccurrences(of: #"\bdel\s+el\b"#, with: "del", options: .regularExpression)
      }
      return out
    }


    private func commitConventionPhrase(reason: String, finalText: String) {
      // DROP_TINY: skip micro-utterances during mid-speech; allow at final tail.
      if finalText.count < minConventionCommitChars && reason != "finalTail" {
        logBreadcrumb("DROP_TINY(\(finalText.count))")
        return
      }

      // Normalize the speaker’s narration (base = peerLanguage)
      let speakerBase = String(peerLanguage.prefix(2)).lowercased()
      let cleaned = normalizeNarration(
        finalText.trimmingCharacters(in: .whitespacesAndNewlines),
        base: speakerBase
      )

      // Speaker → me (peerLanguage → myLanguage)
      let src = peerLanguage
      let dst = myLanguage

      let now = Date().timeIntervalSince1970
      logBreadcrumb("PHRASE_COMMIT(\(cleaned.count))")
      isProcessing = false

      // De-dupe guard for near-identical quick repeats
      guard allowSpeakAndMark(cleaned) else {
        logBreadcrumb("DROP_DUP(\(cleaned.count))")
        return
      }

      Task {
        // Translate the cleaned phrase
        let tx = (try? await UnifiedTranslateService.translate(cleaned, from: src, to: dst)) ?? cleaned
        let txClean = tx.trimmingCharacters(in: .whitespacesAndNewlines)

        await MainActor.run {
          // History
          localTurns.append(LocalTurn(
            sourceLang:   src,
            sourceText:   cleaned,
            targetLang:   dst,
            translatedText: txClean,
            timestamp:    now
          ))

          // UI
          peerSaidText = cleaned
          translatedTextForMeToHear = txClean

          // Enqueue spoken text (translated)
          let commit = PhraseCommit(
            srcFull: src,
            dstFull: dst,
            raw:     txClean,
            committedAt: now,
            decidedAt:   now,
            confidence:  1.0
          )

          // If somehow already speaking this exact id, don’t re-queue
          if let cur = currentSpeakingID, cur == commit.id { return }

          phraseQueue.append(commit)
          phraseTranslations[commit.id] = txClean
          queueBargeDeadline = Date().addingTimeInterval(phraseInterGapMax)

          if phraseQueue.count >= 3 && ttsService.isSpeaking {
            let ran = (ttsStartedAt != nil) ? Date().timeIntervalSince(ttsStartedAt!) : 0
            if ran >= 0.7 { ttsService.stopAtBoundary() }
          }
          drainPhraseQueue()
        }
      }
    }

    
    // TranslationViewModel.swift
    private func wireOfflineOnePhonePipelines() {
      // Partial snapshots from native STT (iOS 26)
      nativeSTT.partialSnapshotSubject
        .receive(on: RunLoop.main)
        .throttle(for: .milliseconds(200), scheduler: RunLoop.main, latest: true)
        .sink { [weak self] snap in
          guard let self else { return }
          switch self.mode {
          case .onePhone:    self.handleOnePhonePartial(snap)
          case .convention:  self.handleConventionPartial(snap)
          case .peer:        break
          }
        }
        .store(in: &cancellables)

      // Stable boundaries / finals from native STT
      nativeSTT.stableBoundarySubject
        .receive(on: RunLoop.main)
        .sink { [weak self] boundary in
          guard let self else { return }
          switch self.mode {
          case .onePhone:    self.handleStableBoundary(boundary)
          case .convention:  self.handleConventionStableBoundary(boundary)
          case .peer:        break
          }
        }
        .store(in: &cancellables)

      nativeSTT.finalResultSubject
        .receive(on: RunLoop.main)
        .sink { [weak self] raw in
          guard let self else { return }
          let b = NativeSTTService.StableBoundary(text: raw, timestamp: Date(), reason: "finalTail")
          switch self.mode {
          case .onePhone:    self.handleStableBoundary(b)
          case .convention:  self.handleConventionStableBoundary(b)
          case .peer:        break
          }
        }
        .store(in: &cancellables)

      ttsService.startedSubject
        .receive(on: RunLoop.main)
        .sink { [weak self] in self?.handleTTSStarted() }
        .store(in: &cancellables)

      ttsService.finishedSubject
        .receive(on: RunLoop.main)
        .sink { [weak self] in self?.handleTTSEnded() }
        .store(in: &cancellables)
    }

    private func handleOnePhonePartial(_ snapshot: NativeSTTService.PartialSnapshot) {
      guard mode == .onePhone, useOfflineOnePhone else { return }
      translatedTextForMeToHear = snapshot.text

      if turnContext == nil || (turnContext?.committed == true && snapshot.text != turnContext?.rollingText) {
        prepareNextTurnContext(now: snapshot.timestamp)
      }

      guard var ctx = turnContext else { return }

      if ctx.committed {
        if snapshot.text == ctx.rollingText { return }
        prepareNextTurnContext(now: snapshot.timestamp)
        guard var fresh = turnContext else { return }
        fresh.update(with: snapshot.text, now: snapshot.timestamp)
        turnContext = fresh
        ctx = fresh
      } else {
        ctx.update(with: snapshot.text, now: snapshot.timestamp)
        turnContext = ctx
      }

      logBreadcrumb("PARTIAL(\(snapshot.text.count))")
      evaluateRetargetIfNeeded(for: snapshot.text)

      guard let active = turnContext else { return }
      if shouldCommitDueToPunctuation(active.rollingText) {
        commitCurrentPhrase(reason: "punctuation", finalText: active.rollingText)
      } else if snapshot.timestamp.timeIntervalSince(active.startedAt) >= phraseLongSpeechCap {
        commitCurrentPhrase(reason: "cap", finalText: active.rollingText)
      }
    }

    private func handleStableBoundary(_ boundary: NativeSTTService.StableBoundary) {
      guard mode == .onePhone, useOfflineOnePhone else { return }
      guard let ctx = turnContext, !ctx.committed else { return }
      if ctx.shouldDelayForTrailingConjunction() { return }
      commitCurrentPhrase(reason: boundary.reason, finalText: boundary.text)
    }

    private func shouldCommitDueToPunctuation(_ text: String) -> Bool {
      let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
      guard let last = trimmed.last else { return false }
      return [".", "?", "!"].contains(last)
    }

    private func evaluateRetargetIfNeeded(for partial: String) {
      guard retargetWindowActive else { return }
      if Date() > retargetDeadline { retargetWindowActive = false; expectedBaseAfterResume = nil; return }
      guard var ctx = turnContext else { return }
      guard !ctx.flipUsed else { return }
      guard let guessBase = TranslationViewModel.guessBase2(partial) else { return }
      guard let expected = expectedBaseAfterResume, guessBase != expected else { return }

      ctx.flipUsed = true
      turnContext = ctx
      retargetWindowActive = false
      expectedBaseAfterResume = guessBase
      let other = (guessBase == String(myLanguage.prefix(2)).lowercased()) ? myLanguage : peerLanguage
      restartAutoSTT(to: other)
      logBreadcrumb("AUTO_FLIP(\(guessBase))")
    }

    private func commitCurrentPhrase(reason: String, finalText: String) {
      guard var ctx = turnContext else { return }
      guard !ctx.committed else { return }

      let trimmed = finalText.trimmingCharacters(in: .whitespacesAndNewlines)
      guard trimmed.count > 1 else { return }

      ctx.update(with: trimmed, now: Date())

      let defaultBase = String(currentAutoLang.prefix(2)).lowercased()
      let (decidedBase, confidence) = ctx.decidedBase(defaultBase: defaultBase)

      let myBase = String(myLanguage.prefix(2)).lowercased()
      let srcFull = (decidedBase == myBase) ? myLanguage : peerLanguage
      let dstFull = (srcFull == myLanguage) ? peerLanguage : myLanguage

      ctx.lock(base: decidedBase)
      ctx.committed = true
      turnContext = ctx

      let now = Date()
      let commit = PhraseCommit(
        srcFull: srcFull,
        dstFull: dstFull,
        raw: trimmed,
        committedAt: now.timeIntervalSince1970,
        decidedAt: now.timeIntervalSince1970,
        confidence: confidence
      )

      phraseQueue.append(commit)
      queueBargeDeadline = Date().addingTimeInterval(phraseInterGapMax)
      lastCommitAt = now
      logBreadcrumb("PHRASE_COMMIT(\(trimmed.count))")
      logBreadcrumb("LANG_DECIDE(\(srcFull),\(String(format: "%.2f", confidence)))")
      logBreadcrumb("QUEUE_DEPTH(\(phraseQueue.count))")
      fireHaptic(.phraseCommit)
      isProcessing = false

        if phraseQueue.count >= 3 && ttsService.isSpeaking {
          let ran = (ttsStartedAt != nil) ? Date().timeIntervalSince(ttsStartedAt!) : 0
          if ran >= 0.7 { ttsService.stopAtBoundary() }
        }

      translate(commit: commit)
      drainPhraseQueue()

      let nextBias = (decidedBase == myBase) ? String(peerLanguage.prefix(2)).lowercased()
                                            : String(myLanguage.prefix(2)).lowercased()
      pendingAutoLang = (srcFull == myLanguage) ? peerLanguage : myLanguage
      nextContextBiasBase = nextBias
      expectedBaseAfterResume = nextBias
      retargetWindowActive = true
      retargetDeadline = Date().addingTimeInterval(2.0)
      turnContext = nil
    }

    private func translate(commit: PhraseCommit) {
      Task {
        let translated = (try? await UnifiedTranslateService.translate(commit.raw, from: commit.srcFull, to: commit.dstFull)) ?? commit.raw
        await MainActor.run {
          self.registerTranslation(translated, for: commit)
        }
      }
    }

    private func registerTranslation(_ translation: String, for commit: PhraseCommit) {
      let translationClean = translation.trimmingCharacters(in: .whitespacesAndNewlines)
      phraseTranslations[commit.id] = translationClean

      // Append cleaned items to history
      localTurns.append(LocalTurn(
        sourceLang:     commit.srcFull,
        sourceText:     commit.raw,          // commit.raw was set to the translated text in this flow
        targetLang:     commit.dstFull,
        translatedText: translationClean,
        timestamp:      Date().timeIntervalSince1970
      ))

      // Update visible lines
      let srcBase = String(commit.srcFull.prefix(2)).lowercased()
      if srcBase == String(myLanguage.prefix(2)).lowercased() {
        myTranscribedText = commit.raw
      } else {
        peerSaidText = commit.raw
      }
      translatedTextForMeToHear = translationClean

      drainPhraseQueue()
    }

    private func drainPhraseQueue() {
      guard !queueDraining else { return }
      guard let next = phraseQueue.first else { return }
      guard let translation = phraseTranslations[next.id] else { return }

      queueDraining = true
      activeCommitID = next.id
      currentSpeakingID = next.id
      activeTTSDestination = next.dstFull
      translatedTextForMeToHear = translation
      resumeAfterTTSTask?.cancel(); resumeAfterTTSTask = nil
      hasFloor = true

      if let idx = debugItems.firstIndex(where: { $0.id == next.id }) {
        debugItems[idx].state = .speaking
      }

      ttsStartedAt = Date()
      ttsService.speak(
        text: translation,
        languageCode: next.dstFull,
        voiceIdentifier: voice_for_lang[next.dstFull]
      )
    }

    private func handleTTSStarted() {
      hasFloor = true
      fireHaptic(.ttsStart)
      if let dst = activeTTSDestination {
        logBreadcrumb("TTS_START(\(dst))")
      }
      if let commitAt = lastCommitAt {
        let latency = Date().timeIntervalSince(commitAt)
        let ms = Int(latency * 1000)
        logBreadcrumb("COMMIT_TO_TTS(\(ms))")
      }
    }

    private func handleTTSEnded() {
      fireHaptic(.ttsEnd)
      queueDraining = false
      hasFloor = false

      if !phraseQueue.isEmpty {
        let finished = phraseQueue.removeFirst()
        phraseTranslations[finished.id] = nil
        if let idx = debugItems.firstIndex(where: { $0.id == finished.id }) {
          debugItems[idx].state = .done
        }
      }
      activeCommitID = nil
      currentSpeakingID = nil
      ttsStartedAt = nil

      logBreadcrumb("TTS_END")

      if !phraseQueue.isEmpty {
        let delay = max(0, queueBargeDeadline.timeIntervalSinceNow)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
          self?.drainPhraseQueue()
        }
      }
    }


    private func prepareNextTurnContext(now: Date) {
      let bias = nextContextBiasBase ?? expectedBaseAfterResume ?? String(currentAutoLang.prefix(2)).lowercased()
      var votes = LangVotes()
      votes.biasToward(base: bias, weight: 0.5)
      turnContext = TurnContext(
        rollingText: "",
        lockedSrcBase: nil,
        votes: votes,
        startedAt: now,
        lastGrowthAt: now,
        committed: false,
        flipUsed: false
      )
      nextContextBiasBase = nil
      expectedBaseAfterResume = bias
      retargetWindowActive = true
      retargetDeadline = now.addingTimeInterval(2.0)
    }

    private func routeAwareGrace() -> TimeInterval { 1.2 } // NOTE_TUNABLE baseline grace; route-aware variants in M3

    private enum HapticEvent { case captureStart, phraseCommit, ttsStart, ttsEnd, captureResume }

    private func fireHaptic(_ event: HapticEvent) {
#if canImport(UIKit)
      let style: UIImpactFeedbackGenerator.FeedbackStyle
      switch event {
      case .captureStart, .captureResume: style = .light
      case .phraseCommit: style = .medium
      case .ttsStart: style = .rigid
      case .ttsEnd: style = .soft
      }
      UIImpactFeedbackGenerator(style: style).impactOccurred()
#else
      print("[HAPTIC] \(event)")
#endif
    }

    private func logBreadcrumb(_ entry: String) {
#if DEBUG
      print("[Telemetry] \(entry)")
#endif
    }


    private func purity(of text: String, expectedTargetBase base: String) -> Double {
      // Super-lightweight “is this mostly target language?” heuristic.
      let tokens = text
        .lowercased()
        .split { !$0.isLetter }
      guard !tokens.isEmpty else { return 0 }

      let targetStopwords: Set<String>
      switch base {
      case "es":
        targetStopwords = ["el","la","los","las","de","y","que","como","estás","hola","buenos","buenas","gracias","por","favor","sí","no","dónde","cuánto","yo","tú","usted","nosotros","ellos","muy","bien","mal"]
      case "en":
        targetStopwords = ["the","and","you","are","is","hello","hi","how","what","where","please","thanks","i","we","they","good","morning","night"]
      case "fr":
        targetStopwords = ["le","la","les","de","et","vous","je","bonjour","merci","s'il","est","où","comment"]
      case "de":
        targetStopwords = ["der","die","das","und","ist","wo","wie","hallo","danke","bitte","ich","du","wir","sie","guten"]
      default:
        targetStopwords = []
      }

      var hits = 0
      for t in tokens {
        if targetStopwords.contains(String(t)) { hits += 1 }
      }
      return Double(hits) / Double(tokens.count)
    }
    
    var captureIsActive: Bool {
      switch mode {
      case .onePhone:
        return nativeSTT.isListening && isAutoListening
      case .peer, .convention:
        return useOfflinePeer ? nativeSTT.isListening : sttService.isListening
      }
    }

    // Tiny language guesser reused (keep private)
    private static func guessBase2(_ raw: String) -> String? {
      guard !raw.isEmpty else { return nil }

      // Use Foundation's NSLinguisticTagger (no extra import needed)
      if let lang = NSLinguisticTagger.dominantLanguage(for: raw) {
        switch lang {
        case "en": return "en"
        case "es": return "es"
        case "fr": return "fr"
        case "de": return "de"
        case "ja": return "ja"
        case "zh", "zh-Hans", "zh-Hant": return "zh"
        default: break
        }
      }

      // Simple heuristic for Spanish characters
      if raw.range(of: #"[áéíóúñ¿¡]"#, options: .regularExpression) != nil { return "es" }
      return nil
    }

    private func restartAutoSTT(to lang: String) {
      guard #available(iOS 26.0, *), currentAutoLang != lang else { return }
      currentAutoLang = lang
      // Pause -> restart the native recognizer in the new language
      nativeSTT.stopTranscribing()
      // Let CoreAudio breathe a tick to avoid "mDataByteSize (0)" logs
      Task { @MainActor in
        try? await Task.sleep(nanoseconds: 120_000_000)
        nativeSTT.startTranscribing(languageCode: lang)
      }
    }



    private func wireConnectionBadge() {
      Publishers.CombineLatest($mode, multipeerSession.$connectionState)
        .receive(on: RunLoop.main)
        .map { [weak self] mode, state -> String in
          guard let self else { return Localization.localized("Not Connected") }

          // One-Phone / Convention keep their fixed badges
          if mode == .onePhone     { return Localization.localized("One Phone") }
          if mode == .convention   { return Localization.localized("Convention") }

          // Peer mode
          let peerName = multipeerSession.connectedPeers.first?.displayName
          let peer = peerName ?? Localization.localized("peer")

          switch state {
          case .notConnected:
            return Localization.localized("Not Connected")

          case .connecting:
            return Localization.localized("Connecting…")

          case .connected:
            // Append " · On-Device" when *all* peers advertise iOS 26+
            // (useOfflinePeer already checks the connectedPeers + capability map)
            let base = Localization.localized("Connected to %@", peer)
            if useOfflinePeer { return base + " · On-Device" }
            return base

          @unknown default:
            return Localization.localized("Unknown")
          }
        }
        .assign(to: &$connectionStatus)
    }

    // TranslationViewModel.swift
    // Pause/resume policy while device is speaking.
    // Do NOT stop nativeSTT; we only gate emission via hasFloor/queue.
    private func wireMicPauseDuringPlayback() {
      ttsService.$isSpeaking
        .receive(on: RunLoop.main)
        .removeDuplicates()
        .sink { [weak self] speaking in
          guard let self else { return }

          if speaking {
            // Snapshot intent to resume only for Azure path
            wasListeningPrePlayback =
              (mode != .onePhone) || sttService.isListening || autoService.isListening || nativeSTT.isListening

            // Pause only online capture paths; keep native STT running.
            if (sttService as! AzureSpeechTranslationService).isListening {
              (sttService as! AzureSpeechTranslationService).stop()
            }
            if autoService.isListening {
              autoService.stop()
            }
            // nativeSTT: do NOT stop; we want continuous capture per Audio Rules

          } else {
            guard wasListeningPrePlayback else { isProcessing = false; return }
            wasListeningPrePlayback = false

            // Small grace applies to online paths only; native STT is already running.
            resumeAfterTTSTask?.cancel()
            resumeAfterTTSTask = Task { [weak self] in
              try? await Task.sleep(nanoseconds: 1_200_000_000) // 1.2s
              await MainActor.run {
                guard let self else { return }
                switch mode {
                case .peer:
                  if !useOfflinePeer {
                    (sttService as! AzureSpeechTranslationService).start(src: myLanguage, dst: peerLanguage)
                  }
                case .convention:
                  if !useOfflinePeer {
                    (sttService as! AzureSpeechTranslationService).start(src: peerLanguage, dst: myLanguage)
                  }
                case .onePhone:
                  if !useOfflineOnePhone {
                    autoService.start(between: myLanguage, and: peerLanguage)
                  }
                }
                isProcessing = false
              }
            }
          }
        }
        .store(in: &cancellables)
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
        translatedText: Localization.localized("…"),
        timestamp: now
      ))
      leftDraft = ""

      Task {
        do {
          let tx = try await UnifiedTranslateService.translate(text, from: myLanguage, to: peerLanguage)
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
            errorMessage = "Text translation failed. Speaking original.".localized
            replaceLocalTurn(id: pendingId, with: LocalTurn(
              id: pendingId,
              sourceLang: myLanguage,
              sourceText: text,
              targetLang: peerLanguage,
              translatedText: "(untranslated) %@".localizedFormat(text),
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
        translatedText: Localization.localized("…"),
        timestamp: now
      ))
      rightDraft = ""

      Task {
        do {
          let tx = try await UnifiedTranslateService.translate(text, from: peerLanguage, to: myLanguage)
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
            errorMessage = "Text translation failed. Speaking original.".localized
            replaceLocalTurn(id: pendingId, with: LocalTurn(
              id: pendingId,
              sourceLang: peerLanguage,
              sourceText: text,
              targetLang: myLanguage,
              translatedText: "(untranslated) %@".localizedFormat(text),
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

  // ─────────────────────────────── Messaging / Emission
    private func emitChunk(_ text: String, isFinal: Bool) {
      guard !text.isEmpty else { return }

      switch mode {
      case .peer:
        // send to peer; they will speak it
        sendTextToPeer(text, isFinal: isFinal, reliable: isFinal)

      case .convention:
        // 🚦 Convention is phrase-commit only. Queue for local TTS (no partial TTS).
        // Treat 'text' as already in myLanguage when we call from finalize paths.
        let commit = PhraseCommit(
          srcFull: peerLanguage,
          dstFull: myLanguage,
          raw: text,
          committedAt: Date().timeIntervalSince1970,
          decidedAt:   Date().timeIntervalSince1970,
          confidence:  1.0
        )
        phraseQueue.append(commit)
          
        phraseTranslations[commit.id] = text
          
        debugItems.append(DebugQ(id: commit.id, text: text, state: .queued, timestamp: Date()))

        queueBargeDeadline = Date().addingTimeInterval(phraseInterGapMax)
          if phraseQueue.count >= 3 && ttsService.isSpeaking {
            let ran = (ttsStartedAt != nil) ? Date().timeIntervalSince(ttsStartedAt!) : 0
            if ran >= 0.7 { ttsService.stopAtBoundary() }
          }
        drainPhraseQueue()

      case .onePhone:
        // finals-only unless you add streaming MT
        if isFinal {
          ttsService.speak(
            text: text,
            languageCode: myLanguage,
            voiceIdentifier: voice_for_lang[myLanguage]
          )
        }
      }
    }
    
    private func sendTextToPeer(_ text: String, isFinal: Bool, reliable: Bool) {
      guard !text.isEmpty else { return }

      // The payload we send in Peer mode is already translated for the peer,
      // so the language of *this* text is peerLanguage, not myLanguage.
      let payloadLang = (mode == .peer) ? peerLanguage : myLanguage

      let msg = MessageData(
        id: UUID(),
        originalText:       text,
        sourceLanguageCode: payloadLang,   // ✅ label with the language of the text we’re sending
        targetLanguageCode: nil,
        isFinal:            isFinal,
        timestamp:          Date().timeIntervalSince1970
      )

      if multipeerSession.connectedPeers.isEmpty {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
          self?.multipeerSession.send(message: msg, reliable: reliable)
        }
      } else {
        multipeerSession.send(message: msg, reliable: reliable)
      }
    }


    // TranslationViewModel.swift
    // ─────────────────────────────── Messaging (peer → me)
    private func handleReceivedMessage(_ m: MessageData) {
      guard markSeen(m.id) else { return }         // 🚫 drop duplicates
      guard m.timestamp > lastReceivedTimestamp else { return }
      lastReceivedTimestamp = m.timestamp

        Task {
          // If the payload is already in my language, don’t translate again.
          let srcBase = String(m.sourceLanguageCode.prefix(2)).lowercased()
          let myBase  = String(myLanguage.prefix(2)).lowercased()

          let tx: String
          if srcBase == myBase {
            tx = m.originalText.trimmingCharacters(in: .whitespacesAndNewlines)   // ✅ already my language
          } else {
            tx = (try? await UnifiedTranslateService.translate(
                    m.originalText,
                    from: m.sourceLanguageCode,
                    to:   myLanguage
                  )) ?? m.originalText
          }

          await MainActor.run {
            if m.isFinal {
              peerSaidText = "Peer: %@".localizedFormat(tx)
            } else {
              translatedTextForMeToHear = tx
            }
            isProcessing = true
            print("PeerRX: \(useOfflinePeer ? "on-device" : "online") tx to \(myLanguage)")
            ttsService.speak(text: tx,
                             languageCode: myLanguage,
                             voiceIdentifier: voice_for_lang[myLanguage])
          }
        }

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
    myTranscribedText         = "Tap 'Start' to speak.".localized
    peerSaidText              = ""
    translatedTextForMeToHear = ""
    localTurns.removeAll()
  }
}
