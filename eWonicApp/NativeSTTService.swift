//
//  NativeSTTService.swift
//  eWonicApp
//
//  v7.4 – emits boundary reasons so listeners can choose safe commit points
//

import Foundation
import AVFoundation
import Speech
import Combine
import Accelerate

extension AVAudioPCMBuffer {
  var rmsEnergy: Float {
    guard let channelData = floatChannelData?[0] else { return 0 }
    let n = Int(frameLength)
    var mean: Float = 0
    vDSP_meamgv(channelData, 1, &mean, vDSP_Length(n))
    return sqrt(mean)
  }
}

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
  static let svcCrash                = 1101
}

@MainActor
final class NativeSTTService: NSObject, ObservableObject {

  // MARK: – Engine
  private var speechRecognizer: SFSpeechRecognizer?
  private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
  private var recognitionTask:   SFSpeechRecognitionTask?
  private let audioEngine = AVAudioEngine()

  // MARK: – Timers / state
  private var segmentStart               = Date()
  private var lastBufferHostTime: UInt64 = 0
  private var stableTimer:   DispatchSourceTimer?
  private var watchdogTimer: DispatchSourceTimer?
  private var pendingSoftRotate: DispatchWorkItem?

  // boundary tracking
  private var pendingBoundary: BoundaryReason?
  @Published private(set) var lastBoundaryReason: BoundaryReason = .asrFinal

  // tuned windows
  private var maxSegmentSeconds: TimeInterval = 8.0
  private let silenceTimeout:     TimeInterval = 1.5
  private let stableTimeout:      TimeInterval = 1.0

  @Published private(set) var isListening = false
  @Published var recognizedText = ""
  @Published var sensitivity: Float = 0.6

  let partialResultSubject = PassthroughSubject<String,Never>()
  let finalResultSubject   = PassthroughSubject<String,Never>()
  let errorSubject         = PassthroughSubject<STTError,Never>()

  public  let partialStream: AsyncStream<String>
  private let partialContinuation: AsyncStream<String>.Continuation
  private var streamCancellable: AnyCancellable?

  override init() {
    let (stream, cont) = AsyncStream<String>.makeStream(
      bufferingPolicy: .bufferingNewest(32)
    )
    partialStream       = stream
    partialContinuation = cont
    super.init()
    streamCancellable = partialResultSubject.sink { [cont] text in cont.yield(text) }
  }

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

  func setupSpeechRecognizer(languageCode: String) {
    guard let r = SFSpeechRecognizer(locale: Locale(identifier: languageCode)) else {
      errorSubject.send(.taskError("Speech recognizer unavailable for \(languageCode)"))
      return
    }
    speechRecognizer = r
    r.delegate = self
  }

  func startTranscribing(languageCode: String) {
    guard !isListening else { return }
    setupSpeechRecognizer(languageCode: languageCode)
    guard speechRecognizer != nil else { return }

    AudioSessionManager.shared.begin()
    isListening    = true
    recognizedText = "Listening…"

    installTap()
    spinUpTask()
  }

  func stopTranscribing() {
    guard isListening else { return }
    teardownTask()
    removeTap()
    isListening = false
    AudioSessionManager.shared.end()
  }

  private var ignoreBuffers = false

  private func installTap() {
    let node = audioEngine.inputNode
    let fmt  = node.outputFormat(forBus: 0)
    node.removeTap(onBus: 0)
    node.installTap(onBus: 0, bufferSize: 1024, format: fmt) { [self] buf, when in
      guard !ignoreBuffers else { return }

      // energy gate
      let energy = buf.rmsEnergy
      if energy < (0.02 + (1.0 - sensitivity) * 0.40) { return }

      // silence boundary
      if lastBufferHostTime != 0 {
        let now  = AVAudioTime.seconds(forHostTime: when.hostTime)
        let prev = AVAudioTime.seconds(forHostTime: lastBufferHostTime)
        if now - prev >= silenceTimeout {
          pendingBoundary = .silence
          recognitionRequest?.endAudio()
          ignoreBuffers = true
          return
        }
      }

      recognitionRequest?.append(buf)
      lastBufferHostTime = when.hostTime
    }

    do { audioEngine.prepare(); try audioEngine.start() }
    catch {
      errorSubject.send(.taskError("Audio engine start failed: \(error.localizedDescription)"))
    }
  }

  private func removeTap() {
    audioEngine.stop()
    audioEngine.inputNode.removeTap(onBus: 0)
  }

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

  private func handle(result: SFSpeechRecognitionResult) {
    pendingSoftRotate?.cancel(); pendingSoftRotate = nil

    Task { @MainActor in
      recognizedText = result.bestTranscription.formattedString
      partialResultSubject.send(recognizedText)
      partialContinuation.yield(recognizedText)
      restartStableTimer()

      let overTime = Date().timeIntervalSince(segmentStart) > maxSegmentSeconds
      if overTime || result.isFinal {
        if overTime && pendingBoundary == nil { pendingBoundary = .timeout }
        if result.isFinal && pendingBoundary == nil {
          pendingBoundary = endsWithTerminalPunct(recognizedText) ? .punctuation : .asrFinal
        }
        emitFinal()
        rotate()
      }
    }
  }

  private func handle(error e: NSError) {
    if e.domain == "kAFAssistantErrorDomain",
       InternalErr.noSpeechCodes.contains(e.code) {
      pendingSoftRotate?.cancel()
      let work = DispatchWorkItem { [weak self] in self?.rotate() }
      pendingSoftRotate = work
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
      return
    }

    if e.domain == "kAFAssistantErrorDomain", e.code == InternalErr.svcCrash {
      hardRebootRecognizer(); return
    }

    errorSubject.send(.recognitionError(e))
    rotate()
  }

  private func emitFinal() {
    stableTimer?.cancel()
    let txt = recognizedText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard txt.count > 2 else { pendingBoundary = nil; return }

    // finalize boundary reason
    let reason = pendingBoundary ?? (endsWithTerminalPunct(txt) ? .punctuation : .asrFinal)
    lastBoundaryReason = reason
    pendingBoundary = nil

    finalResultSubject.send(txt)
  }

  private func rotate() {
    teardownTask()
    ignoreBuffers = false
    lastBufferHostTime = 0
    spinUpTask()
    segmentStart = Date()
  }

  private func hardRebootRecognizer() {
    let currentLang = speechRecognizer?.locale.identifier ?? "en-US"
    teardownTask()
    removeTap()
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
      guard let self else { return }
      self.installTap()
      self.setupSpeechRecognizer(languageCode: currentLang)
      self.spinUpTask()
    }
  }

  private func restartStableTimer() {
    stableTimer?.cancel()
    let snap = recognizedText
    stableTimer = DispatchSource.makeTimerSource(queue:.main)
    stableTimer?.schedule(deadline: .now() + stableTimeout)
    stableTimer?.setEventHandler { [weak self] in
      guard let self else { return }
      if self.recognizedText == snap {
        self.pendingBoundary = .stable
        self.emitFinal()
        self.rotate()
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

  private func endsWithTerminalPunct(_ s: String) -> Bool {
    guard let ch = s.trimmingCharacters(in: .whitespacesAndNewlines).last else { return false }
    return ".!?;:…".contains(ch)
  }

  func partialTokensStream() -> AsyncStream<String> { partialStream }
}

extension NativeSTTService: SFSpeechRecognizerDelegate {
  func speechRecognizer(_ r:SFSpeechRecognizer, availabilityDidChange ok:Bool) {
    if !ok {
      isListening = false
      errorSubject.send(.unavailable)
    }
  }
}
