import AVFoundation

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
    private init() { configure() }
    
    /// Configure global category / mode once at launch.
    func configure() {
        try? session.setCategory(
            .playAndRecord,
            mode: .voiceChat,
            options: [
                .defaultToSpeaker,
                .allowBluetooth,
                .allowBluetoothA2DP,
                .mixWithOthers,
                .allowAirPlay
            ])
    }
    
    /// Enter full-duplex mode (idempotent).
    func begin() {
        if ref_count == 0 {
            try? session.setActive(true, options: [.notifyOthersOnDeactivation])
        }
        ref_count += 1
    }
    
    func end() {
        guard ref_count > 0 else { return }
        ref_count -= 1
        if ref_count == 0 {
            try? session.setActive(false, options: [.notifyOthersOnDeactivation])
        }
    }
}
