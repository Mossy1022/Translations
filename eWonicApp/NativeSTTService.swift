//
//  NativeSTTService.swift
//  eWonicApp
//
//  v7.2 – resilient mic loop, but *all* public API kept 1-to-1 with v6
//

import Foundation
import AVFoundation
import Speech
import Combine
import UIKit
import Accelerate

extension AVAudioPCMBuffer {
    /// Simple RMS (energy) of the buffer for thresholding
    var rmsEnergy: Float {
        guard let channelData = floatChannelData?[0] else { return 0 }
        let n = Int(frameLength)
        var mean: Float = 0
        vDSP_meamgv(channelData, 1, &mean, vDSP_Length(n))
        return sqrt(mean)
    }
}

// ───────────── Global STTError (unchanged) ─────────────
enum STTError: Error, LocalizedError {
  case unavailable, permissionDenied, recognitionError(Error), taskError(String)

  var errorDescription: String? {
    switch self {
    case .unavailable:      return "Speech recognition is not available on this device or for the selected language."
    case .permissionDenied: return "Speech recognition permission was denied."
    case .recognitionError(let e): return "Recognition failed: \(e.localizedDescription)"
    case .taskError(let m): return m
    }
  }
}


private enum InternalErr {
    static let noSpeechCodes: Set<Int> = [203, 1110]
   static let svcCrash = 1101
}

// ───────────── Service ─────────────
@MainActor
final class NativeSTTService: NSObject, ObservableObject {

  struct PartialSnapshot {
    let text: String
    let timestamp: Date
  }

  struct StableBoundary {
    let text: String
    let timestamp: Date
    let reason: String
  }

  // MARK: – Engine plumbing
  private var speechRecognizer: SFSpeechRecognizer?
  private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
  private var recognitionTask:   SFSpeechRecognitionTask?
  private let audioEngine = AVAudioEngine()
        
    private var silenceBeganAt: Double? = nil
    private var pendingRotateWork: DispatchWorkItem? = nil
    
    // Debounce frantic re-rotates immediately after a restart
    private var rotateCooldownUntil = Date.distantPast
    private let rotateCooldown:    TimeInterval = 1.80    // was 0.80

    // Tiny state log for silence/voice transitions (not per buffer spam)
    private var wasSilent = true
    
    private var awaitingSilenceRotate = false   // prevents multiple rotate timers per segment
    private let silenceRotateDelay: TimeInterval = 0.35

  private var externallyQuiesced = false

  private var pendingSoftRotate: DispatchWorkItem?

  // MARK: – Timers / state
  private var segmentStart              = Date()
  private var lastBufferHostTime: UInt64 = 0
  private var stableTimer:    DispatchSourceTimer?
  private var watchdogTimer:  DispatchSourceTimer?

  private let maxSegmentSeconds: TimeInterval = 120
  private let silenceTimeout:    TimeInterval = 1.5
  private let stableTimeout:     TimeInterval = 1.2
  private let noSpeechCode                    = 203   // Apple private

    
    private var noGrowthTimer: DispatchSourceTimer?
    private let shortNoGrowthTimeout: TimeInterval = 1.30
    private let longNoGrowthTimeout:  TimeInterval = 2.20

    
  // MARK: – Published (same spelling!)
  @Published private(set) var isListening = false
  @Published var recognizedText = ""

    @Published var sensitivity: Float = 0.6     // default; set by ViewModel
    var farFieldBoost = false // set by the VM for Convention mode if desired

    private func currentBaseThreshold() -> Float {
      let isBT = AudioSessionManager.shared.inputIsBluetooth
      return isBT ? 0.0025 as Float : 0.0040 as Float
    }
    
