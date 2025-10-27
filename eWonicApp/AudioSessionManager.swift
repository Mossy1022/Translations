import AVFoundation
import Combine

/// Centralised wrapper that keeps the system audio session in the
/// correct “full-duplex” state for simultaneous mic capture **and**
/// speaker playback.
///
/// • `.voiceChat` mode enables Apple’s built-in echo-cancelling DSP so
///   the recogniser won’t hear the device’s own TTS output.
/// • `.mixWithOthers` lets STT and TTS run together without either
///   being paused or ducked.
/// • Reference-counting guarantees `setActive( )` is only called once
///   for the first renter and balanced by the final `end( )`.
final class AudioSessionManager {
    static let shared = AudioSessionManager()

    private let session = AVAudioSession.sharedInstance()
    private var ref_count = 0
    let errorSubject = PassthroughSubject<String, Never>()
    private init() { configure() }
    
    /// Configure global category / mode once at launch.
    func configure() {
        do {
            try session.setCategory(
                .playAndRecord,
                mode: .voiceChat,
                options: [
                    .defaultToSpeaker,
                    .allowBluetoothHFP,
                    .mixWithOthers,
                    .allowAirPlay
                ])
            // Prefer sane I/O defaults up front (some routes will refine these later).
            try? session.setPreferredSampleRate(48_000)           // common HW rate on iOS
            try? session.setPreferredIOBufferDuration(0.0232)     // ~23ms is a good streaming target
            try? session.setPreferredInputNumberOfChannels(1)     // mono voice capture
        } catch {
            let msg = "Audio session category failed: \(error.localizedDescription)"
            print("❌ \(msg)")
            errorSubject.send(msg)
        }
    }

    
    /// Enter full-duplex mode (idempotent).
    /// Enter full-duplex mode (idempotent).
    func begin() {
        if ref_count == 0 {
            do {
                try session.setActive(true, options: [.notifyOthersOnDeactivation])
                // Re-assert I/O prefs *after* activation — some routes reset them on activate.
                try? session.setPreferredSampleRate(48_000)
                try? session.setPreferredIOBufferDuration(0.0232)
                try? session.setPreferredInputNumberOfChannels(1)
            } catch {
                let msg = "Audio session activate failed: \(error.localizedDescription)"
                print("❌ \(msg)")
                errorSubject.send(msg)
            }
        }
        ref_count += 1
    }

    
    func end() {
        guard ref_count > 0 else { return }
        ref_count -= 1
        if ref_count == 0 {
            do {
                try session.setActive(false, options: [.notifyOthersOnDeactivation])
            } catch let err as NSError {
                if let code = AVAudioSession.ErrorCode(rawValue: err.code), code == .isBusy {
                    // benign – mic or speaker still shutting down; let the next renter win
                    print("⚠️ Audio session still active; skipping deactivate")
                } else {
                    let msg = "Audio session deactivate failed: \(err.localizedDescription)"
                    print("❌ \(msg)")
                    errorSubject.send(msg)
                }
            }
        }
    }


    /// Adjust microphone sensitivity (0.0 – 1.0).
    func setInputGain(_ value: Float) {
        let clamped = max(0, min(1, value))
        guard session.isInputGainSettable else { return }
        do {
            try session.setInputGain(clamped)
        } catch {
            let msg = "Mic gain failed: \(error.localizedDescription)"
            print("❌ \(msg)")
            errorSubject.send(msg)
        }
    }

}

extension AudioSessionManager {
  var inputIsBluetooth: Bool {
    let inputs = session.currentRoute.inputs
    return inputs.contains { port in
      port.portType == .bluetoothHFP || port.portType == .bluetoothLE
    }
  }
}
