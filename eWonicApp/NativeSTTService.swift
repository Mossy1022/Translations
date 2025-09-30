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

    
  // MARK: – Published (same spelling!)
  @Published private(set) var isListening = false
  @Published var recognizedText = ""

    @Published var sensitivity: Float = 0.6     // default; set by ViewModel
    
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
      ignoreBuffers = false                 // ✅ re-open the tap gate
      lastBufferHostTime = 0

      setupSpeechRecognizer(languageCode: languageCode)
      guard speechRecognizer != nil else { return }

      AudioSessionManager.shared.begin()
      isListening    = true
      recognizedText = "Listening…"

      // Keep the UI responsive; do heavy work next tick.
      DispatchQueue.main.async { [weak self] in
        guard let self else { return }
        self.installTap()
        self.spinUpTask()
        print("[NativeSTT] audio engine started")
      }
    }

    func stopTranscribing() {
      guard isListening || !externallyQuiesced else { return }
      externallyQuiesced = true

      // Kill any pending restarts
      pendingSoftRotate?.cancel(); pendingSoftRotate = nil
      stableTimer?.cancel();        stableTimer       = nil
      watchdogTimer?.cancel();      watchdogTimer     = nil

      ignoreBuffers = true                  // pause tap immediately
      recognitionRequest?.endAudio()
      recognitionTask?.cancel()
      recognitionRequest = nil
      recognitionTask    = nil

      removeTap()
      do { audioEngine.reset() } catch { /* benign */ }

      isListening = false
      AudioSessionManager.shared.end()
      print("[NativeSTT] stopped")
    }
    
    private var ignoreBuffers = false

  // ───────────── Mic tap (unchanged behaviour) ─────────────
    private func installTap() {
      ignoreBuffers = false                 // ✅ make sure the tap is live
      let node = audioEngine.inputNode
      let fmt  = node.outputFormat(forBus: 0)
      node.removeTap(onBus: 0)

      node.installTap(onBus: 0, bufferSize: 1024, format: fmt) { [self] buf, when in
        guard !ignoreBuffers else { return }

        let threshold: Float = 0.004 + (1.0 - sensitivity) * 0.012
        let energy = buf.rmsEnergy

        if energy < threshold {
          if lastBufferHostTime != 0 {
            let now  = AVAudioTime.seconds(forHostTime: when.hostTime)
            let prev = AVAudioTime.seconds(forHostTime: lastBufferHostTime)
            if now - prev >= silenceTimeout {
              recognitionRequest?.endAudio()
              ignoreBuffers = true          // end this segment; mic will reopen on rotate()
            }
          }
          return
        }

        recognitionRequest?.append(buf)
        lastBufferHostTime = when.hostTime
      }

      do {
        audioEngine.prepare()
        try audioEngine.start()
      } catch {
        let msg = "Audio engine start failed: \(error.localizedDescription)"
        print("⚠️ \(msg)")
        errorSubject.send(.taskError(msg))
      }
    }


  private func removeTap() {
    audioEngine.stop()
    audioEngine.inputNode.removeTap(onBus: 0)
  }

  // ───────────── Task life-cycle ─────────────
    // In spinUpTask(), force on-device on iOS 26 and log it
    private func spinUpTask() {
      guard let recognizer = speechRecognizer else { return }

      recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
      // Try to force on-device when running on iOS 26+ (for languages that support it)
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
      recognitionTask    = nil

      // Cancel timers *and* pending soft-rotate so we don’t bounce back unexpectedly
      pendingSoftRotate?.cancel(); pendingSoftRotate = nil
      stableTimer?.cancel();         stableTimer      = nil
      watchdogTimer?.cancel();       watchdogTimer    = nil
    }


  // ───────────── Result / Error handlers ─────────────
    private func handle(result: SFSpeechRecognitionResult) {
        pendingSoftRotate?.cancel(); pendingSoftRotate = nil
        Task { @MainActor in
            recognizedText = result.bestTranscription.formattedString
            let snapshot = PartialSnapshot(text: recognizedText, timestamp: Date())
            partialResultSubject.send(recognizedText)
            partialSnapshotSubject.send(snapshot)
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
      if externallyQuiesced { return }

      print("[NativeSTT] DEBUG  domain=\(e.domain)  code=\(e.code)  desc=\(e.localizedDescription)")

      // Transient “busy/retry” conditions
      if e.domain == "kAFAssistantErrorDomain", [209,216].contains(e.code) {
        // Give CoreAudio/Speech daemon more room before we rotate
        errorSubject.send(.taskError("Speech service busy (code \(e.code)); retrying"))
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
        hardRebootRecognizer()
        return
      }

      errorSubject.send(.recognitionError(e))
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
    let boundary = StableBoundary(text: txt, timestamp: Date(), reason: "final")
    stableBoundarySubject.send(boundary)
    finalResultSubject.send(txt)
  }

    private func rotate() {
      // Don’t rotate if we were intentionally quiesced (e.g., during TTS)
      guard !externallyQuiesced else { return }
      teardownTask()
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
  private func restartStableTimer() {
    stableTimer?.cancel()
    let snap = recognizedText
    stableTimer = DispatchSource.makeTimerSource(queue:.main)
    stableTimer?.schedule(deadline: .now() + stableTimeout)
    stableTimer?.setEventHandler { [weak self] in
      guard let self else { return }
      if recognizedText == snap {
        let boundary = StableBoundary(text: snap, timestamp: Date(), reason: "stable")
        stableBoundarySubject.send(boundary)
        emitFinal(); rotate()
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