    private func thresholdForCurrentRoute() -> (threshold: Float, margin: Float) {
      let base = currentBaseThreshold()
      let isBT = AudioSessionManager.shared.inputIsBluetooth

    let span: Float = isBT ? 0.008 : 0.012
    var thr:  Float = base + (1.0 - sensitivity) * span
    var marg: Float = 0.0015

      if farFieldBoost {
        thr  *= 0.65 as Float
        marg *= 0.75 as Float
      }
        
//    print("[STT] threshold recalculated → sensitivity=\(sensitivity) thr=\(thr) marg=\(marg)")

      return (thr, marg)
    }
  // MARK: – Subjects (same names!)
  let partialResultSubject = PassthroughSubject<String,Never>()
  let finalResultSubject   = PassthroughSubject<String,Never>()
  let partialSnapshotSubject = PassthroughSubject<PartialSnapshot, Never>()
  let stableBoundarySubject  = PassthroughSubject<StableBoundary, Never>()
  let errorSubject         = PassthroughSubject<STTError,Never>()   // only .unavailable emitted now
    
    public  let partialStream: AsyncStream<String>     // outward-facing
    private let partialContinuation: AsyncStream<String>.Continuation
    private var streamCancellable: AnyCancellable?


    override init() {
        // 1) make the pipe
        let (stream, cont) = AsyncStream<String>.makeStream(
                               bufferingPolicy: .bufferingNewest(32))
        self.partialStream       = stream
        self.partialContinuation = cont

        super.init()             // ← call NSObject

        // 2) forward every partial transcript into the pipe
        streamCancellable = partialResultSubject
            .sink { [cont] text in
                cont.yield(text)        // <-- live push
            }
        
        
    }
    
    private func wordCount(_ s: String) -> Int {
      s.split { !$0.isLetter && !$0.isNumber }.count
    }

