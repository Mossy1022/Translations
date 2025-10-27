# eWonic Translation App - Architecture Guide

## Project Overview

**eWonic** is a real-time bidirectional translation iOS app supporting three operation modes:
1. **Peer Mode**: Multi-device translation (up to 6 devices) with full offline capability on iOS 26+
2. **One Phone Mode**: Single-device conversation mode with automatic language detection
3. **Convention Mode**: One-to-many broadcasting (host speaks, listeners receive translations)

The app **prioritizes offline operation** on iOS 26+ devices using Apple's on-device Speech Recognition and Translation frameworks. For older devices or network availability, it falls back to cloud services (Azure Speech/Translation). All audio output uses Apple AVSpeechSynthesizer for local text-to-speech.

---

## Core Architecture

### Primary Components

#### 1. **TranslationViewModel** (`TranslationViewModel.swift`)
**Purpose**: Central state manager and orchestrator for all translation workflows

**Public API**:
```swift
@MainActor
final class TranslationViewModel: ObservableObject {
  // Mode management
  enum Mode { case peer, onePhone, convention }
  @Published var mode: Mode
  @Published var isConventionHost: Bool

  // Services
  @Published var multipeerSession: MultipeerSession
  @Published var sttService: AzureSpeechTranslationService
  @Published var autoService: AzureAutoConversationService
  @Published var ttsService: AppleTTSService

  // UI State
  @Published var myTranscribedText: String
  @Published var peerSaidText: String
  @Published var translatedTextForMeToHear: String
  @Published var connectionStatus: String
  @Published var isProcessing: Bool
  @Published var errorMessage: String?

  // Language & Voice
  @Published var myLanguage: String
  @Published var peerLanguage: String
  @Published var voice_for_lang: [String: String]

  // Settings
  @Published var micSensitivity: Double
  @Published var playbackSpeed: Double

  // One-Phone State
  @Published var localTurns: [LocalTurn]
  @Published var leftDraft: String
  @Published var rightDraft: String
  @Published var isAutoListening: Bool

  // Control methods
  func startListening()
  func stopListening()
  func startAuto()
  func stopAuto()
  func checkAllPermissions()
}
```

**State Management**:
- **Peer/Convention**: Tracks turn sequences (`turnId`, `seqCounter`) for message ordering
- **Convention chunking**: Uses `TurnContext` to commit speech every ~5 seconds with structural validation
- **One-Phone**: Maintains `TurnContext` with language voting, phrase queue with translation cache
- **Early TTS**: Streams partial translations in 8-second chunks (Peer mode only)

**Key Flows**:

1. **Peer Mode (iOS 26+ Offline)**:
   - **Sender**: User A presses "Start" → `NativeSTTService` captures mic (on-device)
   - **Broadcasting**: Sends RAW text to all connected peers (up to 6) via MultipeerSession
   - **Receivers**: Each peer receives RAW text → `AppleOnDeviceTranslator` translates locally → `AppleTTSService` speaks
   - **Early-TTS**: Streams translations at sentence boundaries every 8s for low latency
   - **Fully Offline**: No network/Azure calls when all peers are iOS 26+ (`useOfflinePeer` = true)
   - **Fallback**: Pre-iOS 26 devices use `AzureSpeechTranslationService` (cloud-based)

2. **Convention Mode (Host)**:
   - Host captures speech (speaker language = `peerLanguage`)
   - Commits chunks every 5s with linguistic validation (verb presence, no hanging connectors)
   - Broadcasts RAW chunks to all connected listeners
   - Listeners translate locally and speak

3. **One-Phone Mode**:
   - Auto-detects language per utterance using `TurnContext` voting
   - Phrases queued → translated asynchronously → spoken in sequence
   - De-duplication via `spokenLRU` to prevent replays

**External Services**:
- Azure Speech Translation (cloud, pre-iOS 26)
- Native STT Service (iOS 26+, on-device)
- Azure Text Translator (for final translation refinement)
- UnifiedTranslateService (wrapper for translation APIs)
- AppleTTSService (local voice synthesis)

