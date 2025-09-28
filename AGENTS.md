Here’s a ready-to-drop **AGENTS.md** tailored for ChatGPT Codex to build out the robust, offline-first EN↔ES iOS app you’ve defined.

---

# AGENTS.md

> Coordination file for AI coding agents working on **eWonic** (iOS 26+, offline-first EN↔ES).
>
> **Goal:** Implement a reliable, eyes-up, natural conversation translator with strict runtime guardrails.
>
> **Source of truth for behavior:**
> `docs/`
> • Turn Engine.md • Audio Rules.md • Emission.md • Auto Detect.md • P2P Messages.md • Tunables.md • Known Failures.md • Test Matrix.md • Product Vision Condensed.md

---

## 0) Mission (do this, not that)

* **Do:** Implement the offline **One-Phone** flow (phrase commit + per-phrase language lock + PhraseQueue), and the **Peer** flow (exactly-once messaging with sequencing).
* **Do:** Enforce invariants (floor control, no echo, sentence-safe emission) and acceptance bars.
* **Do:** Keep the app fully **usable without looking at the screen**; use haptics for flow cues.
* **Do not:** Add cloud dependencies, analytics that capture transcript, or change product scope beyond EN↔ES offline-first.

---

## 1) Scope & Repo Map

**Working language:** Swift (iOS 26 APIs allowed), small JSON/Plist edits okay.
**Edit only:** `eWonicApp/**/*.swift`, `eWonicApp/Info.plist`, and `docs/*.md` (when tunables change).
**Do not edit:** app icons, signing/provisioning, `Secrets.xcconfig` semantics, Pods, build settings.
**Key files:**

  * `eWonicApp/TranslationViewModel.swift` — orchestration brain
  * `eWonicApp/NativeSTTService.swift` — on‑device ASR (iOS 26)
  * `eWonicApp/AppleOnDeviceTranslator.swift` + `eWonicApp/SessionBroker.swift` — on‑device MT
  * `eWonicApp/AppleTTSService.swift` — TTS w/ normalized rate + preferred voices
  * `eWonicApp/AudioSessionManager.swift` — AVAudioSession policy + ref‑counts
  * `eWonicApp/MultipeerSession.swift` — P2P transport
  * `eWonicApp/ContentView.swift`, `eWonicApp/OnboardingView.swift` — shells
  * `eWonicApp/Azure*` — pre‑26 paths (keep compiling; don’t expand)


**Do not edit:**

* App icons, assets (except adding new haptic identifiers or strings), signing/provisioning, 3rd-party sdk binary settings, Secrets.xcconfig semantics.

**Known files (key ones):**

* `TranslationViewModel.swift` — orchestration brain
* `NativeSTTService.swift` — on-device ASR (iOS 26)
* `AppleOnDeviceTranslator.swift` + `SessionBroker.swift` — on-device MT
* `AppleTTSService.swift` — TTS with normalized rate + preferred voices
* `AudioSessionManager.swift` — AVAudioSession policy + ref counts
* `MultipeerSession.swift` — P2P transport
* `Azure*` files — pre-26 paths (keep compiling, but **do not expand**)
* `ContentView.swift` / `OnboardingView.swift` — UI shells

---

## 2) Hard Guardrails (must not break)

1. **Floor control:** at TTS start set `hasFloor = true`; pause capture; resume once after **route-aware grace** (~1.2s baseline).
2. **No echo:** never overlap TTS+mic; `.playAndRecord + .voiceChat`; do not re-inject TTS into STT.
3. **One-Phone phrase commit:** translate/speak only at **punctuation** OR **stable cutoff ~1.3s** OR **7s cap**.
4. **Per-phrase language lock:** decide at commit via rolling votes; **no mid-phrase flips**; next phrase has **2.0s** retarget window (max 1 flip).
5. **Peer exactly-once:** UUID LRU + `seq` ordering (≤500ms reordering buffer); finals include unsent tail.
6. **Don’t pause the tap during TTS:** only pause processing/emit; keep capture running to fill next phrase.
7. **Privacy:** no transcript logging in prod; telemetry = event codes + timings only.
8. **EN↔ES only** for on-device MT/ASR caches; limit TranslationSession warm pairs to `en→es` & `es→en`.

---

## 3) Commands Palette (how Codex should “work”)

Use these verbs in your plan/output; don’t actually run shell commands—describe changes as patch plans.

* **READ_DOCS**: scan all Charter Pack docs under `docs/`.
* **PATCH**: add/modify files; list functions/classes explicitly.
* **ADD_TESTCASE**: dev‑only shims/flags under `#if DEBUG`.
* **RUN_CHECKS**: compile mentally; verify invariants + acceptance bars.
* **NOTE_TUNABLE**: if constants change, update `docs/TUNABLES.md`.

---

## 4) Coding Standards

* Swift 5+, iOS 26 APIs allowed under availability checks.
* Keep public surface **small**; prefer `private`/`fileprivate`.
* Cancel timers/tasks **before** starting new ones.
* Idempotent `pauseCapture(reason)` / `resumeCapture(targetLang)`; no scattered direct start/stop.
* No blocking UI alerts for audio/session errors; use existing `ErrorBanner`.
* Unit-testable helpers (pure functions) for language vote & segmentation.

---

## 5) Golden Interfaces (must implement/keep)

### 5.1 Turn Context & Phrase Queue (One-Phone)

**New types (in `TranslationViewModel.swift` or a dedicated file):**

