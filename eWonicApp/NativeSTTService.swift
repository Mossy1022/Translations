//
//  NativeSTTService.swift
//  eWonicMVP
//
//  Created by Evan Moscoso on 5/18/25.
//

import Speech
import Combine

enum STTError: Error, LocalizedError {
    case unavailable
    case permissionDenied
    case recognitionError(Error)
    case taskError(String)
    case noAudioInput

    var errorDescription: String? {
        switch self {
        case .unavailable: return "Speech recognition is not available on this device or for the selected language."
        case .permissionDenied: return "Speech recognition permission was denied."
        case .recognitionError(let err): return "Recognition failed: \(err.localizedDescription)"
        case .taskError(let msg): return msg
        case .noAudioInput: return "No audio input was detected or the input was too quiet."
        }
    }
}

class NativeSTTService: ObservableObject {
    private var speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()

    @Published var isListening = false
    @Published var recognizedText: String = ""
    let partialResultSubject = PassthroughSubject<String, Never>() // For live updates
    let finalResultSubject = PassthroughSubject<String, STTError>()

    func setupSpeechRecognizer(languageCode: String) {
        let locale = Locale(identifier: languageCode)
        guard let recognizer = SFSpeechRecognizer(locale: locale) else {
            finalResultSubject.send(completion: .failure(.unavailable))
            return
        }
        self.speechRecognizer = recognizer
        self.speechRecognizer?.delegate = self // SFSpeechRecognizerDelegate for availability changes

        if !recognizer.isAvailable {
            finalResultSubject.send(completion: .failure(.unavailable))
            return
        }
        print("NativeSTTService: Speech recognizer setup for \(languageCode). On-device: \(recognizer.supportsOnDeviceRecognition)")
    }
    
    func requestPermission(completion: @escaping (Bool) -> Void) {
        SFSpeechRecognizer.requestAuthorization { authStatus in
            DispatchQueue.main.async {
                switch authStatus {
                case .authorized:
                    AVAudioSession.sharedInstance().requestRecordPermission { granted in
                        DispatchQueue.main.async {
                            completion(granted)
                        }
                    }
                default:
                    completion(false)
                }
            }
        }
    }

    func startTranscribing(languageCode: String) {
        guard !isListening else {
            print("NativeSTTService: Already listening.")
            return
        }
        
        setupSpeechRecognizer(languageCode: languageCode) // Ensure it's set up for the current language
        guard let speechRecognizer = self.speechRecognizer, speechRecognizer.isAvailable else {
            print("NativeSTTService: Speech recognizer not available or not setup.")
            finalResultSubject.send(completion: .failure(.unavailable))
            return
        }

        if recognitionTask != nil {
            recognitionTask?.cancel()
            recognitionTask = nil
        }

        let audioSession = AVAudioSession.sharedInstance()
        do {
            try audioSession.setCategory(.record, mode: .measurement, options: .duckOthers)
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            print("NativeSTTService: Audio session setup error: \(error)")
            finalResultSubject.send(completion: .failure(.recognitionError(error)))
            return
        }

        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let recognitionRequest = recognitionRequest else {
            fatalError("Unable to create an SFSpeechAudioBufferRecognitionRequest object")
        }
        recognitionRequest.shouldReportPartialResults = true
        if speechRecognizer.supportsOnDeviceRecognition {
             recognitionRequest.requiresOnDeviceRecognition = true // Prioritize on-device
        }


        let inputNode = audioEngine.inputNode
        recognitionTask = speechRecognizer.recognitionTask(with: recognitionRequest) { [weak self] result, error in
            guard let self = self else { return }
            var isFinal = false

            if let result = result {
                let bestTranscription = result.bestTranscription.formattedString
                self.recognizedText = bestTranscription
                self.partialResultSubject.send(bestTranscription) // Send partial result
                isFinal = result.isFinal
                print("NativeSTTService: Partial: \(bestTranscription)")
            }

            if error != nil || isFinal {
                self.stopTranscribing() // Also stops audioEngine
                if let error = error {
                    print("NativeSTTService: Recognition error: \(error!)")
                    if (error as NSError).code == SFSpeechErrorCode.noAudioDetected.rawValue {
                        self.finalResultSubject.send(completion: .failure(.noAudioInput))
                    } else {
                        self.finalResultSubject.send(completion: .failure(.recognitionError(error)))
                    }
                } else if isFinal, let finalResultText = self.recognizedText, !finalResultText.isEmpty {
                    print("NativeSTTService: Final: \(finalResultText)")
                    self.finalResultSubject.send(finalResultText)
                    self.finalResultSubject.send(completion: .finished) // Important to complete the subject
                } else if isFinal && (self.recognizedText == nil || self.recognizedText.isEmpty) {
                     print("NativeSTTService: Final result was empty.")
                     self.finalResultSubject.send(completion: .failure(.noAudioInput)) // Or a different error
                }
            }
        }

        let recordingFormat = inputNode.outputFormat(forBus: 0)
        // Check if format is valid (non-zero sample rate, etc.)
        guard recordingFormat.sampleRate > 0 else {
            print("NativeSTTService: Invalid recording format (sample rate is 0). Ensure microphone is available and permission granted.")
            finalResultSubject.send(completion: .failure(.taskError("Invalid audio recording format.")))
            stopTranscribing() // Clean up
            return
        }
        
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { (buffer, _) in
            self.recognitionRequest?.append(buffer)
        }

        audioEngine.prepare()
        do {
            try audioEngine.start()
            DispatchQueue.main.async {
                self.isListening = true
                self.recognizedText = "Listening..." // Initial state for UI
            }
            print("NativeSTTService: Audio engine started, listening...")
        } catch {
            print("NativeSTTService: Audio engine couldn't start: \(error)")
            finalResultSubject.send(completion: .failure(.recognitionError(error)))
            stopTranscribing()
        }
    }

    func stopTranscribing() {
        guard isListening else { return }
        
        DispatchQueue.main.async { // Ensure UI updates and engine stop are on main thread if they affect UI state
            self.isListening = false
        }

        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0) // Important!
        
        recognitionRequest?.endAudio() // Tell SFSpeechAudioBufferRecognitionRequest that audio is finished
        recognitionRequest = nil
        
        recognitionTask?.cancel() // Cancel if it's still running (e.g. user stopped early)
        recognitionTask = nil
        
        print("NativeSTTService: Transcription stopped.")
        
        // Reset audio session (optional, depending on app flow)
        // do {
        //     try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        // } catch {
        //     print("Audio session deactivation error: \(error)")
        // }
    }
}

extension NativeSTTService: SFSpeechRecognizerDelegate {
    func speechRecognizer(_ speechRecognizer: SFSpeechRecognizer, availabilityDidChange available: Bool) {
        if !available {
            DispatchQueue.main.async {
                self.isListening = false // Stop if it becomes unavailable
                self.finalResultSubject.send(completion: .failure(.unavailable))
            }
            print("NativeSTTService: Recognizer became unavailable.")
        } else {
            print("NativeSTTService: Recognizer became available.")
        }
    }
}
