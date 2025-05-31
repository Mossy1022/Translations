//
//  NativeSTTService.swift
//  eWonicApp
//
//  Streams partial results in real-time, but also guarantees a final “chunk”
//  under three different conditions: Apple flags `isFinal`, the speaker pauses
//  for `silenceTimeout`, or the same partial stays unchanged for
//  `stableTimeout` (useful in noisy outdoor scenarios).
//

import Foundation
import AVFoundation
import Speech
import Combine

// ───────────── Error envelope ─────────────
enum STTError: Error, LocalizedError {
  case unavailable, permissionDenied, recognitionError(Error), taskError(String), noAudioInput

  var errorDescription: String? {
    switch self {
    case .unavailable:      return "Speech recognition is not available on this device or for the selected language."
    case .permissionDenied: return "Speech recognition permission was denied."
    case .recognitionError(let e): return "Recognition failed: \(e.localizedDescription)"
    case .taskError(let m): return m
    case .noAudioInput:     return "No audio input was detected or the input was too quiet."
    }
  }
}

// ───────────── Service ─────────────
@MainActor
final class NativeSTTService: NSObject, ObservableObject {

  // Engine plumbing
  private var speechRecognizer: SFSpeechRecognizer?
  private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
  private var recognitionTask: SFSpeechRecognitionTask?
  private let audioEngine = AVAudioEngine()

  // Timing / rotation
  private var segmentStart = Date()
  private let maxSegmentSeconds: TimeInterval = 120
  private var lastBufferHostTime: UInt64 = 0
  private let silenceTimeout: TimeInterval = 1.5          // long pause → endAudio()
  private let stableTimeout:  TimeInterval = 1.2          // same partial too long → final
  private var watchdogTimer:  DispatchSourceTimer?        // 55 min safety
  private var stableTimer:    DispatchSourceTimer?        // same-partial watchdog
  private var lastPartialText = ""

  // Public state
  @Published private(set) var isListening = false
  @Published var recognizedText = ""

  // Combine subjects
  let partialResultSubject = PassthroughSubject<String, Never>()
  let finalResultSubject   = PassthroughSubject<String, STTError>()

  private let noSpeechDetectedCode = 203    // Apple private

  // ───────────── Permissions ─────────────
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

  // ───────────── Setup ─────────────
  func setupSpeechRecognizer(languageCode: String) {
    let locale = Locale(identifier: languageCode)
    guard let recognizer = SFSpeechRecognizer(locale: locale) else {
      finalResultSubject.send(completion: .failure(.unavailable)); return
    }
    speechRecognizer = recognizer
    recognizer.delegate = self
    guard recognizer.isAvailable else {
      finalResultSubject.send(completion: .failure(.unavailable)); return
    }
    print("[NativeSTT] recognizer ready – lang: \(languageCode), on-device: \(recognizer.supportsOnDeviceRecognition)")
  }

  // ───────────── Start ─────────────
  func startTranscribing(languageCode: String) {
    guard !isListening else { return }

    setupSpeechRecognizer(languageCode: languageCode)
    guard let recognizer = speechRecognizer, recognizer.isAvailable else { return }

    recognitionTask?.cancel(); recognitionTask = nil
    AudioSessionManager.shared.begin()

    recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
    guard let request = recognitionRequest else { return }
    request.shouldReportPartialResults = true
    if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }

    // Long-running task watchdog
    segmentStart = Date()
    watchdogTimer?.cancel()
    watchdogTimer = DispatchSource.makeTimerSource(queue: .main)
    watchdogTimer?.schedule(deadline: .now() + 55*60)
    watchdogTimer?.setEventHandler { [weak self] in self?.rotateTask() }
    watchdogTimer?.resume()

    // Apple recogniser callback --------------------------------------
      recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self = self else { return }

            if let r = result {
              // 🛠 Hop to MainActor before touching properties
              Task { @MainActor [weak self] in
                guard let self else { return }

                recognizedText = r.bestTranscription.formattedString
                partialResultSubject.send(recognizedText)
                print("[NativeSTT] partial – \(recognizedText)")

                restartStableTimer()

                if r.isFinal { emitFinalAndContinue(); return }
                if Date().timeIntervalSince(segmentStart) > maxSegmentSeconds {
                  emitFinalAndContinue()
                }
              }
            }

