//
//  NativeSTTService.swift
//  eWonicApp
//
//  Created by Evan Moscoso on 5/18/25.
//

import Foundation
import AVFoundation
import Speech
import Combine

// MARK: – Speech‑to‑Text error envelope used by the rest of the app
enum STTError: Error, LocalizedError {
  case unavailable
  case permissionDenied
  case recognitionError(Error)
  case taskError(String)
  case noAudioInput

  var errorDescription: String? {
    switch self {
    case .unavailable:          return "Speech recognition is not available on this device or for the selected language."
    case .permissionDenied:     return "Speech recognition permission was denied."
    case .recognitionError(let e): return "Recognition failed: \(e.localizedDescription)"
    case .taskError(let msg):   return msg
    case .noAudioInput:         return "No audio input was detected or the input was too quiet."
    }
  }
}

/// Manages the AVAudioEngine + SFSpeechRecognizer pipeline and publishes
/// partial / final results via Combine.
///
/// Must inherit from `NSObject` – `SFSpeechRecognizerDelegate` in Objective‑C
/// extends `NSObjectProtocol`.
final class NativeSTTService: NSObject, ObservableObject {
  // MARK: – Private engine / recognizer plumbing
  private var speechRecognizer: SFSpeechRecognizer?
  private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
  private var recognitionTask: SFSpeechRecognitionTask?
  private let audioEngine = AVAudioEngine()

  // MARK: – State exposed to SwiftUI
  @Published private(set) var isListening = false
  @Published var recognizedText: String = ""

  // MARK: – Combine subjects
  let partialResultSubject = PassthroughSubject<String,Never>()
  let finalResultSubject   = PassthroughSubject<String,STTError>()

  // Apple (as of iOS 17) does not expose a Swift enum for the “no speech”
  // condition, only an integer code. 203 has been stable since iOS 10.
  private let noSpeechDetectedCode = 203

  // MARK: – Permission helpers
  func requestPermission(_ completion:@escaping (Bool)->Void) {
    SFSpeechRecognizer.requestAuthorization { auth in
      DispatchQueue.main.async {
        guard auth == .authorized else { completion(false); return }
        AVAudioSession.sharedInstance().requestRecordPermission { micOK in
          DispatchQueue.main.async { completion(micOK) }
        }
      }
    }
  }

  // MARK: – Recognizer configuration ------------------------------------------------
  func setupSpeechRecognizer(languageCode: String) {
    let locale = Locale(identifier: languageCode)
    guard let recognizer = SFSpeechRecognizer(locale: locale) else {
      finalResultSubject.send(completion: .failure(.unavailable))
      return
    }

    speechRecognizer = recognizer
    recognizer.delegate = self

    guard recognizer.isAvailable else {
      finalResultSubject.send(completion: .failure(.unavailable))
      return
    }

    print("[NativeSTT] recognizer ready – lang: \(languageCode), on‑device: \(recognizer.supportsOnDeviceRecognition)")
  }

  // MARK: – Start / Stop ------------------------------------------------------------
  func startTranscribing(languageCode: String) {
    guard !isListening else { print("[NativeSTT] already listening"); return }

    setupSpeechRecognizer(languageCode: languageCode)
    guard let recognizer = speechRecognizer, recognizer.isAvailable else { return }

    // Cancel any prior task
    recognitionTask?.cancel(); recognitionTask = nil

    do {
      let sess = AVAudioSession.sharedInstance()
      try sess.setCategory(.record, mode: .measurement, options: .duckOthers)
      try sess.setActive(true, options: .notifyOthersOnDeactivation)
    } catch {
      finalResultSubject.send(completion: .failure(.recognitionError(error)))
      return
    }

    // Build request & task ----------------------------------------------------------
    recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
    guard let req = recognitionRequest else { fatalError("Could not create SFSpeechAudioBufferRecognitionRequest") }
    req.shouldReportPartialResults = true
    if recognizer.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }

    recognitionTask = recognizer.recognitionTask(with: req) { [weak self] result, err in
      guard let self = self else { return }
      var isFinal = false

      if let r = result {
        let text = r.bestTranscription.formattedString
        self.recognizedText = text
        self.partialResultSubject.send(text)
        isFinal = r.isFinal
        print("[NativeSTT] partial – \(text)")
      }

      // Terminal path (either error or final)
      if err != nil || isFinal {
        self.stopTranscribing()

          if let e = err as NSError? {
            print("[NativeSTT] error – domain: \(e.domain) code: \(e.code)")
            if e.domain == "kAFAssistantErrorDomain" && e.code == self.noSpeechDetectedCode {
              self.finalResultSubject.send(completion: .failure(.noAudioInput))
            } else {
              self.finalResultSubject.send(completion: .failure(.recognitionError(e)))
            }
            return
          }


        // Success path – final produced
        if !self.recognizedText.isEmpty {
          self.finalResultSubject.send(self.recognizedText)
          self.finalResultSubject.send(completion: .finished)
          print("[NativeSTT] final – \(self.recognizedText)")
        } else {
          self.finalResultSubject.send(completion: .failure(.noAudioInput))
          print("[NativeSTT] final empty – treated as noAudioInput")
        }
      }
    }

    // Microphone tap ---------------------------------------------------------------
    let node   = audioEngine.inputNode
    let format = node.outputFormat(forBus: 0)
    guard format.sampleRate > 0 else {
      finalResultSubject.send(completion: .failure(.taskError("Invalid microphone format")))
      return
    }

    node.installTap(onBus: 0, bufferSize: 1024, format: format) { buf, _ in
      self.recognitionRequest?.append(buf)
    }

    audioEngine.prepare()
    do {
      try audioEngine.start()
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
          guard let self = self else { return }
          if self.isListening && self.recognizedText.count > 3 {
            print("[NativeSTT] ⏱ Timeout triggered – forcing final result")
            self.finalResultSubject.send(self.recognizedText)
            self.finalResultSubject.send(completion: .finished)
            self.stopTranscribing()
          }
        }

      DispatchQueue.main.async { self.isListening = true }
      recognizedText = "Listening…"
      print("[NativeSTT] audio engine started")
    } catch {
      finalResultSubject.send(completion: .failure(.recognitionError(error)))
      stopTranscribing()
    }
  }

  func stopTranscribing() {
    guard isListening else { return }
    DispatchQueue.main.async { self.isListening = false }

    audioEngine.stop()
    audioEngine.inputNode.removeTap(onBus: 0)

    recognitionRequest?.endAudio(); recognitionRequest = nil
    recognitionTask?.cancel();        recognitionTask  = nil
    print("[NativeSTT] stopped")
  }
}

// MARK: – Availability callbacks
extension NativeSTTService: SFSpeechRecognizerDelegate {
  func speechRecognizer(_ recognizer:SFSpeechRecognizer, availabilityDidChange available: Bool) {
    if !available {
      DispatchQueue.main.async { self.isListening = false }
      finalResultSubject.send(completion: .failure(.unavailable))
      print("[NativeSTT] recognizer became unavailable")
    } else {
      print("[NativeSTT] recognizer available again")
    }
  }
}
