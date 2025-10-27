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
import NaturalLanguage
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

    @Published var debugMode: Bool = false           // toggle if you want
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
  @Published var isConventionHost: Bool = true   // host speaks; listeners are receive-only
    private var lastSpeakerPartialAt: Date = .distantPast
    private var micHealthTimer: DispatchSourceTimer?


    // near other state
    @Published private var micIntentActive = false
    private var micGuardCancellable: AnyCancellable?
    
    private var micWatchArmedAt = Date.distantFuture
    private var sttRestartCooldownUntil = Date.distantPast
    private var sttRestartInFlight = false

    
    // Kills any in-flight partial MT tasks when we advance the epoch.
    private var rxDraftEpoch: Int = 0

    // Peer/Convention RAW sequencing
    private var turnId = UUID()
    private var seqCounter = 0
    
    // ─────────────────────────────── Convention tunables/state
    private let conventionChunkSeconds: TimeInterval = 5.0
    private var convContext: TurnContext?
    
    // how many characters of the current STT segment we’ve already committed
    private var convCursor: Int = 0

    // carry the last final text into the next segment to avoid re-speaking
    private var convCarryPrefix: String = ""
    
    private let minConventionCommitChars = 12
    
    private func isGarbageTranslation(_ s: String) -> Bool {
      let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
      return t.count == 1
    }
    
    private var peerIdleNudgeWork: DispatchWorkItem?
    private let peerIdleNudgeAfter: TimeInterval = 0.95
    private let peerShortMinChars = 3

    
    // Listener-side per-turn raw accumulator to avoid re-speaking the same words
    private var rxRawAccum: [UUID: String] = [:]
    
    private var rxCoveredCount: [UUID: Int] = [:]   // ✅ how many raw chars we’ve covered per turn
    private var rxLastChunkAt: [UUID: Date] = [:]
    private var rxDstAccum: [UUID:String] = [:]   // turnId → concatenated spoken target text

    // Listener-side idle flush per turn
    private var rxLastRecvAt   : [UUID: Date] = [:]
    private var rxIdleTimers   : [UUID: DispatchWorkItem] = [:]
    private let idleFlushAfter : TimeInterval = 0.90   // speak tail if no arrivals ~900ms
    private let idleMinChars   : Int = 4              // relaxed min to avoid silence at end


    private var seenPartialSinceOpen = false

    
    // ── Peer "rolling phrase" chunking (speaker) ─────────────────────────
    private let peerChunkSeconds: TimeInterval = 1.5
    private let minPeerCommitChars = 26

    private var peerContext: TurnContext?
    private var peerCursor: Int = 0         // how far into the current STT segment we've already sent
    private var peerCarryPrefix: String = "" // last final/stable to avoid re-sends on repeats

    // small recent partials buffer for tail-stability, like Convention
    private var peerRecentPartials: [(text: String, at: Date)] = []
    private var peerLastPartialAt: Date = .distantPast
    private let peerTailWindow: TimeInterval = 0.30
    private let peerTailTokens = 3

    private var convFirstSpoken: Bool = false

    
    // Tail-stability buffer (last few partials within ~300ms)
    private var recentPartials: [(text: String, at: Date)] = []
    private var lastPartialAt: Date = .distantPast
    private let tailStabilityWindow: TimeInterval = 0.30  // 300 ms
    private let tailStabilityTokens = 3
    
    
    private var lastSpokenText: String = ""
    private var lastSpokenAt = Date.distantPast
    private let nearDupWindow: TimeInterval = 3.0
    
    private var lastSpeakerFinalAt: Date = .distantPast

    
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
    
    private let sentenceMarks: Set<Character> = [".","!","?","…","。","！","？"]

    @MainActor
    private func lastSentenceBoundarySmart(in s: String, fromOffset off: Int) -> String.Index? {
      if let punctCut = lastSentenceBoundary(in: s, fromOffset: off) { return punctCut }
      if #available(iOS 12.0, *) {
        let tok = NLTokenizer(unit: .sentence); tok.string = s
        var bestEnd: Int? = nil
        tok.enumerateTokens(in: s.startIndex..<s.endIndex) { range, _ in
          let end = range.upperBound.utf16Offset(in: s)
          if end > off { bestEnd = end }
          return true
        }
        if let end = bestEnd { return s.index(s.startIndex, offsetBy: end) }
      }
      return nil
    }

    @MainActor
    private func shouldEmitSentence(_ cleaned: String, dst: String, isFirstPiece: Bool) -> Bool {
      let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else { return false }
      if let last = trimmed.last, sentenceMarks.contains(last) { return true }

      // fall back to structure/verb checks
      let tokenCount = trimmed.split { !$0.isLetter && !$0.isNumber }.count
      if looksSentenceLike(trimmed, languageCode: dst) {
        return isFirstPiece ? (tokenCount >= 5 || trimmed.count >= 28)
                            : (tokenCount >= 4 || trimmed.count >= 22)
      }
      return isFirstPiece ? false : (trimmed.count >= 32 || tokenCount >= 7)
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
    @Published var myLanguage: String {
      didSet { refreshVoices(); multipeerSession.updateLocalLanguage(myLanguage) }
    }
    @Published var peerLanguage: String {
      didSet { refreshVoices() }
    }

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
    
    
    enum StreamingProfile { case streaming, finalsOnly, hybridSimple }
    @Published var profile: StreamingProfile = .hybridSimple

    private struct RxTurnState {
      var startedAt: Date
      var warmupDeadline: Date
      var firstSpoken: Bool = false
    }

    private var rxTurnState: [UUID: RxTurnState] = [:]

    
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
  private let phraseLongSpeechCap: TimeInterval = 5.0   // NOTE_TUNABLE
  private let phraseInterGapMax: TimeInterval = 0.25    // NOTE_TUNABLE
    
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
    private let earlyTTSMinChunkChars = 28    // avoid tiny staccato chunks

    private var earlyTTSSentPrefix = 0        // chars already sent/spoken this turn
    private var earlyTTSTimer: DispatchSourceTimer?
    private var lastPartialForTurn = ""

    private var ttsStartedAt: Date?
    
    private var rxPartialMTTask: Task<Void, Never>?


    private var rxBuffers: [UUID: (expect:Int, stash:[Int:MessageData], timer: DispatchWorkItem?)] = [:]

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
    
    private func looksLikeGlitch(_ s: String) -> Bool {
      let t = s.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
      if t.isEmpty { return true }
      // very short single-token snippets are often jitters
      let toks = t.split { !$0.isLetter }
      if toks.count <= 1 && t.count < 6 { return true }
      // repeated letters (“hmmmm”, “aaa”)
      if t.range(of: #"([a-z])\1{2,}"#, options: .regularExpression) != nil { return true }
      // common fillers
      let fillers: Set<String> = ["um","uh","er","erm","hmm","mmm","mm","uhh","umm","eh","ah","uh-huh","mm-hmm"]
      if fillers.contains(t) { return true }
      return false
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

      // purge stale LRU
      spokenLRU = spokenLRU.filter { now.timeIntervalSince($0.value) <= spokenLRUWindow }
      if spokenLRU.count > spokenLRULimit {
        let drop = spokenLRU.sorted { $0.value < $1.value }.prefix(8).map { $0.key }
        drop.forEach { spokenLRU.removeValue(forKey: $0) }
      }

      // 0) If something is currently speaking and it’s “effectively the same”, drop.
      if let speakingID = activeCommitID, let speaking = phraseTranslations[speakingID] {
        let a = normalizedKey(speaking), b = key
        if a == b || a.contains(b) || b.contains(a) || highlySimilar(a, b) { return false }
      }

      // 1) If the last queued is “effectively the same”, drop.
      if let last = phraseQueue.last, let lastText = phraseTranslations[last.id] {
        let a = normalizedKey(lastText), b = key
        if a == b || a.contains(b) || b.contains(a) || highlySimilar(a, b) { return false }
      }

      // 2) LRU (recent actually-spoken items): treat contains/high-similar as duplicates too.
      //    This blocks "¿Cómo estás?" right after "Oye, ¿cómo estás?"
      for (recent, t) in spokenLRU {
        if now.timeIntervalSince(t) <= spokenLRUWindow {
          if recent == key || recent.contains(key) || key.contains(recent) || highlySimilar(recent, key) {
            return false
          }
        }
      }

      // Accept → remember
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
    
    // Normalize to tokens to be robust to small punctuation/spaces/accents
    @MainActor
    private func normTokens(_ s: String) -> [String] {
      s.lowercased()
        .folding(options: .diacriticInsensitive, locale: .current)
        .components(separatedBy: CharacterSet.alphanumerics.inverted)
        .filter { !$0.isEmpty }
    }

    // Find the last index in FULL where a trailing window of SPOKEN appears (token-wise).
    // Returns the token index in FULL *after* the overlap, or nil if not found.
    @MainActor
    private func suffixStartIndex(full: String, spoken: String) -> Int? {
      let f = normTokens(full)
      let s = normTokens(spoken)
      guard !f.isEmpty, !s.isEmpty else { return nil }

      // Use a trailing window of spoken to allow small drift
      let tailWin = max(5, min(12, s.count)) // 5–12 tokens
      let probe = Array(s.suffix(tailWin))

      // Scan f to find the LAST match of probe (allow small edit drift by sliding)
      // Simple greedy: slide probe inside f, require ≥80% token match inside window
      func matchAt(_ start: Int) -> Bool {
        let end = start + probe.count
        guard end <= f.count else { return false }
        let slice = Array(f[start..<end])
        let inter = Set(slice).intersection(Set(probe)).count
        return Double(inter) / Double(probe.count) >= 0.80
      }

      var lastHit: Int? = nil
      if f.count >= probe.count {
        for i in 0...(f.count - probe.count) {
          if matchAt(i) { lastHit = i + probe.count }
        }
      }
      return lastHit
    }

    // Compute only-the-new suffix (text side, not token side).
    // If there’s no reliable overlap or the delta is too short, return "" to skip.
    @MainActor
    private func suffixDelta(full: String, spoken: String) -> String {
      let cutTok = suffixStartIndex(full: full, spoken: spoken)
      guard let cutTok else { return "" }  // no solid overlap → skip (prevents repeats)

      // Map token cut back into character cut *approximately* by walking tokens
      let fToks = normTokens(full)
      let targetTailTokens = Array(fToks.suffix(max(0, fToks.count - cutTok)))
      guard !targetTailTokens.isEmpty else { return "" }

      // Cheap char cut: find the substring whose tokens ≈ targetTailTokens
      // We take the full and drop until the first occurrence of the first tail token
      let tailFirst = targetTailTokens.first!
      guard let r = full.range(of: "\\b\(NSRegularExpression.escapedPattern(for: tailFirst))\\b",
                               options: [.regularExpression, .caseInsensitive]) else {
        return "" // couldn’t map back confidently → skip
      }
      var out = String(full[r.lowerBound...]).trimmingCharacters(in: .whitespacesAndNewlines)

      // Final minimal gates to avoid micro-stubs
      let hasTerminal = out.last.map { ".?!…".contains($0) } == true
      let tokenCount  = out.split { !$0.isLetter && !$0.isNumber }.count
      if !hasTerminal && tokenCount < 5 && out.count < 28 { return "" }

      return out
    }

    

    // Normalize minimally for overlap checks (lowercase, collapse spaces)
    private func norm(_ s: String) -> String {
      s.lowercased()
       .trimmingCharacters(in: .whitespacesAndNewlines)
       .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }

    // Common-prefix length on the *normalized* strings, but return the original-index cut for `b`
    private func commonPrefixCountNormalized(_ a: String, _ b: String) -> Int {
      let an = Array(norm(a)), bn = Array(norm(b))
      let n = min(an.count, bn.count)
      var i = 0
      while i < n, an[i] == bn[i] { i += 1 }
      // Map back: approximate by proportion of b’s raw length
      let br = Array(b)
      return Int(Double(br.count) * (Double(i) / Double(bn.count == 0 ? 1 : bn.count)))
    }

    // Trim any already-spoken prefix for this turnId; return the “new delta”
    private func trimAlreadySpokenPrefix(tid: UUID, candidate: String) -> String {
      let already = rxDstAccum[tid] ?? ""
      if already.isEmpty { return candidate }
      // If candidate starts with (approximately) what we've spoken, cut it
      let cut = commonPrefixCountNormalized(already, candidate)
      guard cut > 0, cut <= candidate.count else { return candidate }
      let idx = candidate.index(candidate.startIndex, offsetBy: cut)
      return String(candidate[idx...]).trimmingCharacters(in: .whitespacesAndNewlines)
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
        
        // 1) Seed languages from onboarding preference
         let initialLang = LanguageSettings.currentLanguage.rawValue
         self._myLanguage   = Published(initialValue: initialLang)
         self._peerLanguage = Published(initialValue: TranslationViewModel.defaultPeer(for: initialLang))

         // 2) Build Multipeer once, advertising *my* language
         self.multipeerSession = MultipeerSession(localLanguage: initialLang)

        checkAllPermissions()
        refreshVoices()
        wireConnectionBadge()
        wirePeerPipelines()
        wireAutoPipelines()
        wireOfflineOnePhonePipelines()
        wirePeerPipelinesOffline()
        wireMicPauseDuringPlayback()
        
        nativeSTT.$isListening
          .receive(on: RunLoop.main)
          .sink { [weak self] on in
            print("[UI] nativeSTT.isListening = \(on)")
            self?.objectWillChange.send() // refreshes captureIsActive-driven UI
          }
          .store(in: &cancellables)
        
        micGuardCancellable = nativeSTT.$isListening
          .receive(on: RunLoop.main)
          .dropFirst()
          .sink { [weak self] listening in
            guard let self else { return }
            print("[MicGuard] isListening=\(listening) intent=\(self.micIntentActive) "
                + "mode=\(self.mode) tts=\(self.ttsService.isSpeaking) "
                + "connected=\(self.multipeerSession.connectionState.rawValue) "
                + "cooldown=\(Date() < self.sttRestartCooldownUntil) inFlight=\(self.sttRestartInFlight)")

            guard self.mode == .peer else { return }
            guard self.micIntentActive else { print("[MicGuard] skip: intent=false"); return }
            guard !listening else { return }
            guard self.multipeerSession.connectionState == .connected else { print("[MicGuard] skip: not connected"); return }
            guard !self.ttsService.isSpeaking else { print("[MicGuard] skip: local TTS"); return }
            guard !self.sttRestartInFlight else { print("[MicGuard] skip: restart in-flight"); return }
            guard Date() >= self.sttRestartCooldownUntil else { print("[MicGuard] skip: cooldown"); return }

            self.sttRestartInFlight = true
            self.sttRestartCooldownUntil = Date().addingTimeInterval(2.0)
            print("[MicGuard] RESTART in 150ms")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
              guard let self else { return }
                if self.micIntentActive, !self.nativeSTT.isListening, !self.ttsService.isSpeaking {
                  print("[MicGuard] startTranscribing(\(self.myLanguage))")
                  // ⬇️ Same seeding here
                  self.lastSpeakerPartialAt = Date()
                  self.micWatchArmedAt = Date().addingTimeInterval(1.2)
                  self.seenPartialSinceOpen = false

                  self.nativeSTT.startTranscribing(languageCode: self.myLanguage)
                }
              // release in-flight after a short grace
              DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                  self.sttRestartInFlight = false
              }
            }
          }




        (sttService as! AzureSpeechTranslationService).$isListening
          .receive(on: RunLoop.main)
          .sink { [weak self] on in
            print("[UI] azureSTT.isListening = \(on)")
            self?.objectWillChange.send()
          }
          .store(in: &cancellables)

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
          .sink { [weak self] v in
            self?.nativeSTT.sensitivity = Float(v)
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

        // 🔁 Disconnect radios whenever *not* in Peer mode (prevents stray Multipeer errors in Convention)
        $mode
          .removeDuplicates()
          .sink { [weak self] m in
            guard let self else { return }
            switch m {
            case .peer:
                // Defensive: ensure mic is closed on this device unless user taps Start
                if nativeSTT.isListening { nativeSTT.stopTranscribing() }
              self.multipeerSession.updateMode("peer", isHost: false)
            case .convention:
              self.multipeerSession.updateMode("convention", isHost: self.isConventionHost)
            case .onePhone:
                multipeerSession.disconnect()       // instead of `break`
              // we intentionally disconnect radios already (you did this)
            }
          }
          .store(in: &cancellables)

        $isConventionHost
          .removeDuplicates()
          .sink { [weak self] isHost in
            guard let self, self.mode == .convention else { return }
            self.multipeerSession.updateMode("convention", isHost: isHost)
          }
          .store(in: &cancellables)

        
        multipeerSession.onMessageReceived = { [weak self] msg in
          self?.handleReceivedMessage(msg)
        }
        
        startMicHealthWatchdog()

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

        print("[Mic] startListening tapped; mode=\(mode) connected=\(multipeerSession.connectionState)")

        micIntentActive = true


        // Give STT a warm-up window before MicWatch is allowed to nudge.
        micWatchArmedAt = Date().addingTimeInterval(2.0)

        // Clear any previous restart lockout
        sttRestartCooldownUntil = Date.distantPast
        sttRestartInFlight = false
        
        seenPartialSinceOpen = false
        
      switch mode {
      case .peer:
          guard multipeerSession.connectionState == .connected else {
              myTranscribedText = "Not connected.".localized; return
            }
            // Only the device that taps “Start” should capture.
            // If this device already has TTS floor or is speaking, don’t open mic.
            guard !ttsService.isSpeaking else { return }
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
        guard isConventionHost else { return } // ignore accidental calls
        if #available(iOS 26.0, *) {
          guard !nativeSTT.isListening else { return }
          resetEarlyTTSState()
          nativeSTT.farFieldBoost = true // <-- enable boost here
          isProcessing = true
          peerSaidText = ""; translatedTextForMeToHear = ""
          convCursor = 0                                // ← add this
          nativeSTT.startTranscribing(languageCode: peerLanguage)
        }  else {
          guard !sttService.isListening else { return }
          resetEarlyTTSState()
          nativeSTT.farFieldBoost = true // <-- enable boost here
          isProcessing = true
          peerSaidText = ""; translatedTextForMeToHear = ""
          (sttService as! AzureSpeechTranslationService).start(src: peerLanguage, dst: myLanguage)
        }

      case .onePhone:
        startAuto()
      }
    }

    private func isNearDuplicate(_ a: String, _ b: String) -> Bool {
      let na = normalizedKey(a)
      let nb = normalizedKey(b)
      if na == nb { return true }
      // token overlap ≥ 85% OR one is strong prefix of the other
      let ta = na.split(separator: " ")
      let tb = nb.split(separator: " ")
      guard !ta.isEmpty, !tb.isEmpty else { return false }
      let setA = Set(ta), setB = Set(tb)
      let inter = Double(setA.intersection(setB).count)
      let union = Double(setA.union(setB).count)
      let jaccard = union > 0 ? inter/union : 0
      let prefixish = na.hasPrefix(nb) || nb.hasPrefix(na)
      return jaccard >= 0.85 || prefixish
    }

    func stopListening() {
      print("[Mic] stopListening tapped; mode=\(mode)")

        micIntentActive = false
        
      switch mode {
      case .peer, .convention:
        // Always stop native STT if it’s open (independent of useOfflinePeer)
        if nativeSTT.isListening {
          nativeSTT.farFieldBoost = false
          peerIdleNudgeWork?.cancel(); peerIdleNudgeWork = nil
          resumeAfterTTSTask?.cancel(); resumeAfterTTSTask = nil
          earlyTTSTimer?.cancel(); earlyTTSTimer = nil

          nativeSTT.stopTranscribing()

          // Safety: if STT didn’t close cleanly, force it.
          DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self else { return }
            if self.nativeSTT.isListening {
              print("⚠️ [Mic] STT still active after 250ms – forcing stop")
              self.nativeSTT.forceStop()
            }
          }
        }

        // Also stop any online paths if they’re active (harmless if not)
        if (sttService as! AzureSpeechTranslationService).isListening {
          (sttService as! AzureSpeechTranslationService).stop()
        }
        if autoService.isListening {
          autoService.stop()
        }

        resetEarlyTTSState()
        isProcessing = false


      case .onePhone:
        stopAuto()
      }

      recentPartials.removeAll()
      lastPartialAt = .distantPast
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
      // LOCAL translated partials → UI (keep)
      sttService.partialResult
        .receive(on: RunLoop.main)
        .removeDuplicates()
        .throttle(for: .milliseconds(250), scheduler: RunLoop.main, latest: true)
        .sink { [weak self] txt in
          guard let self, self.mode != .onePhone else { return }
          self.handleStreamingPartial(txt)
        }
        .store(in: &cancellables)

      // NEW: RAW partials from Azure → broadcast in Peer / Convention(host)
      (sttService as! AzureSpeechTranslationService).sourcePartialResult
        .receive(on: RunLoop.main)
        .throttle(for: .milliseconds(250), scheduler: RunLoop.main, latest: true)
        .sink { [weak self] raw in
          guard let self else { return }
          if self.mode == .peer { self.sendRawToPeers(raw, isFinal: false) }
          if self.mode == .convention && self.isConventionHost { /* optional: not needed if you commit by chunks */ }
        }
        .store(in: &cancellables)

      // LOCAL translated finals → UI (keep)
      sttService.finalResult
        .receive(on: RunLoop.main)
        .sink { [weak self] tx in
          guard let self, self.mode != .onePhone else { return }
          self.isProcessing = false
          self.finalizePeerTurn(with: tx)
        }
        .store(in: &cancellables)

      // RAW finals from Azure → broadcast in Peer / Convention(host)
      (sttService as! AzureSpeechTranslationService).sourceFinalResult
        .receive(on: RunLoop.main)
        .sink { [weak self] raw in
          guard let self, self.mode != .onePhone else { return }
          if self.mode == .peer { self.sendRawToPeers(raw, isFinal: true) }
          if self.mode == .convention && self.isConventionHost {
            // Convention host normally commits by chunks; if you want an end-of-segment final too:
            self.sendRawToPeers(raw, isFinal: true)
          }
          if self.mode == .peer { self.myTranscribedText = raw }
          else if self.mode == .convention { self.peerSaidText = raw }
        }
        .store(in: &cancellables)
    }
    
    // TranslationViewModel.swift
    // ─────────────────────────────── Peer pipelines (iOS 26+ native STT → on-device MT)
    private func wirePeerPipelinesOffline() {
      // Live native partials → UI line (keep)
        nativeSTT.partialSnapshotSubject
          .receive(on: RunLoop.main)
          .throttle(for: .milliseconds(200), scheduler: RunLoop.main, latest: true)
          .sink { [weak self] snap in
            guard let self else { return }
            if self.mode == .peer {
              self.handlePeerPartialChunk(snap)
            } else if self.mode == .convention {
              self.handleConventionPartial(snap) // unchanged
            }
          }
          .store(in: &cancellables)


      // Finals from native STT
        nativeSTT.finalResultSubject
          .receive(on: RunLoop.main)
          .sink { [weak self] raw in
            guard let self, self.mode != .onePhone else { return }
            self.isProcessing = false

            if self.mode == .peer {
              self.sendRawToPeers(raw, isFinal: true)
              self.myTranscribedText = raw
              self.finalizePeerTurn(with: raw)

              // 🔧 Cool-down so MicWatch doesn’t flap right after a final
              self.lastSpeakerFinalAt = Date()
              self.micWatchArmedAt = Date().addingTimeInterval(2.5)

            } else {
              self.peerSaidText = self.cleanForPresentation(raw)
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

              print("[Route] current=\(AVAudioSession.sharedInstance().currentRoute)")

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

    private func startMicHealthWatchdog() {
      micHealthTimer?.cancel(); micHealthTimer = nil
      let t = DispatchSource.makeTimerSource(queue: .main)
      t.schedule(deadline: .now() + 1.5, repeating: 1.5)
      t.setEventHandler { [weak self] in
        guard let self else { return }
        guard self.mode == .peer, self.micIntentActive else { return }
        guard self.multipeerSession.connectionState == .connected else { return }
        guard !self.ttsService.isSpeaking else { return }

        let postFinalGuard: TimeInterval = 4.0
        let staleThreshold: TimeInterval = 6.0

        // Give the user a beat after a final/tts.
        guard Date() >= self.lastSpeakerFinalAt.addingTimeInterval(postFinalGuard) else { return }
        // Don’t nudge until we’ve actually seen a partial since this mic-open.
        guard self.seenPartialSinceOpen else { return }
        // Warm-up grace.
        guard Date() >= self.micWatchArmedAt else { return }
        // We need at least one real partial on record.
        guard self.lastSpeakerPartialAt != .distantPast else { return }
        // ⬇️ Prevent fights with our own restart logic
        guard !self.sttRestartInFlight else { return }
        guard Date() >= self.sttRestartCooldownUntil else { return }

        let staleFor = Date().timeIntervalSince(self.lastSpeakerPartialAt)
        if self.nativeSTT.isListening, staleFor > staleThreshold {
          print("[MicWatch] STT stale (\(Int(staleFor*1000))ms) → soft nudge")
          print("[Watch] STT stale armed=\(Date() >= self.micWatchArmedAt) seenPartial=\(self.seenPartialSinceOpen) staleFor=\(Int(staleFor*1000))ms")
          self.sttRestartInFlight = true
          self.sttRestartCooldownUntil = Date().addingTimeInterval(2.0)

          self.nativeSTT.stopTranscribing()
          DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            if self.micIntentActive, !self.ttsService.isSpeaking {
              print("[MicWatch] startTranscribing(\(self.myLanguage))")
              print("[Watch] start transcribing armed=\(Date() >= self.micWatchArmedAt) seenPartial=\(self.seenPartialSinceOpen) staleFor=\(Int(staleFor*1000))ms")
              // Do NOT fake-seed lastSpeakerPartialAt here.
              self.seenPartialSinceOpen = false
              self.micWatchArmedAt = Date().addingTimeInterval(1.2)
              self.nativeSTT.startTranscribing(languageCode: self.myLanguage)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
              self.sttRestartInFlight = false
            }
          }
        }
      }
      t.resume()
      micHealthTimer = t
    }

    
    // MARK: – Peer chunking (speaker)
    private func handlePeerPartialChunk(_ snapshot: NativeSTTService.PartialSnapshot) {
      guard mode == .peer else { return }
        
        lastSpeakerPartialAt = snapshot.timestamp
        
        if !seenPartialSinceOpen { seenPartialSinceOpen = true }



      let full = snapshot.text
      translatedTextForMeToHear = full // live line on speaker device (optional)

      // keep a tiny history for stability checks
      peerLastPartialAt = snapshot.timestamp
      peerRecentPartials.append((text: full, at: snapshot.timestamp))
      if peerRecentPartials.count > 6 { peerRecentPartials.removeFirst(peerRecentPartials.count - 6) }

      // init a new "segment context" if needed
      if peerContext == nil {
        peerRecentPartials.removeAll()
        peerLastPartialAt = snapshot.timestamp

        var votes = LangVotes()
        votes.biasToward(base: String(myLanguage.prefix(2))) // speaker speaks myLanguage

        peerContext = TurnContext(
          rollingText: "",
          lockedSrcBase: String(myLanguage.prefix(2)).lowercased(),
          votes: votes,
          startedAt: snapshot.timestamp,
          lastGrowthAt: snapshot.timestamp,
          committed: false,
          flipUsed: true
        )

        // carry: skip repeated prefix at front of a brand-new OS segment
        if !peerCarryPrefix.isEmpty {
          peerCursor = commonPrefixCount(full, peerCarryPrefix)
        } else {
          peerCursor = 0
        }
      }

      guard var ctx = peerContext else { return }
      ctx.update(with: full, now: snapshot.timestamp)
      peerContext = ctx
        
    // ─── Idle‑nudge: if nothing changes for ~650ms, stream the current tail ───
    peerIdleNudgeWork?.cancel()
    let snapshotText   = full
    let snapshotCursor = peerCursor
    let work = DispatchWorkItem { [weak self] in
      Task { @MainActor in
        guard let self else { return }
        // no new growth?
        guard self.peerContext?.rollingText == snapshotText else { return }
        guard self.peerCursor == snapshotCursor else { return }

        // current tail
        let start = snapshotText.index(snapshotText.startIndex, offsetBy: snapshotCursor)
        let tail  = String(snapshotText[start...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard tail.count >= self.peerShortMinChars else { return }
        if self.looksLikeGlitch(tail) { return }

          // Guard open tails (e.g., “on / the / de”)
          if self.shouldHoldTail(tail, base: String(self.myLanguage.prefix(2)).lowercased(), langCode: self.myLanguage) {
            print("[PeerTx] IDLE-HOLD_OPEN_TAIL len=\(tail.count)")
          } else {
            // send as non-final; the later FINAL will reconcile coverage
            self.sendRawToPeers(tail, isFinal: false)
            self.peerCursor += tail.count
            print("[PeerTx] IDLE-NUDGE len=\(tail.count) cursor=\(self.peerCursor)")
          }
      }
    }
    peerIdleNudgeWork = work
    DispatchQueue.main.asyncAfter(deadline: .now() + peerIdleNudgeAfter, execute: work)


      if peerCursor > full.count { peerCursor = full.count }
      let tailStart = full.index(full.startIndex, offsetBy: peerCursor)
      let tail = String(full[tailStart...])

      let elapsed = snapshot.timestamp.timeIntervalSince(ctx.startedAt)
        
        print("[PeerTx] check elapsed=\(String(format:"%.2f", elapsed))s tailLen=\(tail.count) cursor=\(peerCursor)/\(full.count)")

        if elapsed >= peerChunkSeconds, !tail.isEmpty {
          let speakerBase = String(myLanguage.prefix(2)).lowercased()
          if let (chunk, consumed) = conventionBestChunk(fromTail: tail,
                                                         base: speakerBase,
                                                         langCode: myLanguage,
                                                         loose: true),
             !looksLikeGlitch(chunk) {
            // Hold if we cut on a connector/determiner/subordinator; give it one more beat.
            if shouldHoldTail(chunk, base: speakerBase, langCode: myLanguage) && elapsed < (peerChunkSeconds * 1.8) {
              print("[PeerTx] HOLD_OPEN_TAIL \"\(chunk.suffix(24))\"")
            } else {
              // ✅ ship RAW chunk to peers (not final)
              sendRawToPeers(chunk, isFinal: false)
              peerCursor += consumed
              print("[PeerTx] CHUNK len=\(chunk.count) cursor+=\(consumed) final=false")
              // reset interval window
              peerContext = TurnContext(
                rollingText: full,
                lockedSrcBase: String(myLanguage.prefix(2)).lowercased(),
                votes: LangVotes(),
                startedAt: Date(),
                lastGrowthAt: Date(),
                committed: false,
                flipUsed: true
              )
            }
          } else {
            print("[PeerTx] NO-CHUNK gate failed (structure) tailPreview=\"\(tail.prefix(40))…\"")
          }
        } else if elapsed >= peerChunkSeconds * 1.7, !tail.isEmpty {
        // fallback on word boundary near end
        if let cut = lastWordBoundary(in: tail, fromOffset: max(0, tail.count - 100)) {
          let candidate = String(tail[..<cut]).trimmingCharacters(in: .whitespacesAndNewlines)
          if candidate.count >= minPeerCommitChars {
            let cleaned = collapseImmediateRepeats(candidate)
            sendRawToPeers(cleaned, isFinal: false)
            peerCursor += candidate.count

            peerContext = TurnContext(
              rollingText: full,
              lockedSrcBase: String(myLanguage.prefix(2)).lowercased(),
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

    private func handlePeerStableBoundary(_ boundary: NativeSTTService.StableBoundary) {
      guard mode == .peer else { return }
        
      peerIdleNudgeWork?.cancel(); peerIdleNudgeWork = nil


      let full = boundary.text.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !full.isEmpty else { return }

      if peerCursor > full.count { peerCursor = full.count }
      let tailStart = full.index(full.startIndex, offsetBy: peerCursor)
      let tail = String(full[tailStart...])

      if !tail.isEmpty {
        let speakerBase = String(myLanguage.prefix(2)).lowercased()
        if let (chunk, consumed) = conventionBestChunk(fromTail: tail,
                                                       base: speakerBase,
                                                       langCode: myLanguage,
                                                       loose: false) {
            
          // Send the final chunk as final? We keep sending RAW **final** when the STT turn ends anyway.
          // Here we stream “stable” phrase as still-not-final so listeners keep flowing.
          sendRawToPeers(chunk, isFinal: false)
          peerCursor += consumed
        } else {
          // fallback: ship entire tail
          let cleaned = collapseImmediateRepeats(tail)
          sendRawToPeers(cleaned, isFinal: false)
          peerCursor = full.count
        }
      }

      // carry the full OS segment to skip if it repeats at next segment
      peerCarryPrefix = full
      if peerCarryPrefix.count > 500 { peerCarryPrefix = String(peerCarryPrefix.suffix(500)) }

      // clean up
      peerContext = nil
      peerRecentPartials.removeAll()
      peerLastPartialAt = .distantPast
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
            recentPartials.removeAll()
            lastPartialAt = snapshot.timestamp
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
            
            convFirstSpoken = false    // RESET for new speaker segment
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
                                                           loose: true), !looksLikeGlitch(chunk) {          // ← loose for mid-speech
                
                
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
            if isConventionHost {
              sendRawToPeers(chunk, isFinal: true)
            }
           print("[Convention] stable-commit consumed=\(consumed) newCursor=\(convCursor)")
         } else {
           // existing finalTail fallback stays as-is
           let cleaned = collapseImmediateRepeats(tail)
           commitConventionPhrase(reason: "finalTail", finalText: cleaned)
             if isConventionHost {
               sendRawToPeers(cleaned, isFinal: true)
             }
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
      recentPartials.removeAll()
      lastPartialAt = .distantPast
    }

    private func conventionBestChunk(fromTail tail: String,
                                     base: String,
                                     langCode: String,
                                     loose: Bool) -> (String, Int)? {
      let raw = tail.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !raw.isEmpty else { return nil }

        func ok(_ s: String) -> Bool {
          let passStructure = isStructurallyComplete(s, base: base, langCode: langCode, minChars: minConventionCommitChars)
          if loose { return passStructure }
          // stable/final: structure + (stability OR not-suspicious)
          let stable = tailLooksStable(s, now: lastPartialAt)
          let weird  = rareTailLooksSuspicious(s)
          return passStructure && (stable || !weird)
        }

        // 1) Prefer a sentence boundary (smart)
        if let cut = lastSentenceBoundarySmart(in: raw, fromOffset: 0) {
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
    
    
    /// Light guard: if the tail ends on a connector/determiner/subordinator, hold a beat.
    private func endsWithDeterminer(_ s: String, base: String) -> Bool {
      let t = tokens(s)
      guard let last = t.last else { return false }
      switch String(base.prefix(2)).lowercased() {
      case "es": return ["el","la","los","las","un","una","unos","unas","lo","al","del","este","esta","ese","esa"].contains(last)
      default:   return ["the","a","an","this","that","these","those"].contains(last)
      }
    }

    /// True if we should wait a bit longer before committing this tail.
    private func shouldHoldTail(_ s: String, base: String, langCode: String) -> Bool {
      return endsWithConnector(s, base: base)
          || endsWithDeterminer(s, base: base)
          || subordinatorOpensClause(s, base: base) && !hasVerb(s, languageCode: langCode)
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
    
    func appendToAccum(_ tid: UUID?, spoken: String) {
      guard let tid = tid, !spoken.isEmpty else { return }
      let prev = rxDstAccum[tid] ?? ""
      rxDstAccum[tid] = prev.isEmpty ? spoken : (prev + " " + spoken)
    }


    private func commitConventionPhrase(reason: String, finalText: String) {
      // DROP_TINY: skip micro-utterances during mid-speech; allow at final tail.
        if looksLikeGlitch(finalText) && reason != "finalTail" { return }

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
        var txClean = tx.trimmingCharacters(in: .whitespacesAndNewlines)
          
          let isFirst = !convFirstSpoken
          if !shouldEmitSentence(txClean, dst: dst, isFirstPiece: isFirst) {
            // Hold until we see a sentence boundary or enough material
            return
          }

          // High-overlap guard with the last enqueued/speaking item
          if let last = phraseQueue.last,
             let lastText = phraseTranslations[last.id],
             last.dstFull == dst,
             highlySimilar(lastText, txClean) {
            print("[Convention] DROP_DUP/HIGH_OVERLAP len=\(txClean.count)")
            return
          }
          
        if isGarbageTranslation(txClean) { txClean = cleaned } // speak source if MT hiccups


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

            // 🔒 Near-duplicate guard: recent actual speech only (not live partials)
             if activeTTSDestination == dst,
                Date().timeIntervalSince(lastSpokenAt) < nearDupWindow,
                isNearDuplicate(txClean, lastSpokenText) {
               logBreadcrumb("DROP_NEAR_DUP(\(txClean.count))")
               return
             }

            // If somehow already speaking this exact id, don’t re-queue
            if let cur = currentSpeakingID, cur == commit.id { return }

            if mode == .convention && isConventionHost {
              // Send RAW chunk (speaker language) to listeners; they translate to their own language
              sendRawToPeers(cleaned, isFinal: false)
            }
            
            phraseQueue.append(commit)
            convFirstSpoken = true
            
            // We never barge current TTS in peer mode; just ensure the next item
            // doesn't slam in with 0ms gap if it was enqueued while speaking.
            if ttsService.isSpeaking {
              queueBargeDeadline = max(queueBargeDeadline, Date().addingTimeInterval(0.22))
            }
          phraseTranslations[commit.id] = txClean
            
            
          queueBargeDeadline = Date().addingTimeInterval(phraseInterGapMax)

//          if phraseQueue.count >= 3 && ttsService.isSpeaking {
//            let ran = (ttsStartedAt != nil) ? Date().timeIntervalSince(ttsStartedAt!) : 0
//            if ran >= 0.7 { ttsService.stopAtBoundary() }
//          }
          drainPhraseQueue()
        }
      }
    }

    private func looksWeirdSingleWord(_ s: String) -> Bool {
      // One long token, no terminal punctuation → likely a bad fragment for TTS
      let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
      if t.isEmpty { return true }
      let tokens = t.split { !$0.isLetter && !$0.isNumber }
      if tokens.count == 1 && t.count >= 16 && (t.last.map { ".?!…".contains($0) } != true) {
        return true
      }
      return false
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
          case .peer:        self.handlePeerStableBoundary(boundary)
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
        // We never barge current TTS in peer mode; just ensure the next item
        // doesn't slam in with 0ms gap if it was enqueued while speaking.
        if ttsService.isSpeaking {
          queueBargeDeadline = max(queueBargeDeadline, Date().addingTimeInterval(0.22))
        }
      queueBargeDeadline = Date().addingTimeInterval(phraseInterGapMax)
      lastCommitAt = now
      logBreadcrumb("PHRASE_COMMIT(\(trimmed.count))")
      logBreadcrumb("LANG_DECIDE(\(srcFull),\(String(format: "%.2f", confidence)))")
      logBreadcrumb("QUEUE_DEPTH(\(phraseQueue.count))")
      isProcessing = false

//        if phraseQueue.count >= 3 && ttsService.isSpeaking {
//          let ran = (ttsStartedAt != nil) ? Date().timeIntervalSince(ttsStartedAt!) : 0
//          if ran >= 0.7 { ttsService.stopAtBoundary() }
//        }

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
    
    /// True if `s` looks like an actual clause in the target language.
    /// For Spanish we also allow common imperative/aux openings.
    private func looksSentenceLike(_ s: String, languageCode: String) -> Bool {
      let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else { return false }
      if hasVerb(trimmed, languageCode: languageCode) { return true }

      let low = trimmed.lowercased()
      let base = String(languageCode.prefix(2)).lowercased()
      if base == "es" {
        // common imperative/aux openings that imply a verb even without tagging
        return low.hasPrefix("ve ")          // imperative: go
            || low.hasPrefix("puedes ")      // can you
            || low.hasPrefix("¿puedes ")     // question form
            || low.hasPrefix("necesito ")    // I need
            || low.hasPrefix("tengo que ")   // I have to
            || low.hasPrefix("debo ")        // I must
            || low.hasPrefix("quiero ")      // I want
      }
      return false
    }


    // TranslationViewModel.swift
    private func drainPhraseQueue() {
        // 🔧 Conservative self-heal: only reset if we've been waiting long enough for TTS to start.
        // Otherwise, avoid thrashing by returning early.
        if queueDraining && !ttsService.isSpeaking {
          if let started = ttsStartedAt, Date().timeIntervalSince(started) > 0.6 {
            queueDraining = false
            activeCommitID = nil
            currentSpeakingID = nil
            ttsStartedAt = nil
          } else {
            // We just scheduled TTS; don't schedule again.
            return
          }
        }


        guard !queueDraining && !ttsService.isSpeaking else { return }
      guard let next = phraseQueue.first,
        let translation = phraseTranslations[next.id] else { return }

      queueDraining = true
      activeCommitID = next.id
      currentSpeakingID = next.id
      activeTTSDestination = next.dstFull
      translatedTextForMeToHear = translation
      resumeAfterTTSTask?.cancel(); resumeAfterTTSTask = nil
      hasFloor = true
      lastSpokenText = translation
      lastSpokenAt   = Date()

      if let idx = debugItems.firstIndex(where: { $0.id == next.id }) {
        debugItems[idx].state = .speaking
      }

      ttsStartedAt = Date()

        print("[TTS] about-to-speak len=\(translation.count) dst=\(next.dstFull) id=\(next.id)")
        print("[Route] current=\(AVAudioSession.sharedInstance().currentRoute)")

      // Small async tick helps avoid "mDataByteSize (0)" right after route changes.
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in  // was 0.01
          guard let self else { return }
//          print("[TTS] speak len=\(translation.count) dst=\(next.dstFull) id=\(next.id)")
          print("[TTS] SAY dst=\(next.dstFull) \"\(translation.prefix(120))…\"")
          self.ttsService.speak(
            text: translation,
            languageCode: next.dstFull,
            voiceIdentifier: self.voice_for_lang[next.dstFull]
          )
        }

    }

    private func handleTTSStarted() {
      hasFloor = true
        print("[Floor] held by local TTS; queueDepth=\(phraseQueue.count)")
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
        print("[Floor] released by local TTS; queueDepth(after) \(phraseQueue.count)")

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
        // Show “Stop” if *either* capture path is open
        return nativeSTT.isListening || sttService.isListening
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
              print("[Capture] pause online paths (Azure/Auto). Native stays running.")

            // Snapshot intent to resume only for Azure path
              wasListeningPrePlayback =
                sttService.isListening || autoService.isListening || nativeSTT.isListening

            // Pause only online capture paths; keep native STT running.
            if (sttService as! AzureSpeechTranslationService).isListening {
              (sttService as! AzureSpeechTranslationService).stop()
            }
            if autoService.isListening {
              autoService.stop()
            }
            // nativeSTT: do NOT stop; we want continuous capture per Audio Rules

          } else {
              print("[Capture] resume guard wasListening=\(wasListeningPrePlayback)")

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
            var tx = try await UnifiedTranslateService.translate(text, from: myLanguage, to: peerLanguage)
            if isGarbageTranslation(tx) { tx = text }
            await MainActor.run {
            replaceLocalTurn(id: pendingId, with: LocalTurn(
              id: pendingId,
              sourceLang: myLanguage,
              sourceText: text,
              targetLang: peerLanguage,
              translatedText: tx,
              timestamp: now
            ))
                print("[Route] s current=\(AVAudioSession.sharedInstance().currentRoute)")

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
              
              print("[Route]3 current=\(AVAudioSession.sharedInstance().currentRoute)")

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
            var tx = try await UnifiedTranslateService.translate(text, from: myLanguage, to: peerLanguage)
            if isGarbageTranslation(tx) { tx = text }
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
//        sendTextToPeer(text, isFinal: isFinal, reliable: isFinal)
          print("[Emit] mode=\(mode) isFinal=\(isFinal) len=\(text.count) earlySentPrefix=\(earlyTTSSentPrefix)")

          break

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
          
          // We never barge current TTS in peer mode; just ensure the next item
          // doesn't slam in with 0ms gap if it was enqueued while speaking.
          if ttsService.isSpeaking {
            queueBargeDeadline = max(queueBargeDeadline, Date().addingTimeInterval(0.22))
          }
        phraseTranslations[commit.id] = text
          
          
        debugItems.append(DebugQ(id: commit.id, text: text, state: .queued, timestamp: Date()))

        queueBargeDeadline = Date().addingTimeInterval(phraseInterGapMax)
//          if phraseQueue.count >= 3 && ttsService.isSpeaking {
//            let ran = (ttsStartedAt != nil) ? Date().timeIntervalSince(ttsStartedAt!) : 0
//            if ran >= 0.7 { ttsService.stopAtBoundary() }
//          }
        drainPhraseQueue()

      case .onePhone:
          print("[Route] 4current=\(AVAudioSession.sharedInstance().currentRoute)")

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
    
//    private func sendTextToPeer(_ text: String, isFinal: Bool, reliable: Bool) {
//      guard !text.isEmpty else { return }
//
//      // The payload we send in Peer mode is already translated for the peer,
//      // so the language of *this* text is peerLanguage, not myLanguage.
//      let payloadLang = (mode == .peer) ? peerLanguage : myLanguage
//
//      let msg = MessageData(
//        id: UUID(),
//        originalText:       text,
//        sourceLanguageCode: payloadLang,   // ✅ label with the language of the text we’re sending
//        targetLanguageCode: nil,
//        isFinal:            isFinal,
//        timestamp:          Date().timeIntervalSince1970
//      )
//
//      if multipeerSession.connectedPeers.isEmpty {
//        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
//          self?.multipeerSession.send(message: msg, reliable: reliable)
//        }
//      } else {
//        multipeerSession.send(message: msg, reliable: reliable)
//      }
//    }
    
    private func sendRawToPeers(_ text: String, isFinal: Bool) {
      guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
      let msg = MessageData(
        id: UUID(),
        turnId: turnId,
        seq: seqCounter,
        originalText: text,
        sourceLanguageCode: (mode == .peer ? myLanguage : peerLanguage), // Peer: I speak; Convention host: speaker lang
        isFinal: isFinal,
        timestamp: Date().timeIntervalSince1970,
        mode: mode.rawValue.lowercased()
      )
      seqCounter += 1
      multipeerSession.send(message: msg, reliable: isFinal)
      if isFinal { turnId = UUID(); seqCounter = 0 }
    }

    // Re-order window for turnId/seq delivery (≤500 ms)
    // Re-order window for turnId/seq delivery (≤500 ms), robust to late-attach
    private func deliverSequenced(_ turnId: UUID, _ seq: Int, _ m: MessageData) {
      // Buffer shape: expect — next contiguous seq we want to deliver
      if rxBuffers[turnId] == nil {
        rxBuffers[turnId] = (expect: seq, stash: [:], timer: nil)   // 👈 start at first we see
        print("[Seq] NEW turn=\(turnId.uuidString.prefix(8)) expect=\(seq)")
      }
      var buf = rxBuffers[turnId]!
      buf.stash[seq] = m
      print("[Seq] STASH turn=\(turnId.uuidString.prefix(8)) seq=\(seq) expect=\(buf.expect) size=\(buf.stash.count)")

      // If 'expect' isn't present in stash, slide 'expect' down to the current minimum so we can begin flushing.
      if buf.stash[buf.expect] == nil, let minSeq = buf.stash.keys.min() {
        if minSeq != buf.expect {
          print("[Seq] ADJUST expect \(buf.expect)→\(minSeq)")
          buf.expect = minSeq
        }
      }
        
        if let tid = m.turnId, rxTurnState[tid] == nil {
          let now = Date()
          rxTurnState[tid] = RxTurnState(
            startedAt: now,
            warmupDeadline: now.addingTimeInterval(1.2) // WARMUP
          )
        }


      // Try to flush as much as we can contiguously
      var delivered = 0
      while let next = buf.stash[buf.expect] {
        buf.stash.removeValue(forKey: buf.expect)
        let toDeliver = next
        buf.expect += 1
        delivered += 1
        Task { [weak self] in self?.deliverMessage(toDeliver) }
      }
      if delivered > 0 {
        print("[Seq] FLUSH turn=\(turnId.uuidString.prefix(8)) delivered=\(delivered) nextExpect=\(buf.expect) remaining=\(buf.stash.count)")
      }

      // Arm/refresh a short timer to flush any gaps; also do a best-effort fallback later.
      buf.timer?.cancel()
      let work = DispatchWorkItem { [weak self] in
        guard let self else { return }
        var b = self.rxBuffers[turnId]!

        // Try normal contiguous flush again
        var delivered2 = 0
        while let _ = b.stash[b.expect] {
          if let next = b.stash[b.expect] {
            b.stash.removeValue(forKey: b.expect)
            b.expect += 1
            delivered2 += 1
            Task { [weak self] in self?.deliverMessage(next) }
          }
        }
        if delivered2 > 0 {
          print("[Seq] TIMER-FLUSH turn=\(turnId.uuidString.prefix(8)) delivered=\(delivered2) nextExpect=\(b.expect) remaining=\(b.stash.count)")
        }

        // 🔧 SAFETY: if still blocked (e.g., we only ever got seq=5), deliver the lowest one we have.
        if !b.stash.isEmpty, b.stash[b.expect] == nil {
          if let minSeq = b.stash.keys.min(), let next = b.stash[minSeq] {
            b.stash.removeValue(forKey: minSeq)
            b.expect = minSeq + 1
            print("[Seq] TIMER-FALLBACK turn=\(turnId.uuidString.prefix(8)) forced seq=\(minSeq) nextExpect=\(b.expect) remaining=\(b.stash.count)")
            Task { [weak self] in self?.deliverMessage(next) }
          }
        }

        // Drop empty buffers
        if b.stash.isEmpty {
          self.rxBuffers.removeValue(forKey: turnId)
        } else {
          self.rxBuffers[turnId] = b
        }
      }
      buf.timer = work
      rxBuffers[turnId] = buf
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func dumpQueue(prefix: String) {
      #if DEBUG
      let items = phraseQueue.map { q in
        let txt = (phraseTranslations[q.id] ?? q.raw)
        let head = txt.prefix(40).replacingOccurrences(of: "\n", with: " ")
        return "• \(q.id.uuidString.prefix(8)) [\(txt.count)] \"\(head)…\""
      }
      print("[Queue] \(prefix) depth=\(phraseQueue.count)")
      items.forEach { print("[Queue] \($0)") }
      #endif
    }

    func coalesceAccum(_ tid: UUID?, oldTail: String, newTail: String) {
      guard let tid = tid else { return }
      guard var acc = rxDstAccum[tid], acc.hasSuffix(oldTail) else { return }
      acc.removeLast(oldTail.count)
      rxDstAccum[tid] = acc + newTail
    }
    
    private func highlySimilar(_ a: String, _ b: String) -> Bool {
      let na = normalizedKey(a)
      let nb = normalizedKey(b)
      if na == nb { return true }
      let ta = Set(na.split { !$0.isLetter && !$0.isNumber })
      let tb = Set(nb.split { !$0.isLetter && !$0.isNumber })
      if ta.isEmpty || tb.isEmpty { return false }
      let inter = Double(ta.intersection(tb).count)
      let union = Double(ta.union(tb).count)
      return union > 0 && (inter / union) >= 0.85
    }

    
    /// Enqueue only the text that was added by coalescing while the previous commit is already speaking.
    private func enqueueDeltaAfterCoalesce(
      dst: String,
      oldSpoken: String,
      merged: String,
      srcFull: String
    ) {
      guard merged.count > oldSpoken.count else { return }
      let start = merged.index(merged.startIndex, offsetBy: oldSpoken.count)
      var delta = String(merged[start...]).trimmingCharacters(in: .whitespacesAndNewlines)
        
      guard !delta.isEmpty else { return }

        let hasTerminal = delta.last.map { ".?!…".contains($0) } == true
        let bigEnough   = delta.count >= 24 || delta.split { !$0.isLetter }.count >= 4
        guard hasTerminal || bigEnough else { return }

      let commit = PhraseCommit(
        srcFull: srcFull,
        dstFull: dst,
        raw: delta,
        committedAt: Date().timeIntervalSince1970,
        decidedAt:   Date().timeIntervalSince1970,
        confidence:  1.0
      )

      // Don’t mark as duplicate against the previous sentence – this is explicitly its continuation
      phraseQueue.append(commit)
      phraseTranslations[commit.id] = delta
        
        // NEW: mirror the continuation in the UI immediately
        translatedTextForMeToHear = delta

      // Ensure the follow-up plays quickly after the current item
      queueBargeDeadline = Date().addingTimeInterval(phraseInterGapMax)
      print("[PeerRx] DELTA enqueue dst=\(dst) deltaLen=\(delta.count)")

      drainPhraseQueue()
    }

    
    /// If no new pieces arrive for `idleFlushAfter`, speak the uncovered tail.
    @MainActor
    private func scheduleIdleFlush(
      for tid: UUID,
      rawOsRaw: String,
      srcFull: String,
      dstFull: String
    ) {
      // Only flush if nothing new has arrived since our idle timer armed.
      let last = self.rxLastRecvAt[tid] ?? .distantPast
      let idle = Date().timeIntervalSince(last) >= self.idleFlushAfter
      guard idle, !self.ttsService.isSpeaking, !self.queueDraining else { return }

      // Uncovered tail from the last covered pointer.
      let covered = self.rxCoveredCount[tid] ?? 0
      guard rawOsRaw.count > covered else { return }
      let startIdx = rawOsRaw.index(rawOsRaw.startIndex, offsetBy: covered)
      var tailRaw = String(rawOsRaw[startIdx...]).trimmingCharacters(in: .whitespacesAndNewlines)
      guard !tailRaw.isEmpty else { return }

      // Prefer a sentence boundary; else a conservative late word boundary.
        if let cut = lastSentenceBoundarySmart(in: tailRaw, fromOffset: 0) {
        tailRaw = String(tailRaw[..<cut]).trimmingCharacters(in: .whitespacesAndNewlines)
      } else if let cutW = self.lastWordBoundary(in: tailRaw,
                                                 fromOffset: max(0, tailRaw.count - 80)) {
        let c = String(tailRaw[..<cutW]).trimmingCharacters(in: .whitespacesAndNewlines)
        if c.count >= self.idleMinChars { tailRaw = c }
      }
      guard !tailRaw.isEmpty else { return }

      // Helper: guard target language (runs on main actor)
      @MainActor
      func guardTargetLanguage(_ text: String, dstFull: String) -> String? {
        let base = String(dstFull.prefix(2)).lowercased()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let score = self.purity(of: trimmed, expectedTargetBase: base)
        if score >= 0.08 { return trimmed }                // relaxed
        if base == "es", trimmed.count >= 10 { return trimmed } // Spanish allowance
        if trimmed.unicodeScalars.contains(where: { $0.value >= 0x00C0 }) { return trimmed }
        return nil
      }

      // Helper: light Spanish cleanup for speech
      @MainActor
      func polishSpanishIfNeeded(_ s: String, dst: String) -> String {
        guard String(dst.prefix(2)).lowercased() == "es" else { return s }
        var t = s
        // drop stray single-letter uppercase + space at start ("D " etc.)
        t = t.replacingOccurrences(of: #"^[A-ZÁÉÍÓÚÑ]\s+"#, with: "", options: .regularExpression)
        // fix frequent “Revolver para …” artifact
        t = t.replacingOccurrences(of: #"^Revolver para "#, with: "Para ", options: .regularExpression)
        // small generic tweak (e.g., “de la”/“del la” → “de la”; “de la la” → “de la”)
        t = t.replacingOccurrences(of: #"\b(de\s+la|del\s+la)\b"#, with: "de la", options: .regularExpression)
        return t
      }

        // MT only what we intend to speak (translate just the chosen tail).
        Task { @MainActor in
          let chunkTx = (try? await UnifiedTranslateService.translate(
            tailRaw, from: srcFull, to: dstFull
          )) ?? tailRaw

          guard let cleaned0 = guardTargetLanguage(chunkTx, dstFull: dstFull) else { return }
          let cleaned = polishSpanishIfNeeded(cleaned0, dst: dstFull)

          let enough = cleaned.count >= self.idleMinChars
                    || (cleaned.last.map { ".?!…".contains($0) } ?? false)
          guard enough else { return }

          // First piece must be a real sentence
          let isFirstPiece = (self.rxCoveredCount[tid] ?? 0) == 0
          if isFirstPiece {
            guard self.shouldEmitSentence(cleaned, dst: dstFull, isFirstPiece: true) else { return }
            let tokenCount = cleaned.split { !$0.isLetter && !$0.isNumber }.count
            let longEnough = cleaned.count >= 28 || tokenCount >= 5
            let terminal   = cleaned.last.map { ".?!…".contains($0) } ?? false
            if !(terminal || longEnough) {
              print("[PeerRx] FIRST_PIECE_HOLD len=\(cleaned.count) tokens=\(tokenCount)")
              return
            }
          }

          // 🔸 Speak only the *new* delta for this turn
          var speak = trimAlreadySpokenPrefix(tid: tid, candidate: cleaned)
          speak = speak.trimmingCharacters(in: .whitespacesAndNewlines)
          guard !speak.isEmpty else { return }
          guard !self.looksWeirdSingleWord(speak), self.allowSpeakAndMark(speak) else { return }

          // Enqueue & advance coverage.
          let now = Date()

          self.translatedTextForMeToHear = speak
          let newCovered = (self.rxCoveredCount[tid] ?? 0) + tailRaw.count
          let rawNow = String(rawOsRaw.prefix(newCovered)).trimmingCharacters(in: .whitespacesAndNewlines)
          self.peerSaidText = self.cleanForPresentation(rawNow)

          let commit = PhraseCommit(
            srcFull:   srcFull,
            dstFull:   dstFull,
            raw:       speak,
            committedAt: now.timeIntervalSince1970,
            decidedAt:   now.timeIntervalSince1970,
            confidence:  1.0
          )

          self.phraseQueue.append(commit)
          self.phraseTranslations[commit.id] = speak
          self.rxCoveredCount[tid] = (self.rxCoveredCount[tid] ?? 0) + tailRaw.count
          self.rxLastChunkAt[tid]  = now
          self.appendToAccum(tid, spoken: speak)
          self.queueBargeDeadline = Date().addingTimeInterval(self.phraseInterGapMax)

          print("[PeerRx] IDLE-FLUSH enqueue dst=\(dstFull) len=\(speak.count)")
          self.drainPhraseQueue()
        }

    }


    

    @MainActor
    private func deliverMessage(_ m: MessageData) {
        Task { @MainActor in
            print("[Rx] ENTER deliverMessage final=\(m.isFinal) turn=\(m.turnId?.uuidString.prefix(8) ?? "--") seq=\(m.seq ?? -1) len=\(m.originalText.count)")
            
            let minSpokenTailChars = 16
            let sentenceMarks: Set<Character> = [".","!","?","…","。","！","？"]
            
            // ───────── Local helpers (MainActor) ─────────
            @MainActor
            func guardTargetLanguage(_ text: String, dstFull: String) -> String? {
                let base = String(dstFull.prefix(2)).lowercased()
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return nil }
                let score = self.purity(of: trimmed, expectedTargetBase: base)
                if score >= 0.08 { return trimmed }                          // relaxed threshold
                if base == "es", trimmed.count >= 10 { return trimmed }       // Spanish allowance
                if trimmed.unicodeScalars.contains(where: { $0.value >= 0x00C0 }) { return trimmed }
                return nil
            }
            
            @MainActor
            func longEnoughOrTerminal(_ s: String) -> Bool {
                let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
                if t.count >= minSpokenTailChars { return true }
                if let last = t.last, sentenceMarks.contains(last) { return true }
                // short, meaningful replies
                let tokens = t.split { !$0.isLetter && !$0.isNumber }
                if t.count >= 3 && tokens.count <= 3 { return true }
                if ["ok","sí","si","no"].contains(t.lowercased()) { return true }
                return false
            }
            
            // Prefer **true sentence boundaries** over commas using NLTokenizer.
            // Falls back to punctuation-based cut if NL isn’t available.
            @MainActor
            func lastSentenceBoundarySmart(in s: String, fromOffset off: Int) -> String.Index? {
                if let punctCut = self.lastSentenceBoundary(in: s, fromOffset: off) { return punctCut }
                if #available(iOS 12.0, *) {
                    let tok = NLTokenizer(unit: .sentence); tok.string = s
                    var bestEnd: Int? = nil
                    tok.enumerateTokens(in: s.startIndex..<s.endIndex) { range, _ in
                        let end = range.upperBound.utf16Offset(in: s)
                        if end > off { bestEnd = end }
                        return true
                    }
                    if let end = bestEnd {
                        return s.index(s.startIndex, offsetBy: end)
                    }
                }
                return nil
            }
            
            // Gatekeeper: only speak when it *looks like a sentence* or ends with terminal punctuation.
            @MainActor
            func shouldEmitSentence(_ cleaned: String, dst: String, isFirstPiece: Bool) -> Bool {
                let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return false }
                let terminal = trimmed.last.map { sentenceMarks.contains($0) } ?? false
                if terminal { return true }
                
                let tokenCount = trimmed.split { !$0.isLetter && !$0.isNumber }.count
                // rely on our existing verb/structure heuristic
                if looksSentenceLike(trimmed, languageCode: dst) {
                    // Keep first audio chunk crisp: require a bit more body
                    if isFirstPiece { return tokenCount >= 5 || trimmed.count >= 28 }
                    return tokenCount >= 4 || trimmed.count >= 22
                }
                
                // If it doesn't look sentence-like, be conservative, especially for the *first* chunk.
                if isFirstPiece { return false }
                return trimmed.count >= 32 || tokenCount >= 7
            }
            
            @MainActor
            func tryCoalesceWithLast(_ cleaned: String, dst: String) -> Bool {
                guard var last = phraseQueue.last,
                      last.dstFull == dst,
                      let lastText = phraseTranslations[last.id] else { return false }
                
                let a = lastText, b = cleaned
                let common = commonPrefixCount(a, b)
                let thresh = Int(Double(max(a.count, b.count)) * 0.8)
                if common >= thresh || a.hasPrefix(b) || b.hasPrefix(a) {
                    let merged = (a.count >= b.count) ? a : b
                    phraseTranslations[last.id] = merged
                    translatedTextForMeToHear = merged
                    print("[PeerRx] COALESCE dst=\(dst) old=\(a.count) new=\(b.count) -> \(merged.count)")
                    
                    if let active = activeCommitID, active == last.id, ttsService.isSpeaking, merged.count > a.count {
                        enqueueDeltaAfterCoalesce(dst: dst, oldSpoken: a, merged: merged, srcFull: last.srcFull)
                    }
                    return true
                }
                return false
            }
            
            // Spanish polish applied to *spoken* text
            @MainActor
            func polishSpanishIfNeeded(_ s: String, dst: String) -> String {
                guard String(dst.prefix(2)).lowercased() == "es" else { return s }
                var t = s
                t = t.replacingOccurrences(of: #"^[A-ZÁÉÍÓÚÑ]\s+"#, with: "", options: .regularExpression)
                t = t.replacingOccurrences(of: #"^Revolver para "#, with: "Para ", options: .regularExpression)
                return t
            }
            
            // Prevent single weird tokens like “Dietilestilbestrol…”
            @MainActor
            func looksWeirdSingleWord(_ s: String) -> Bool {
                let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
                if t.isEmpty { return true }
                let tokens = t.split { !$0.isLetter && !$0.isNumber }
                if tokens.count == 1 && t.count >= 16 && (t.last.map { sentenceMarks.contains($0) } != true) {
                    return true
                }
                return false
            }
            
            // Simple high-similarity check to avoid “say the full final twice”
            @MainActor
            func highlySimilar(_ a: String, _ b: String) -> Bool {
                let ta = a.lowercased().split { !$0.isLetter && !$0.isNumber }
                let tb = b.lowercased().split { !$0.isLetter && !$0.isNumber }
                guard !ta.isEmpty, !tb.isEmpty else { return false }
                let sa = Set(ta), sb = Set(tb)
                let j = Double(sa.intersection(sb).count) / Double(sa.union(sb).count)
                return j >= 0.85 || a.hasPrefix(b) || b.hasPrefix(a)
            }
            
            // ───────── PARTIALS → UI + (maybe) enqueue *tail* chunk ─────────
            if !m.isFinal {
                let myFull   = self.myLanguage
                let peerFull = self.peerLanguage
                let myBase   = String(myFull.prefix(2)).lowercased()
                let peerBase = String(peerFull.prefix(2)).lowercased()
                let fallbackOther = (myBase == "en") ? "es-US" : "en-US"
                
                let raw = m.originalText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !raw.isEmpty else { return }
                
                if let tid = m.turnId {
                    rxLastRecvAt[tid] = Date()
                    rxIdleTimers[tid]?.cancel()
                    let work = DispatchWorkItem { [weak self] in
                        guard let self else { return }
                        Task { @MainActor in
                            self.scheduleIdleFlush(
                                for: tid,
                                rawOsRaw: raw,
                                srcFull: m.sourceLanguageCode,
                                dstFull: myFull
                            )
                        }
                    }
                    rxIdleTimers[tid] = work
                    DispatchQueue.main.asyncAfter(deadline: .now() + idleFlushAfter, execute: work)
                }
                
                self.rxPartialMTTask?.cancel()
                if raw.count >= 6 {
                    var srcCandidate = m.sourceLanguageCode
                    if String(srcCandidate.prefix(2)).lowercased() == myBase {
                        srcCandidate = (peerBase != myBase) ? peerFull : fallbackOther
                    }
                    if String(srcCandidate.prefix(2)).lowercased() == myBase {
                        srcCandidate = (peerBase != myBase) ? peerFull : fallbackOther
                    }
                    let srcFinal = srcCandidate
                    let dst      = myFull
                    
                    self.rxDraftEpoch &+= 1
                    let epoch = self.rxDraftEpoch
                    
                    self.rxPartialMTTask = Task { [weak self] in
                        guard let self else { return }
                        guard !Task.isCancelled, epoch == self.rxDraftEpoch else { return }
                        
                        // 1) Live draft translate for UI
                        let draft = (try? await UnifiedTranslateService.translate(raw, from: srcFinal, to: dst)) ?? ""
                        guard !Task.isCancelled, epoch == self.rxDraftEpoch else { return }
                        await MainActor.run {
                            guard epoch == self.rxDraftEpoch else { return }
                            self.translatedTextForMeToHear = draft.isEmpty ? raw : draft
                            self.peerSaidText = self.cleanForPresentation(raw)
                            print("[Rx] DRAFT_IDLE isSpeaking=\(self.ttsService.isSpeaking) draining=\(self.queueDraining) qDepth=\(self.phraseQueue.count)")
                        }
                        
                        // ─── NUDGE: conservative tail (prefer sentence boundary) ───
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.30) { [weak self] in
                            Task { @MainActor in
                                guard let self else { return }
                                guard !self.ttsService.isSpeaking, !self.queueDraining else { return }
                                guard let tid = m.turnId else { return }
                                
                                let rawTrim = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                                var covered = self.rxCoveredCount[tid] ?? 0
                                covered = min(covered, rawTrim.count)
                                guard rawTrim.count > covered + 10 else { return }
                                
                                let startIdx = rawTrim.index(rawTrim.startIndex, offsetBy: covered)
                                var tailRaw = String(rawTrim[startIdx...]).trimmingCharacters(in: .whitespacesAndNewlines)
                                guard !tailRaw.isEmpty else { return }
                                print("[PeerRx] NUDGE tailRawLen=\(tailRaw.count) covered=\(covered) rawLeft=\(rawTrim.count - covered)")
                                
                                if let cut = lastSentenceBoundarySmart(in: rawTrim, fromOffset: covered) {
                                    tailRaw = String(rawTrim[startIdx..<cut]).trimmingCharacters(in: .whitespacesAndNewlines)
                                } else if let cutW = self.lastWordBoundary(in: tailRaw, fromOffset: max(0, tailRaw.count - 80)) {
                                    let c = String(tailRaw[..<cutW]).trimmingCharacters(in: .whitespacesAndNewlines)
                                    if c.count >= 12 { tailRaw = c }
                                }
                                guard !tailRaw.isEmpty else { return }
                                
                                let dst = self.myLanguage
                                let chunkTx = (try? await UnifiedTranslateService.translate(tailRaw,
                                                                                            from: m.sourceLanguageCode,
                                                                                            to:   dst)) ?? tailRaw
                                guard let cleanedMaybe = guardTargetLanguage(chunkTx, dstFull: dst) else {
                                    // try to absorb into last if purity fails
                                    _ = tryCoalesceWithLast(chunkTx, dst: dst)
                                    return
                                }
                                let cleaned = cleanedMaybe
                                
                                let isFirstPiece = (self.rxCoveredCount[tid] ?? 0) == 0
                                guard shouldEmitSentence(cleaned, dst: dst, isFirstPiece: isFirstPiece) else { return }
                                guard !looksWeirdSingleWord(cleaned), self.allowSpeakAndMark(cleaned) else { return }
                                
                                let now = Date()
                                let speakText = polishSpanishIfNeeded(cleaned, dst: dst)
                                let commit = PhraseCommit(
                                    srcFull: m.sourceLanguageCode, dstFull: dst, raw: speakText,
                                    committedAt: now.timeIntervalSince1970, decidedAt: now.timeIntervalSince1970, confidence: 1.0
                                )
                                self.phraseQueue.append(commit)
                                self.phraseTranslations[commit.id] = speakText
                                self.appendToAccum(tid, spoken: speakText)
                                self.rxCoveredCount[tid] = min(covered + tailRaw.count, rawTrim.count)
                                self.rxLastChunkAt[tid]  = now
                                self.queueBargeDeadline  = Date().addingTimeInterval(self.phraseInterGapMax)
                                
                                // NEW: keep UI in sync with what will be spoken
                                self.translatedTextForMeToHear = speakText
                                if let tid = m.turnId {
                                    let newCovered = self.rxCoveredCount[tid] ?? 0
                                    let rawNow = String(rawTrim.prefix(newCovered)).trimmingCharacters(in: .whitespacesAndNewlines)
                                    self.peerSaidText = self.cleanForPresentation(rawNow)
                                }
                                
                                print("[PeerRx] NUDGE enqueue dst=\(dst) len=\(speakText.count)")
                                self.drainPhraseQueue()
                            }
                        }
                        
                        // 2) Stream a *completed* chunk from the NEW “fresh piece” only
                        guard let tid = m.turnId else { return }
                        let rawTrim = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                        
                        let coveredTotal0 = self.rxCoveredCount[tid] ?? 0
                        let coveredTotal  = min(coveredTotal0, rawTrim.count)
                        print("[PeerRx] SEQ \(m.seq ?? -1) freshPiece chunkLen=\(rawTrim.count) coveredTotal=\(coveredTotal)")
                        guard !rawTrim.isEmpty else { return }
                        
                        let now     = Date()
                        let lastAt  = self.rxLastChunkAt[tid] ?? .distantPast
                        let heldFor = now.timeIntervalSince(lastAt)
                        
                        // 1) choose a candidate – NO coverage changes yet
                        var candidateRaw: String? = nil
                        if let cut = lastSentenceBoundarySmart(in: rawTrim, fromOffset: 0) {
                            candidateRaw = String(rawTrim[..<cut]).trimmingCharacters(in: .whitespacesAndNewlines)
                        } else {
                            let allowFallback = rawTrim.count >= 28 || heldFor >= 1.2
                            if allowFallback,
                               let cutWord = self.lastWordBoundary(in: rawTrim, fromOffset: max(0, rawTrim.count - 80)) {
                                let c = String(rawTrim[..<cutWord]).trimmingCharacters(in: .whitespacesAndNewlines)
                                if c.count >= self.minPeerCommitChars { candidateRaw = c }
                            }
                        }
                        guard let candidate = candidateRaw, candidate.count >= self.minPeerCommitChars else { return }
                        
                        @MainActor
                        func advanceCoverageWithoutEnqueue(
                          _ tid: UUID,
                          candidate: String,
                          rawTrimCount: Int,
                          now: Date
                        ) {
                          let coveredNow = min(self.rxCoveredCount[tid] ?? 0, rawTrimCount)
                          self.rxCoveredCount[tid] = min(coveredNow + candidate.count, rawTrimCount)
                          // keep a lightweight raw preview for UI reconciliation
                          let prev = self.rxRawAccum[tid] ?? ""
                          self.rxRawAccum[tid] = prev.isEmpty ? candidate : (prev + " " + candidate)
                          self.rxLastChunkAt[tid] = now
                        }

                        // 2) translate + gate
                        let translatedChunk = (try? await UnifiedTranslateService.translate(candidate,
                                                                                            from: m.sourceLanguageCode,
                                                                                            to:   self.myLanguage)) ?? candidate
                        
                        guard let cleanedMaybe = guardTargetLanguage(translatedChunk, dstFull: self.myLanguage) else {
                            print("[PeerRx] DROP_LANG dst=\(self.myLanguage) txt=\"\(translatedChunk.prefix(40))…\"")
                            advanceCoverageWithoutEnqueue(tid,
                              candidate: candidate,
                              rawTrimCount: rawTrim.count,
                              now: now
                            )
                            return
                        }
                        let cleaned = cleanedMaybe
                        
                        let isFirstPiece = (self.rxCoveredCount[tid] ?? 0) == 0
                        let passesGate: Bool = {
                            if isFirstPiece {
                                let endsTerminal = cleaned.last.map { "?!".contains($0) } ?? false
                                let tokenCount   = cleaned.split { !$0.isLetter && !$0.isNumber }.count
                                if endsTerminal && tokenCount >= 3 { return true }
                                return shouldEmitSentence(cleaned, dst: self.myLanguage, isFirstPiece: true)
                            } else {
                                return shouldEmitSentence(cleaned, dst: self.myLanguage, isFirstPiece: false)
                            }
                        }()
                        
                        guard !looksWeirdSingleWord(cleaned) else { advanceCoverageWithoutEnqueue(tid,
                                                                                                  candidate: candidate,
                                                                                                  rawTrimCount: rawTrim.count,
                                                                                                  now: now
                                                                                                ); return }
                        
                        guard passesGate, self.allowSpeakAndMark(cleaned) else {
                            advanceCoverageWithoutEnqueue(tid,
                              candidate: candidate,
                              rawTrimCount: rawTrim.count,
                              now: now
                            )

                            return
                        }
                        
                        // 3) try coalesce; if it absorbed, still advance coverage (no new commit)
                        if tryCoalesceWithLast(cleaned, dst: self.myLanguage) {
                            self.rxCoveredCount[tid] = min(coveredTotal + candidate.count, rawTrim.count)
                            self.rxLastChunkAt[tid]  = now
                            return
                        }
                        
                        // 4) enqueue (the normal commit path) + advance coverage
                        let speakText = polishSpanishIfNeeded(cleaned, dst: self.myLanguage)
                        let commit = PhraseCommit(
                            srcFull: m.sourceLanguageCode, dstFull: self.myLanguage, raw: speakText,
                            committedAt: Date().timeIntervalSince1970, decidedAt: Date().timeIntervalSince1970, confidence: 1.0
                        )
                        
                        self.phraseQueue.append(commit)
                        self.phraseTranslations[commit.id] = speakText
                        self.appendToAccum(tid, spoken: speakText)
                        self.queueBargeDeadline = Date().addingTimeInterval(self.phraseInterGapMax)
                        
                        // advance coverage
                        let newlyCovered = min(coveredTotal + candidate.count, rawTrim.count)
                        self.rxCoveredCount[tid] = newlyCovered
                        self.rxLastChunkAt[tid]  = now
                        
                        // keep RAW accumulator in sync for UI reconciliation
                        let prevRaw = self.rxRawAccum[tid] ?? ""
                        self.rxRawAccum[tid] = prevRaw.isEmpty ? candidate : (prevRaw + " " + candidate)
                        
                        // UI sync
                        self.translatedTextForMeToHear = speakText
                        let rawSoFar = self.rxRawAccum[tid] ?? candidate
                        self.peerSaidText = self.cleanForPresentation(rawSoFar)
                        
                        print("[PeerRx] CHUNK enqueue dst=\(self.myLanguage) len=\(speakText.count) covered=\(newlyCovered)/\(rawTrim.count) qDepth(after)=\(self.phraseQueue.count)")
                        self.drainPhraseQueue()
                        
                    }
                } else {
                    print("[Rx] PARTIAL show-raw len=\(raw.count)")
                    translatedTextForMeToHear = raw
                }
                
                print("[Rx] PARTIAL UI turn=\(m.turnId?.uuidString.prefix(8) ?? "--") seq=\(m.seq ?? -1)")
                return
            }
            
            // ───────── FINAL BRANCH → enqueue remaining tail + reconcile suffix ─────────
            if self.rxPartialMTTask != nil { print("[Rx] CANCEL draft-MT before FINAL") }
            self.rxDraftEpoch &+= 1
            self.rxPartialMTTask?.cancel()
            self.rxPartialMTTask = nil

            if let tid = m.turnId { rxIdleTimers[tid]?.cancel(); rxIdleTimers[tid] = nil }

            let myFull   = self.myLanguage
            let peerFull = self.peerLanguage
            let myBase   = String(myFull.prefix(2)).lowercased()
            let peerBase = String(peerFull.prefix(2)).lowercased()
            let dst      = myFull
            let fallbackOther = (myBase == "en") ? "es-US" : "en-US"

            var srcCandidate = m.sourceLanguageCode
            if String(srcCandidate.prefix(2)).lowercased() == myBase {
              srcCandidate = (peerBase != myBase) ? peerFull : fallbackOther
              print("[Rx] FINAL src==myBase → flip→ \(srcCandidate)")
            }
            if String(srcCandidate.prefix(2)).lowercased() == String(dst.prefix(2)).lowercased() {
              srcCandidate = (peerBase != myBase) ? peerFull : fallbackOther
              print("[Rx] FINAL src==dst base → flip→ \(srcCandidate)")
            }
            let srcFinal = srcCandidate

            print("[Rx] FINAL decide my=\(myFull) peer=\(peerFull) rawBase=\(String(m.sourceLanguageCode.prefix(2)).lowercased())")
            print("[Rx] FINAL MT \(srcFinal)→\(dst) rawLen=\(m.originalText.count)")

            let translatedFull = (try? await UnifiedTranslateService.translate(
              m.originalText, from: srcFinal, to: dst)) ?? m.originalText

            // ——— Helpers (suffix-only policy) ———
            func normTokens(_ s: String) -> [String] {
              s.lowercased()
                .folding(options: .diacriticInsensitive, locale: .current)
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { !$0.isEmpty }
            }

            func suffixStartIndex(full: String, spoken: String) -> Int? {
              let f = normTokens(full), s = normTokens(spoken)
              guard !f.isEmpty, !s.isEmpty else { return nil }
              let tailWin = max(5, min(12, s.count))
              let probe = Array(s.suffix(tailWin))
              func matchAt(_ i: Int) -> Bool {
                let j = i + probe.count
                guard j <= f.count else { return false }
                let slice = Array(f[i..<j])
                let inter = Set(slice).intersection(Set(probe)).count
                return Double(inter) / Double(probe.count) >= 0.80
              }
              var lastHit: Int? = nil
              if f.count >= probe.count {
                for i in 0...(f.count - probe.count) {
                  if matchAt(i) { lastHit = i + probe.count }
                }
              }
              return lastHit
            }

            func suffixDelta(full: String, spoken: String) -> String {
              guard let cutTok = suffixStartIndex(full: full, spoken: spoken) else { return "" }
              let fToks = normTokens(full)
              let tailTokens = Array(fToks.suffix(max(0, fToks.count - cutTok)))
              guard let firstTok = tailTokens.first else { return "" }

              // Approximate map from tokens → character index by searching first token boundary
              if let r = full.range(of: "\\b\(NSRegularExpression.escapedPattern(for: firstTok))\\b",
                                    options: [.regularExpression, .caseInsensitive]) {
                var out = String(full[r.lowerBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                // minimum gate
                let hasTerminal = out.last.map { ".?!…".contains($0) } == true
                let tokenCount  = out.split { !$0.isLetter && !$0.isNumber }.count
                if !hasTerminal && tokenCount < 5 && out.count < 28 { return "" }
                return out
              }
              return ""
            }

            // Update UI lines to the clean full text (always)
            self.peerSaidText              = self.cleanForPresentation(m.originalText)
            self.translatedTextForMeToHear = translatedFull

            // ——— Suffix-only final: if we already spoke something this turn, NEVER enqueue a full ———
            if let tid = m.turnId, let already = self.rxDstAccum[tid], !already.isEmpty {
              var delta = suffixDelta(full: translatedFull, spoken: already)
              if !delta.isEmpty {
                delta = polishSpanishIfNeeded(delta, dst: dst)
                if self.allowSpeakAndMark(delta) {
                  let commit = PhraseCommit(
                    srcFull: srcFinal, dstFull: dst, raw: delta,
                    committedAt: Date().timeIntervalSince1970, decidedAt: Date().timeIntervalSince1970, confidence: 1.0
                  )
                  self.phraseQueue.append(commit)
                  self.phraseTranslations[commit.id] = delta
                  self.appendToAccum(tid, spoken: delta)
                  self.queueBargeDeadline = Date().addingTimeInterval(self.phraseInterGapMax)
                  print("[PeerRx] FINAL suffix-only enqueue len=\(delta.count)")
                  self.drainPhraseQueue()
                } else {
                  print("[PeerRx] FINAL suffix-only DROP_DUP len=\(delta.count)")
                }
              } else {
                print("[PeerRx] FINAL suffix-only empty → skip")
              }

              // clear per-turn coverage/accum
              self.rxCoveredCount.removeValue(forKey: tid)
              self.rxRawAccum.removeValue(forKey: tid)
              self.rxLastChunkAt[tid] = Date()
              self.rxDstAccum.removeValue(forKey: tid)
              return
            }

            // ——— Nothing spoken yet this turn → speak the FULL once (subject to guards) ———
            var speakFull = translatedFull.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !speakFull.isEmpty else { return }
            speakFull = polishSpanishIfNeeded(speakFull, dst: dst)

            // First-chunk guard: require sentence-like or long/terminal
            let tokenCountFull = speakFull.split { !$0.isLetter && !$0.isNumber }.count
            let looksSent = self.looksSentenceLike(speakFull, languageCode: dst)
            let terminal  = speakFull.last.map { ".?!…".contains($0) } ?? false
            let goodFirst = terminal || looksSent || speakFull.count >= 28 || tokenCountFull >= 5
            guard goodFirst else {
              print("[PeerRx] FINAL DROP_SHORT/FIRST len=\(speakFull.count)")
              return
            }
            guard self.allowSpeakAndMark(speakFull) else {
              print("[PeerRx] FINAL DROP_DUP full len=\(speakFull.count)")
              return
            }

            let commit = PhraseCommit(
              srcFull: srcFinal, dstFull: dst, raw: speakFull,
              committedAt: Date().timeIntervalSince1970, decidedAt: Date().timeIntervalSince1970, confidence: 1.0
            )
            self.phraseQueue.append(commit)
            self.phraseTranslations[commit.id] = speakFull
            self.appendToAccum(m.turnId, spoken: speakFull)
            self.queueBargeDeadline = Date().addingTimeInterval(self.phraseInterGapMax)

            print("[PeerRx] FINAL full-once enqueue len=\(speakFull.count)")
            self.drainPhraseQueue()

            
            // ───────── RECONCILE: speak any remaining suffix of full translation ─────────
            if let tid = m.turnId {
                func numberWords(for base: String) -> Set<String> {
                    switch base {
                    case "es": return ["cero","uno","una","dos","tres","cuatro","cinco","seis","siete","ocho","nueve","diez","once","doce"]
                    case "en": return ["zero","one","two","three","four","five","six","seven","eight","nine","ten"]
                    case "fr": return ["zéro","un","une","deux","trois","quatre","cinq","six","sept","huit","neuf","dix"]
                    case "de": return ["null","eins","eine","zwei","drei","vier","fünf","sechs","sieben","acht","neun","zehn"]
                    default:   return []
                    }
                }
                func looksNumericSuffix(_ s: String, base: String) -> Bool {
                    let t = s.lowercased()
                    if t.rangeOfCharacter(from: .decimalDigits) != nil { return true }
                    let toks = t.split { !$0.isLetter }
                    let nums = numberWords(for: base)
                    return toks.contains(where: { nums.contains(String($0)) })
                }
                func okShortSuffix(_ s: String, base: String) -> Bool {
                    let toks = s.lowercased().split { !$0.isLetter && !$0.isNumber }
                    if toks.count <= 4 && looksNumericSuffix(s, base: base) { return true }
                    return false
                }
                
                let already = self.rxDstAccum[tid] ?? ""
                let full    = translatedFull.trimmingCharacters(in: .whitespacesAndNewlines)
                let baseDst = String(dst.prefix(2)).lowercased()
                
                // Before considering suffixes, kill duplicates caused by “tail then full”.
                if let last = self.phraseQueue.last,
                   last.dstFull == dst,
                   let lastText = self.phraseTranslations[last.id] {
                    
                    let lastNorm = normalizedKey(lastText)
                    let fullNorm = normalizedKey(full)
                    
                    let containsOrSimilar =
                    fullNorm.contains(lastNorm) || lastNorm.contains(fullNorm) || highlySimilar(lastNorm, fullNorm)
                    
                    if containsOrSimilar {
                        if self.activeCommitID == last.id && self.ttsService.isSpeaking {
                            self.appendToAccum(tid, spoken: lastText)
                            print("[PeerRx] RECONCILE skip (full≈last while speaking)")
                            return
                        } else {
                            self.phraseTranslations[last.id] = full
                            self.translatedTextForMeToHear   = full
                            // Mark only new delta
                            let delta = trimAlreadySpokenPrefix(tid: tid, candidate: full)
                            if !delta.isEmpty { self.appendToAccum(tid, spoken: delta) }
                            print("[PeerRx] RECONCILE upgrade last → FULL (no new enqueue)")
                            return
                        }
                    }
                }
                
                let cp = commonPrefixCount(already, full)
                if cp < full.count {
                    var suffix = String(full.dropFirst(cp)).trimmingCharacters(in: .whitespacesAndNewlines)
                    
                    if !okShortSuffix(suffix, base: baseDst) {
                        if let purified = guardTargetLanguage(suffix, dstFull: dst) { suffix = purified }
                        else { print("[PeerRx] RECONCILE drop (purity) len=\(suffix.count) text=\"\(suffix)\""); return }
                    }
                    
                    let endsTerminal = suffix.last.map { sentenceMarks.contains($0) } ?? false
                    if suffix.count < 18 && !endsTerminal && !okShortSuffix(suffix, base: baseDst) {
                        print("[PeerRx] RECONCILE drop (tiny suffix) len=\(suffix.count)")
                        return
                    }
                    
                    if let last = self.phraseQueue.last,
                       last.dstFull == dst,
                       let lastText = self.phraseTranslations[last.id] {
                        
                        if full.hasPrefix(lastText) {
                            let merged = full
                            self.phraseTranslations[last.id] = merged
                            self.translatedTextForMeToHear   = merged
                            let delta = trimAlreadySpokenPrefix(tid: tid, candidate: merged)
                            if !delta.isEmpty { appendToAccum(tid, spoken: delta) }
                            print("[PeerRx] RECONCILE upgrade last → FULL; len+=\(suffix.count)")
                            return
                        }
                        
                        if highlySimilar(lastText, suffix) {
                            print("[PeerRx] RECONCILE drop (high overlap with last)")
                            return
                        }
                        
                        if tryCoalesceWithLast(suffix, dst: dst) {
                            let delta = trimAlreadySpokenPrefix(tid: tid, candidate: suffix)
                            if !delta.isEmpty { appendToAccum(tid, spoken: delta) }
                            return
                        }
                    }
                    
                    // Enqueue only the *new* suffix delta
                    var sCommitText = polishSpanishIfNeeded(suffix, dst: dst)
                    sCommitText = trimAlreadySpokenPrefix(tid: tid, candidate: sCommitText)
                    sCommitText = sCommitText.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !sCommitText.isEmpty else { return }
                    
                    let tokenCount = sCommitText.split { !$0.isLetter && !$0.isNumber }.count
                    let enoughNew  = (sCommitText.last.map { ".?!…".contains($0) } ?? false)
                    || sCommitText.count >= 28 || tokenCount >= 5
                    guard enoughNew else {
                        print("[PeerRx] RECONCILE drop (not enough new material) len=\(sCommitText.count)")
                        return
                    }
                    
                    let sCommit = PhraseCommit(
                        srcFull: srcFinal, dstFull: dst, raw: sCommitText,
                        committedAt: Date().timeIntervalSince1970,
                        decidedAt:   Date().timeIntervalSince1970,
                        confidence:  1.0
                    )
                    self.phraseQueue.append(sCommit)
                    self.phraseTranslations[sCommit.id] = sCommitText
                    self.queueBargeDeadline = Date().addingTimeInterval(self.phraseInterGapMax)
                    appendToAccum(tid, spoken: sCommitText)
                    self.drainPhraseQueue()
                }
                
                self.rxCoveredCount.removeValue(forKey: tid)
                self.rxRawAccum.removeValue(forKey: tid)
                self.rxLastChunkAt[tid] = Date()
                self.rxDstAccum.removeValue(forKey: tid)
            }
            
            // Safety net if nothing starts speaking
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                guard let self else { return }
                if !self.ttsService.isSpeaking && !self.queueDraining,
                   let first = self.phraseQueue.first,
                   self.activeCommitID == first.id,
                   let txt = self.phraseTranslations[first.id] {
                    print("[Rx] FINAL direct-TTS fallback dst=\(dst) len=\(txt.count)")
                    self.ttsService.speak(text: txt, languageCode: dst, voiceIdentifier: self.voice_for_lang[dst])
                }
            }
        }
    }




    private func routeHasSpeaker() -> Bool {
      AVAudioSession.sharedInstance().currentRoute.outputs.contains { $0.portType == .builtInSpeaker }
    }


    private static func defaultPeer(for my: String) -> String {
      let base = String(my.prefix(2)).lowercased()
      switch base {
      case "en": return "es-US"
      case "es": return "en-US"
      case "fr": return "en-US"
      case "de": return "en-US"
      case "ja": return "en-US"
      case "zh": return "en-US"
      default:   return "en-US"
      }
    }


    // TranslationViewModel.swift
    // ─────────────────────────────── Messaging (peer → me)
    private func handleReceivedMessage(_ m: MessageData) {
      guard markSeen(m.id) else { return }

      if let tid = m.turnId, let s = m.seq {
        print("[Rx] BRANCH sequenced tid=\(tid.uuidString.prefix(8)) seq=\(s) final=\(m.isFinal)")
        deliverSequenced(tid, s, m)
        return
      } else {
        print("[Rx] BRANCH unsequenced final=\(m.isFinal)")
        deliverMessage(m)
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