```swift
struct TurnContext {
  var rollingText: String = ""
  var lockedSrcBase: String?      // "en" | "es"
  var votes: LangVotes            // struct with running scores & confidences
  var startedAt: Date
  var lastGrowthAt: Date
  var committed: Bool = false
}

struct PhraseCommit {
  let id: UUID
  let srcFull: String    // "en-US" | "es-US" from lock+tiles
  let dstFull: String
  let raw: String
  let decidedAt: TimeInterval
}
```

**Required behavior:**

* Maintain **rolling votes** (NLRecognizer conf, accent hits, stopword ratio, prior).
* Lock `lockedSrcBase` at **commit** only; **no flips** within phrase.
* **Enqueue** `PhraseCommit` into a FIFO `phraseQueue` (new property).
* TTS drains queue while capture continues; if depth > 1, allow **barge-in** or enforce ≤150ms inter-gap.

### 5.2 Sequencing (Peer)

* Extend `MessageData` with `seq: Int`.
* VM maintains `nextSeq` per session; sender increments; receiver buffers ≤500ms waiting for `nextSeq`; otherwise fallback to timestamp ordering.

### 5.3 Route-aware grace

* Extend mic pause/resume wiring: compute grace = 1.2s baseline; if route is Bluetooth or MFi hearing aids, increase toward 1.4–1.6s.

### 5.4 Capability & Offline-only

* On launch (or before first capture/MT), verify iOS 26 EN/ES packs present; if missing, surface inline prompt (non-modal).
* Add a setting (in-memory for now) **Offline Only**; when true, **block** any cloud fallback paths.

### 5.5 Haptics mapping (eyes-up)

* Trigger short, distinct haptics on:

  * `CAPTURE_START`, `PHRASE_COMMIT`, `TTS_START`, `TTS_END`.

---

## 6) Telemetry Events (dev builds)

Emit **only** event names + timings (no transcript):

```
CAPTURE_START(lang)
PARTIAL(len)
PHRASE_COMMIT(len)
LANG_DECIDE(srcLang,conf)
TTS_START(dstLang)
TTS_END
CAPTURE_RESUME(lang)
```

Counters: floorGrabs, micResumes, autoDetectFlips, queueDepth, cancelRetries.
Timings: lastAudio→commit, commit→speak, ttsDuration, resumeLatency.

---

## 7) Acceptance Bars (must hit)

* Commit→TTS start: **p50 ≤ 300ms**, **p95 ≤ 450ms**
* Wrong-language commits: **≤1%** quiet, **≤3%** noisy café
* Echo events: **0** in 30-min session (AirPods/Wired/Speaker)
* Thermal: no stutter over **20 min** continuous dialog
* Reconnect: **≤1** missed turn during **10-s** AWDL drop

---

## 8) Milestones (ordered, independent patches)

### M1 — TurnContext + PhraseQueue (One-Phone)

**Goal:** Phrase-commit pipeline with per-phrase language lock and FIFO queue.
**Definition of done:**

* Phrase commits on punctuation / ~1.3s stable / 7s cap.
* Language locked at commit; **no mid-phrase flips**.
* FIFO queue drains via TTS while capture continues; barge-in or ≤150ms inter-gap.
* Haptics at CAPTURE_START/PHRASE_COMMIT/TTS_START/TTS_END.
* Dev telemetry logs events & timings; no transcript.

### M2 — Sequenced Peer Emission

**Goal:** Deterministic ordering & exactly-once delivery in Peer.
**Definition of done:**

* `MessageData.seq` added; sender increments per turn.
* Receiver buffers ≤500ms for `nextSeq`; fallback to timestamp tie-break.
* Finals include unsent tail; LRU de-dup (≤64) enforced.

### M3 — Route-Aware Grace & Single Resume Token

**Goal:** Robust post-TTS resume without races.
**Definition of done:**

* Compute grace based on audio route (wired/speaker vs BT/MFi).
* Single `resumeAfterTTSTask`; idempotent `resumeCapture(targetLang)`; cancels pending tasks first.

### M4 — Capability Check & Offline-Only Guard

**Goal:** Guarantee offline presence and prevent accidental cloud use.
**Definition of done:**

* Launch-time check for EN/ES on-device packs; inline prompt if missing.
* “Offline Only” setting disables Azure/Text fallbacks (code paths guarded by availability + flag).

---

## 9) Patch Plan Template (Codex must output first)

```
Your Plan (return this section first)

Patch Plan:
- Files (<6 total): list files to add/modify.
- Functions: names to add/replace with brief role.
- Data structs: TurnContext / PhraseCommit / LangVotes additions.
- Risks & rollback: what could break; how to revert.
- Test hooks: dev flags, logs to verify acceptance bars.

Steps:
1) READ_DOCS →  docs/*
2) Implement <feature> in <files>
3) Wire telemetry & haptics
4) Verify against TEST_MATRIX.md
```


## 10) Review Checklist (Codex self-check before returning a patch)

* Invariants held (floor, no echo, no overlap, don’t pause tap).
* One-Phone: commits only at boundary; lock decided at commit; queue present.
* Peer: `seq` added; receiver reorders; finals include tail; LRU enforced.
* Route-aware grace and **single** resume token.
* No new cloud calls; offline-only respected.
* Tunables referenced from one place; if changed, update `Tunables.md`.
* Acceptance bars addressed; add notes if any risk remains.

