**Invariants**
- Always `AVAudioSession(.playAndRecord, .voiceChat, mixWithOthers + defaultToSpeaker + BT + AirPlay)`.
- TTS and mic never overlap on the same device (explicit pause on `isSpeaking == true`).
- Treat `.isBusy` deactivation as benign; log and continue; do not present modals.
- **During TTS:** **do not pause the audio tap**; pause only processing/emit. This preserves the next phrase while TTS drains the queue.

**Echo / feedback**
- Never re-inject received TTS into STT (AEC + ref-count + explicit pause).
- Use route-aware grace; longer for Bluetooth.

**Mic sensitivity**
- RMS gate + (optionally) spectral tilt / noise floor estimate.
- Presets map UI → thresholds: Near / Table / Auditorium.