**Error Paths**:
- Permission failures → `hasAllPermissions = false`, blocks mic access
- Network errors from Azure → auto-retry with user notification
- Multipeer disconnects → stops listening, shows "Not Connected"
- STT errors → logged, trigger service restart or mode fallback

---

#### 2. **MultipeerSession** (`MultipeerSession.swift`)
**Purpose**: Peer-to-peer networking using Apple MultipeerConnectivity framework

**Public API**:
```swift
final class MultipeerSession: ObservableObject {
  @Published private(set) var connectedPeers: [MCPeerID]
  @Published private(set) var discoveredPeers: [MCPeerID]
  @Published private(set) var peerLanguages: [MCPeerID: String]
  @Published private(set) var connectionState: MCSessionState
  @Published private(set) var peerOfflineCapable: [MCPeerID: Bool]
  @Published var wireMode: WireMode // .peer or .convention
  @Published var isHost: Bool

  func startHosting()
  func stopHosting()
  func startBrowsing()
  func stopBrowsing()
  func invitePeer(_ id: MCPeerID)
  func disconnect()
  func send(message: MessageData, reliable: Bool)
  func updateMode(_ mode: String, isHost: Bool)

  var onMessageReceived: ((MessageData) -> Void)?
}
```

**Discovery Info Advertised**:
```swift
["lang": localLanguage, "o26": isIOS26Plus ? "1" : "0",
 "mode": "peer" | "convention", "role": "host" | "listener" | "peer"]
```

**Message Protocol**: JSON-encoded `MessageData` compressed with zlib:
```swift
struct MessageData: Codable {
  let id: UUID
  let turnId: UUID?        // groups chunks in a turn
  let seq: Int?            // ordering within turn
  let originalText: String // RAW speaker text
  let sourceLanguageCode: String
  let isFinal: Bool
  let timestamp: TimeInterval
  let mode: String?
}
```

**Key Behaviors**:
- **Peer Limit**: Supports up to 6 simultaneous connections (`MultipeerSession.peerLimit = 6`)
- **Offline Capability Detection**: Advertises iOS 26+ capability via `"o26": "1"` in discovery info
- **Auto-Discovery Quiesce**: Stops advertising/browsing once connected (reduces radio/battery usage)
- **Connection State**: Tracks `peerOfflineCapable[MCPeerID]` to determine if full offline mode is available
- **Mode-Aware**: Convention listeners are receive-only (no mic access), peers have full duplex

---

#### 3. **Speech Services**

**AzureSpeechTranslationService** (`AzureSpeechTranslationService.swift`):
- Cloud-based STT + MT (pre-iOS 26 fallback)
- Streams partial translations (`partialResult`)
- Emits RAW source partials (`sourcePartialResult`) for Peer broadcasting
- Auto-reconnects on cancellation/network errors

**NativeSTTService** (`NativeSTTService.swift`):
- iOS 26+ on-device speech recognition (no cloud dependency)
- Features:
  - Energy-based voice activity detection with hysteresis
  - Auto-rotation every ~120s or after silence (1.5s timeout)
  - Stable boundary detection (1s of no-change + structural validation)
  - Far-field boost mode for Convention (lowers threshold 35%)
- Subjects: `partialResultSubject`, `finalResultSubject`, `partialSnapshotSubject`, `stableBoundarySubject`

**AppleTTSService** (`AppleTTSService.swift`):
- AVSpeechSynthesizer wrapper
- Per-language voice selection
- Rate control (0-1 normalized → actual rate via multiplier)
- Playback management with pause/resume hooks

---

#### 4. **UI Layer** (`ContentView.swift`)

**Structure**:
```
ContentView
├── Header_bar
├── ModePicker (Peer | One Phone | Convention)
├── Connection_pill (status indicator)
├── Mode-specific screens:
│   ├── PeerDiscoveryView (Host/Join buttons)
│   ├── Peer screen (Language_bar, Voice_bar, Conversation_scroll, Settings_sliders, Record_button)
│   ├── ConventionDiscoveryView
│   ├── ConventionScreen (Host: mic controls, Listener: passive)
│   └── OnePhoneConversationScreen (dual LanguageTiles, MicButton, turn cards)
└── ErrorBanner
```

