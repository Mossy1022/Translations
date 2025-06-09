//
//  AzureSpeechTranslationService.swift
//  eWonicApp
//
//  Online STT → translation → (optional) TTS pipeline powered by Azure Cognitive Services.
//  Mirrors NativeSTTService so the VM can hot-swap either implementation.
//

import Foundation
import Combine
import AVFoundation
import Speech
import MicrosoftCognitiveServicesSpeech

@MainActor
final class AzureSpeechTranslationService: NSObject, ObservableObject {
    
    // ─────────────────────────────────────────────
    // MARK: – Secrets
    // ─────────────────────────────────────────────
    private let AZ_KEY: String = {
        guard let k = Bundle.main.object(forInfoDictionaryKey: "AZ_KEY") as? String
        else { fatalError("AZ_KEY missing from Info.plist") }
        return k.trimmingCharacters(in: .whitespacesAndNewlines)
    }()
    
    private let AZ_REGION: String = {
        guard let r = Bundle.main.object(forInfoDictionaryKey: "AZ_REGION") as? String
        else { fatalError("AZ_REGION missing from Info.plist") }
        return r.trimmingCharacters(in: .whitespacesAndNewlines)
    }()
    
    // ─────────────────────────────────────────────
    // MARK: – Public surface
    // ─────────────────────────────────────────────
    @Published private(set) var isListening = false
    @Published              var recognizedText = ""
    
    let  partialResult = PassthroughSubject<String, Never>()
    let  finalResult   = PassthroughSubject<String, Never>()
    let  sourceFinalResult   = PassthroughSubject<String,Never>()   // **raw** full sentence
    let  audioChunk    = PassthroughSubject<Data,   Never>()   // TTS bytes
    
    private let partialStreamCont : AsyncStream<String>.Continuation
    public  let partialStream     : AsyncStream<String>
    
    private var recognizer : SPXTranslationRecognizer?
    private var dstLang2   = "es"      // 2-letter, used by SDK
    
    override init() {
        let (s,c)         = AsyncStream<String>.makeStream(bufferingPolicy:.bufferingNewest(64))
        partialStream     = s
        partialStreamCont = c
        super.init()
    }
    
    // ─────────────────────────────────────────────
    // MARK: – Permissions
    // ─────────────────────────────────────────────
    func requestPermission(_ done:@escaping(Bool)->Void) {
        SFSpeechRecognizer.requestAuthorization { auth in
            DispatchQueue.main.async {
                guard auth == .authorized else { done(false); return }
                AVAudioSession.sharedInstance().requestRecordPermission { micOK in
                    DispatchQueue.main.async { done(micOK) }
                }
            }
        }
    }
    
    func setupSpeechRecognizer(languageCode: String) { /* noop – kept for API parity */ }
    
    // ─────────────────────────────────────────────
    // MARK: – Continuous STT → translation
    // ─────────────────────────────────────────────
    /// `src` and `dst` **must** be full BCP-47 strings, e.g. “en-US”, “es-ES”.
    func start(src:String = "en-US", dst:String = "es-ES") {
        guard !isListening else { return }
        do {
            let cfg = try SPXSpeechTranslationConfiguration(subscription: AZ_KEY,
                                                            region: AZ_REGION)
            cfg.speechRecognitionLanguage = src
            dstLang2 = String(dst.prefix(2).lowercased())
            cfg.addTargetLanguage(dstLang2)
            if let v = voice(for: dst) { cfg.speechSynthesisVoiceName = v }
            
            recognizer = try SPXTranslationRecognizer(
                speechTranslationConfiguration: cfg,
                audioConfiguration: try SPXAudioConfiguration())
            
            hookEvents()
            try recognizer?.startContinuousRecognition()
            isListening = true
        } catch { print("❌ Azure recognizer failed: \(error)") }
    }
    
    func stop() {
        guard isListening else { return }
        try? recognizer?.stopContinuousRecognition()
        recognizer = nil
        isListening = false
    }
    
    // ─────────────────────────────────────────────
    // MARK: – Internal event wiring
    // ─────────────────────────────────────────────
    private func hookEvents() {
        // incremental translation tokens → UI
        recognizer!.addRecognizingEventHandler { [weak self] _, ev in
            guard let self,
                  let tx = ev.result.translations[self.dstLang2] as? String else { return }
            partialResult.send(tx)
        }
        
        // sentence complete → both raw + translated
        recognizer!.addRecognizedEventHandler { [weak self] _, ev in
            guard let self else { return }
            let raw = ev.result.text ?? ""
            if let tx = ev.result.translations[self.dstLang2] as? String {
                finalResult.send(tx)
            }
            if !raw.isEmpty { sourceFinalResult.send(raw) }
        }
        
        // synthesized‑audio passthrough (optional)
        recognizer!.addSynthesizingEventHandler { [weak self] _, ev in
            guard let self, let data = ev.result.audio else { return }
            audioChunk.send(data)
        }
        
        recognizer!.addCanceledEventHandler { _, ev in
            print("⚠️  Azure canceled (\(ev.errorCode.rawValue)) – \(ev.errorDetails)")
        }
    }




  private func voice(for locale:String) -> String? {
    switch locale.lowercased() {
      case "es-es": return "es-ES-AlvaroNeural"
      case "en-us": return "en-US-JennyNeural"
      default:      return nil                              // skip if unknown
    }
  }
    

  // MARK: – Stream helper (VM compatibility)
  func partialTokensStream() -> AsyncStream<String> { partialStream }
  func stopTranscribing()            { stop() }
}
