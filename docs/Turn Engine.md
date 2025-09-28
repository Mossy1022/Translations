### State machine (per mode)
```
Idle → Capturing → Translating(partials) → Emitting(early-TTS/enqueue) → Speaking(TTS) → Grace → Capturing
```
**Transition rules**
- All transitions go through a single coordinator that first cancels timers / pending tasks.
- While `Speaking(TTS)`, capture may **collect** but emit/translate is paused. Resume once after **grace**.
- `Grace` is route-aware (~1.2s baseline; see Tunables).
- **Interruption handling (lock-screen / phone call):**  
On interruption: pause capture, set `hasFloor=false`, cancel resume timers.  
On resume: `resumeCapture(previousTargetLang)` and rebuild the current **TurnContext**.

**Floor control**
- `hasFloor = true` at TTS start; `false` at TTS finish + grace.
- If `hasFloor == true`, queue capture requests; no immediate reopen.

**Capture APIs (atomic)**
- `pauseCapture(reason)` / `resumeCapture(targetLang)` decide Azure vs Native vs Auto internally.
- UI must **not** call service start/stop directly.

**Per-mode intent on resume**
- **One‑Phone:** resume biased to **other side**.
- **Peer / Convention:** resume biased to **me**.

**Telemetry breadcrumbs**
```
CAPTURE_START(lang)
PARTIAL(len)
PHRASE_COMMIT(len)
LANG_DECIDE(srcLang,conf)
TTS_START(dstLang)
TTS_END
CAPTURE_RESUME(lang)
```

---