            // error path – no actor-hop needed (we delegate to helper that hops)
            if let e = error as NSError? {
              Task { @MainActor [weak self] in
                guard let self else { return }
                stopTranscribing()
                if e.domain == "kAFAssistantErrorDomain", e.code == noSpeechDetectedCode {
                  finalResultSubject.send(completion: .failure(.noAudioInput))
                } else {
                  finalResultSubject.send(completion: .failure(.recognitionError(e)))
                }
              }
            }
          }


    // Mic tap – feed audio & silence detection -----------------------
    let node = audioEngine.inputNode
    let format = node.outputFormat(forBus: 0)
    guard format.sampleRate > 0 else {
      finalResultSubject.send(completion: .failure(.taskError("Invalid microphone format"))); return
    }

    node.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, when in
      self.recognitionRequest?.append(buffer)

      if self.lastBufferHostTime != 0 {
        let current = AVAudioTime.seconds(forHostTime: when.hostTime)
        let last    = AVAudioTime.seconds(forHostTime: self.lastBufferHostTime)
        if current - last >= self.silenceTimeout {     // long pause
          self.recognitionRequest?.endAudio()
        }
      }
      self.lastBufferHostTime = when.hostTime
    }

    do {
      audioEngine.prepare(); try audioEngine.start()
      isListening = true; recognizedText = "Listening…"
      print("[NativeSTT] audio engine started")
    } catch {
      finalResultSubject.send(completion: .failure(.recognitionError(error)))
      stopTranscribing()
    }
  }

  // ───────────── Stop ─────────────
  func stopTranscribing() {
    guard isListening else { return }
    isListening = false

    watchdogTimer?.cancel()
    stableTimer?.cancel()
    AudioSessionManager.shared.end()

    audioEngine.stop(); audioEngine.inputNode.removeTap(onBus: 0)
    recognitionRequest?.endAudio(); recognitionRequest = nil
    recognitionTask?.cancel();        recognitionTask  = nil
    print("[NativeSTT] stopped")
  }

  // ───────────── Helper: final emission ─────────────
  private func emitFinalAndContinue() {
    stableTimer?.cancel()

    let finalText = recognizedText.trimmingCharacters(in: .whitespacesAndNewlines)
    if finalText.count > 2 {                 // ignore “uh”, noise, etc.
      print("[NativeSTT] FINAL  – \(finalText)")
      finalResultSubject.send(finalText)
    } else {
      print("[NativeSTT] Ignored tiny chunk ⟨\(finalText)⟩")
    }
    rotateTask()
  }

  // ───────────── Helper: stable-partial timer ─────────────
  private func restartStableTimer() {
    stableTimer?.cancel()
    lastPartialText = recognizedText

    stableTimer = DispatchSource.makeTimerSource(queue: .main)
    stableTimer?.schedule(deadline: .now() + stableTimeout)
    stableTimer?.setEventHandler { [weak self] in
      guard let self else { return }
      if self.recognizedText == self.lastPartialText {   // unchanged
        self.emitFinalAndContinue()
      }
    }
    stableTimer?.resume()
  }

  // ───────────── Rotate recogniser (keeps mic live) ─────────────
  private func rotateTask() {
    recognitionRequest?.endAudio(); recognitionRequest = nil
    recognitionTask?.cancel();        recognitionTask  = nil
    stableTimer?.cancel()

    guard isListening, let recognizer = speechRecognizer else { return }
    recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
    guard let req = recognitionRequest else { return }
    req.shouldReportPartialResults = true
    if recognizer.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }

    segmentStart = Date(); lastBufferHostTime = 0

    recognitionTask = recognizer.recognitionTask(with: req) { [weak self] result, error in
      guard let self else { return }

      if let r = result {
        recognizedText = r.bestTranscription.formattedString
        partialResultSubject.send(recognizedText)
        print("[NativeSTT] partial – \(recognizedText)")
        restartStableTimer()

        if r.isFinal { emitFinalAndContinue() }
      }

      if let e = error {
        stopTranscribing()
        finalResultSubject.send(completion: .failure(.recognitionError(e)))
      }
    }
  }
}

// ───────────── Availability callback ─────────────
extension NativeSTTService: SFSpeechRecognizerDelegate {
  func speechRecognizer(_ recognizer: SFSpeechRecognizer, availabilityDidChange ok: Bool) {
    if !ok {
      isListening = false
      finalResultSubject.send(completion: .failure(.unavailable))
      print("[NativeSTT] recognizer became unavailable")
    } else {
      print("[NativeSTT] recognizer available again")
    }
  }
}
