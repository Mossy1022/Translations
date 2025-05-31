import AVFoundation

final class AudioSessionManager {
  static let shared = AudioSessionManager()
  private let session = AVAudioSession.sharedInstance()
  private var refCount = 0
  private init() { configure() }

  func configure() {
    try? session.setCategory(.playAndRecord,
                             mode: .spokenAudio,
                             options:[.defaultToSpeaker,
                                      .allowBluetooth,
                                      .allowBluetoothA2DP,
                                      .duckOthers])
  }

  func begin() {
    refCount += 1
    try? session.setActive(true)
  }

  func end() {
    refCount = max(0, refCount-1)
    if refCount == 0 {
      try? session.setActive(false,
                             options:.notifyOthersOnDeactivation)
    }
  }
}