**One-Phone Screen**:
- Dual language tiles with inline text input + language picker
- Auto-listening mode with mic button (start/stop)
- Scrolling conversation history with replay buttons
- Voice & speed settings sheet

---

## Offline Architecture (iOS 26+)

### Overview
eWonic **prioritizes offline operation** when all connected devices run iOS 26+. This provides:
- ✅ Zero network latency
- ✅ Privacy (no data leaves devices)
- ✅ Works in airplane mode or poor connectivity
- ✅ No API costs

### Offline Mode Detection

**`useOfflinePeer` Property** (TranslationViewModel.swift:178-183):
```swift
private var useOfflinePeer: Bool {
  if #available(iOS 26.0, *) {
    // ALL connected peers must be iOS 26+ for full offline mode
    return multipeerSession.connectedPeers.allSatisfy { p in
      multipeerSession.peerOfflineCapable[p] == true
    }
  }
  return false
}
```

**Logic**:
- Each device advertises its capability: `"o26": isIOS26Plus ? "1" : "0"`
- Receivers track this in `peerOfflineCapable: [MCPeerID: Bool]`
- Offline mode activates **only if ALL peers are iOS 26+**
- Mixed sessions (iOS 26 + older) fall back to Azure cloud services

### Offline Service Stack

| **Layer** | **iOS 26+ (Offline)** | **Pre-iOS 26 (Fallback)** |
|-----------|----------------------|---------------------------|
| **STT** | `NativeSTTService` (Apple Speech) | `AzureSpeechTranslationService` |
| **Translation** | `AppleOnDeviceTranslator` (Translation framework) | `AzureTextTranslator` (cloud) |
| **TTS** | `AppleTTSService` (AVSpeechSynthesizer) | `AppleTTSService` (same) |

**UnifiedTranslateService** (automatic routing):
```swift
enum UnifiedTranslateService {
  static func translate(_ text: String, from src: String, to dst: String) async throws -> String {
    if #available(iOS 26.0, *) {
      // iOS 26+: strictly on-device via Translation framework
      return try await AppleOnDeviceTranslator.shared.translate(text, from: src, to: dst)
    } else {
      // Older OS: Azure Text Translator (cloud)
      return try await AzureTextTranslator.translate(text, from: src, to: dst)
    }
  }
}
```

### Peer Mode Offline Flow

**1. Sender (Device A - iOS 26+)**:
```
User taps "Start"
  ↓
NativeSTTService.startTranscribing(languageCode: myLanguage)
  ↓
Mic audio → Apple Speech Recognition (on-device)
  ↓
partialResultSubject emits RAW text every 200ms
  ↓
sendRawToPeers(text, isFinal: false) → MultipeerSession
  ↓
Broadcasts to ALL connected peers (up to 6)
```

**2. Receivers (Devices B, C, D... - iOS 26+)**:
```
MultipeerSession receives MessageData
  ↓
handleReceivedMessage() → deliverMessage()
  ↓
UnifiedTranslateService.translate(raw, from: peerLang, to: myLang)
  ↓
AppleOnDeviceTranslator (Translation framework - offline)
  ↓
translatedTextForMeToHear = result
  ↓
AppleTTSService.speak(result, languageCode: myLang)
```

**3. Early-TTS Streaming**:
- Partials chunked at sentence boundaries (`.?!…`)
- 8-second timeout for mid-speech bailout
- Avoids waiting for complete utterance before speaking
- Reduces perceived latency in long speeches

### Translation Framework Integration

**AppleOnDeviceTranslator** (iOS 26+):
```swift
@available(iOS 26.0, *)
final class AppleOnDeviceTranslator {
  func translate(_ text: String, from src: String, to dst: String) async throws -> String {
    let req = TranslationSession.Request(
      sourceText: text,
      clientIdentifier: UUID().uuidString
    )
    let responses = try await SessionBroker.shared.responses(
      src: normalize(src),
      dst: normalize(dst),
      requests: [req]
    )
    return responses.first?.targetText ?? text
  }
}
```