    private func restartNoGrowthTimer() {
      noGrowthTimer?.cancel(); noGrowthTimer = nil
      let snap = recognizedText
      let wc   = wordCount(snap)
      let timeout = (wc <= 3 && snap.count <= 18) ? shortNoGrowthTimeout : longNoGrowthTimeout

      noGrowthTimer = DispatchSource.makeTimerSource(queue: .main)
      noGrowthTimer?.schedule(deadline: .now() + timeout)
      noGrowthTimer?.setEventHandler { [weak self] in
        guard let self else { return }
        // If the text didn't change during the window, treat it as a final.
        if self.recognizedText == snap &&
           !snap.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          print("[NativeSTT] NOGROWTH_CUTOFF len=\(snap.count) words=\(wc)")
        let base = String((self.speechRecognizer?.locale.identifier ?? "en").prefix(2)).lowercased()
        let openTail = self.looksOpenTail(snap, base: base)
        if openTail {
          print("[NativeSTT] NOGROWTH deferral (open tail) len=\(snap.count)")
          self.restartNoGrowthTimer() // give it another window
          return
        }

          self.emitFinal()
          self.rotate(reason: "noGrowth")
        } else {
          print("[NativeSTT] NOGROWTH_SKIPPED (changed)")
        }
      }
      noGrowthTimer?.resume()
    }


    func forceStop() {
      externallyQuiesced = true
      // kill timers
      pendingSoftRotate?.cancel(); pendingSoftRotate = nil
      pendingRotateWork?.cancel(); pendingRotateWork = nil
      awaitingSilenceRotate = false
      stableTimer?.cancel(); stableTimer = nil
      watchdogTimer?.cancel(); watchdogTimer = nil
      noGrowthTimer?.cancel(); noGrowthTimer = nil

      // end the recognition task + audio
      ignoreBuffers = true
      recognitionRequest?.endAudio()
      recognitionTask?.cancel()
      recognitionRequest = nil
      recognitionTask    = nil

      removeTap()
      do { audioEngine.reset() } catch { /* benign */ }

      isListening = false
      AudioSessionManager.shared.end()
      print("[NativeSTT] forceStop() complete")
    }
    
  // ───────────── Permissions (unchanged) ─────────────
    func requestPermission(_ done: @escaping (Bool)->Void) {
      SFSpeechRecognizer.requestAuthorization { auth in
        DispatchQueue.main.async {
          guard auth == .authorized else { done(false); return }
          AVAudioSession.sharedInstance().requestRecordPermission { micOK in
            DispatchQueue.main.async { done(micOK) }
          }
        }
      }
    }
    
  // ───────────── Setup recognizer ─────────────
    func setupSpeechRecognizer(languageCode: String) {
      guard let r = SFSpeechRecognizer(locale: Locale(identifier: languageCode)) else {
        errorSubject.send(.taskError("Speech recognizer unavailable for \(languageCode)"))
        return
      }
      speechRecognizer = r
      r.delegate = self
      let onDevice = r.supportsOnDeviceRecognition
      print("[NativeSTT] recognizer ready – lang: \(languageCode), on-device:\(onDevice)")
    }

  // ───────────── Public start/stop (same names!) ─────────────
    @MainActor
    func startTranscribing(languageCode: String) {
      guard !isListening else { return }

      externallyQuiesced = false
      ignoreBuffers = false
      lastBufferHostTime = 0
      wasSilent = true
      silenceBeganAt = nil

      setupSpeechRecognizer(languageCode: languageCode)
      guard speechRecognizer != nil else { return }

      // Bring up the audio session first; normalize I/O before engine work
      AudioSessionManager.shared.begin()
      normalizeSessionIO()

      // Mark listening only after session is active
      isListening = true
      print("[NativeSTT] isListening=TRUE (startTranscribing)")
      recognizedText = "Listening…"

      // Do engine/tap work next tick to avoid racing route changes
      DispatchQueue.main.async { [weak self] in
        guard let self else { return }
        self.installTap()
        self.spinUpTask()
        print("[NativeSTT] audio engine started")
      }
    }

    func stopTranscribing() {
      externallyQuiesced = true

      // Kill any pending restarts/rotates
      pendingSoftRotate?.cancel(); pendingSoftRotate = nil
      pendingRotateWork?.cancel(); pendingRotateWork = nil
      awaitingSilenceRotate = false

      stableTimer?.cancel();  stableTimer  = nil
      watchdogTimer?.cancel();watchdogTimer = nil
      noGrowthTimer?.cancel();noGrowthTimer = nil

      ignoreBuffers = true

      recognitionRequest?.endAudio()
      recognitionTask?.cancel()
      recognitionRequest = nil
      recognitionTask    = nil

      removeTap()
      do { audioEngine.reset() } catch { /* benign */ }

      isListening = false
      print("[NativeSTT] isListening=FALSE (stopTranscribing)")
      AudioSessionManager.shared.end()
      print("[NativeSTT] stopped")
    }

    
    private var ignoreBuffers = false

    private func looksOpenTail(_ s: String, base: String) -> Bool {
      let t = s.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
      guard !t.isEmpty else { return true }
      let last = t.split { !$0.isLetter && !$0.isNumber }.last.map(String.init) ?? ""
      let en = Set(["the","a","an","and","or","but","so","to","of","for","with","by","on","in","at"])
      let es = Set(["el","la","los","las","un","una","y","o","pero","de","a","en","con","para","por","al","del"])
      let base2 = String((speechRecognizer?.locale.identifier ?? "en").prefix(2)).lowercased()
      return (base2 == "es" ? es : en).contains(last)
    }

    
    private func installTap() {
      ignoreBuffers = false

      let node = audioEngine.inputNode
      // Use the HW input format, not outputFormat, to avoid deinterleave mismatches
      let hwFmt = node.inputFormat(forBus: 0)

      node.removeTap(onBus: 0)

      // First attempt with the exact HW format
      node.installTap(onBus: 0, bufferSize: 1024, format: hwFmt) { [self] buf, when in
        guard !ignoreBuffers else { return }

        // Energy gate (unchanged)
        let (threshold, margin) = thresholdForCurrentRoute()
        let energy = buf.rmsEnergy
        let voiceGate = threshold + margin

        if energy < threshold {
          if !wasSilent { print("[NativeSTT] → silence"); wasSilent = true }
          let nowHost = AVAudioTime.seconds(forHostTime: when.hostTime)
          if silenceBeganAt == nil { silenceBeganAt = nowHost }
          let silentFor = nowHost - (silenceBeganAt ?? nowHost)

          if silentFor >= silenceTimeout, !awaitingSilenceRotate {
            awaitingSilenceRotate = true
            pendingRotateWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
              guard let self else { return }
              let last = self.lastBufferHostTime
              let lastSec = (last == 0) ? 0 : AVAudioTime.seconds(forHostTime: last)
              let nowSec  = AVAudioTime.seconds(forHostTime: mach_absolute_time())
              let stillSilent = (nowSec - max(lastSec, self.silenceBeganAt ?? nowSec)) >= self.silenceTimeout
              if self.externallyQuiesced { return }
              if stillSilent { print("[NativeSTT] silence-confirmed → rotate"); self.rotate(reason: "silence") }
              else { print("[NativeSTT] rotate-cancelled (voice resumed)") }
              self.awaitingSilenceRotate = false
              self.pendingRotateWork = nil
            }
            pendingRotateWork = work
            print("[NativeSTT] schedule rotate confirm in \(silenceRotateDelay)s")
            DispatchQueue.main.asyncAfter(deadline: .now() + silenceRotateDelay, execute: work)
          }
          return
        }

        if wasSilent {
          if energy < voiceGate { return }
          print("[NativeSTT] → voice (rms=\(String(format: "%.4f", energy)))")
          wasSilent = false
          if awaitingSilenceRotate {
            awaitingSilenceRotate = false
            pendingRotateWork?.cancel()
            pendingRotateWork = nil
          }
        }

        recognitionRequest?.append(buf)
        lastBufferHostTime = when.hostTime
        silenceBeganAt = nil
      }

      do {
        if !audioEngine.isRunning {
          try audioEngine.start()
        }
      } catch {
        // Some routes balk at the explicit format; retry with nil (engine picks bus format)
        print("⚠️ Audio engine start failed: \(error.localizedDescription) → retry with nil format tap")
        node.removeTap(onBus: 0)
        node.installTap(onBus: 0, bufferSize: 1024, format: nil) { [self] buf, when in
          guard !ignoreBuffers else { return }
          let (threshold, margin) = thresholdForCurrentRoute()
          let energy = buf.rmsEnergy
          let voiceGate = threshold + margin
          if energy < threshold {
            if !wasSilent { print("[NativeSTT] → silence"); wasSilent = true }
            let nowHost  = AVAudioTime.seconds(forHostTime: when.hostTime)
            if silenceBeganAt == nil { silenceBeganAt = nowHost }
            return
          }
          if wasSilent {
            if energy < voiceGate { return }
            print("[NativeSTT] → voice (rms=\(String(format: "%.4f", energy)))")
            wasSilent = false
          }
          recognitionRequest?.append(buf)
          lastBufferHostTime = when.hostTime
          silenceBeganAt = nil
        }
        do {
          if !audioEngine.isRunning {
            try audioEngine.start()
          }
        } catch {
          let msg = "Audio engine start failed (retry): \(error.localizedDescription)"
          print("⚠️ \(msg)")
          errorSubject.send(.taskError(msg))
        }
      }
    }




    private func removeTap() {
      if audioEngine.isRunning {
        audioEngine.stop()
      }
      audioEngine.inputNode.removeTap(onBus: 0)
    }

  // ───────────── Task life-cycle ─────────────
    // In spinUpTask(), force on-device on iOS 26 and log it
    private func spinUpTask() {
      guard let recognizer = speechRecognizer else { return }

      recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
      if #available(iOS 26.0, *) {
        recognitionRequest?.requiresOnDeviceRecognition = true
        print("[NativeSTT] requiresOnDeviceRecognition=true (iOS26)")
      } else if recognizer.supportsOnDeviceRecognition {
        recognitionRequest?.requiresOnDeviceRecognition = true
        print("[NativeSTT] requiresOnDeviceRecognition=true")
      } else {
        print("[NativeSTT] on-device not supported for this locale; cloud dictation may be used by iOS")
      }

      recognitionRequest?.shouldReportPartialResults = true
      if #available(iOS 13.0, *) {
        recognitionRequest?.taskHint = .dictation
      }

      segmentStart = Date()
      lastBufferHostTime = 0
      scheduleWatchdog()

      recognitionTask = recognizer.recognitionTask(with: recognitionRequest!) { [self] res, err in
        if let r = res { handle(result: r) }
        if let e = err as NSError? { handle(error: e) }
      }
    }


    private func teardownTask() {
      recognitionRequest?.endAudio()
      recognitionTask?.cancel()
      recognitionRequest = nil
      recognitionTask    = nil

      pendingSoftRotate?.cancel(); pendingSoftRotate = nil
      pendingRotateWork?.cancel(); pendingRotateWork = nil
      awaitingSilenceRotate = false

      stableTimer?.cancel();  stableTimer  = nil
      watchdogTimer?.cancel();watchdogTimer = nil
      noGrowthTimer?.cancel();noGrowthTimer = nil

      wasSilent = true
      silenceBeganAt = nil
    }


  // ───────────── Result / Error handlers ─────────────
    
    private func refine(_ r: SFSpeechRecognitionResult) -> String {
      // Build from segments, picking a better alternative when the token looks odd.
      // Rules:
      //  - mid-sentence TitleCase → prefer lower/split alt
      //  - token not in dictionary → prefer an alt that is in dictionary or splits into 2 known words
      //  - collapse immediate duplicates later (VM already has this)
      let segs = r.bestTranscription.segments
      var parts: [String] = []
      let checker = UITextChecker()
      let lang = "en_US"  // runtime-select from recognizer.locale if you want

      func isWord(_ s: String) -> Bool {
        let ns = s as NSString
        let range = NSRange(location: 0, length: ns.length)
        let miss = checker.rangeOfMisspelledWord(in: s, range: range, startingAt: 0, wrap: false, language: lang)
        return miss.location == NSNotFound
      }

      func splitIntoTwoWordsIfPossible(_ token: String) -> String? {
        guard token.count >= 6 else { return nil }
        let cs = Array(token)
        for i in 2..<(cs.count - 2) {
          let a = String(cs[0..<i]), b = String(cs[i..<cs.count])
          if isWord(a) && isWord(b) { return a + " " + b }
        }
        return nil
      }

      for (i, s) in segs.enumerated() {
        var tok = s.substring

        // Heuristic: mid-sentence titlecase suspicious -> try lower
        if i > 0, tok.first?.isUppercase == true {
          tok = tok.lowercased()
        }

        // If token isn't a known word (or looks jammed), try better alt
        if !isWord(tok) {
          // 1) try an alternative that *is* a known word
          if let alt = s.alternativeSubstrings.first(where: { isWord($0) }) {
            tok = alt
          } else if let split = splitIntoTwoWordsIfPossible(tok) {
            tok = split
          } else if let altSplit = s.alternativeSubstrings.compactMap(splitIntoTwoWordsIfPossible).first {
            tok = altSplit
          }
        }

        parts.append(tok)
      }

      // Basic rebuild; let VM do further dedupe/cleanup
      return parts.joined(separator: " ")
    }

    
    private func handle(result: SFSpeechRecognitionResult) {
        pendingSoftRotate?.cancel(); pendingSoftRotate = nil
        awaitingSilenceRotate = false
        
        
        Task { @MainActor in
            let refined = refine(result)
            recognizedText = refined
            let snapshot = PartialSnapshot(text: recognizedText, timestamp: Date())
            partialResultSubject.send(recognizedText)
            partialSnapshotSubject.send(snapshot)
            partialContinuation.yield(recognizedText)
            print("[NativeSTT] PARTIAL – \(recognizedText) len=\(recognizedText.count) isFinal=\(result.isFinal)")

            restartStableTimer()
            restartNoGrowthTimer()

            if result.isFinal || Date().timeIntervalSince(segmentStart) > maxSegmentSeconds {
                print("[NativeSTT] FINAL boundary (isFinal:\(result.isFinal))")
                emitFinal()
                rotate(reason: result.isFinal ? "final" : "segmentCap")
            }
        }
    }

    private func handle(error e: NSError) {
      if externallyQuiesced { return }

        awaitingSilenceRotate = false
        
        // ⛔ Dictation disabled: do not rotate forever
          if e.domain == "kLSRErrorDomain", e.code == 201 {
            print("[NativeSTT] FATAL DictationDisabled → stopping")
            errorSubject.send(.taskError("On-device speech is disabled. Enable “Dictation” in Settings > General > Keyboard."))
            stopTranscribing()                 // ⟵ break the loop
            return
          }
        
        // If we *just* rotated, ignore one wave of 1110 to avoid churn
        if Date() < rotateCooldownUntil,
           e.domain == "kAFAssistantErrorDomain",
           InternalErr.noSpeechCodes.contains(e.code) {
          print("[NativeSTT] 1110 suppressed (cooldown)")
          return
        }

      print("[NativeSTT] DEBUG  domain=\(e.domain)  code=\(e.code)  desc=\(e.localizedDescription)")

      // Transient “busy/retry” conditions
      if e.domain == "kAFAssistantErrorDomain", [209,216].contains(e.code) {
        // Give CoreAudio/Speech daemon more room before we rotate
        errorSubject.send(.taskError("Speech service busy (code \(e.code)); retrying"))
        print("[NativeSTT] BUSY \(e.code) → backoff rotate")
        pendingSoftRotate?.cancel()
        let backoff: Double = 0.65   // seconds (tunable)
        let work = DispatchWorkItem { [weak self] in self?.rotate() }
        pendingSoftRotate = work
        DispatchQueue.main.asyncAfter(deadline: .now() + backoff, execute: work)
        return
      }

      if e.domain == "kAFAssistantErrorDomain",
         InternalErr.noSpeechCodes.contains(e.code) {
        errorSubject.send(.taskError("No speech detected"))
        pendingSoftRotate?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.rotate() }
        pendingSoftRotate = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
        return
      }

      if e.domain == "kAFAssistantErrorDomain", e.code == InternalErr.svcCrash {
        errorSubject.send(.taskError("Speech recogniser service crashed"))
          print("[NativeSTT] ERROR domain1=\(e.domain) code=\(e.code) → rotate")
        hardRebootRecognizer()
        return
      }

      errorSubject.send(.recognitionError(e))
      print("[NativeSTT] ERROR domain=\(e.domain) code=\(e.code) → rotate")
      rotate(reason: "error:\(e.domain)#\(e.code)")
    }
    
  private func emitFinal() {
    stableTimer?.cancel()
    let txt = recognizedText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard txt.count > 2 else {
      print("[NativeSTT] Ignored tiny chunk ⟨\(txt)⟩")
      return
    }
    print("[NativeSTT] FINAL  – \(txt)")
    let boundary = StableBoundary(text: txt, timestamp: Date(), reason: "final")
    awaitingSilenceRotate = false
    stableBoundarySubject.send(boundary)
    finalResultSubject.send(txt)
  }
    
    /// Set sane I/O prefs that work across built-in mic/speaker & BT.
    private func normalizeSessionIO() {
      let s = AVAudioSession.sharedInstance()
      do {
        // Prefer 48k (matches most iOS HW paths); OK if the HW picks something else.
        try s.setPreferredSampleRate(48_000)
      } catch { /* non-fatal */ }
      do {
        // ~20–30ms is a good compromise for streaming STT
        try s.setPreferredIOBufferDuration(0.0232)
      } catch { /* non-fatal */ }
      do {
        // Monophonic capture is fine for speech; some routes ignore this, which is OK.
        try s.setPreferredInputNumberOfChannels(1)
      } catch { /* non-fatal */ }
    }


    // In NativeSTTService.rotate(reason:)
    private func rotate(reason: String = "unspecified") {
      guard !externallyQuiesced else { return }

      // If we’re rotating for silence and have content, emit a final once.
      if reason == "silence" {
        let txt = recognizedText.trimmingCharacters(in: .whitespacesAndNewlines)
        if txt.count > 2 { emitFinal() }
      }

      // Debounce rotates to avoid rapid thrash
      if Date() < rotateCooldownUntil {
        print("[NativeSTT] ROTATE suppressed during cooldown (\(reason))")
        return
      }
      rotateCooldownUntil = Date().addingTimeInterval(rotateCooldown)

      silenceBeganAt = nil
      awaitingSilenceRotate = false
      print("[NativeSTT] ROTATE reason=\(reason) ignoreBuffers=\(ignoreBuffers) isListening=\(isListening)")
      print("[NativeSTT] rotate() tearing down & re-spinning task (isListening=\(isListening))")

      teardownTask()
      removeTap()
      do { audioEngine.reset() } catch { }

      // Rebuild tap + task
      installTap()
      ignoreBuffers = false
      lastBufferHostTime = 0
      spinUpTask()
    }



    
    private func hardRebootRecognizer() {
      let currentLang = speechRecognizer?.locale.identifier ?? "en-US"
      teardownTask()
      removeTap()
      do { audioEngine.reset() }                  // reclaim HW
      catch { /* non-fatal */ }

      DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
        guard let self else { return }
        self.installTap()
        self.setupSpeechRecognizer(languageCode: currentLang)
        self.spinUpTask()
      }
    }

  // ───────────── Timers ─────────────
    // 2) helper
    private func looksStructurallyCompleteForStable(_ s: String) -> Bool {
      let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !t.isEmpty else { return false }
      // Only finalize on sentence-ending punctuation
      if let last = t.last, ".?!…。！？".contains(last) { return true }
      return false
    }



    // 3) in restartStableTimer(), gate the stable final:
    private func restartStableTimer() {
      stableTimer?.cancel()
      let snap = recognizedText
      stableTimer = DispatchSource.makeTimerSource(queue: .main)
      stableTimer?.schedule(deadline: .now() + stableTimeout)
      stableTimer?.setEventHandler { [weak self] in
        guard let self else { return }
        if recognizedText == snap && looksStructurallyCompleteForStable(snap) {
            print("[NativeSTT] STABLE_CUTOFF len=\(snap.count)")
          let boundary = StableBoundary(text: snap, timestamp: Date(), reason: "stable")
          stableBoundarySubject.send(boundary)
          emitFinal()
          rotate()
        } else {
            print("[NativeSTT] STABLE_SKIPPED len=\(snap.count)")
        }
      }
      stableTimer?.resume()
    }

  private func scheduleWatchdog() {
    watchdogTimer?.cancel()
    watchdogTimer = DispatchSource.makeTimerSource(queue:.main)
    watchdogTimer?.schedule(deadline: .now() + 55*60)
    watchdogTimer?.setEventHandler { [weak self] in self?.rotate() }
    watchdogTimer?.resume()
  }
    
    func partialTokensStream() -> AsyncStream<String> { partialStream }

}


// ───────────── Availability callback ─────────────
extension NativeSTTService: SFSpeechRecognizerDelegate {
  func speechRecognizer(_ r:SFSpeechRecognizer, availabilityDidChange ok:Bool) {
    if !ok {
      isListening = false
      errorSubject.send(.unavailable)
      print("[NativeSTT] recognizer became unavailable")
    } else {
      print("[NativeSTT] recognizer available again")
    }
  }
}
