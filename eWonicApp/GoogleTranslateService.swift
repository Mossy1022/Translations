//
//  GoogleTranslateServic.swift
//  eWonicMVP
//
//  Created by Evan Moscoso on 5/18/25.
//

import AVFoundation

class AppleTTSService: ObservableObject {
    private let speechSynthesizer = AVSpeechSynthesizer()
    private var audioSessionActive = false

    init() {
        speechSynthesizer.delegate = self // To manage audio session deactivation
    }

    private func activateAudioSession() {
        guard !audioSessionActive else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .voiceChat, options: []) // .voiceChat allows mic to stay somewhat active if needed, or use .default
            try session.setActive(true)
            audioSessionActive = true
            print("AppleTTSService: Audio session activated for playback.")
        } catch {
            print("AppleTTSService: Failed to activate audio session for TTS: \(error.localizedDescription)")
        }
    }

    private func deactivateAudioSession() {
        guard audioSessionActive else { return }
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            audioSessionActive = false
            print("AppleTTSService: Audio session deactivated after playback.")
        } catch {
            print("AppleTTSService: Failed to deactivate audio session: \(error.localizedDescription)")
        }
    }

    func speak(text: String, languageCode: String) {
        activateAudioSession() // Activate session before speaking

        let utterance = AVSpeechUtterance(string: text)
        if let voice = AVSpeechSynthesisVoice(language: languageCode) {
            utterance.voice = voice
        } else {
            print("AppleTTSService: Warning - Could not find voice for language \(languageCode). Using default.")
            // Consider falling back to a default voice or informing the user.
            // For example, find a voice that matches the base language (e.g., "en" if "en-GB" not found)
            let baseLanguageCode = languageCode.components(separatedBy: "-").first ?? languageCode
            utterance.voice = AVSpeechSynthesisVoice(language: baseLanguageCode)
        }
        
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 1.0 // Adjust rate if needed
        utterance.volume = 1.0

        if speechSynthesizer.isSpeaking {
            speechSynthesizer.stopSpeaking(at: .immediate)
        }
        speechSynthesizer.speak(utterance)
        print("AppleTTSService: Attempting to speak '\(text)' in \(languageCode)")
    }

    func stopSpeaking() {
        if speechSynthesizer.isSpeaking {
            speechSynthesizer.stopSpeaking(at: .immediate)
            print("AppleTTSService: Speech stopped by request.")
        }
        deactivateAudioSession() // Ensure session is deactivated if stopped manually
    }
}

extension AppleTTSService: AVSpeechSynthesizerDelegate {
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        print("AppleTTSService: Finished speaking.")
        deactivateAudioSession()
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        print("AppleTTSService: Speech cancelled.")
        deactivateAudioSession()
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        print("AppleTTSService: Started speaking.")
    }
}