**SessionBroker**:
- Manages Translation framework sessions
- Handles language pair caching
- Downloads models on-demand (first use per language pair)
- Models stored locally for subsequent offline use

### Offline Indicators

**UI Status Line** (TranslationViewModel.swift:1701-1703):
```swift
var connectionBadge: String {
  if mode == .peer && multipeerSession.connectionState == .connected {
    if useOfflinePeer { return "Connected · On-Device" }  // ← iOS 26+ all peers
    return "Connected to \(multipeerSession.connectedPeers.first?.displayName ?? "Peer")"
  }
  // ...
}
```

Users see **"Connected · On-Device"** when full offline mode is active.

### Performance Characteristics

| **Metric** | **Offline (iOS 26+)** | **Cloud (Azure)** |
|------------|----------------------|-------------------|
| **STT Latency** | ~100-200ms | ~300-500ms |
| **MT Latency** | ~50-150ms | ~200-400ms |
| **Total RTT** | ~150-350ms | ~500-900ms |
| **Network** | None (Multipeer only) | Continuous internet |
| **Battery** | Lower (no radio for STT/MT) | Higher (4G/5G data) |
| **Privacy** | Full (local processing) | Data sent to Azure |

### Limitations & Edge Cases

**1. Mixed Device Versions**:
- If any peer is pre-iOS 26, **all devices** fall back to Azure
- Trade-off: consistency over partial offline support
- Prevents translation quality mismatches

**2. Model Availability**:
- Translation framework requires language models
- First-time use prompts download (requires internet once)
- Subsequent uses fully offline
- Fallback to Azure if model unavailable

**3. Language Support**:
- Translation framework supports fewer languages than Azure
- App's `availableLanguages` list curated for offline support
- Unsupported pairs gracefully fall back to cloud

**4. Multipeer Range**:
- WiFi Direct: ~30m / 100ft (typical indoor)
- Bluetooth LE: ~10m / 30ft (fallback)
- No internet needed, but devices must be physically proximate

---

## Translation Pipeline Details

### Convention Mode Linguistic Validation

**Structural Completeness Check** (`isStructurallyComplete`):
```swift
func isStructurallyComplete(_ text: String, base: String,
                           langCode: String, minChars: Int) -> Bool {
  guard text.count >= minChars else { return false }
  if endsWithConnector(text, base: base) { return false }  // "and", "pero", "et"
  if subordinatorOpensClause(text, base: base) && !hasVerb(text, languageCode: langCode) {
    return false  // "although..." without verb → incomplete
  }
  return true
}
```

- **Connector detection**: Language-aware lists (EN/ES/FR/DE) to avoid mid-clause cuts
- **Verb presence**: Uses NSLinguisticTagger to ensure utterance has verb if subordinator present
- **Tail stability**: Buffers recent partials (300ms window) to confirm last 3 tokens unchanged

**Chunk Commit Strategy**:
1. Try sentence boundary (`.?!…`)
2. Fallback to word boundary near end (last 100 chars)
3. Emergency fallback at 1.7× interval if no clean cut found

---

## Error Handling & Edge Cases

### Dupli Deduplication:
- **Near-duplicate detection**: 85% Jaccard similarity or strong prefix match
- **Spoken LRU cache**: Tracks last 32 spoken texts for 8s window
- **Turn sequencing**: Out-of-order messages buffered and reassembled

### Audio Route Changes:
- NativeSTT adjusts thresholds for Bluetooth vs built-in mic
- Full engine reset on rotation to avoid zero-size buffers

### Network Resilience:
- Azure auto-reconnects on cancellation
- Multipeer shows error banner on disconnect
- UnifiedTranslateService retries with exponential backoff

---

## Configuration & Settings

**Secrets** (stored in `Info.plist` from `Secrets.xcconfig`):
- `AZ_KEY`: Azure Speech API key
- `AZ_REGION`: Azure region (e.g., "eastus")

