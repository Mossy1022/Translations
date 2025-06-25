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
    
    func pause()  { ignoreBuffers = true  }   // stop feeding recogniser
    func resume() { ignoreBuffers = false }   // resume feeding

  // MARK: – Engine plumbing
  private var speechRecognizer: SFSpeechRecognizer?
  private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
  private var recognitionTask:   SFSpeechRecognitionTask?
  private let audioEngine = AVAudioEngine()
    
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
    
 private var isRebooting = false        // new
    private var noSpeechStrike = 0


    
  // MARK: – Published (same spelling!)
  @Published private(set) var isListening = false
  @Published var recognizedText = ""

  // MARK: – Subjects (same names!)
  let partialResultSubject = PassthroughSubject<String,Never>()
  let finalResultSubject   = PassthroughSubject<String,Never>()
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
    guard let r = SFSpeechRecognizer(locale: Locale(identifier: languageCode)) else { return }
    speechRecognizer = r
    r.delegate = self
    print("[NativeSTT] recognizer ready – lang: \(languageCode), on-device:\(r.supportsOnDeviceRecognition)")
  }

  // ───────────── Public start/stop (same names!) ─────────────
  func startTranscribing(languageCode: String) {
    guard !isListening else { return }
    setupSpeechRecognizer(languageCode: languageCode)
    guard speechRecognizer != nil else { return }

    AudioSessionManager.shared.begin()
    isListening   = true
    recognizedText = "Listening…"

    installTap()
    spinUpTask()
    print("[NativeSTT] audio engine started")
  }

  func stopTranscribing() {
    guard isListening else { return }
    teardownTask()
    removeTap()
    isListening = false
    AudioSessionManager.shared.end()
    print("[NativeSTT] stopped")
  }
    
    private var ignoreBuffers = false

  // ───────────── Mic tap (unchanged behaviour) ─────────────
    private func installTap() {
      let node = audioEngine.inputNode
      let fmt  = node.outputFormat(forBus: 0)
      node.removeTap(onBus: 0)
      node.installTap(onBus: 0, bufferSize: 1024, format: fmt) { [self] buf, when in
          guard !ignoreBuffers else { return }
        // --- Do the silence test *before* appending the buffer
        if lastBufferHostTime != 0 {
          let now  = AVAudioTime.seconds(forHostTime: when.hostTime)
          let prev = AVAudioTime.seconds(forHostTime: lastBufferHostTime)
          if now - prev >= silenceTimeout {
            recognitionRequest?.endAudio()
            ignoreBuffers = true
            return                // ◀︎ DON’T push this (or any more) audio
          }
        }

        recognitionRequest?.append(buf)   // normal path
        lastBufferHostTime = when.hostTime
      }

      do { audioEngine.prepare(); try audioEngine.start() }
      catch { print("⚠️ audio engine start failed: \(error)") }
    }

  private func removeTap() {
    audioEngine.stop()
    audioEngine.inputNode.removeTap(onBus: 0)
  }

  // ───────────── Task life-cycle ─────────────
  private func spinUpTask() {
    guard let recognizer = speechRecognizer else { return }

    recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
    if recognizer.supportsOnDeviceRecognition { recognitionRequest?.requiresOnDeviceRecognition = true }
    recognitionRequest?.shouldReportPartialResults = true

    segmentStart = Date(); lastBufferHostTime = 0
    scheduleWatchdog()

    recognitionTask = recognizer.recognitionTask(with: recognitionRequest!) { [self] res, err in
      if let r = res { handle(result:r) }
      if let e = err as NSError? { handle(error:e) }
    }
  }

  private func teardownTask() {
    recognitionRequest?.endAudio()
    recognitionTask?.cancel()
    recognitionRequest = nil
    recognitionTask   = nil
    watchdogTimer?.cancel(); stableTimer?.cancel()
  }

  // ───────────── Result / Error handlers ─────────────
    private func handle(result: SFSpeechRecognitionResult) {
        pendingSoftRotate?.cancel(); pendingSoftRotate = nil
        Task { @MainActor in
            recognizedText = result.bestTranscription.formattedString
            partialResultSubject.send(recognizedText)
            partialContinuation.yield(recognizedText)
            print("[NativeSTT] partial – \(recognizedText)")
            restartStableTimer()

            if result.isFinal || Date().timeIntervalSince(segmentStart) > maxSegmentSeconds {
                emitFinal()
                rotate()
            }
        }
    }

    private func handle(error e: NSError) {
        
        print("[NativeSTT] DEBUG  domain=\(e.domain)  code=\(e.code)  desc=\(e.localizedDescription)")

        // 1) “No speech detected” → schedule (but let it be cancelled)
        if e.domain == "kAFAssistantErrorDomain",
           InternalErr.noSpeechCodes.contains(e.code) {

          noSpeechStrike += 1
         let delay = min(pow(2.0, Double(noSpeechStrike)) * 0.25, 4.0) // 0.25 s → 4 s
            print(String(format: "[NativeSTT] no speech – rotate in %.2f s", delay))

          pendingSoftRotate?.cancel()
          let work = DispatchWorkItem { [weak self] in
            self?.noSpeechStrike = 0                        // reset on success
            self?.rotate()
            self?.pendingSoftRotate = nil
          }
          pendingSoftRotate = work
          DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
          return
        }


      // 2) Daemon‐crashed (1101) → full reboot
      if e.domain == "kAFAssistantErrorDomain", e.code == InternalErr.svcCrash {
        print("[NativeSTT] recogniser service crashed – hard reboot")
        hardRebootRecognizer()
        return
      }

      // 3) Any other error → a normal rotate()
      print("[NativeSTT] fatal error – \(e.localizedDescription) – soft rotate")
      rotate()
    }
    
  private func emitFinal() {
    stableTimer?.cancel()
    let txt = recognizedText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard txt.count > 2 else {
      print("[NativeSTT] Ignored tiny chunk ⟨\(txt)⟩")
      return
    }
    print("[NativeSTT] FINAL  – \(txt)")
    finalResultSubject.send(txt)
  }

  private func rotate() {
    teardownTask()
    ignoreBuffers = false
    lastBufferHostTime = 0      // ← reset the silence‐timer anchor
    spinUpTask()
  }
    
    private func hardRebootRecognizer() {
      guard !isRebooting else { return }
      isRebooting = true
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
        self.isRebooting = false
      }
    }

  // ───────────── Timers ─────────────
  private func restartStableTimer() {
    stableTimer?.cancel()
    let snap = recognizedText
    stableTimer = DispatchSource.makeTimerSource(queue:.main)
    stableTimer?.schedule(deadline: .now() + stableTimeout)
    stableTimer?.setEventHandler { [weak self] in
      guard let self else { return }
      if recognizedText == snap { emitFinal(); rotate() }
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