**Supported Languages** (`availableLanguages`):
```swift
["en-US", "es-US", "es-MX", "es-ES", "fr-FR", "de-DE", "ja-JP", "zh-CN"]
```

**Tunables** (in TranslationViewModel):
- `phraseStableCutoff: 1.3s` – delay before committing phrase
- `phraseLongSpeechCap: 7.0s` – max phrase length before forced commit
- `conventionChunkSeconds: 5.0s` – interval between Convention chunks
- `minConventionCommitChars: 12` – minimum chunk length
- `earlyTTSBailSeconds: 8s` – timeout for early TTS chunk emission
- `earlyTTSMinChunkChars: 24` – min chars to speak partial

---

## Data Structures

### TurnContext
```swift
struct TurnContext {
  var rollingText: String
  var lockedSrcBase: String?
  var votes: LangVotes
  var startedAt: Date
  var lastGrowthAt: Date
  var committed: Bool
  var flipUsed: Bool
}
```
Used in One-Phone mode to track phrase boundaries and language detection.

### PhraseCommit
```swift
struct PhraseCommit {
  let id: UUID
  let text: String
  let srcBase: String
  let dstCode: String
  let srcCode: String
  let timestamp: TimeInterval
}
```
Queued phrase awaiting translation in One-Phone mode.

### LocalTurn (One-Phone History)
```swift
struct LocalTurn {
  let id: UUID
  let sourceLang: String
  let sourceText: String
  let targetLang: String
  let translatedText: String
  let timestamp: TimeInterval
}
```

---

## Testing & Debugging

**Debug Mode** (`debugMode: Bool`):
- Enables `DebugQueueHUD` overlay showing phrase queue state
- Logs breadcrumbs: `CAPTURE_START`, `PHRASE_COMMIT`, `DROP_TINY`, etc.
- Visual indicators: Queued (Q), Speaking (▶), Done (✓)

**Common Issues**:
1. **"Dictation disabled" error**: Enable Settings > General > Keyboard > Dictation
2. **Peer not found**: Check WiFi/Bluetooth enabled, devices on same network
3. **No on-device recognition**: Language may not support offline (fallback to Azure)
4. **TTS skipping text**: Check `spokenLRU` dedup logic or `allowSpeakAndMark` gate

---

## File Structure Summary

```
eWonicApp/
├── TranslationViewModel.swift    # Core orchestrator (2193 lines)
├── ContentView.swift              # SwiftUI screens
├── MultipeerSession.swift         # P2P networking
├── MessageData.swift              # Wire protocol
├── AzureSpeechTranslationService.swift  # Cloud STT+MT
├── NativeSTTService.swift         # iOS 26+ on-device STT
├── AppleTTSService.swift          # Local TTS
├── UnifiedTranslateService.swift  # Translation API wrapper
├── AzureAutoConversationService.swift  # One-Phone auto mode
├── AudioSessionManager.swift      # AVAudioSession lifecycle
├── TurnContext.swift              # Phrase state tracking
├── SessionBroker.swift            # (unused legacy)
├── LanguageGuesser.swift          # Auto-detection helpers
├── Theme.swift                    # Color constants
├── Log.swift                      # Logging utilities
└── OnboardingView.swift           # Initial setup
```

---

## Future Considerations

- **✅ Offline Translation**: **IMPLEMENTED** - Using Apple Translation framework (iOS 26+)
- **Conversation Export**: Save `localTurns` to JSON/PDF for record-keeping
- **Advanced VAD**: Replace RMS energy with ML-based voice activity detection (e.g., Silero VAD)
- **Multi-speaker Convention**: Track individual speakers with speaker diarization (e.g., pyannote)
- **Mesh Networking**: Extend range beyond single-hop Multipeer (relay messages through intermediate devices)
- **Translation Quality Metrics**: Track BLEU scores or user corrections to improve language pair selection
- **Offline Model Pre-caching**: Download all translation models during onboarding for guaranteed offline operation

---

**Generated with Claude Code**
Last updated: 2025-01-16
